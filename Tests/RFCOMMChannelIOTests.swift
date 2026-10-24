import Foundation
import Darwin
@preconcurrency import IOBluetooth
import XCTest
@testable import Acouplet

final class RFCOMMChannelIOTests: XCTestCase {
    @MainActor
    func testSocketWritesRemainSeparateUntilThePeerConsumesEachFrame() async throws {
        for _ in 0..<20 {
            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            let sender = descriptors[0]
            let receiver = descriptors[1]
            defer { Darwin.close(sender); Darwin.close(receiver) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            XCTAssertEqual(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
            let channel = SocketChannel(descriptor: sender)
            let io = RFCOMMChannelIO(channel: channel)
            let completed = expectation(description: "Separated writes completed")
            completed.expectedFulfillmentCount = 2
            let received = expectation(description: "Peer read separate frames")
            for data in [Data([1, 2]), Data([3, 4, 5])] {
                io.write(data) { status in
                    XCTAssertEqual(status, kIOReturnSuccess)
                    completed.fulfill()
                }
            }
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.02)
                var bytes = [UInt8](repeating: 0, count: 8)
                XCTAssertEqual(read(receiver, &bytes, bytes.count), 2)
                XCTAssertEqual(Array(bytes.prefix(2)), [1, 2])
                Thread.sleep(forTimeInterval: 0.01)
                XCTAssertEqual(read(receiver, &bytes, bytes.count), 3)
                XCTAssertEqual(Array(bytes.prefix(3)), [3, 4, 5])
                received.fulfill()
            }
            await fulfillment(of: [received, completed], timeout: 4)
        }
    }

    @MainActor
    func testSocketDrainFailsClosedForInvalidClosedAndStalledPeers() async {
        for failure in ["invalid", "closed", "stalled"] {
            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            defer { Darwin.close(descriptors[0]); if descriptors[1] >= 0 { Darwin.close(descriptors[1]) } }
            if failure == "closed" { Darwin.close(descriptors[1]); descriptors[1] = -1 }
            let channel = SocketChannel(descriptor: failure == "invalid" ? -1 : descriptors[0])
            let io = RFCOMMChannelIO(channel: channel)
            let completed = expectation(description: "Unsafe write rejected")
            io.write(Data([1, 2])) { status in
                XCTAssertEqual(status, failure == "stalled" ? kIOReturnTimeout : kIOReturnNotOpen)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 4)
        }
    }

    @MainActor
    func testCloseCancelsAnUndrainedSocketWrite() async {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let sender = descriptors[0]
        let receiver = descriptors[1]
        defer { Darwin.close(sender); Darwin.close(receiver) }
        let io = RFCOMMChannelIO(channel: SocketChannel(descriptor: sender))
        let received = expectation(description: "Write reached peer buffer")
        let completed = expectation(description: "Undrained write cancelled")
        let closed = expectation(description: "Transport closed")
        io.write(Data([1, 2])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            completed.fulfill()
        }
        DispatchQueue.global().async {
            var descriptor = pollfd(fd: receiver, events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(poll(&descriptor, 1, 1000), 1)
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 2)
        io.close { _, _ in closed.fulfill() }
        io.didClose()
        await fulfillment(of: [completed, closed], timeout: 1)
    }

    @MainActor
    func testBlockedWriteRetainsChannelAndDataWithoutBlockingMain() async {
        let started = expectation(description: "Write started")
        let completed = expectation(description: "Write completed")
        let released = expectation(description: "Data released")
        let release = DispatchSemaphore(value: 0)
        var channel: TestChannel? = TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        weak var retainedChannel = channel
        var io: RFCOMMChannelIO? = RFCOMMChannelIO(channel: channel!)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 1)
        pointer.initializeMemory(as: UInt8.self, repeating: 7, count: 64)
        var data: Data? = Data(bytesNoCopy: pointer, count: 64, deallocator: .custom { @Sendable pointer, _ in
            pointer.deallocate()
            released.fulfill()
        })
        io?.write(data!) { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(status, kIOReturnSuccess)
            completed.fulfill()
        }
        data = nil
        channel = nil
        io = nil

        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(retainedChannel)
        let responsive = expectation(description: "Main queue responsive")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        let survivingChannel = retainedChannel
        release.signal()
        await fulfillment(of: [completed, released], timeout: 2)
        XCTAssertEqual(survivingChannel?.writes, [Data(repeating: 7, count: 64)])
    }

    @MainActor
    func testWritesAreFIFOAndCompleteOnMain() async {
        let completed = expectation(description: "Writes completed")
        completed.expectedFulfillmentCount = 3
        let channel = TestChannel()
        let io = RFCOMMChannelIO(channel: channel)
        for value: UInt8 in [1, 2, 3] {
            io.write(Data([value])) { status in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(status, kIOReturnSuccess)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1]), Data([2]), Data([3])])
    }

    @MainActor
    func testCloseRetiresQueuedWritesAndWaitsForBlockedWrite() async {
        let started = expectation(description: "Write started")
        let closeReturned = expectation(description: "Native close returned")
        let wrote = expectation(description: "Write returned")
        let cancelled = expectation(description: "Queued writes cancelled")
        cancelled.expectedFulfillmentCount = 2
        let closed = expectation(description: "Close completed")
        let closedEarly = expectation(description: "Close must not complete while blocked")
        closedEarly.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }, onClose: { closeReturned.fulfill() })
        let io = RFCOMMChannelIO(channel: channel)
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnSuccess)
            wrote.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        io.write(Data([2])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        io.close { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            closedEarly.fulfill()
            closed.fulfill()
        }
        io.close { _, _ in XCTFail("Duplicate close completed") }
        io.write(Data([3])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        await fulfillment(of: [closeReturned], timeout: 2)
        io.didClose()
        await fulfillment(of: [closedEarly], timeout: 0.1)
        release.signal()
        await fulfillment(of: [wrote, cancelled, closed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1])])
        XCTAssertEqual(channel.closeCount, 1)
    }

    @MainActor
    func testCloseCompletionAlsoWaitsForNativeClose() async {
        let started = expectation(description: "Native close started")
        let closed = expectation(description: "Close completed")
        let closedEarly = expectation(description: "Close must not complete while blocked")
        closedEarly.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onClose: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        io.close { _, _ in
            closedEarly.fulfill()
            closed.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        io.didClose()
        await fulfillment(of: [closedEarly], timeout: 0.1)
        release.signal()
        await fulfillment(of: [closed], timeout: 2)
    }

    @MainActor
    func testCloseReleasesChannelOffMainBeforeCompletingWhileIORemainsRetained() async {
        let released = expectation(description: "Channel released")
        let closed = expectation(description: "Close completed")
        var channel: TestChannel? = TestChannel(onDeinit: {
            XCTAssertFalse(Thread.isMainThread)
            released.fulfill()
        })
        weak var retainedChannel = channel
        let io = RFCOMMChannelIO(channel: channel!)
        channel = nil
        io.close { _, _ in
            XCTAssertNil(retainedChannel)
            closed.fulfill()
        }
        io.didClose()
        await fulfillment(of: [released, closed], timeout: 2)
        withExtendedLifetime(io) {}
    }

    @MainActor
    func testCloseReportsNativeFailuresAfterRetiringWrites() async {
        let closed = expectation(description: "Close results returned")
        let cancelled = expectation(description: "Retired write rejected")
        let channel = TestChannel(delegateStatus: kIOReturnError, closeStatus: kIOReturnTimeout)
        let io = RFCOMMChannelIO(channel: channel)
        io.close { delegateStatus, closeStatus in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(delegateStatus, kIOReturnError)
            XCTAssertEqual(closeStatus, kIOReturnTimeout)
            closed.fulfill()
        }
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        io.didClose()
        await fulfillment(of: [closed, cancelled], timeout: 2)
        XCTAssertTrue(channel.writes.isEmpty)
        XCTAssertEqual(channel.closeCount, 1)
    }

    @MainActor
    func testCloseReturnKeepsDelegateUntilTerminalEventAndCallbackUnwinds() async {
        let returned = expectation(description: "Native close returned")
        let drained = expectation(description: "Retired write queue drained")
        let closed = expectation(description: "Retirement completed")
        let channel = TestChannel(onClose: { returned.fulfill() })
        let io = RFCOMMChannelIO(channel: channel)
        var callbackReturned = false
        var completions = 0
        io.close { _, _ in
            XCTAssertTrue(callbackReturned)
            completions += 1
            closed.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(channel.delegateClearCount, 0)
        io.didClose()
        io.didClose()
        XCTAssertEqual(completions, 0)
        callbackReturned = true
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(channel.delegateClearCount, 1)
    }

    @MainActor
    func testRetiredOpeningWaitsForLateSuccessThenClosesAgain() async {
        let firstClose = expectation(description: "Opening close requested")
        let lateClose = expectation(description: "Late successful open closed")
        let closed = expectation(description: "Retirement completed")
        let channel = TestChannel(onCloseNumber: { count in
            if count == 1 { firstClose.fulfill() }
            else if count == 2 { lateClose.fulfill() }
            else { XCTFail("Duplicate native close") }
        })
        let io = RFCOMMChannelIO(channel: channel, opening: true)
        var completions = 0
        io.close { _, _ in completions += 1; closed.fulfill() }
        await fulfillment(of: [firstClose], timeout: 2)
        XCTAssertEqual(completions, 0)
        io.didOpen(status: kIOReturnSuccess)
        io.didOpen(status: kIOReturnSuccess)
        await fulfillment(of: [lateClose], timeout: 2)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(channel.delegateClearCount, 0)
        io.didClose()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(channel.closeCount, 2)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testRetiredOpeningSettlesOnFailureOrDeviceDisconnectWithoutCloseCallback() async {
        for failedOpen in [true, false] {
            let returned = expectation(description: "Opening close returned")
            let closed = expectation(description: "Opening retirement completed")
            let channel = TestChannel(onClose: { returned.fulfill() })
            let io = RFCOMMChannelIO(channel: channel, opening: true)
            io.close { _, _ in closed.fulfill() }
            await fulfillment(of: [returned], timeout: 2)
            XCTAssertEqual(channel.delegateClearCount, 0)
            if failedOpen { io.didOpen(status: kIOReturnNotOpen) }
            else { io.didDisconnect() }
            await fulfillment(of: [closed], timeout: 2)
            XCTAssertEqual(channel.closeCount, 1)
            XCTAssertEqual(channel.delegateClearCount, 1)
        }
    }

    @MainActor
    func testQueuedStopCannotConfirmSilenceBeforeNativeWriteAdmission() async throws {
        let started = expectation(description: "Preceding write started")
        let completed = expectation(description: "Writes completed")
        completed.expectedFulfillmentCount = 2
        let admitted = expectation(description: "Stop admitted")
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onFirstWrite: {
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        io.write(Data([1]), willSend: {
            started.fulfill()
            return true
        }) { _ in completed.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        var session = EarbudFindingSession(target: .left, timeoutSeconds: 30)
        _ = session.begin()
        _ = session.connectionOpened()
        let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30))
        XCTAssertTrue(session.commandWillSend(command))
        XCTAssertEqual(session.stop(), [.send(.stop)])
        io.write(try XCTUnwrap(FastPairRingCommand.stop.message.encoded), willSend: {
            XCTAssertTrue(Thread.isMainThread)
            let allowed = session.commandWillSend(.stop)
            admitted.fulfill()
            return allowed
        }) { status in
            XCTAssertEqual(status, kIOReturnSuccess)
            completed.fulfill()
        }
        let stopped = try XCTUnwrap(FastPairRingStatus(payload: [0]))
        XCTAssertEqual(session.receive(.acknowledgement(stopped)), [])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        release.signal()
        release.signal()
        await fulfillment(of: [admitted, completed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1]), try XCTUnwrap(FastPairRingCommand.stop.message.encoded)])
        XCTAssertEqual(session.receive(.acknowledgement(stopped)), [.close])
        XCTAssertFalse(session.mayBeRinging)
    }

    final class SocketChannel: RFCOMMChannel, @unchecked Sendable {
        let writeSocketDescriptor: Int32?

        init(descriptor: Int32) { writeSocketDescriptor = descriptor }
        func isOpen() -> Bool { true }
        func getMTU() -> BluetoothRFCOMMMTU { 127 }
        func setDelegate(_ delegate: Any!) -> IOReturn { kIOReturnSuccess }
        func close() -> IOReturn { kIOReturnSuccess }
        func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
            Darwin.write(writeSocketDescriptor!, data, Int(length)) == Int(length) ? kIOReturnSuccess : kIOReturnError
        }
    }

    final class TestChannel: FastPairChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedWrites: [Data] = []
        private var recordedCloseCount = 0
        private var recordedDelegateClearCount = 0
        private let onFirstWrite: @Sendable () -> Void
        private let onClose: @Sendable () -> Void
        private let onCloseNumber: @Sendable (Int) -> Void
        private let onDeinit: @Sendable () -> Void
        private let delegateStatus: IOReturn
        private let closeStatus: IOReturn

        var writes: [Data] { lock.withLock { recordedWrites } }
        var closeCount: Int { lock.withLock { recordedCloseCount } }
        var delegateClearCount: Int { lock.withLock { recordedDelegateClearCount } }

        init(onFirstWrite: @escaping @Sendable () -> Void = {}, onClose: @escaping @Sendable () -> Void = {},
             onCloseNumber: @escaping @Sendable (Int) -> Void = { _ in },
             onDeinit: @escaping @Sendable () -> Void = {},
             delegateStatus: IOReturn = kIOReturnSuccess, closeStatus: IOReturn = kIOReturnSuccess) {
            self.onFirstWrite = onFirstWrite
            self.onClose = onClose
            self.onCloseNumber = onCloseNumber
            self.onDeinit = onDeinit
            self.delegateStatus = delegateStatus
            self.closeStatus = closeStatus
        }

        deinit { onDeinit() }

        func isOpen() -> Bool { true }
        func isTransmissionPaused() -> Bool { false }
        func getMTU() -> BluetoothRFCOMMMTU { 127 }

        func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            if lock.withLock({ recordedWrites.isEmpty }) { onFirstWrite() }
            lock.withLock { recordedWrites.append(Data(bytes: data, count: Int(length))) }
            return kIOReturnSuccess
        }

        func setDelegate(_ delegate: Any!) -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(delegate)
            lock.withLock { recordedDelegateClearCount += 1 }
            return delegateStatus
        }

        func close() -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            lock.withLock { recordedCloseCount += 1 }
            onClose()
            onCloseNumber(closeCount)
            return closeStatus
        }
    }
}
