import XCTest
@testable import Acouplet

final class SonyPowerOffTests: XCTestCase {
    @MainActor
    func testPowerOffPausesMacPlaybackBeforeSendingCommandAndStoppingLDAC() throws {
        var controller: SonyHeadphonesController!
        defer { controller = nil }
        var pauses = 0
        controller = SonyHeadphonesController(startAutomatically: false, simulated: true, pauseMacPlayback: {
            pauses += 1
            XCTAssertNil(controller.powerOffState)
            XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        })
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let observation = controller.disconnectionRequests.sink { XCTAssertEqual(pauses, 1) }
        let session = try XCTUnwrap(controller.powerOffSession)
        controller.powerOff(expectedSession: session + 1)
        XCTAssertEqual(pauses, 0)
        controller.powerOff(expectedSession: session)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x24, 3, 1])
        controller.powerOff(expectedSession: session)
        XCTAssertEqual(pauses, 1)
        observation.cancel()
        controller.simulateControlLoss()
    }

    @MainActor
    func testDisconnectPausesMacPlaybackBeforeClosingTheConnectionAndStoppingLDAC() {
        var controller: SonyHeadphonesController!
        defer { controller = nil }
        var pauses = 0
        controller = SonyHeadphonesController(startAutomatically: false, simulated: true, pauseMacPlayback: {
            pauses += 1
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertFalse(controller.isDisconnectedByUser)
        })
        controller.disconnect()
        XCTAssertEqual(pauses, 0)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let observation = controller.disconnectionRequests.sink { XCTAssertEqual(pauses, 1) }
        controller.disconnect()
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertFalse(controller.isDeviceConnected)
        controller.disconnect()
        XCTAssertEqual(pauses, 1)
        observation.cancel()
        controller.simulateControlLoss()
    }

    @MainActor
    func testPowerOffRequiresReadyAdvertisedSupportAndTheConfirmedSession() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        XCTAssertNil(controller.powerOffSession)
        controller.powerOff(expectedSession: controller.simulatedControlSession)
        XCTAssertNil(controller.powerOffState)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let oldSession = try XCTUnwrap(controller.powerOffSession)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.powerOff(expectedSession: oldSession)
        XCTAssertNil(controller.powerOffState)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x24, 3, 1] })

        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        deliver([0x07, 0, 1, 0x6B, 0xFF], to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.supportedFunctions.contains(0x23))
        XCTAssertFalse(controller.canPowerOff)
        controller.powerOff(expectedSession: controller.simulatedControlSession)
        XCTAssertNil(controller.powerOffState)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x24, 3, 1] })
        controller.simulateControlLoss()
    }

    @MainActor
    func testAcknowledgmentIsDeliveryOnlyAndCommandsStaySuppressedUntilExplicitConnect() throws {
        let controller = readyController()
        let session = try XCTUnwrap(controller.powerOffSession)
        let ambient = controller.ambientLevel
        let mode = controller.noiseControlMode
        controller.powerOff(expectedSession: session)
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x24, 3, 1])
        XCTAssertEqual(controller.powerOffState, .sending)
        XCTAssertTrue(controller.isPoweringOff)
        XCTAssertFalse(controller.canPowerOff)
        controller.powerOff(expectedSession: session)
        controller.setAmbientLevel(3)
        controller.setFocusOnVoice(true)
        controller.applyPreset(mode: .anc, ambientLevel: 3, focusOnVoice: true)
        controller.setNoiseControl(.off)
        controller.setEqualizerPreset(.off)
        controller.setDSEE(.off)
        controller.setSidetone(true)
        controller.controlPlayback(.play)
        controller.setPlaybackVolume(25)
        controller.setConnectionMode(.lowLatency)
        controller.setMultipointEnabled(false)
        controller.refreshEqualizer(trackConfirmation: true)
        controller.refreshDevices()
        controller.refreshSoundPressure()
        XCTAssertEqual(controller.ambientLevel, ambient)
        XCTAssertEqual(controller.noiseControlMode, mode)
        XCTAssertFalse(controller.focusOnVoice)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.pendingPlaybackCommand)
        XCTAssertNil(controller.connectionTransition)
        XCTAssertNil(controller.multipointTransition)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        XCTAssertFalse(controller.canRefreshDevices)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.powerOffState, .acknowledged)
        XCTAssertFalse(controller.isPoweringOff)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload), [[0x24, 3, 1]])
        let frames = controller.simulatedTransmittedFrames
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        controller.refresh()
        controller.setReconnectAutomatically(true)
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        XCTAssertTrue(controller.simulatedReconnectAutomatically)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.powerOffState, .disconnected)
        XCTAssertTrue(controller.showsMenuBarIcon)
        let disconnectedSession = controller.simulatedControlSession
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, disconnectedSession)
        XCTAssertNil(controller.retrySecondsRemaining)
        controller.connect()
        XCTAssertNil(controller.powerOffState)
        XCTAssertTrue(controller.simulatedReconnectAutomatically)
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x24, 3, 1] }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testExistingWritesDebouncesAndConnectionChangesRejectShutdown() {
        for scenario in 0..<6 {
            let controller = readyController()
            switch scenario {
            case 0: controller.setDSEE(.off)
            case 1: controller.setCustomEqualizer(.flat)
            case 2: controller.setAmbientLevel(3)
            case 3: controller.controlPlayback(.play)
            case 4: controller.setConnectionMode(.lowLatency)
            default: controller.setMultipointEnabled(false)
            }
            XCTAssertFalse(controller.canPowerOff)
            XCTAssertNil(controller.powerOffSession)
            controller.powerOff(expectedSession: controller.simulatedControlSession)
            XCTAssertNil(controller.powerOffState)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x24, 3, 1] })
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testAcknowledgmentRequiresCompletedWriteAndExactFrameSequence() throws {
        let controller = readyController()
        controller.defersSimulatedWrites = true
        controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        acknowledgeAll(controller, limit: 1)
        XCTAssertEqual(controller.powerOffState, .sending)
        controller.completeSimulatedWrite()
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: frame.sequence, payload: []))
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: [0]))
        XCTAssertEqual(controller.powerOffState, .sending)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.powerOffState, .acknowledged)
        controller.simulateControlLoss()
    }

    @MainActor
    func testControlLossBeforeAcknowledgmentLeavesUnknownOutcomeAndNeverReplays() throws {
        let controller = readyController()
        controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
        let session = controller.simulatedControlSession
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.powerOffState, .unconfirmed)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []), session: session)
        XCTAssertEqual(controller.powerOffState, .unconfirmed)
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.powerOff(expectedSession: controller.simulatedControlSession)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x24, 3, 1] }.count, 1)
        controller.connectBluetoothLE()
        XCTAssertNil(controller.powerOffState)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.canPowerOff)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testExplicitConnectCancelsPendingSessionAndLateWriteCannotAcknowledgeNewConnection() throws {
        let controller = readyController()
        controller.setReconnectAutomatically(false)
        controller.defersSimulatedWrites = true
        controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
        let session = controller.simulatedControlSession
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.connect()
        XCTAssertNil(controller.powerOffState)
        XCTAssertFalse(controller.simulatedReconnectAutomatically)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.completeSimulatedWrite()
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []), session: session)
        XCTAssertNil(controller.powerOffState)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.canPowerOff)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x24, 3, 1] }.count, 1)
    }

    @MainActor
    func testAcknowledgmentTimeoutIsUnknownAndKeepsAutomaticReconnectSuppressed() async throws {
        let controller = readyController()
        let stalledWrite = readyController()
        stalledWrite.defersSimulatedWrites = true
        stalledWrite.powerOff(expectedSession: try XCTUnwrap(stalledWrite.powerOffSession))
        controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
        let session = controller.simulatedControlSession
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        try await Task.sleep(for: .seconds(3.1))
        XCTAssertEqual(controller.powerOffState, .unconfirmed)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.lastErrorMessage, String(localized: "The power-off command was not acknowledged. Its outcome is unknown."))
        XCTAssertEqual(stalledWrite.powerOffState, .unconfirmed)
        XCTAssertNil(stalledWrite.simulatedPendingFrame)
        stalledWrite.completeSimulatedWrite()
        XCTAssertEqual(stalledWrite.powerOffState, .unconfirmed)
        XCTAssertNil(stalledWrite.simulatedPendingFrame)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []), session: session)
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.powerOffState, .unconfirmed)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x24, 3, 1] }.count, 1)
        controller.connect()
        XCTAssertNil(controller.powerOffState)
        XCTAssertTrue(controller.simulatedReconnectAutomatically)
    }

    @MainActor
    func testMenuEntryTracksExplicitRecoveryAndHidesAfterDisconnectedFailure() throws {
        for useBluetoothLE in [false, true] {
            let controller = readyController()
            controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
            acknowledgeAll(controller)
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertEqual(controller.deviceModel, .wfXM5)
            XCTAssertTrue(controller.showsMenuBarIcon)
            if useBluetoothLE { controller.connectBluetoothLE() } else { controller.connect() }
            XCTAssertNil(controller.powerOffState)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertFalse(controller.showsMenuBarIcon)
            if useBluetoothLE {
                XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: true, classicConnected: false))
            } else {
                XCTAssertNotNil(controller.simulateClassicConnection())
            }
            XCTAssertTrue(controller.showsMenuBarIcon)

            controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 1, 0], beginConnection: true)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.linkState, .failed(String(localized: "Acouplet does not support this device’s control protocol.")))
            XCTAssertNil(controller.powerOffState)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertEqual(controller.deviceModel, .wfXM5)
            XCTAssertFalse(controller.showsMenuBarIcon)

            controller.simulateControlLoss(deviceConnected: true)
            controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeAll(controller)
            deliver([0x07, 0, 2, 0x6B, 0xFF, 0x23, 0xFF], to: controller)
            acknowledgeAll(controller)
            deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.showsMenuBarIcon)
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertNil(controller.powerOffState)
            XCTAssertFalse(controller.showsMenuBarIcon)
        }
    }

    @MainActor
    func testDisconnectedRecoveryTimeoutAndStopDoNotRetainMenuEntryDuringAutomaticBLEWait() throws {
        for ending in ["classicFailure", "bleTimeout", "disconnect", "stop"] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.powerOff(expectedSession: try XCTUnwrap(controller.powerOffSession))
            acknowledgeAll(controller)
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertTrue(controller.showsMenuBarIcon)
            controller.connect()
            XCTAssertNil(controller.powerOffState)
            XCTAssertFalse(controller.showsMenuBarIcon)
            if ending == "classicFailure" {
                let complete = try XCTUnwrap(controller.simulateClassicConnection())
                XCTAssertTrue(controller.showsMenuBarIcon)
                complete(-1, false)
            } else {
                XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: true, classicConnected: false))
                XCTAssertTrue(controller.showsMenuBarIcon)
                switch ending {
                case "bleTimeout": controller.simulateBLEDisconnect(String(localized: "The headphone connection timed out. Try again."))
                case "disconnect": controller.simulateBLEDisconnect(nil)
                default: controller.stop()
                }
            }
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertFalse(controller.showsMenuBarIcon)
            if ending == "stop" { controller.systemDidWake() }
            XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true, classicConnected: false))
            XCTAssertFalse(controller.hasPendingManualBLEConnection)
            XCTAssertFalse(controller.showsMenuBarIcon)
        }
    }

    @MainActor
    private func readyController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController, limit: Int = 80) {
        for _ in 0..<limit {
            guard let frame = controller.simulatedPendingFrame else { return }
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
    }
}
