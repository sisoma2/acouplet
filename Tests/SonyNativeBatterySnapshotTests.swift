#if !ACOUPLET_PUBLIC_APIS_ONLY
import XCTest
@testable import Acouplet

final class SonyNativeBatterySnapshotTests: XCTestCase {
    @MainActor
    func testAutomaticBatteryReadsUseComponentFreshnessDuringOrdinaryAndLDACPlayback() throws {
        for streaming in [false, true] {
            let controller = batteryController(functions: [0x29, 0x2A])
            defer { controller.simulateControlLoss() }
            deliverBattery([0x23, 0x09, 73, 0, 84, 0, 20, 20], to: controller)
            deliverBattery([0x23, 0x0A, 65, 0, 20], to: controller)
            deliverBattery([0x25, 0x09, 72, 0, 83, 0, 20, 20], to: controller)
            let observedAt = try XCTUnwrap(controller.lastSyncDate)
            controller.isLDACStreaming = streaming
            let pairReads = batteryReadCount(controller, inquiry: 0x09)
            let caseReads = batteryReadCount(controller, inquiry: 0x0A)
            for _ in 0..<20 { controller.simulateAutomaticRefresh(at: observedAt.addingTimeInterval(29)) }
            XCTAssertEqual(batteryReadCount(controller, inquiry: 0x09), pairReads)
            XCTAssertEqual(batteryReadCount(controller, inquiry: 0x0A), caseReads)
            controller.simulateAutomaticRefresh(at: observedAt.addingTimeInterval(31))
            acknowledgeBatteryCommands(controller)
            XCTAssertEqual(batteryReadCount(controller, inquiry: 0x09), pairReads + 1)
            XCTAssertEqual(batteryReadCount(controller, inquiry: 0x0A), caseReads + 1)
            deliverBattery([0x25, 0x09, 71, 0, 82, 0, 20, 20], to: controller)
            deliverBattery([0x23, 0x09, 70, 0, 81, 0, 20, 20], to: controller)
            XCTAssertEqual(controller.batteries.left?.level, 71)
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(batteryReadCount(controller, inquiry: 0x09), pairReads + 1)
        }
    }

    func testDiagnosticsOmitNativeNameAndIdentifierWhilePreservingBatteryReadings() {
        let date = Date(timeIntervalSince1970: 1_000)
        let identifier = UUID()
        var snapshot = SonyNativeBatterySnapshot(identifier: identifier, name: "Private renamed earbuds")
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x09, 73, 0, 84, 1, 20, 20]))
        snapshot.update(batteries, type: 0x09, observedAt: date)
        let report = snapshot.diagnosticDescription(at: date)
        XCTAssertFalse(report.contains(snapshot.name))
        XCTAssertFalse(report.contains(identifier.uuidString))
        XCTAssertTrue(report.contains("Left: 73%, not charging"))
        XCTAssertTrue(report.contains("Right: 84%, charging"))
        XCTAssertTrue(report.contains("fresh"))
        XCTAssertTrue(report.contains("received \(date.ISO8601Format())"))
    }

    @MainActor
    func testChargingCasePresenceRequiresFreshPairAndEndsOnExpiryOrControlLoss() {
        let controller = batteryController(functions: [0x29, 0x2A])
        defer { controller.simulateControlLoss() }
        deliverBattery([0x23, 0x09, 73, 1, 84, 1, 20, 20], to: controller)
        XCTAssertTrue(controller.isChargingInCase)
        controller.simulateChargingCaseTimeout()
        XCTAssertFalse(controller.isChargingInCase)
        deliverBattery([0x25, 0x0A, 90, 1, 20], to: controller)
        XCTAssertFalse(controller.isChargingInCase)
        for state: UInt8 in [0, 2, 3] {
            deliverBattery([0x25, 0x09, 73, 1, 84, state, 20, 20], to: controller)
            XCTAssertFalse(controller.isChargingInCase)
        }
        deliverBattery([0x25, 0x09, 73, 1, 84, 1, 20, 20], to: controller)
        XCTAssertTrue(controller.isChargingInCase)
        controller.simulateControlLoss()
        XCTAssertFalse(controller.isChargingInCase)
    }

    @MainActor
    func testCaseBatteryExpiryPreservesLastReportedReadingWithoutExpiringTheOtherBudOrSession() throws {
        let controller = batteryController(functions: [0x29, 0x2A])
        defer { controller.simulateControlLoss() }
        deliverBattery([0x23, 0x0A, 65, 1, 20], to: controller)
        let observedAt = try XCTUnwrap(controller.lowBatteryReadings.first { $0.part == .caseBattery }?.observedAt)
        let session = controller.simulatedControlSession
        deliverBattery([0x25, 0x09, 73, 0, 76, 0, 20, 20], to: controller)
        controller.simulateCaseBatteryExpiry(at: observedAt.addingTimeInterval(45))
        XCTAssertEqual(controller.batteries.caseBattery?.isCharging, true)
        controller.simulateCaseBatteryExpiry(at: observedAt.addingTimeInterval(46))
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)
        XCTAssertEqual(controller.batteries.caseBattery?.chargingState, .charging)
        XCTAssertFalse(controller.lowBatteryReadings.contains { $0.part == .caseBattery })
        XCTAssertEqual(controller.batteries.left?.level, 73)
        XCTAssertEqual(controller.batteries.right?.level, 76)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.diagnosticReport.contains("Case charging (last reported): Charging"))
        deliverBattery([0x25, 0x0A, 64, 0, 20], to: controller)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 64)
        XCTAssertEqual(controller.batteries.caseBattery?.chargingState, .notCharging)
        controller.simulateControlLoss()
        controller.simulateCaseBatteryExpiry(at: observedAt.addingTimeInterval(90))
        XCTAssertNil(controller.batteries.caseBattery)
    }

    func testUnknownChargingCannotBecomeAKnownNativeBooleanAndChargedKeepsItsLevel() {
        let date = Date(timeIntervalSince1970: 1_000)
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: UUID(), name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x23, 0x09, 73, 0, 84, 1, 20, 20]))
        snapshot.update(batteries, type: 0x09, observedAt: date)
        XCTAssertTrue(batteries.update([0x25, 0x09, 74, 2, 85, 3, 20, 20]))
        snapshot.update(batteries, type: 0x09, observedAt: date.addingTimeInterval(1))
        XCTAssertEqual(batteries.left?.level, 74)
        XCTAssertNil(snapshot.left)
        XCTAssertEqual(snapshot.right?.level, 85)
        XCTAssertEqual(snapshot.right?.isCharging, false)
        XCTAssertTrue(batteries.update([0x23, 0x0A, 67, 3, 20]))
        snapshot.update(batteries, type: 0x0A, observedAt: date)
        XCTAssertEqual(snapshot.caseBattery?.level, 67)
        XCTAssertEqual(snapshot.caseBattery?.isCharging, false)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 68, 2, 20]))
        snapshot.update(batteries, type: 0x0A, observedAt: date.addingTimeInterval(1))
        XCTAssertEqual(batteries.caseBattery?.level, 68)
        XCTAssertNil(snapshot.caseBattery)
    }

    @MainActor
    func testUnknownChargingClearsLowBatteryObservationsWithoutDiscardingPercentages() {
        let controller = batteryController(functions: [0x29, 0x2A])
        defer { controller.simulateControlLoss() }
        deliverBattery([0x23, 0x09, 15, 0, 16, 0, 20, 20], to: controller)
        deliverBattery([0x23, 0x0A, 17, 0, 20], to: controller)
        XCTAssertEqual(controller.lowBatteryReadings.count, 3)
        deliverBattery([0x25, 0x09, 15, 2, 16, 2, 20, 20], to: controller)
        deliverBattery([0x25, 0x0A, 17, 2, 20], to: controller)
        XCTAssertTrue(controller.lowBatteryReadings.isEmpty)
        XCTAssertEqual(controller.batteries.left?.level, 15)
        XCTAssertEqual(controller.batteries.right?.level, 16)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 17)
        XCTAssertTrue(controller.diagnosticReport.contains("Left charging: Unknown"))
        XCTAssertTrue(controller.diagnosticReport.contains("Case charging (last reported): Unknown"))
    }

    @MainActor
    func testLowBatteryObservationsKeepGroupsFreshIndependentlyAndNeverAuthorizeSimulation() throws {
        let controller = batteryController(functions: [0x29, 0x2A])
        defer { controller.simulateControlLoss() }
        deliverBattery([0x23, 0x09, 20, 0, 60, 1, 20, 20], to: controller)
        let pair = controller.lowBatteryReadings
        XCTAssertEqual(pair.map(\.part), [.left, .right])
        XCTAssertEqual(pair.map(\.level), [20, 60])
        XCTAssertEqual(pair.map(\.isCharging), [false, true])
        XCTAssertEqual(pair.first?.observedAt, pair.last?.observedAt)
        XCTAssertNil(controller.lowBatteryNotificationDeviceID)
        deliverBattery([0x23, 0x0A, 1, 0, 15], to: controller)
        XCTAssertEqual(Array(controller.lowBatteryReadings.prefix(2)), pair)
        let caseReading = try XCTUnwrap(controller.lowBatteryReadings.last)
        XCTAssertEqual(caseReading.part, .caseBattery)
        XCTAssertEqual(caseReading.level, 1)
        deliverBattery([0x25, 0x09, 0, 0, 255, 0, 20, 20], to: controller)
        XCTAssertEqual(controller.lowBatteryReadings, [caseReading])
        let session = controller.notificationSession
        controller.simulateControlLoss()
        XCTAssertTrue(controller.lowBatteryReadings.isEmpty)
        XCTAssertGreaterThan(controller.notificationSession, session)
    }

    @MainActor
    func testCaseZeroClearsLowBatteryObservationWithoutRefreshingTheBuds() {
        for command: UInt8 in [0x23, 0x25] {
            let controller = batteryController(functions: [0x29, 0x2A])
            defer { controller.simulateControlLoss() }
            deliverBattery([0x23, 0x09, 0x46, 0, 0x40, 0, 0x64, 0x64], to: controller)
            deliverBattery([0x23, 0x0A, 15, 0, 0x1E], to: controller)
            XCTAssertTrue(controller.lowBatteryReadings.contains { $0.part == .caseBattery })
            let pair = controller.lowBatteryReadings.filter { $0.part != .caseBattery }
            controller.refresh()
            acknowledgeBatteryCommands(controller)
            deliverBattery([command, 0x0A, 0, 0, 0x1E], to: controller)
            XCTAssertNil(controller.batteries.caseBattery)
            XCTAssertEqual(controller.lowBatteryReadings, pair)
            XCTAssertEqual(controller.batteries.left?.level, 70)
            XCTAssertEqual(controller.batteries.right?.level, 64)
            deliverBattery([0x25, 0x0A, 1, 0, 0x1E], to: controller)
            XCTAssertEqual(controller.batteries.caseBattery?.level, 1)
            XCTAssertEqual(controller.lowBatteryReadings.first { $0.part == .caseBattery }?.level, 1)
        }
    }

    @MainActor
    func testLowBatterySideLossDoesNotRestoreOldReadingsOnReconnection() {
        let controller = batteryController(functions: [0x11, 0x29, 0x2A])
        defer { controller.simulateControlLoss() }
        deliverBattery([0x15, 0x01, 1, 1], to: controller)
        deliverBattery([0x23, 0x09, 15, 0, 16, 0, 20, 20], to: controller)
        deliverBattery([0x23, 0x0A, 24, 0, 15], to: controller)
        let caseReading = controller.lowBatteryReadings.first { $0.part == .caseBattery }
        deliverBattery([0x15, 0x01, 0, 1], to: controller)
        XCTAssertNil(controller.lowBatteryReadings.first { $0.part == .left })
        deliverBattery([0x15, 0x01, 1, 1], to: controller)
        XCTAssertNil(controller.lowBatteryReadings.first { $0.part == .left })
        XCTAssertEqual(controller.lowBatteryReadings.first { $0.part == .caseBattery }, caseReading)
        deliverBattery([0x25, 0x09, 14, 0, 15, 0, 20, 20], to: controller)
        XCTAssertEqual(controller.lowBatteryReadings.first { $0.part == .left }?.level, 14)
    }

    @MainActor
    func testSimulatedHeadphonesNeverSupplyNativeBatteryReadings() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, simulatedReady: true)
        XCTAssertNil(controller.nativeBatterySnapshot)
        controller.simulateProtocolMessage([0x25, 0x09, 73, 0, 76, 1])
        XCTAssertEqual(controller.batteries.left?.level, 73)
        XCTAssertNil(controller.nativeBatterySnapshot)
        controller.simulateProtocolMessage([0x25, 0x09, 72, 0, 75, 1, 20, 20])
        XCTAssertEqual(controller.batteries.left?.level, 72)
        XCTAssertNil(controller.nativeBatterySnapshot)
        controller.simulateProtocolMessage([0x25, 0x0A, 65, 0, 15])
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)
        XCTAssertNil(controller.nativeBatterySnapshot)
        controller.simulateControlLoss()
        XCTAssertNil(controller.nativeBatterySnapshot)
    }

    func testOnlyTheReportedPartsBecomeFreshAndUnknownDoesNotBecomeZero() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: UUID(), name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x23, 0x09, 73, 0, 76, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: firstDate)
        XCTAssertEqual(snapshot.freshReadings(at: firstDate).count, 2)
        XCTAssertEqual(snapshot.left?.level, 73)
        XCTAssertEqual(snapshot.right?.isCharging, true)
        XCTAssertNil(snapshot.caseBattery)
        XCTAssertTrue(batteries.update([0x23, 0x0A, 1, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: firstDate.addingTimeInterval(30))
        XCTAssertEqual(snapshot.caseBattery?.level, 1)
        XCTAssertEqual(snapshot.freshReadings(at: firstDate.addingTimeInterval(46)).keys.sorted(), ["Case"])
        XCTAssertTrue(batteries.update([0x25, 0x09, 255, 0, 76, 0]))
        snapshot.update(batteries, type: 0x09, observedAt: firstDate.addingTimeInterval(60))
        XCTAssertNil(snapshot.left)
        XCTAssertEqual(snapshot.freshReadings(at: firstDate.addingTimeInterval(60)).keys.sorted(), ["Case", "Right"])
        XCTAssertEqual(snapshot.caseBattery?.observedAt, firstDate.addingTimeInterval(30))
        XCTAssertTrue(snapshot.freshReadings(at: firstDate.addingTimeInterval(106)).isEmpty)
        XCTAssertTrue(snapshot.diagnosticDescription(at: firstDate.addingTimeInterval(106)).contains("Left: unknown"))
        XCTAssertTrue(snapshot.diagnosticDescription(at: firstDate.addingTimeInterval(106)).contains("expired"))
    }

    func testIdenticalBatteryRepliesRefreshTheirOwnObservationWithoutRefreshingOtherParts() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: UUID(), name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x23, 0x0A, 100, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: firstDate)
        XCTAssertTrue(batteries.update([0x23, 0x09, 73, 0, 76, 0]))
        snapshot.update(batteries, type: 0x09, observedAt: firstDate)
        snapshot.update(batteries, type: 0x09, observedAt: firstDate.addingTimeInterval(40))
        XCTAssertEqual(snapshot.freshReadings(at: firstDate.addingTimeInterval(46)).keys.sorted(), ["Left", "Right"])
        XCTAssertTrue(snapshot.freshReadings(at: firstDate.addingTimeInterval(-6)).isEmpty)
    }

    func testFullThresholdRepliesRefreshOnlyTheirReportedParts() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: UUID(), name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x23, 0x09, 73, 0, 76, 1, 20, 20]))
        snapshot.update(batteries, type: 0x09, observedAt: firstDate)
        XCTAssertEqual(snapshot.left?.level, 73)
        XCTAssertEqual(snapshot.right?.isCharging, true)
        XCTAssertNil(snapshot.caseBattery)
        XCTAssertTrue(batteries.update([0x23, 0x0A, 61, 0, 15]))
        snapshot.update(batteries, type: 0x0A, observedAt: firstDate.addingTimeInterval(30))
        XCTAssertEqual(snapshot.caseBattery?.level, 61)
        XCTAssertEqual(snapshot.left?.observedAt, firstDate)
        let previous = snapshot
        for payload: [UInt8] in [[0x23, 0x09, 73, 0, 76, 1, 20], [0x23, 0x0A, 61, 0, 15, 1]] {
            let accepted = batteries.update(payload)
            XCTAssertFalse(accepted)
            if accepted { snapshot.update(batteries, type: payload[1], observedAt: firstDate.addingTimeInterval(40)) }
            XCTAssertEqual(snapshot, previous)
        }
        XCTAssertEqual(snapshot.freshReadings(at: firstDate.addingTimeInterval(46)).keys.sorted(), ["Case"])
    }

    func testUnavailableBudsInvalidateTheirReadingsWithoutChangingCaseOrResurrectingOnReconnect() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        for unavailable: Bool? in [false, nil] {
            var batteries = SonyBatteries()
            var snapshot = SonyNativeBatterySnapshot(identifier: UUID(), name: "WF-1000XM5")
            XCTAssertTrue(batteries.update([0x25, 0x09, 73, 0, 76, 0, 20, 20]))
            snapshot.update(batteries, type: 0x09, observedAt: firstDate)
            XCTAssertTrue(batteries.update([0x25, 0x0A, 1, 0, 15]))
            snapshot.update(batteries, type: 0x0A, observedAt: firstDate)
            let caseReading = snapshot.caseBattery
            let rightReading = snapshot.right

            snapshot.invalidateUnavailableBuds(leftConnected: unavailable, rightConnected: true)
            XCTAssertNil(snapshot.left)
            XCTAssertEqual(snapshot.right, rightReading)
            XCTAssertEqual(snapshot.caseBattery, caseReading)
            snapshot.invalidateUnavailableBuds(leftConnected: true, rightConnected: true)
            XCTAssertNil(snapshot.left)

            let nextDate = firstDate.addingTimeInterval(20)
            snapshot.update(batteries, type: 0x09, observedAt: nextDate)
            snapshot.invalidateUnavailableBuds(leftConnected: true, rightConnected: unavailable)
            XCTAssertEqual(snapshot.left?.observedAt, nextDate)
            XCTAssertNil(snapshot.right)
            XCTAssertEqual(snapshot.caseBattery, caseReading)

            XCTAssertTrue(batteries.update([0x25, 0x09, 0, 0, 255, 0, 20, 20]))
            snapshot.update(batteries, type: 0x09, observedAt: nextDate.addingTimeInterval(1))
            snapshot.invalidateUnavailableBuds(leftConnected: true, rightConnected: true)
            XCTAssertNil(snapshot.left)
            XCTAssertNil(snapshot.right)
            XCTAssertEqual(snapshot.caseBattery?.level, 1)
            XCTAssertEqual(snapshot.caseBattery?.observedAt, firstDate)
        }
    }

    @MainActor
    func testConnectionLossRetiresTransmittedWFPairReadButLeavesCaseReadUsable() {
        for state: UInt8 in [0, 0xFE] {
            let controller = batteryController(functions: [0x11, 0x29, 0x2A])
            defer { controller.simulateControlLoss() }
            deliverBattery([0x15, 0x01, 1, 1], to: controller)
            deliverBattery([0x23, 0x09, 73, 0, 76, 0, 20, 20], to: controller)
            deliverBattery([0x23, 0x0A, 65, 0, 15], to: controller)
            controller.refresh()
            acknowledgeBatteryCommands(controller)
            deliverBattery([0x15, 0x01, state, 1], to: controller)
            deliverBattery([0x15, 0x01, 1, 1], to: controller)
            let previous = controller.batteries
            let reportedAt = controller.lastSyncDate
            deliverBattery([0x23, 0x09, 75, 0, 78, 0, 20, 20], to: controller)
            XCTAssertEqual(controller.batteries, previous)
            XCTAssertEqual(controller.lastSyncDate, reportedAt)
            deliverBattery([0x23, 0x0A, 64, 0, 15], to: controller)
            XCTAssertEqual(controller.batteries.caseBattery?.level, 64)
            controller.refresh()
            acknowledgeBatteryCommands(controller)
            deliverBattery([0x23, 0x09, 72, 0, 75, 0, 20, 20], to: controller)
            XCTAssertEqual(controller.batteries.left?.level, 72)
            XCTAssertEqual(controller.batteries.right?.level, 75)
            XCTAssertNil(controller.nativeBatterySnapshot)
        }
    }

    @MainActor
    func testBatteryNotificationSupersedesOnlyItsTransmittedPollWithoutRefreshingTime() {
        let cases: [(UInt8, UInt8, [UInt8], [UInt8])] = [
            (0x20, 0x00, [80, 0], [79, 1]),
            (0x21, 0x01, [80, 0, 82, 0], [79, 1, 81, 0]),
            (0x22, 0x02, [80, 0], [79, 1]),
            (0x28, 0x08, [80, 0, 20], [79, 1, 20]),
            (0x29, 0x09, [80, 0, 82, 0, 20, 20], [79, 1, 81, 0, 20, 20]),
            (0x2A, 0x0A, [80, 0, 20], [79, 1, 20]),
        ]
        for (function, inquiry, old, newer) in cases {
            let controller = batteryController(functions: [function])
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x22, inquiry] })
            deliverBattery([0x25, inquiry] + newer, to: controller)
            let reported = controller.batteries
            let reportedAt = controller.lastSyncDate
            let lowBatteryReadings = controller.lowBatteryReadings
            XCTAssertFalse(lowBatteryReadings.isEmpty)
            XCTAssertNotNil(reportedAt)
            deliverBattery([0x23, inquiry] + old, to: controller)
            XCTAssertEqual(controller.batteries, reported)
            XCTAssertEqual(controller.lastSyncDate, reportedAt)
            XCTAssertEqual(controller.lowBatteryReadings, lowBatteryReadings)
            deliverBattery([0x23, inquiry] + old, to: controller)
            XCTAssertEqual(controller.batteries, reported)
            XCTAssertEqual(controller.lastSyncDate, reportedAt)

            let reads = batteryReadCount(controller, inquiry: inquiry)
            controller.refresh()
            acknowledgeBatteryCommands(controller)
            XCTAssertEqual(batteryReadCount(controller, inquiry: inquiry), reads + 1)
            deliverBattery([0x23, inquiry] + old, to: controller)
            var expected = SonyBatteries()
            XCTAssertTrue(expected.update([0x23, inquiry] + old))
            XCTAssertEqual(controller.batteries, expected)
            XCTAssertGreaterThanOrEqual(controller.lastSyncDate!, reportedAt!)
            XCTAssertNil(controller.nativeBatterySnapshot)
        }
    }

    @MainActor
    func testBatteryReadsRequireActualTransmissionAndKeepPartsIndependent() {
        let controller = batteryController(functions: [0x29, 0x2A], acknowledgeReads: false)
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x22, 0x09])
        deliverBattery([0x25, 0x09, 73, 0, 76, 1], to: controller)
        let paired = controller.batteries
        let reportedAt = controller.lastSyncDate
        deliverBattery([0x23, 0x0A, 80, 0], to: controller)
        XCTAssertEqual(controller.batteries, paired)
        XCTAssertEqual(controller.lastSyncDate, reportedAt)

        controller.defersSimulatedWrites = true
        let pending = controller.simulatedPendingFrame!
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - pending.sequence, payload: []))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x22, 0x0A])
        controller.defersSimulatedWrites = false
        deliverBattery([0x23, 0x0A, 80, 0], to: controller)
        XCTAssertNil(controller.batteries.caseBattery)
        XCTAssertEqual(controller.lastSyncDate, reportedAt)
        controller.completeSimulatedWrite()
        acknowledgeBatteryCommands(controller)
        deliverBattery([0x23, 0x0A, 80, 0], type: 0x0E, to: controller)
        XCTAssertNil(controller.batteries.caseBattery)
        deliverBattery([0x23, 0x0A, 80, 0, 10, 20], to: controller)
        XCTAssertNil(controller.batteries.caseBattery)
        deliverBattery([0x23, 0x0A, 80, 0, 20], to: controller)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 80)
        let caseReportedAt = controller.lastSyncDate
        deliverBattery([0x23, 0x09, 74, 0, 77, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 73)
        XCTAssertEqual(controller.batteries.right?.level, 76)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 80)
        XCTAssertEqual(controller.lastSyncDate, caseReportedAt)
    }

    @MainActor
    func testMissingOptionalBatteryReplyDoesNotReconnectOrReuseItsOwner() async throws {
        let controller = batteryController(functions: [0x29, 0x2A], acknowledgeReads: false)
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.simulateBatteryReadTimeout([0x22, 0x0A])
        for _ in 0..<5 { await Task.yield() }
        acknowledgeBatteryCommands(controller)
        deliverBattery([0x23, 0x0A, 65, 0], to: controller)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)

        controller.simulateBatteryReadTimeout([0x22, 0x09])
        for _ in 0..<5 { await Task.yield() }
        let reads = batteryReadCount(controller, inquiry: 0x09)
        for _ in 0..<3 {
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            acknowledgeBatteryCommands(controller)
        }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(batteryReadCount(controller, inquiry: 0x09), reads)
        deliverBattery([0x25, 0x09, 73, 0, 76, 1], to: controller)
        let reportedAt = controller.lastSyncDate
        deliverBattery([0x23, 0x09, 74, 0, 77, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 73)
        XCTAssertEqual(controller.lastSyncDate, reportedAt)
        controller.simulateAutomaticRefresh(at: try XCTUnwrap(reportedAt).addingTimeInterval(31))
        acknowledgeBatteryCommands(controller)
        XCTAssertEqual(batteryReadCount(controller, inquiry: 0x09), reads + 1)
        deliverBattery([0x23, 0x09, 72, 0, 75, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 72)
        controller.simulateBatteryReadTimeout([0x22, 0x09])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        acknowledgeBatteryCommands(controller)
        controller.simulateBatteryReadTimeout([0x22, 0x09])
        controller.simulateControlLoss()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.batteries.left)
        XCTAssertNil(controller.nativeBatterySnapshot)
    }

    @MainActor
    private func batteryController(functions: [UInt8], acknowledgeReads: Bool = true) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeBatteryCommands(controller)
        let supported: [UInt8] = [0x6B] + functions
        deliverBattery([0x07, 0, UInt8(supported.count)] + supported.flatMap { [$0, 0] }, to: controller)
        acknowledgeBatteryCommands(controller)
        deliverBattery([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        if acknowledgeReads { acknowledgeBatteryCommands(controller) }
        XCTAssertTrue(controller.isReady)
        return controller
    }

    @MainActor
    private func batteryReadCount(_ controller: SonyHeadphonesController, inquiry: UInt8) -> Int {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x22, inquiry] }.count
    }

    @MainActor
    private func acknowledgeBatteryCommands(_ controller: SonyHeadphonesController) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 50 {
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    private func deliverBattery(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }
}
#endif
