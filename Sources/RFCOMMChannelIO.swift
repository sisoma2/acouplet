import Foundation
import Darwin
import OSLog
@preconcurrency import IOBluetooth

protocol RFCOMMChannel: AnyObject {
    func isOpen() -> Bool
    func getMTU() -> BluetoothRFCOMMMTU
    func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn
    func setDelegate(_ delegate: Any!) -> IOReturn
    func close() -> IOReturn
    var writeSocketDescriptor: Int32? { get }
}

extension RFCOMMChannel {
    var writeSocketDescriptor: Int32? { nil }
}

extension IOBluetoothRFCOMMChannel: RFCOMMChannel {
    var writeSocketDescriptor: Int32? {
        #if ACOUPLET_PUBLIC_APIS_ONLY
        nil
        #else
        guard responds(to: NSSelectorFromString("rfcommchannel")),
              let transport = value(forKey: "rfcommchannel") as? NSObject,
              transport.responds(to: NSSelectorFromString("socketFD")),
              let descriptor = transport.value(forKey: "socketFD") as? NSNumber else { return nil }
        return descriptor.int32Value
        #endif
    }
}

final class RFCOMMChannelIO: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "RFCOMMChannelIO")
    private var channel: (any RFCOMMChannel)?
    private let writeQueue = DispatchQueue(label: "dev.baglayan.Acouplet.rfcomm-write", qos: .utility)
    private let lock = NSLock()
    private var retired = false

    init(channel: any RFCOMMChannel) {
        self.channel = channel
    }

    @MainActor
    func write(_ data: Data, willSend: (@MainActor @Sendable () -> Bool)? = nil, completion: @escaping @MainActor @Sendable (IOReturn) -> Void) {
        writeQueue.async {
            let retired = self.lock.withLock { self.retired }
            guard !retired else {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            if let willSend, !DispatchQueue.main.sync(execute: { willSend() }) {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            let result = self.writeBuffer(data)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func writeBuffer(_ data: Data) -> IOReturn {
        let queue: Int32
        var event = kevent()
        let baseline: Int
        if let descriptor = channel!.writeSocketDescriptor {
            guard descriptor >= 0 else { return kIOReturnNotOpen }
            queue = kqueue()
            guard queue >= 0 else { return kIOReturnNoResources }
            var change = kevent(ident: UInt(descriptor), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_ENABLE),
                                fflags: 0, data: 0, udata: nil)
            var immediate = timespec(tv_sec: 0, tv_nsec: 0)
            guard kevent(queue, &change, 1, &event, 1, &immediate) == 1,
                  event.flags & UInt16(EV_ERROR | EV_EOF) == 0, event.data >= data.count else {
                Darwin.close(queue)
                return kIOReturnNotOpen
            }
            baseline = event.data
        } else {
            queue = -1
            baseline = 0
        }
        defer { if queue >= 0 { Darwin.close(queue) } }
        var buffer = data
        let result = buffer.withUnsafeMutableBytes {
            channel!.writeSync($0.baseAddress, length: UInt16($0.count))
        }
        guard result == kIOReturnSuccess, queue >= 0 else { return result }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            guard !lock.withLock({ retired }) else { return kIOReturnAborted }
            var interval = timespec(tv_sec: 0, tv_nsec: 1_000_000)
            let count = kevent(queue, nil, 0, &event, 1, &interval)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count == 0 || event.flags & UInt16(EV_ERROR | EV_EOF) == 0 else { return kIOReturnNotOpen }
            if count == 1, event.data >= baseline { return kIOReturnSuccess }
            Thread.sleep(forTimeInterval: 0.001)
        }
        Self.logger.error("Control write drain timed out; baseline=\(baseline) remainingCapacity=\(event.data) length=\(data.count) flags=\(event.flags)")
        return kIOReturnTimeout
    }

    @MainActor
    func close(completion: @escaping @MainActor @Sendable () -> Void) {
        let alreadyRetired = lock.withLock {
            let previous = retired
            retired = true
            return previous
        }
        guard !alreadyRetired else { return }
        DispatchQueue.global(qos: .utility).async {
            self.channel!.setDelegate(nil)
            self.channel!.close()
            self.writeQueue.async {
                self.channel = nil
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
