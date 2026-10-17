import Combine
import CoreAudio
import Foundation

struct MacAudioTransport: RawRepresentable, Equatable, Sendable {
    let rawValue: UInt32

    var title: String {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: String(localized: "Built-in")
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth Classic"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeVirtual: String(localized: "Virtual")
        case kAudioDeviceTransportTypeAggregate: String(localized: "Aggregate")
        case kAudioDeviceTransportTypeAutoAggregate: String(localized: "Automatic aggregate")
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeUnknown: String(localized: "Unknown")
        default: String(format: String(localized: "Other (0x%08X)"), rawValue)
        }
    }
}

struct MacAudioRoute: Equatable, Sendable {
    let deviceID: AudioObjectID
    let name: String?
    let uid: String?
    let transport: MacAudioTransport?
    let outputChannels: UInt32?
    let nominalSampleRate: Double?

    var pcmFormatDescription: String {
        let channels = outputChannels.map { String(localized: "\($0) \($0 == 1 ? String(localized: "channel") : String(localized: "channels"))") } ?? String(localized: "Channels unavailable")
        let rate = nominalSampleRate.map { "\(($0 / 1_000).formatted()) kHz" } ?? String(localized: "Sample rate unavailable")
        return "\(channels) · \(rate) PCM"
    }

    var diagnosticReport: String {
        [
            "Mac audio output: Selected; name omitted",
            "Output transport: \(transport?.title ?? "Unknown")",
            "Output format: \(pcmFormatDescription)",
        ].joined(separator: "\n")
    }

    static func channelCount(in data: Data) -> UInt32? {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        guard data.count >= offset else { return nil }
        return data.withUnsafeBytes { bytes in
            let count = Int(bytes.loadUnaligned(as: UInt32.self))
            guard count <= (bytes.count - offset) / MemoryLayout<AudioBuffer>.stride else { return nil }
            var channels: UInt32 = 0
            for index in 0..<count {
                let value = bytes.loadUnaligned(fromByteOffset: offset + index * MemoryLayout<AudioBuffer>.stride, as: UInt32.self)
                let sum = channels.addingReportingOverflow(value)
                guard !sum.overflow else { return nil }
                channels = sum.partialValue
            }
            return channels
        }
    }
}

@MainActor
final class MacAudioRouteObserver: ObservableObject {
    @Published private(set) var route: MacAudioRoute?
    @Published private(set) var error: String?
    private var systemListeners: [MacAudioRouteListener] = []
    private var deviceListeners: [MacAudioRouteListener] = []
    private var systemListenerErrors: [String] = []
    private var deviceListenerErrors: [String] = []
    private var observedDeviceID = AudioObjectID(kAudioObjectUnknown)

    init(startAutomatically: Bool = true) {
        if startAutomatically {
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
                do {
                    systemListeners.append(try listen(to: AudioObjectID(kAudioObjectSystemObject), selector: selector))
                } catch {
                    systemListenerErrors.append(error.localizedDescription)
                }
            }
            refresh()
        }
    }

    var diagnosticReport: String {
        let output = route?.diagnosticReport ?? "Mac audio output: \(error == nil ? "No output selected" : "Unavailable")"
        return output + "\nCoreAudio issue: \(error ?? "None")"
    }

    #if DEBUG
    func simulateRoute(_ route: MacAudioRoute?) {
        self.route = route
    }
    #endif

    func refresh() {
        var errors = systemListenerErrors
        do {
            let deviceID = try read(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
            observeDevice(deviceID)
            errors += deviceListenerErrors
            if deviceID == kAudioObjectUnknown {
                route = nil
            } else {
                func optional<T>(_ read: () throws -> T) -> T? {
                    do { return try read() }
                    catch {
                        errors.append(error.localizedDescription)
                        return nil
                    }
                }
                route = MacAudioRoute(
                    deviceID: deviceID,
                    name: optional { try readString(deviceID, selector: kAudioObjectPropertyName) },
                    uid: optional { try readString(deviceID, selector: kAudioDevicePropertyDeviceUID) },
                    transport: optional { MacAudioTransport(rawValue: try read(deviceID, selector: kAudioDevicePropertyTransportType, initial: UInt32(0))) },
                    outputChannels: optional { try readChannels(deviceID) },
                    nominalSampleRate: optional {
                        let value = try read(deviceID, selector: kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
                        guard value.isFinite, value > 0 else {
                            throw MacAudioRouteError(message: "CoreAudio returned an invalid nominal sample rate: \(value).")
                        }
                        return value
                    }
                )
            }
        } catch {
            observeDevice(AudioObjectID(kAudioObjectUnknown))
            route = nil
            errors.append(error.localizedDescription)
        }
        error = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func observeDevice(_ deviceID: AudioObjectID) {
        guard deviceID != observedDeviceID else { return }
        deviceListeners = []
        deviceListenerErrors = []
        observedDeviceID = deviceID
        guard deviceID != kAudioObjectUnknown else { return }
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        ]
        for (selector, scope) in properties {
            do {
                deviceListeners.append(try listen(to: deviceID, selector: selector, scope: scope))
            } catch {
                deviceListenerErrors.append(error.localizedDescription)
            }
        }
    }

    private func listen(to objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> MacAudioRouteListener {
        var address = Self.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
        guard status == noErr else { throw MacAudioRouteError(objectID: objectID, selector: selector, operation: "observe", status: status) }
        return MacAudioRouteListener(objectID: objectID, address: address, block: block)
    }

    private func read<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = Self.address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw MacAudioRouteError(objectID: objectID, selector: selector, operation: "read", status: status) }
        guard size == MemoryLayout<T>.size else {
            throw MacAudioRouteError(message: "CoreAudio returned an invalid size for property \(selector) on device \(objectID): \(size).")
        }
        return value
    }

    private func readString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        let value = try read(objectID, selector: selector, initial: Optional<Unmanaged<CFString>>.none)
        guard let value else {
            throw MacAudioRouteError(message: "CoreAudio returned no string for property \(selector) on device \(objectID).")
        }
        return value.takeRetainedValue() as String
    }

    private func readChannels(_ objectID: AudioObjectID) throws -> UInt32 {
        let selector = kAudioDevicePropertyStreamConfiguration
        var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw MacAudioRouteError(objectID: objectID, selector: selector, operation: "read size of", status: status) }
        guard size >= MemoryLayout<UInt32>.size else {
            throw MacAudioRouteError(message: "CoreAudio returned an empty output stream configuration for device \(objectID).")
        }
        var data = Data(count: Int(size))
        status = data.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw MacAudioRouteError(objectID: objectID, selector: selector, operation: "read", status: status) }
        guard size <= data.count, let channels = MacAudioRoute.channelCount(in: data.prefix(Int(size))) else {
            throw MacAudioRouteError(message: "CoreAudio returned an invalid output stream configuration for device \(objectID).")
        }
        return channels
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

private struct MacAudioRouteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(message: String) {
        self.message = message
    }

    init(objectID: AudioObjectID, selector: AudioObjectPropertySelector, operation: String, status: OSStatus) {
        message = String(format: "Could not %@ CoreAudio property 0x%08X on device %u (OSStatus %d).", operation, selector, objectID, status)
    }
}

private final class MacAudioRouteListener {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = address
        self.block = block
    }

    deinit {
        var address = address
        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        if status != noErr, status != kAudioHardwareBadObjectError {
            NSLog("Could not remove CoreAudio route listener on device %u (OSStatus %d).", objectID, status)
        }
    }
}
