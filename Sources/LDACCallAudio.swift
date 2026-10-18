#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class LDACCallAudio: ObservableObject {
    enum Activity: Equatable { case unknown, idle, active }

    struct Access {
        var microphoneIsActive: () throws -> Bool
        var defaultInputUID: () throws -> String?
        var headsetInputUID: (String) throws -> String?
        var selectInput: (String) throws -> Void
        var defaultOutputUID: () throws -> String?
        var headsetOutputUID: (String) throws -> String?
        var selectOutput: (String) throws -> Void
        var microphoneActivity: (() throws -> [LDACMicrophoneActivity])? = nil

        static var live: Access {
            Access(microphoneIsActive: LDACCallHardware.microphoneIsActive,
                   defaultInputUID: LDACCallHardware.defaultInputUID,
                   headsetInputUID: LDACCallHardware.headsetInputUID,
                   selectInput: LDACCallHardware.selectInput,
                   defaultOutputUID: { try LDACCallHardware.defaultUID(selector: kAudioHardwarePropertyDefaultOutputDevice) },
                   headsetOutputUID: { try LDACCallHardware.headsetUID(address: $0, scope: kAudioObjectPropertyScopeOutput) },
                   selectOutput: { try LDACCallHardware.select(uid: $0, selector: kAudioHardwarePropertyDefaultOutputDevice,
                                                              scope: kAudioObjectPropertyScopeOutput) },
                   microphoneActivity: LDACCallHardware.microphoneActivity)
        }
    }

    @Published private(set) var activity: Activity = .unknown
    @Published private(set) var issue: String?
    @Published private(set) var microphoneActivities: [LDACMicrophoneActivity] = []
    private(set) var policy: LDACMicrophonePolicy = .headset
    private(set) var externalMicrophoneUID: String?
    private(set) var manualHandoffRequested = false
    private var savedExternalInputUID: String?
    private var appliedExternalInputUID: String?
    private let access: Access
    private let now: () -> TimeInterval
    private let pollsAutomatically: Bool
    private var pollTask: Task<Void, Never>?
    private var address: String?
    private var idleSince: TimeInterval?
    private var hasObservedActivity = false
    private var wantsHeadsetInput = false
    private var inputSelected = false
    private var savedInputUID: String?
    private var selectedInputUID: String?
    private var outputSelected = false
    private var savedOutputUID: String?
    private var selectedOutputUID: String?

    init(access: Access = .live, pollsAutomatically: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.access = access
        self.pollsAutomatically = pollsAutomatically
        self.now = now
    }

    func configure(policy: LDACMicrophonePolicy, externalMicrophoneUID: String?) {
        self.policy = policy
        self.externalMicrophoneUID = externalMicrophoneUID
    }

    func setManualHandoff(_ requested: Bool) {
        manualHandoffRequested = requested
        refresh()
    }

    private func restoreExternalInput() {
        if let savedExternalInputUID, let appliedExternalInputUID,
           (try? access.defaultInputUID()) == appliedExternalInputUID {
            try? access.selectInput(savedExternalInputUID)
        }
        savedExternalInputUID = nil
        appliedExternalInputUID = nil
    }

    func monitor(address: String?) {
        guard self.address != address else { return }
        pollTask?.cancel()
        pollTask = nil
        if activity == .idle { _ = finishCall() }
        restoreExternalInput()
        self.address = address
        manualHandoffRequested = false
        microphoneActivities = []
        wantsHeadsetInput = false
        inputSelected = false
        savedInputUID = nil
        selectedInputUID = nil
        outputSelected = false
        savedOutputUID = nil
        selectedOutputUID = nil
        idleSince = nil
        hasObservedActivity = false
        setIssue(nil)
        activity = .unknown
        guard address != nil else { return }
        if policy == .external, let uid = externalMicrophoneUID {
            do {
                let previous = try access.defaultInputUID()
                if previous != uid {
                    try access.selectInput(uid)
                    savedExternalInputUID = previous
                    appliedExternalInputUID = uid
                }
            } catch {
                setIssue(String(localized: "The selected separate microphone is unavailable. LDAC will wait."))
                return
            }
        }
        refresh()
        guard pollsAutomatically else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard address != nil else { return }
        let active: Bool
        do {
            if let observe = access.microphoneActivity {
                let observations = try observe()
                if microphoneActivities != observations { microphoneActivities = observations }
                switch policy {
                case .headset: active = !observations.isEmpty
                case .external:
                    if observations.contains(where: \.isBluetooth) { active = true }
                    else {
                        guard let externalMicrophoneUID, try access.defaultInputUID() == externalMicrophoneUID else {
                            throw LDACMicrophoneError()
                        }
                        active = observations.contains { $0.inputUID != externalMicrophoneUID }
                    }
                case .manual: active = manualHandoffRequested || observations.contains(where: \.isBluetooth)
                }
            } else {
                active = try access.microphoneIsActive() || manualHandoffRequested
            }
        } catch {
            idleSince = nil
            setIssue(String(localized: "Microphone activity could not be checked. LDAC will wait until audio monitoring is available."))
            activity = .unknown
            return
        }
        if active {
            hasObservedActivity = true
            idleSince = nil
        } else if hasObservedActivity, idleSince == nil {
            idleSince = now()
        }
        let waitingForIdle = hasObservedActivity && (idleSince.map { now() - $0 < 3 } ?? true)
        if issue != nil { setIssue(nil) }
        if wantsHeadsetInput, active || waitingForIdle { routeForCall() }
        if !active, !waitingForIdle { hasObservedActivity = false }
        activity = active || waitingForIdle ? .active : .idle
    }

    func routeForCall() {
        wantsHeadsetInput = true
        do { try selectHeadsetAudio() }
        catch {
            setIssue(String(localized: "Headset call audio could not be selected. Select the headset in Sound settings."))
        }
    }

    @discardableResult
    func finishCall() -> Bool {
        do {
            if let savedInputUID, let selectedInputUID,
               try access.defaultInputUID() == selectedInputUID {
                try access.selectInput(savedInputUID)
            }
            if let savedOutputUID, let selectedOutputUID,
               try access.defaultOutputUID() == selectedOutputUID {
                try access.selectOutput(savedOutputUID)
            }
            wantsHeadsetInput = false
            inputSelected = false
            savedInputUID = nil
            selectedInputUID = nil
            outputSelected = false
            savedOutputUID = nil
            selectedOutputUID = nil
            setIssue(nil)
            return true
        } catch {
            setIssue(String(localized: "The previous audio devices could not be restored. Select your audio devices in Sound settings to resume LDAC."))
            return false
        }
    }

    private func setIssue(_ message: String?) {
        if issue != message { issue = message }
    }

    private func selectHeadsetAudio() throws {
        guard let address else { return }
        if !outputSelected, let uid = try access.headsetOutputUID(address) {
            let previous = try access.defaultOutputUID()
            if previous != uid {
                try access.selectOutput(uid)
                savedOutputUID = previous
                selectedOutputUID = uid
            }
            outputSelected = true
        }
        guard !inputSelected, let uid = try access.headsetInputUID(address) else { return }
        let previous = try access.defaultInputUID()
        if previous != uid {
            try access.selectInput(uid)
            savedInputUID = previous
            selectedInputUID = uid
        }
        inputSelected = true
    }
}

private struct LDACMicrophoneError: Error {}

enum LDACCallHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func microphoneIsActive() throws -> Bool {
        try !microphoneActivity().isEmpty
    }

    static func microphoneActivity() throws -> [LDACMicrophoneActivity] {
        let processes = try objects(system, selector: kAudioHardwarePropertyProcessObjectList)
        var incomplete = false
        var result: [LDACMicrophoneActivity] = []
        for process in processes {
            do {
                let running: UInt32 = try read(process, selector: kAudioProcessPropertyIsRunningInput, initial: 0)
                guard running != 0 else { continue }
                let pid: pid_t = try read(process, selector: kAudioProcessPropertyPID, initial: 0)
                let bundleID = try string(process, selector: kAudioProcessPropertyBundleID)
                guard !isAcouplet(pid: pid, bundleID: bundleID) else { continue }
                var pending = try objects(process, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
                guard !pending.isEmpty else { throw HardwareError() }
                var visited = Set<AudioObjectID>()
                while let device = pending.popLast() {
                    guard visited.insert(device).inserted else { continue }
                    if let children = try microphoneSubdevices(device) {
                        pending.append(contentsOf: children)
                    } else if try channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0 {
                        let transport: UInt32 = try read(device, selector: kAudioDevicePropertyTransportType, initial: 0)
                        result.append(.init(processID: pid,
                            processName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID ?? String(localized: "Unknown application"),
                            bundleID: bundleID, inputUID: try string(device, selector: kAudioDevicePropertyDeviceUID),
                            inputName: try string(device, selector: kAudioObjectPropertyName) ?? String(localized: "Unknown microphone"),
                            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE))
                    }
                }
            } catch { incomplete = true }
        }
        guard !incomplete else { throw HardwareError() }
        return result.sorted { $0.processID == $1.processID ? ($0.inputUID ?? "") < ($1.inputUID ?? "") : $0.processID < $1.processID }
    }

    static func audioDevices(scope: AudioObjectPropertyScope) throws -> [LDACAudioDevice] {
        try objects(system, selector: kAudioHardwarePropertyDevices).compactMap { device in
            guard try channelCount(device, scope: scope) > 0,
                  let uid = try string(device, selector: kAudioDevicePropertyDeviceUID), uid != LDACNativeOutput.uid else { return nil }
            let alive: UInt32 = try read(device, selector: kAudioDevicePropertyDeviceIsAlive, initial: 0)
            let transport: UInt32 = try read(device, selector: kAudioDevicePropertyTransportType, initial: 0)
            let kind: AudioClassID = try read(device, selector: kAudioObjectPropertyClass, initial: 0)
            guard alive == 1, kind != kAudioAggregateDeviceClassID, transport != kAudioDeviceTransportTypeVirtual else { return nil }
            return LDACAudioDevice(id: uid, name: try string(device, selector: kAudioObjectPropertyName) ?? uid,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isAcouplet(pid: pid_t, bundleID: String?) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID else { return false }
        return bundleID == "dev.baglayan.Acouplet" || bundleID.hasPrefix("dev.baglayan.Acouplet.")
            || bundleID == "dev.baglayan.Acouplet-debug" || bundleID.hasPrefix("dev.baglayan.Acouplet-debug.")
    }

    static func containsMicrophone(_ devices: [AudioObjectID], channels: (AudioObjectID) throws -> UInt32,
                                   subdevices: (AudioObjectID) throws -> [AudioObjectID]?) throws -> Bool {
        var pending = devices
        var visited = Set<AudioObjectID>()
        while let device = pending.popLast() {
            guard visited.insert(device).inserted else { continue }
            if let children = try subdevices(device) {
                pending.append(contentsOf: children)
            } else if try channels(device) > 0 {
                return true
            }
        }
        return false
    }

    static func microphoneSubdevices(_ device: AudioObjectID) throws -> [AudioObjectID]? {
        let kind: AudioClassID = try read(device, selector: kAudioObjectPropertyClass, initial: 0)
        if kind == kAudioAggregateDeviceClassID {
            return try objects(device, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
        }
        guard kind == kAudioSubDeviceClassID else { return nil }
        guard let uid = try string(device, selector: kAudioDevicePropertyDeviceUID) else { throw HardwareError() }
        var address = property(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var resolved = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &resolved)
        }
        guard status == noErr, size == MemoryLayout<AudioObjectID>.size, resolved != kAudioObjectUnknown else { throw HardwareError() }
        return [resolved]
    }

    static func defaultInputUID() throws -> String? {
        try defaultUID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultUID(selector: AudioObjectPropertySelector) throws -> String? {
        let device: AudioObjectID = try read(system, selector: selector, initial: 0)
        guard device != kAudioObjectUnknown else { return nil }
        return try string(device, selector: kAudioDevicePropertyDeviceUID)
    }

    static func headsetInputUID(address: String) throws -> String? {
        try headsetUID(address: address, scope: kAudioObjectPropertyScopeInput)
    }

    static func headsetUID(address: String, scope: AudioObjectPropertyScope) throws -> String? {
        for device in try objects(system, selector: kAudioHardwarePropertyDevices) {
            guard let uid = try? string(device, selector: kAudioDevicePropertyDeviceUID),
                  let transport: UInt32 = try? read(device, selector: kAudioDevicePropertyTransportType, initial: 0),
                  LDACNativeOutput.canTransferControls(uid: uid, transport: transport, address: address),
                  (try? hasChannels(device, scope: scope)) == true else { continue }
            return uid
        }
        return nil
    }

    static func selectInput(uid: String) throws {
        try select(uid: uid, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeInput)
    }

    static func select(uid: String, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws {
        for device in try objects(system, selector: kAudioHardwarePropertyDevices) {
            guard (try? string(device, selector: kAudioDevicePropertyDeviceUID)) == uid else { continue }
            guard try hasChannels(device, scope: scope) else { throw HardwareError() }
            var property = property(selector)
            var value = device
            guard AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr else {
                throw HardwareError()
            }
            return
        }
        throw HardwareError()
    }

    static func hasChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Bool {
        let alive: UInt32 = try read(device, selector: kAudioDevicePropertyDeviceIsAlive, initial: 0)
        let eligible: UInt32 = try read(device, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                        scope: scope, initial: 0)
        guard alive == 1, eligible == 1 else { return false }
        return try channelCount(device, scope: scope) > 0
    }

    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { throw HardwareError() }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= data.count,
              let channels = MacAudioRoute.channelCount(in: data.prefix(Int(size))) else { throw HardwareError() }
        return channels
    }

    static func objects(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = property(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else { throw HardwareError() }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let capacity = size
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity, size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else { throw HardwareError() }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func read<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = property(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, size == MemoryLayout<T>.size else { throw HardwareError() }
        return value
    }

    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String? {
        let value = try read(object, selector: selector, initial: Optional<Unmanaged<CFString>>.none)
        return value?.takeRetainedValue() as String?
    }

    static func property(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    struct HardwareError: Error {}
}
#endif
