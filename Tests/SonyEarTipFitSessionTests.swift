import XCTest
@testable import Acouplet

final class SonyEarTipFitSessionTests: XCTestCase {
    @MainActor
    func testDiscoveryRequiresTransmissionAndTheOwningConnection() throws {
        let session = SonyEarTipFitSession()
        session.begin(session: 7, supportedFunctions: [0xF6])
        XCTAssertFalse(session.hasTimeout)
        let queries = advance(session)
        XCTAssertEqual(queries, session.transition?.initialQueries)
        XCTAssertTrue(advance(session).isEmpty)
        for payload in replies {
            XCTAssertEqual(session.receive(payload, session: 7)?.owned, false)
            session.transmitted([payload[0] - 1, payload[1]], session: 8)
            XCTAssertEqual(session.receive(payload, session: 7)?.owned, false)
            session.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertEqual(session.receive(payload, session: 8)?.parsed, false)
            XCTAssertEqual(session.receive(payload, session: 7)?.parsed, true)
        }
        XCTAssertEqual(session.transition?.phase, .ready)
        XCTAssertNotNil(session.model.capability)
        XCTAssertTrue(advance(session).isEmpty)
        XCTAssertFalse(session.hasTimeout)
    }

    @MainActor
    func testCancelledTimeoutCannotInterruptAReplacementAttempt() async throws {
        let session = SonyEarTipFitSession()
        session.begin(session: 7, supportedFunctions: [0xF6])
        session.transmitted(SonyEarTipFit.capabilityQueryPayload, session: 7)
        var expired = 0
        _ = advance(session, onTimeout: { expired += 1 })
        let timeout = try XCTUnwrap(session.simulatedTimeout)
        timeout.perform()
        session.clear()
        session.begin(session: 7, supportedFunctions: [0xF6])
        let replacement = try XCTUnwrap(session.transition?.id)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(expired, 0)
        XCTAssertEqual(session.transition?.id, replacement)
        XCTAssertEqual(session.transition?.phase, .checking)
        XCTAssertFalse(session.hasTimeout)
    }

    @MainActor
    func testTimeoutRequiresCurrentControlConnection() async throws {
        let session = SonyEarTipFitSession()
        session.begin(session: 7, supportedFunctions: [0xF6])
        session.transmitted(SonyEarTipFit.capabilityQueryPayload, session: 7)
        var current = true
        var expired = 0
        _ = session.advance(session: 7, isReady: true, canStart: false, commandPending: false,
                            isCurrent: { current }, onTimeout: { expired += 1 })
        current = false
        try XCTUnwrap(session.simulatedTimeout).perform()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(expired, 0)
        session.clear()
    }

    @MainActor
    func testNewConnectionCannotAdoptAnOldTransitionsTimeout() async throws {
        let session = SonyEarTipFitSession()
        session.begin(session: 7, supportedFunctions: [0xF6])
        session.transmitted(SonyEarTipFit.capabilityQueryPayload, session: 7)
        var expired = 0
        _ = session.advance(session: 8, isReady: true, canStart: false, commandPending: false,
                            isCurrent: { true }, onTimeout: { expired += 1 })
        try XCTUnwrap(session.simulatedTimeout).perform()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(expired, 0)
        XCTAssertEqual(session.transition?.phase, .checking)
        session.clear()
    }

    @MainActor
    func testMeasurementCommandsWaitForTransportAdmissionAndTransmission() throws {
        let session = ready()
        let identifier = try XCTUnwrap(session.transition?.id)
        XCTAssertFalse(session.start(id: UUID()))
        XCTAssertTrue(session.start(id: identifier))
        XCTAssertTrue(advance(session, commandPending: true).isEmpty)
        XCTAssertEqual(advance(session), [SonyEarTipFit.enterModePayload])
        XCTAssertEqual(session.receive(modeIn, session: 7)?.parsed, true)
        XCTAssertEqual(session.transition?.phase, .entering)
        session.transmitted(SonyEarTipFit.enterModePayload, session: 7)
        XCTAssertTrue(advance(session).isEmpty)
        XCTAssertTrue(session.hasTimeout)
        _ = session.receive(modeIn, session: 7)
        XCTAssertEqual(session.transition?.phase, .starting)
        XCTAssertEqual(advance(session), [SonyEarTipFit.startPayload(series: .polyurethane)])
        session.controlLost()
        XCTAssertEqual(session.transition?.phase, .interrupted)
        XCTAssertFalse(session.hasTimeout)
        session.dismiss(id: identifier)
        XCTAssertNotNil(session.transition)
    }

    @MainActor
    func testFinishedCancellationDismissesOnlyItsOwner() throws {
        let session = ready()
        let identifier = try XCTUnwrap(session.transition?.id)
        session.cancel(id: UUID(), dismissWhenFinished: true)
        XCTAssertEqual(session.transition?.phase, .ready)
        session.cancel(id: identifier, dismissWhenFinished: true)
        XCTAssertEqual(session.transition?.phase, .finished)
        XCTAssertTrue(advance(session).isEmpty)
        XCTAssertNil(session.transition)
        XCTAssertFalse(session.hasTimeout)
    }

    @MainActor
    func testPublishedFeatureChangesReachObservers() {
        let session = SonyEarTipFitSession()
        var changes = 0
        let observation = session.objectWillChange.sink { changes += 1 }
        session.begin(session: 7, supportedFunctions: [0xF6])
        XCTAssertGreaterThan(changes, 0)
        let previous = changes
        session.controlLost()
        XCTAssertGreaterThan(changes, previous)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    private func advance(_ session: SonyEarTipFitSession, commandPending: Bool = false,
                         onTimeout: @escaping @MainActor () -> Void = {}) -> [[UInt8]] {
        session.advance(session: 7, isReady: true, canStart: true, commandPending: commandPending,
                        isCurrent: { true }, onTimeout: onTimeout)
    }

    @MainActor
    private func ready() -> SonyEarTipFitSession {
        let session = SonyEarTipFitSession()
        session.begin(session: 7, supportedFunctions: [0xF6])
        _ = advance(session)
        for payload in replies {
            session.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertEqual(session.receive(payload, session: 7)?.parsed, true)
        }
        _ = advance(session)
        XCTAssertEqual(session.transition?.phase, .ready)
        return session
    }

    private var replies: [[UInt8]] {
        [[0xF1, 6, 10, 1, 1, 4, 0, 1, 2, 3], [0xF3, 6, 0, 0, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 255]]
    }

    private var modeIn: [UInt8] { [0xF5, 6, 0, 1, 1, 0] }
}
