import AppIntents
import XCTest
@testable import Acouplet

@available(macOS 27.0, *)
final class HeadphoneIntentsTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)),
            "These tests require macOS 27 or later.")
    }

    @MainActor
    private final class Destinations {
        var values: [HeadphoneDestination] = []
    }

    @MainActor
    func testNavigationRoutesOnlyTheRequestedDestination() async throws {
        let received = Destinations()
        for target in [HeadphoneDestination.settings, .equalizer] {
            var intent = OpenHeadphoneViewIntent(target: target)
            intent.navigation = HeadphoneIntentNavigation { received.values.append($0) }
            _ = try await intent.perform()
        }
        XCTAssertEqual(received.values, [.settings, .equalizer])
        XCTAssertEqual(OpenHeadphoneViewIntent.allowedExecutionTargets, .main)
        XCTAssertEqual(OpenHeadphoneViewIntent.supportedModes, .foreground)
    }

    @MainActor
    func testNoiseQuerySeparatesSavedResolutionFromCurrentlyAvailableSuggestions() async throws {
        let action = HeadphoneNoiseControlAction(id: "device:anc", title: "Noise Cancelling",
            modelName: "WF-1000XM5", symbolName: "Earbuds", systemSymbol: "earbuds.stemless")
        var query = HeadphoneNoiseControlQuery()
        query.controls = HeadphoneIntentControls(actions: { [action] }, resolve: { identifiers in
            identifiers.contains(action.id) ? [action] : []
        }, perform: { _ in })
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["device:anc"])
        XCTAssertEqual(suggested.first?.symbolName, "Earbuds")
        let resolved = try await query.entities(for: ["other-device:anc", "device:wind", "device:anc"])
        XCTAssertEqual(resolved.map(\.id), ["device:anc"])
        XCTAssertEqual(HeadphoneNoiseControlQuery.allowedExecutionTargets, .main)
        query.controls = HeadphoneIntentControls(actions: { [] }, resolve: { identifiers in
            identifiers.contains(action.id) ? [action] : []
        }, perform: { _ in })
        let unavailableSuggestions = try await query.suggestedEntities()
        let saved = try await query.entities(for: [action.id])
        XCTAssertTrue(unavailableSuggestions.isEmpty)
        XCTAssertEqual(saved.map(\.id), [action.id])
    }

    @MainActor
    func testNoiseIntentPassesExactActionAndPropagatesFailure() async throws {
        let action = HeadphoneNoiseControlAction(id: "device:ambient", title: "Ambient",
            modelName: "WH-1000XM5", symbolName: "WHXM5Headphones", systemSymbol: "headphones")
        var intent = SetHeadphoneNoiseControlIntent(action: action)
        intent.controls = HeadphoneIntentControls(actions: { [] }, resolve: { _ in [] }, perform: { identifier in
            XCTAssertEqual(identifier, action.id)
            await Task.yield()
            throw HeadphoneControlError(message: "The headphone connection changed.")
        })
        do {
            _ = try await intent.perform()
            XCTFail("An unconfirmed action must fail.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The headphone connection changed.")
        }
        XCTAssertEqual(SetHeadphoneNoiseControlIntent.allowedExecutionTargets, .main)
        XCTAssertEqual(SetHeadphoneNoiseControlIntent.supportedModes, .background)
    }

    @MainActor
    func testUnconfiguredNoiseControlDoesNotExecuteAnAction() async {
        var intent = SetHeadphoneNoiseControlIntent(action: nil)
        intent.controls = HeadphoneIntentControls(actions: { [] }, resolve: { _ in [] }, perform: { _ in XCTFail("No action was selected.") })
        do {
            _ = try await intent.perform()
            XCTFail("An unconfigured control must fail.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Choose a headphone action in the control's settings first.")
        }
    }

    @MainActor
    func testNoiseActionWaitsForAnExactTransmittedNotification() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        let action = await startAction(.anc, controller: controller)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        deliver([0x69] + payload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        var different = payload
        different[4] = 1
        deliver([0x69] + different.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        deliver([0x69] + payload.dropFirst(), to: controller)
        try await action.value
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .anc)
    }

    @MainActor
    func testOldNoisePollCannotConfirmANewAction() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 0x19] }.count, 1)
        let action = await startAction(.anc, controller: controller)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        acknowledgeAll(controller)
        deliver([0x67] + payload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 0x19] }.count, 2)
        deliver([0x67] + payload.dropFirst(), to: controller)
        try await action.value
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .anc)
    }

    @MainActor
    func testUnavailableWindAndStaleDeviceActionsDoNotWrite() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.noiseControlActions.map(\.title), ["Off", "Noise Cancelling", "Ambient"])
        XCTAssertTrue(controller.noiseControlActions.allSatisfy { $0.symbolName == controller.deviceModel.symbol })
        let action = try XCTUnwrap(controller.noiseControlActions.first)
        let wind = String(action.id.dropLast(NoiseControlMode.off.rawValue.count)) + NoiseControlMode.wind.rawValue
        for identifier in [wind, "another-device:anc"] {
            do {
                try await controller.performNoiseControlAction(identifier)
                XCTFail("Unavailable actions must not be sent.")
            } catch {
                XCTAssertEqual(error.localizedDescription, "This noise-control action is no longer available for the selected headphones.")
            }
        }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        let ambient = try XCTUnwrap(controller.noiseControlActions.first { $0.title == NoiseControlMode.ambient.title })
        try await controller.performNoiseControlAction(ambient.id)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
    }

    @MainActor
    func testNoiseActionFailsWhenItsSessionEnds() async throws {
        let controller = makeController()
        let action = await startAction(.anc, controller: controller)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        do {
            try await action.value
            XCTFail("Session loss must fail an unconfirmed action.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The headphone connection changed before the action was confirmed.")
        }
        controller.simulateProtocolMessage([0x69] + payload.dropFirst(), session: session)
        XCTAssertNil(controller.noiseControlMode)
        XCTAssertTrue(controller.noiseControlActions.isEmpty)
    }

    @MainActor
    func testCancellingNoiseActionDoesNotInventAHardwareResult() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let action = await startAction(.anc, controller: controller)
        action.cancel()
        do {
            try await action.value
            XCTFail("A cancelled action must not report success.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
    }

    @MainActor
    func testNoiseSpinnerExpiryAndTransportAcknowledgmentDoNotConfirm() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let action = await startAction(.anc, controller: controller)
        acknowledgeAll(controller)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertFalse(controller.isApplyingChange)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        do {
            try await action.value
            XCTFail("An acknowledged but unconfirmed action must time out.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Headphones did not confirm the change.")
        }
        XCTAssertEqual(controller.noiseControlMode, .ambient)
    }

    @MainActor
    func testNoiseReadbackPreservesLatestDebouncedAmbientValue() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.setAmbientLevel(14)
        try await Task.sleep(for: .milliseconds(180))
        let first = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        acknowledgeAll(controller)
        controller.setAmbientLevel(16)
        deliver([0x69] + first.dropFirst(), to: controller)
        XCTAssertEqual(controller.ambientLevel, 16)
        try await Task.sleep(for: .milliseconds(180))
        let second = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(second[6], 16)
        acknowledgeAll(controller)
        controller.setAmbientLevel(18)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 2)
        deliver([0x69] + second.dropFirst(), to: controller)
        XCTAssertEqual(controller.ambientLevel, 18)
        let latest = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(latest[6], 18)
        acknowledgeAll(controller)
        deliver([0x69] + first.dropFirst(), to: controller)
        XCTAssertEqual(controller.ambientLevel, 18)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        deliver([0x69] + latest.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
    }

    @MainActor
    private func makeController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    func testSpeakToChatQueryRestoresSavedActionsAndIntentPropagatesFailures() async throws {
        let action = HeadphoneSpeakToChatAction(id: "device:speak-to-chat-on", enabled: true, modelName: "WF-1000XM5")
        var query = HeadphoneSpeakToChatQuery()
        query.controls = HeadphoneIntentSpeakToChat(actions: { [] }, resolve: { identifiers in
            identifiers.contains(action.id) ? [action] : []
        }, perform: { _ in })
        let suggested = try await query.suggestedEntities()
        let resolved = try await query.entities(for: [action.id])
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertEqual(resolved.map(\.id), [action.id])
        XCTAssertEqual(action.controlTitle, "Turn On Speak-to-Chat · WF-1000XM5")
        XCTAssertEqual(HeadphoneSpeakToChatQuery.allowedExecutionTargets, .main)
        for configured in [false, true] {
            var intent = SetHeadphoneSpeakToChatIntent(action: configured ? action : nil)
            intent.controls = HeadphoneIntentSpeakToChat(actions: { [] }, resolve: { _ in [] }, perform: { identifier in
                XCTAssertTrue(configured)
                XCTAssertEqual(identifier, action.id)
                throw HeadphoneControlError(message: "Not confirmed")
            })
            do {
                _ = try await intent.perform()
                XCTFail("An unconfigured or failed action must not succeed.")
            } catch {
                XCTAssertEqual(error.localizedDescription, configured ? "Not confirmed" : "Choose a headphone action in the control's settings first.")
            }
        }
        XCTAssertEqual(SetHeadphoneSpeakToChatIntent.allowedExecutionTargets, .main)
        XCTAssertEqual(SetHeadphoneSpeakToChatIntent.supportedModes, .background)
    }

    @MainActor
    func testSpeakToChatActionRequiresTransmittedConfirmationForBothValues() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        for enabled in [true, false] {
            controller.defersSimulatedWrites = true
            let action = await startSpeakToChatAction(enabled, controller: controller)
            let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
            XCTAssertEqual(payload, [0xF8, 0x0C, enabled ? 0 : 1, 1])
            controller.defersSimulatedWrites = false
            deliver([0xF9] + payload.dropFirst(), to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(.speakToChat)])
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            XCTAssertNotNil(controller.pendingChanges[.system(.speakToChat)])
            deliver([0xF7] + payload.dropFirst(), to: controller)
            deliver([0xF9, 0x0C, enabled ? 1 : 0, 1], to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(.speakToChat)])
            controller.setSystemFeature(.pauseOnRemoval, enabled: false)
            acknowledgeAll(controller)
            deliver([0xF9, 0x01, 1], to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(.speakToChat)])
            deliver([0xF9] + payload.dropFirst(), to: controller)
            try await action.value
            XCTAssertEqual(controller.systemFeatureState(.speakToChat)?.enabled, enabled)
            XCTAssertNil(controller.pendingChanges[.system(.speakToChat)])
        }
    }

    @MainActor
    func testSpeakToChatActionTimeoutCannotReuseStaleStateOrAnOldPoll() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let off = try XCTUnwrap(controller.speakToChatActions.first { !$0.enabled }?.id)
        try await controller.performSpeakToChatAction(off)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        controller.refresh()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xF6, 0x0C] }.count, 1)
        let action = await startSpeakToChatAction(true, controller: controller)
        acknowledgeAll(controller)
        controller.simulateSettingTimeout(.system(.speakToChat))
        do {
            try await action.value
            XCTFail("A transport acknowledgement cannot confirm Speak-to-Chat.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Headphones did not confirm the change.")
        }
        do {
            try await controller.performSpeakToChatAction(off)
            XCTFail("The old displayed Off state cannot make an uncertain request a no-op.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        deliver([0xF7, 0x0C, 0, 1], to: controller)
        XCTAssertFalse(controller.canSetSystemFeature(.speakToChat))
        XCTAssertEqual(controller.systemFeatureState(.speakToChat)?.enabled, false)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xF6, 0x0C] }.count, 2)
        deliver([0xF7, 0x0C, 1, 1], to: controller)
        XCTAssertTrue(controller.canSetSystemFeature(.speakToChat))
        let writes = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.count
        try await controller.performSpeakToChatAction(off)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.count, writes)
    }

    @MainActor
    func testSpeakToChatActionCancellationAndSessionLossRemainFailures() async throws {
        for cancel in [true, false] {
            let controller = makeController()
            defer { controller.simulateControlLoss() }
            let action = await startSpeakToChatAction(true, controller: controller)
            let session = controller.simulatedControlSession
            if cancel { action.cancel() }
            else { controller.simulateControlLoss() }
            do {
                try await action.value
                XCTFail("An interrupted action cannot succeed.")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error.localizedDescription, "The headphone connection changed before the action was confirmed.") }
            }
            if cancel {
                XCTAssertNotNil(controller.pendingChanges[.system(.speakToChat)])
                acknowledgeAll(controller)
            }
            controller.simulateProtocolMessage([0xF9, 0x0C, 0, 1], session: session)
            if cancel { XCTAssertEqual(controller.systemFeatureState(.speakToChat)?.enabled, true) }
            else { XCTAssertNil(controller.systemFeatureState(.speakToChat)) }
        }
    }

    @MainActor
    func testSpeakToChatActionRejectsBusyUnavailableAndWrongIdentityBeforeNoOp() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let off = try XCTUnwrap(controller.speakToChatActions.first { !$0.enabled }?.id)
        for identifier in [off.replacingOccurrences(of: "wfXM5", with: "whXM5"), "other:speak-to-chat-off"] {
            do {
                try await controller.performSpeakToChatAction(identifier)
                XCTFail("An action must stay on its exact device.")
            } catch { XCTAssertTrue(error is HeadphoneControlError) }
        }
        controller.setSystemFeature(.pauseOnRemoval, enabled: false)
        do {
            try await controller.performSpeakToChatAction(off)
            XCTFail("A same-state action must not bypass another pending setting.")
        } catch { XCTAssertEqual(error.localizedDescription, "Wait for the current headphone command to finish.") }
        acknowledgeAll(controller)
        deliver([0xF9, 0x01, 1], to: controller)
        deliver([0xF5, 0x0C, 1, 0], to: controller)
        XCTAssertTrue(controller.speakToChatActions.isEmpty)
        do {
            try await controller.performSpeakToChatAction(off)
            XCTFail("An unavailable feature must not make a same-state action succeed.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.prefix(2) == [0xF8, 0x0C] })
    }

    @MainActor
    private func startSpeakToChatAction(_ enabled: Bool, controller: SonyHeadphonesController) async -> Task<Void, Error> {
        let identifier = controller.speakToChatActions.first { $0.enabled == enabled }!.id
        let started = expectation(description: "Speak-to-Chat action started")
        let action = Task { @MainActor in
            started.fulfill()
            try await controller.performSpeakToChatAction(identifier)
        }
        await fulfillment(of: [started], timeout: 1)
        return action
    }

    @MainActor
    func testNativeActionsSerializeBehindBackgroundReadsAndFailIfThatSessionEnds() async throws {
        for speakToChat in [false, true] {
            for loseSession in [false, true] {
                let controller = makeController()
                defer { controller.simulateControlLoss() }
                controller.refresh()
                let read = try XCTUnwrap(controller.simulatedPendingFrame)
                let action: Task<Void, Error>
                if speakToChat { action = await startSpeakToChatAction(true, controller: controller) }
                else { action = await startAction(.anc, controller: controller) }
                let setting: SonyHeadphonesController.Setting = speakToChat ? .system(.speakToChat) : .noiseControl
                XCTAssertEqual(controller.simulatedPendingFrame, read)
                XCTAssertNotNil(controller.pendingChanges[setting])
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == (speakToChat ? 0xF8 : 0x68) })
                if loseSession {
                    controller.simulateControlLoss()
                    do {
                        try await action.value
                        XCTFail("Losing the preceding read's session must fail the queued native action.")
                    } catch {
                        XCTAssertEqual(error.localizedDescription, "The headphone connection changed before the action was confirmed.")
                    }
                    XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == (speakToChat ? 0xF8 : 0x68) })
                } else {
                    acknowledgeAll(controller)
                    let setter = try XCTUnwrap(controller.simulatedTransmittedFrames.last { $0.payload.first == (speakToChat ? 0xF8 : 0x68) })
                    XCTAssertNotNil(controller.pendingChanges[setting])
                    deliver([speakToChat ? 0xF9 : 0x69] + setter.payload.dropFirst(), to: controller)
                    try await action.value
                    XCTAssertNil(controller.pendingChanges[setting])
                    if speakToChat { XCTAssertEqual(controller.systemFeatureState(.speakToChat)?.enabled, true) }
                    else { XCTAssertEqual(controller.noiseControlMode, .anc) }
                }
            }
        }
    }

    @MainActor
    private func startAction(_ mode: NoiseControlMode, controller: SonyHeadphonesController) async -> Task<Void, Error> {
        let identifier = controller.noiseControlActions.first { $0.title == mode.title }!.id
        let started = expectation(description: "Noise action started")
        let action = Task { @MainActor in
            started.fulfill()
            try await controller.performNoiseControlAction(identifier)
        }
        await fulfillment(of: [started], timeout: 1)
        return action
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

}
