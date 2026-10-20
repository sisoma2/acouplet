#if !ACOUPLET_PUBLIC_APIS_ONLY
import XCTest
@testable import Acouplet

@MainActor
final class LDACVolumeSessionTests: XCTestCase {
    func testWritesCoalesceAndConfigureOnlyTheConfirmedVolume() async throws {
        let harness = Harness()
        harness.session.pendingVolume = 15
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.session.pendingVolume = 18
        harness.send()
        harness.completeWrite()
        try await waitUntil { harness.writes.count == 1 }
        XCTAssertEqual(harness.writes.first?.volume, 18)
        XCTAssertTrue(harness.configurations.isEmpty)
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
        XCTAssertEqual(harness.headphoneVolume, 18)
        XCTAssertEqual(harness.configurations, [18])
        XCTAssertNil(harness.session.pendingVolume)
    }

    func testHeldBindingWaitsWithoutWritingOrFailing() async throws {
        let harness = Harness()
        harness.binding = .held("inventory-stale", transition: false)
        harness.session.pendingVolume = 15
        harness.send()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertTrue(harness.failures.isEmpty)
        XCTAssertEqual(harness.session.pendingVolume, 15)
        harness.binding = .current
        try await waitUntil { harness.writes.count == 1 }
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
    }

    func testCancelledWriteCannotTransmitOrClearItsReplacement() async throws {
        let harness = Harness()
        harness.session.pendingVolume = 15
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.session.cancel()
        harness.sessionID = UUID()
        harness.session.pendingVolume = 18
        harness.send()
        try await waitUntil { harness.writes.count == 2 }
        XCTAssertFalse(try XCTUnwrap(harness.writes.first).isCurrent())
        XCTAssertTrue(try XCTUnwrap(harness.writes.last).isCurrent())
        harness.completeWrite()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(harness.session.isWriting)
        XCTAssertTrue(harness.configurations.isEmpty)
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
        XCTAssertEqual(harness.configurations, [18])
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testQueuedWriteRechecksBindingAndRawTransport() async throws {
        for binding in [LDACMusicBinding.Status.held("refresh", transition: false), .lost("session"), .sourceChanged("source")] {
            let harness = Harness()
            harness.session.pendingVolume = 15
            harness.send()
            try await waitUntil { harness.writes.count == 1 }
            let write = try XCTUnwrap(harness.writes.first)
            harness.hasRawTransport = false
            XCTAssertFalse(write.isCurrent())
            harness.hasRawTransport = true
            harness.binding = binding
            XCTAssertFalse(write.isCurrent())
            harness.completeWrite()
            try await waitUntil { !harness.session.isWriting }
        }
    }

    func testSourceChangeAfterWriteIsReportedWithoutConfiguringOutput() async throws {
        let harness = Harness()
        harness.session.pendingVolume = 15
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.completeWrite()
        harness.binding = .sourceChanged("selected-source")
        try await waitUntil { !harness.session.isWriting }
        XCTAssertEqual(harness.failures, [.sourceChanged("selected-source")])
        XCTAssertTrue(harness.configurations.isEmpty)
    }

    func testHeldBindingDefersAConfigureFailureUsingNativeVolume() async throws {
        let harness = Harness()
        harness.failConfigurationWhileHeld = true
        harness.session.pendingVolume = 15
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
        XCTAssertEqual(harness.deferred, 1)
        XCTAssertEqual(harness.session.pendingVolume, 12)
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testNativeVolumeEchoDoesNotConfigureOutputAgain() async throws {
        let harness = Harness()
        harness.nativeVolume = 15
        harness.session.pendingVolume = 15
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
        XCTAssertTrue(harness.configurations.isEmpty)
    }

    func testInvalidRangeAndLostBindingNeverWrite() async throws {
        for binding in [LDACMusicBinding.Status.current, .lost("control-session-changed")] {
            let harness = Harness()
            harness.binding = binding
            harness.session.pendingVolume = 31
            harness.send()
            try await waitUntil { !harness.session.isWriting }
            XCTAssertEqual(harness.failures, [binding])
            XCTAssertTrue(harness.writes.isEmpty)
        }
    }

    func testContextLostBeforeTaskStartsReleasesTheWriter() async throws {
        let harness = Harness()
        harness.session.pendingVolume = 15
        harness.send()
        harness.isActive = false
        try await waitUntil { !harness.session.isWriting }
        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertEqual(harness.session.pendingVolume, 15)
        harness.isActive = true
        harness.send()
        try await waitUntil { harness.writes.count == 1 }
        harness.completeWrite()
        try await waitUntil { !harness.session.isWriting }
        XCTAssertEqual(harness.configurations, [15])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    @MainActor
    private final class Harness {
        struct Write {
            let volume: Int
            let isCurrent: @MainActor () -> Bool
            let continuation: CheckedContinuation<Void, Error>
        }

        let session = LDACVolumeSession()
        var isActive = true
        var sessionID = UUID()
        var binding = LDACMusicBinding.Status.current
        var hasRawTransport = true
        var headphoneVolume = 12
        var nativeVolume = 12
        var writes: [Write] = []
        var configurations: [Int] = []
        var failures: [LDACMusicBinding.Status] = []
        var deferred = 0
        var failConfigurationWhileHeld = false

        func send() {
            session.send(using: .init(
                context: {
                    guard self.isActive else { return nil }
                    return .init(sessionID: self.sessionID, binding: self.binding, hasRawTransport: self.hasRawTransport,
                                 volumeRange: 0...30, canWrite: true, headphoneVolume: self.headphoneVolume, nativeVolume: self.nativeVolume)
                },
                write: { volume, isCurrent in
                    try await withCheckedThrowingContinuation {
                        self.writes.append(Write(volume: volume, isCurrent: isCurrent, continuation: $0))
                    }
                },
                configure: { volume, _ in
                    if self.failConfigurationWhileHeld {
                        self.binding = .held("inventory-stale", transition: false)
                        throw LDACVolumeSession.Failure.unconfirmed
                    }
                    self.configurations.append(volume)
                    self.nativeVolume = volume
                },
                record: { _, _ in },
                failed: { _, binding in self.failures.append(binding) },
                deferred: { self.deferred += 1 }))
        }

        func completeWrite() {
            guard !writes.isEmpty else { return }
            let write = writes.removeFirst()
            if write.isCurrent() {
                headphoneVolume = write.volume
                write.continuation.resume()
            } else {
                write.continuation.resume(throwing: CancellationError())
            }
        }
    }
}

final class LDACMusicBindingTests: XCTestCase {
    func testBindingFailuresTakePriorityOverTransientFreshness() {
        var context = currentContext
        XCTAssertEqual(LDACMusicBinding.check(context), .current)
        context.pendingTransition = "keeping"
        XCTAssertEqual(LDACMusicBinding.check(context), .held("transition=keeping", transition: true))
        context.boundSession = nil
        XCTAssertEqual(LDACMusicBinding.check(context), .lost("control-session-changed"))
        context.matchesController = false
        XCTAssertEqual(LDACMusicBinding.check(context), .lost("controller-changed"))
    }

    func testStaleInventoryHoldsSourceChangesUntilConfirmed() {
        var context = currentContext
        context.selectedSource = "other"
        context.inventoryIsStale = true
        XCTAssertEqual(LDACMusicBinding.check(context), .held("inventory-stale", transition: false))
        context.inventoryIsStale = false
        XCTAssertEqual(LDACMusicBinding.check(context), .sourceChanged("selected-source"))
        context.selectedSource = nil
        XCTAssertEqual(LDACMusicBinding.check(context), .held("source-unconfirmed", transition: false))
    }

    func testRangeChangesAndLegacyRawOwnershipInvalidateBinding() {
        var context = currentContext
        context.volumeRange = nil
        XCTAssertEqual(LDACMusicBinding.check(context), .held("volume-range-unknown", transition: false))
        context.volumeRange = 0...100
        XCTAssertEqual(LDACMusicBinding.check(context), .lost("volume-range-changed"))
        context.volumeRange = context.boundVolumeRange
        context.requiresRawTransport = true
        context.hasRawTransport = false
        XCTAssertEqual(LDACMusicBinding.check(context), .lost("raw-transport-missing"))
        context.requiresRawTransport = false
        XCTAssertEqual(LDACMusicBinding.check(context), .current)
    }

    func testOnlyCurrentAndHeldBindingsAcceptConfirmations() {
        XCTAssertTrue(LDACMusicBinding.Status.current.acceptsConfirmation)
        XCTAssertTrue(LDACMusicBinding.Status.held("refresh", transition: false).acceptsConfirmation)
        XCTAssertFalse(LDACMusicBinding.Status.sourceChanged("other").acceptsConfirmation)
        XCTAssertFalse(LDACMusicBinding.Status.lost("disconnected").acceptsConfirmation)
        var context = currentContext
        context.hasOwnedMusicContext = false
        XCTAssertEqual(LDACMusicBinding.check(context), .held("source-context-stale", transition: false))
        context.hasCurrentVolumeControl = false
        XCTAssertEqual(LDACMusicBinding.check(context), .held("volume-controls-stale", transition: false))
        context.isLeavingConnectionMode = true
        XCTAssertEqual(LDACMusicBinding.check(context), .sourceChanged("connection-mode"))
        context.isConnected = false
        XCTAssertEqual(LDACMusicBinding.check(context), .lost("device-disconnected"))
    }

    private var currentContext: LDACMusicBinding.Context {
        .init(matchesController: true, isConnected: true, session: 7, boundSession: 7,
              requiresRawTransport: false, hasRawTransport: true, isLeavingConnectionMode: false,
              selectedSource: "local", boundSource: "local", inventoryIsStale: false,
              volumeRange: 0...30, boundVolumeRange: 0...30, pendingTransition: nil,
              hasOwnedMusicContext: true, hasCurrentVolumeControl: true)
    }
}
#endif
