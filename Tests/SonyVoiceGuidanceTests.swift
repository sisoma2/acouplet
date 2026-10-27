import XCTest
@testable import Acouplet

final class SonyVoiceGuidanceTests: XCTestCase {
    func testLegacyGuidanceUsesDistinctCapabilitySelectorsAndOppositeBooleanEncoding() {
        for functions: Set<UInt8> in [[], [0x42], [0x40, 0x41, 0x43]] {
            let guidance = SonyVoiceGuidance(supportedFunctions: functions, generation: .v1)
            XCTAssertFalse(guidance.supportsGuidance)
            XCTAssertTrue(guidance.queryPayloads.isEmpty)
        }
        var guidance = SonyVoiceGuidance(supportedFunctions: [0x39], generation: .v1)
        XCTAssertEqual(guidance.queryPayloads, [[0x40, 1]])
        XCTAssertFalse(guidance.supportsVolume)
        XCTAssertTrue(guidance.update([0x41, 1, 1, 0]))
        XCTAssertEqual(guidance.supportedLanguages, [])
        XCTAssertEqual(guidance.queryPayloads, [[0x42, 1, 1], [0x46, 1, 1]])
        XCTAssertTrue(guidance.update([0x43, 1, 1, 0]))
        XCTAssertTrue(guidance.update([0x47, 1, 1, 1]))
        XCTAssertEqual(guidance.enabled, true)
        XCTAssertNil(guidance.currentLanguage)
        XCTAssertEqual(guidance.setEnabledPayload(false), [0x48, 1, 1, 0])
        XCTAssertEqual(guidance.setEnabledPayload(true), [0x48, 1, 1, 1])
        XCTAssertNil(guidance.setVolumePayload(0))
        XCTAssertNil(guidance.volumeAvailable)
        var modern = readyGuidance()
        XCTAssertTrue(modern.update([0x47, 1, 1, 1]))
        XCTAssertEqual(modern.enabled, false)
        XCTAssertEqual(modern.currentLanguage, 1)
        XCTAssertTrue(guidance.update([0x41, 1, 1, 1, 2, 1, 0xF0]))
        XCTAssertEqual(guidance.supportedLanguages, [1, 0xF0])
        XCTAssertEqual(guidance.setEnabledPayload(false), [0x48, 1, 1, 0])
        let prior = guidance
        for payload: [UInt8] in [[0x41, 1, 1], [0x41, 1, 1, 0, 0], [0x41, 1, 1, 1],
                                 [0x41, 1, 1, 1, 2, 1], [0x41, 1, 1, 2], syntheticCapability,
                                 [0x43, 1, 0, 0], [0x47, 1, 0, 1], [0x49, 1, 0, 1], [0x47, 0x20, 0]] {
            XCTAssertFalse(guidance.update(payload), "\(payload)")
            XCTAssertEqual(guidance, prior)
        }
        XCTAssertTrue(guidance.update([0x45, 1, 1, 0xFF]))
        XCTAssertNil(guidance.available)
        XCTAssertNil(guidance.setEnabledPayload(false))
        XCTAssertTrue(guidance.update([0x45, 1, 1, 0]))
        XCTAssertTrue(guidance.update([0x49, 1, 1, 0xFF]))
        XCTAssertNil(guidance.enabled)
        XCTAssertNil(guidance.setEnabledPayload(false))
        XCTAssertTrue(guidance.update([0x41, 1, 0xFF, 0]))
        XCTAssertNil(guidance.supportsOnOffSwitch)
        XCTAssertTrue(guidance.queryPayloads.isEmpty)
    }

    func testOnlyNegotiatedWFDialectProducesCapabilityStatusAndParameterQueries() {
        for functions: Set<UInt8> in [[], [0x40, 0x41, 0x43, 0x44, 0x45], [0x46, 0x47, 0x48]] {
            var guidance = SonyVoiceGuidance(supportedFunctions: functions)
            XCTAssertFalse(guidance.supportsGuidance)
            XCTAssertTrue(guidance.queryPayloads.isEmpty)
            XCTAssertFalse(guidance.update(syntheticCapability))
            XCTAssertFalse(guidance.update([0x47, 1, 0, 1]))
            XCTAssertNil(guidance.setEnabledPayload(true))
            XCTAssertNil(guidance.setVolumePayload(0))
        }
        let guidance = SonyVoiceGuidance(supportedFunctions: [0x42])
        XCTAssertTrue(guidance.supportsGuidance)
        XCTAssertEqual(guidance.queryPayloads, [[0x40, 1], [0x42, 1, 0], [0x46, 1], [0x46, 0x20]])
    }

    func testCapturedSettingsNeedCapabilityAndGuidanceAvailabilityBeforeWrites() {
        var guidance = SonyVoiceGuidance(supportedFunctions: [0x42])
        XCTAssertTrue(guidance.update([0x47, 0x01, 0x00, 0x01]))
        XCTAssertTrue(guidance.update([0x47, 0x20, 0x00]))
        XCTAssertEqual(guidance.enabled, true)
        XCTAssertEqual(guidance.currentLanguage, 1)
        XCTAssertEqual(guidance.volume, 0)
        XCTAssertNil(guidance.setEnabledPayload(false))
        XCTAssertNil(guidance.setVolumePayload(1))
        XCTAssertTrue(guidance.update([0x43, 1, 0, 0]))
        XCTAssertNil(guidance.setEnabledPayload(false))
        XCTAssertNil(guidance.setVolumePayload(1))
        XCTAssertTrue(guidance.update(syntheticCapability))
        XCTAssertEqual(guidance.supportedLanguages, [1, 0x10])
        XCTAssertEqual(guidance.setEnabledPayload(false), [0x48, 1, 1])
        XCTAssertEqual(guidance.setVolumePayload(1), [0x48, 0x20, 1, 1])
        XCTAssertEqual(guidance.queryPayloads, [[0x42, 1, 0], [0x46, 1], [0x46, 0x20]])
    }

    func testSignedVolumeRangeAlwaysSuppressesPreviewAndDoesNotMutateReportedState() {
        var guidance = readyGuidance()
        let prior = guidance
        for value in -2...2 {
            let byte = UInt8(bitPattern: Int8(value))
            XCTAssertEqual(guidance.setVolumePayload(value), [0x48, 0x20, byte, 0x01])
            XCTAssertEqual(guidance, prior)
        }
        for value in [Int.min, -3, 3, Int.max] { XCTAssertNil(guidance.setVolumePayload(value)) }
        for value in -2...2 {
            XCTAssertTrue(guidance.update([0x47, 0x20, UInt8(bitPattern: Int8(value))]))
            XCTAssertEqual(guidance.volume, value)
        }
        XCTAssertEqual(guidance.enabled, prior.enabled)
        XCTAssertEqual(guidance.currentLanguage, prior.currentLanguage)
    }

    func testEnableSetterOmitsLanguageAndVolumeUsesGuidanceAvailability() {
        var guidance = readyGuidance()
        XCTAssertTrue(guidance.update([0x47, 1, 1, 0xF0]))
        let prior = guidance
        XCTAssertEqual(guidance.setEnabledPayload(true), [0x48, 1, 0])
        XCTAssertEqual(guidance, prior)
        XCTAssertEqual(guidance.currentLanguage, 0xF0)
        XCTAssertFalse(guidance.update([0x45, 1, 1, 1]))
        XCTAssertEqual(guidance.available, true)
        XCTAssertTrue(guidance.update([0x45, 1, 0, 1]))
        XCTAssertNil(guidance.setEnabledPayload(true))
        XCTAssertNil(guidance.setVolumePayload(1))
        XCTAssertFalse(guidance.update([0x45, 0x20, 0]))
        XCTAssertNil(guidance.setVolumePayload(1))
        XCTAssertTrue(guidance.update([0x45, 1, 0, 0]))
        XCTAssertNotNil(guidance.setEnabledPayload(true))
        XCTAssertNotNil(guidance.setVolumePayload(1))
        var noSwitch = syntheticCapability
        noSwitch[6] = 0
        XCTAssertTrue(guidance.update(noSwitch))
        XCTAssertEqual(guidance.supportsOnOffSwitch, false)
        XCTAssertNil(guidance.setEnabledPayload(true))
        XCTAssertTrue(guidance.update([0x45, 1, 0, 0xFF]))
        XCTAssertNil(guidance.available)
        XCTAssertEqual(guidance.volumeAvailable, true)
        XCTAssertNotNil(guidance.setVolumePayload(1))
    }

    func testUnknownValuesClearKnownSettingsAndAvailabilityWithoutGuessingDefaults() {
        var guidance = readyGuidance()
        XCTAssertTrue(guidance.update([0x47, 1, 2, 0xFE]))
        XCTAssertNil(guidance.enabled)
        XCTAssertEqual(guidance.currentLanguage, 0xFE)
        XCTAssertNil(guidance.setEnabledPayload(true))
        for raw: UInt8 in [3, 0xFD, 0x7F, 0x80] {
            XCTAssertTrue(guidance.update([0x47, 0x20, raw]))
            XCTAssertNil(guidance.volume)
            XCTAssertNil(guidance.setVolumePayload(0))
        }
        guidance = readyGuidance()
        XCTAssertTrue(guidance.update([0x43, 1, 0, 0xFF]))
        XCTAssertFalse(guidance.update([0x43, 0x20, 0]))
        XCTAssertNil(guidance.available)
        XCTAssertNil(guidance.volumeAvailable)
        XCTAssertNil(guidance.setEnabledPayload(false))
        XCTAssertNil(guidance.setVolumePayload(1))
        var unknownSwitch = syntheticCapability
        unknownSwitch[6] = 2
        XCTAssertTrue(guidance.update(unknownSwitch))
        XCTAssertNil(guidance.supportsOnOffSwitch)
        XCTAssertNil(guidance.volumeAvailable)
        XCTAssertNil(guidance.setVolumePayload(1))
    }

    func testMalformedCapabilityStatusAndParameterPacketsPreservePriorState() {
        var guidance = readyGuidance()
        let prior = guidance
        for length in 0..<syntheticCapability.count {
            XCTAssertFalse(guidance.update(Array(syntheticCapability.prefix(length))))
            XCTAssertEqual(guidance, prior)
        }
        for payload: [UInt8] in [syntheticCapability + [0], [0x41, 1, 0, 0, 0, 0, 1, 3, 1, 0x10],
                                 [0x43, 1, 0], [0x45, 1, 0, 0, 0], [0x43, 1, 2, 0],
                                 [0x43, 0x20], [0x43, 0x20, 0], [0x45, 0x20, 0], [0x45, 0x20, 0, 0], [0x47, 1, 0], [0x47, 1, 0, 1, 0],
                                 [0x47, 0x20], [0x47, 0x20, 0, 1], [0x47, 2, 0, 1],
                                 [0x49, 1, 0, 1], [0x49, 0x20, 0], [0x48, 1, 0], [0x41, 0x20]] {
            XCTAssertFalse(guidance.update(payload), "\(payload)")
            XCTAssertEqual(guidance, prior)
        }
    }

    @MainActor
    func testLiveWFFunction42RepliesEnableSilentVolumeWithOwnedConfirmation() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        negotiateGuidance(to: controller)
        for query: [UInt8] in [[0x40, 1], [0x42, 1, 0], [0x46, 1], [0x46, 0x20]] {
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == query }.count, 1)
        }
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x42, 0x20] })
        for payload: [UInt8] in [
            [0x41, 0x01, 0x03, 0, 0, 0, 1, 0x0F, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0A, 0x0B, 0x0D, 0x0F, 0x10, 0xF0],
            [0x43, 0x01, 0, 0], [0x47, 0x01, 0, 1], [0x47, 0x20, 1],
        ] {
            controller.simulateProtocolMessage(payload, type: 0x0E)
        }
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertEqual(controller.voiceGuidance.volume, 1)
        XCTAssertEqual(controller.voiceGuidance.volumeAvailable, true)
        controller.setVoiceGuidanceVolume(-2)
        let write = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(write.type, 0x0E)
        XCTAssertEqual(write.payload, [0x48, 0x20, 0xFE, 1])
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains(write))
        XCTAssertEqual(controller.pendingChanges[.voiceGuidanceVolume], [0xFE])
        XCTAssertEqual(controller.voiceGuidance.volume, 1)
        controller.simulateProtocolMessage([0x47, 0x20, 0xFE], type: 0x0E)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidanceVolume], [0xFE])
        XCTAssertEqual(controller.voiceGuidance.volume, 1)
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 0x20] }.count, 2)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidanceVolume], [0xFE])
        controller.simulateProtocolMessage([0x47, 0x20, 0xFE], type: 0x0E)
        XCTAssertNil(controller.pendingChanges[.voiceGuidanceVolume])
        XCTAssertEqual(controller.voiceGuidance.volume, -2)
        for status: UInt8 in [1, 0xFF] {
            controller.simulateProtocolMessage([0x45, 1, 0, status], type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance.volumeAvailable, status == 1 ? false : nil)
            for command: UInt8 in [0x43, 0x45] {
                controller.simulateProtocolMessage([command, 0x20, 0], type: 0x0E)
                XCTAssertEqual(controller.voiceGuidance.volumeAvailable, status == 1 ? false : nil)
            }
            controller.setVoiceGuidanceVolume(0)
            XCTAssertNil(controller.pendingChanges[.voiceGuidanceVolume])
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x48 }.count, 1)
        }
    }

    @MainActor
    func testControllerIsolatesT2RepliesAndConfirmsSilentChangesOnlyFromReportedValues() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setVoiceGuidance(false)
        let enableFrame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(enableFrame.type, 0x0E)
        XCTAssertEqual(enableFrame.payload, [0x48, 1, 1])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertEqual(controller.voiceGuidance.currentLanguage, 1)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x47, 1, 1, 1])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidance])
        for payload: [UInt8] in [[0x47, 1, 1], [0x49, 1, 1, 1], [0x47, 1, 2, 1], [0x47, 1, 0, 1]] {
            controller.simulateProtocolMessage(payload, type: 0x0E)
            XCTAssertNotNil(controller.pendingChanges[.voiceGuidance])
        }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
        XCTAssertEqual(controller.voiceGuidance.currentLanguage, 1)
        controller.simulateProtocolMessage([0x47, 0x20, 0], type: 0x0E)
        controller.setVoiceGuidanceVolume(-2)
        let volumeFrame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(volumeFrame.type, 0x0E)
        XCTAssertEqual(volumeFrame.payload, [0x48, 0x20, 0xFE, 1])
        XCTAssertEqual(controller.voiceGuidance.volume, 0)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidanceVolume])
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x47, 0x20, 0xFE])
        XCTAssertEqual(controller.voiceGuidance.volume, 0)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidanceVolume])
        controller.simulateProtocolMessage([0x47, 0x20, 3], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.volume)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidanceVolume])
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x47, 0x20, 0xFE], type: 0x0E)
        XCTAssertNil(controller.pendingChanges[.voiceGuidanceVolume])
        XCTAssertEqual(controller.voiceGuidance.volume, -2)
        XCTAssertEqual(controller.voiceGuidance.currentLanguage, 1)
        controller.setVoiceGuidance(true)
        XCTAssertNotNil(controller.pendingChanges[.voiceGuidance])
        controller.simulateControlLoss()
        XCTAssertFalse(controller.voiceGuidance.supportsGuidance)
        XCTAssertNil(controller.voiceGuidance.enabled)
        XCTAssertNil(controller.voiceGuidance.volume)
        XCTAssertNil(controller.voiceGuidance.currentLanguage)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    @MainActor
    func testControllerPrewriteGuidanceReadCannotConfirmUntilFreshReadback() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        for _ in 0..<40 { controller.simulateAutomaticRefresh() }
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 1)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setVoiceGuidance(false)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(frame.type, 0x0E)
        XCTAssertEqual(frame.payload, [0x48, 1, 1])
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains(frame))
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 2)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertNil(controller.settingErrors[.voiceGuidance])
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
    }

    @MainActor
    func testGuidanceWritesRequireSourceContextAtAdmissionAndTransmission() throws {
        for volume in [false, true] {
            for queued in [false, true] {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                let setting: SonyHeadphonesController.Setting = volume ? .voiceGuidanceVolume : .voiceGuidance
                if queued {
                    controller.refreshEqualizer()
                    if volume { controller.setVoiceGuidanceVolume(1) }
                    else { controller.setVoiceGuidance(false) }
                    XCTAssertEqual(controller.pendingChanges[setting], [1])
                }
                let session = controller.simulatedControlSession
                controller.setSourceKeeping(!(try XCTUnwrap(controller.multipoint.keeping)))
                XCTAssertEqual(controller.sourceTransition?.isFinished, false)
                if !queued {
                    if volume { controller.setVoiceGuidanceVolume(1) }
                    else { controller.setVoiceGuidance(false) }
                }
                acknowledgeSimulatedCommands(controller)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x48 })
                XCTAssertNil(controller.pendingChanges[setting])
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedControlSession, session)
                if queued { XCTAssertNotNil(controller.settingErrors[setting]) }
            }
        }
    }

    @MainActor
    func testQueuedGuidanceWritesRejectLostAvailabilityAndUnknownCurrentState() {
        for volume in [false, true] {
            for change in 0..<3 {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                let inquiry: UInt8 = volume ? 0x20 : 1
                let setting: SonyHeadphonesController.Setting = volume ? .voiceGuidanceVolume : .voiceGuidance
                let session = controller.simulatedControlSession
                controller.refresh()
                if change == 2 {
                    while let frame = controller.simulatedPendingFrame, frame.type != 0x0E || frame.payload != [0x46, inquiry] {
                        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
                    }
                    XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x46, inquiry])
                }
                if volume { controller.setVoiceGuidanceVolume(1) }
                else { controller.setVoiceGuidance(false) }
                XCTAssertEqual(controller.pendingChanges[setting], [1])
                let reply: [UInt8] = change == 2 ? [0x47, inquiry, volume ? 3 : 0xFF] + (volume ? [] : [1])
                    : [0x45, 1, 0, change == 0 ? 1 : 0xFF]
                controller.simulateProtocolMessage(reply, type: 0x0E)
                acknowledgeSimulatedCommands(controller)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x48 })
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertNotNil(controller.settingErrors[setting])
                XCTAssertNil(controller.pendingChanges[setting])
            }
        }
    }

    @MainActor
    func testVolumePrewriteReadAndUncertainGuidanceChangesNeedFreshOwnedReadback() async {
        for testCase in [(volume: true, expires: false), (volume: false, expires: true), (volume: true, expires: true)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let inquiry: UInt8 = testCase.volume ? 0x20 : 1
            let setting: SonyHeadphonesController.Setting = testCase.volume ? .voiceGuidanceVolume : .voiceGuidance
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            if testCase.volume { controller.setVoiceGuidanceVolume(1) }
            else { controller.setVoiceGuidance(false) }
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.pendingChanges[setting], [1])
            if testCase.expires {
                controller.simulateSettingTimeout(setting)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[setting])
                XCTAssertNotNil(controller.settingErrors[setting])
                if testCase.volume { controller.setVoiceGuidanceVolume(-1) }
                else { controller.setVoiceGuidance(false) }
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x48 }.count, 1)
            }
            controller.simulateProtocolMessage([0x47, inquiry, 1] + (testCase.volume ? [] : [1]), type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance.enabled, true)
            XCTAssertEqual(controller.voiceGuidance.volume, 0)
            if testCase.expires { XCTAssertNotNil(controller.settingErrors[setting]) }
            else { XCTAssertEqual(controller.pendingChanges[setting], [1]) }
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, inquiry] }.count, 2)
            controller.simulateProtocolMessage([0x47, inquiry, testCase.expires ? 0 : 1] + (testCase.volume ? [] : [1]), type: 0x0E)
            XCTAssertNil(controller.pendingChanges[setting])
            XCTAssertNil(controller.settingErrors[setting])
            if testCase.expires {
                if testCase.volume { controller.setVoiceGuidanceVolume(1) }
                else { controller.setVoiceGuidance(false) }
                XCTAssertEqual(controller.pendingChanges[setting], [1])
            } else {
                XCTAssertEqual(controller.voiceGuidance.volume, 1)
            }
        }
    }

    @MainActor
    func testGuidanceAvailabilityNotificationRetiresOlderReadAnd49StaysRejected() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x45, 1, 0, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.available, false)
        controller.simulateProtocolMessage([0x43, 1, 0, 0], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.available, false)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x42, 1, 0] }.count, 2)
        controller.simulateProtocolMessage([0x43, 1, 0, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.available, false)
        controller.simulateProtocolMessage([0x49, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
    }

    @MainActor
    func testGuidanceReadDeadlineStartsAtTransmissionAcceptsUnknownsAndResetsWithSession() async {
        for query: [UInt8] in [[0x46, 1], [0x46, 0x20], [0x42, 1, 0]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.defersSimulatedWrites = true
            controller.refresh()
            controller.simulateVoiceGuidanceReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            controller.defersSimulatedWrites = false
            controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance.enabled, true)
            controller.completeSimulatedWrite()
            acknowledgeSimulatedCommands(controller)
            let unknown: [UInt8] = query[0] == 0x46 ? [0x47, query[1], query[1] == 1 ? 0xFF : 3] + (query[1] == 1 ? [1] : [])
                : [0x43, query[1]] + (query[1] == 1 ? [0] : []) + [0xFF]
            controller.simulateProtocolMessage(unknown, type: 0x0E)
            let session = controller.simulatedControlSession
            controller.simulateVoiceGuidanceReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            switch query {
            case [0x46, 1]: XCTAssertNil(controller.voiceGuidance.enabled)
            case [0x46, 0x20]: XCTAssertNil(controller.voiceGuidance.volume)
            default:
                XCTAssertNil(controller.voiceGuidance.available)
                XCTAssertNil(controller.voiceGuidance.volumeAvailable)
            }
            controller.simulateControlLoss()
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E, session: session)
            controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance.enabled, true)
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == query }.count, 2)
        }
    }

    @MainActor
    func testUnansweredGuidanceReadDisablesDependentFieldsAndQuarantinesLateReply() async {
        for query: [UInt8] in [[0x46, 1], [0x46, 0x20], [0x42, 1, 0]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == query })
            let malformed = [query[0] + 1, query[1]]
            controller.simulateProtocolMessage(malformed, type: 0x0E)
            let session = controller.simulatedControlSession
            controller.simulateVoiceGuidanceReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.voiceGuidance.enabled, query == [0x46, 1] ? nil : true)
            XCTAssertEqual(controller.voiceGuidance.volume, query == [0x46, 0x20] ? nil : 0)
            XCTAssertEqual(controller.voiceGuidance.available, query == [0x42, 1, 0] ? nil : true)
            XCTAssertEqual(controller.voiceGuidance.volumeAvailable, query == [0x42, 1, 0] ? nil : true)
            if query == [0x46, 1] { XCTAssertNotNil(controller.voiceGuidance.setVolumePayload(1)) }
            else if query == [0x46, 0x20] { XCTAssertNotNil(controller.voiceGuidance.setEnabledPayload(false)) }
            else {
                XCTAssertNil(controller.voiceGuidance.setEnabledPayload(false))
                XCTAssertNil(controller.voiceGuidance.setVolumePayload(1))
            }
            let prior = controller.voiceGuidance
            let reply: [UInt8] = query[0] == 0x46 ? [0x47, query[1], 0] + (query[1] == 1 ? [1] : [])
                : [0x43, query[1]] + (query[1] == 1 ? [0] : []) + [0]
            controller.simulateProtocolMessage(reply, type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance, prior)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == query }.count, 2)
            controller.simulateProtocolMessage(reply, type: 0x0E)
            XCTAssertEqual(controller.voiceGuidance, readyGuidance())
        }
    }

    @MainActor
    func testUnknownOwnedGuidanceConfirmationLeavesChangeUnconfirmedWithoutLosingSession() async {
        for volume in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let inquiry: UInt8 = volume ? 0x20 : 1
            let setting: SonyHeadphonesController.Setting = volume ? .voiceGuidanceVolume : .voiceGuidance
            if volume { controller.setVoiceGuidanceVolume(1) }
            else { controller.setVoiceGuidance(false) }
            acknowledgeSimulatedCommands(controller)
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.pendingChanges[setting], [1])
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, inquiry] }.count, 1)
            controller.simulateProtocolMessage([0x47, inquiry, volume ? 3 : 0xFF] + (volume ? [] : [1]), type: 0x0E)
            XCTAssertEqual(controller.pendingChanges[setting], [1])
            let session = controller.simulatedControlSession
            controller.simulateVoiceGuidanceReadTimeout([0x46, inquiry])
            controller.simulateSettingTimeout(setting)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.pendingChanges[setting])
            XCTAssertNotNil(controller.settingErrors[setting])
            if volume { controller.setVoiceGuidanceVolume(1) }
            else { controller.setVoiceGuidance(false) }
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x48 }.count, 1)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, inquiry] }.count, 2)
            controller.simulateProtocolMessage([0x47, inquiry, 1] + (volume ? [] : [1]), type: 0x0E)
            XCTAssertNil(controller.settingErrors[setting])
            if volume { controller.setVoiceGuidanceVolume(-1) }
            else { controller.setVoiceGuidance(true) }
            XCTAssertNotNil(controller.pendingChanges[setting])
        }
    }

    @MainActor
    func testUnknownGuidanceCapabilityCountsAsReceivedAndLeavesUnsupportedSwitchDisabled() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        negotiateGuidance(to: controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x40, 1] })
        var capability = syntheticCapability
        capability[6] = 0xFF
        controller.simulateProtocolMessage(capability, type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.supportsOnOffSwitch)
        XCTAssertEqual(controller.voiceGuidance.supportedLanguages, [1, 0x10])
        XCTAssertNil(controller.voiceGuidance.setEnabledPayload(false))
        let session = controller.simulatedControlSession
        controller.simulateVoiceGuidanceReadTimeout([0x40, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.voiceGuidance.supportedLanguages, [1, 0x10])
    }

    @MainActor
    func testTimedOutGuidanceReadDoesNotBlockConnectionVerificationOrBecomeFreshAfterRehandshake() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        negotiateGuidanceAndConnection(to: controller, mode: 0)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canChangeConnectionMode)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 1)
        controller.setConnectionMode(.stableConnection)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE8, 5, 1, 0] })
        let session = controller.simulatedControlSession
        controller.simulateProtocolMessage([0xE9, 5, 1, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateVoiceGuidanceReadTimeout([0x46, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0])
        negotiateGuidanceAndConnection(to: controller, mode: 1)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 1)
        XCTAssertNil(controller.voiceGuidance.enabled)
        controller.setVoiceGuidance(false)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x48 })
        controller.simulateProtocolMessage([0x47, 1, 0, 1], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.enabled)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 2)
        controller.simulateProtocolMessage([0x47, 1, 0, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        controller.setVoiceGuidance(false)
        let write = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(write.type, 0x0E)
        XCTAssertEqual(write.payload, [0x48, 1, 1])
        acknowledgeSimulatedCommands(controller)
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1] }.count, 3)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
    }

    @MainActor
    func testUnownedTable2RepliesPreserveQueuedAndTransmittedGuidanceChanges() {
        for queued in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            if queued { controller.refreshEqualizer() }
            controller.setVoiceGuidance(false)
            XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
            let session = controller.simulatedControlSession
            let guidance = controller.voiceGuidance
            let functions = controller.supportedFunctions2
            for payload: [UInt8] in [[7, 0, 3, 0x31, 1, 0x32, 1, 0x53, 1], [7, 0, 0]] {
                controller.simulateProtocolMessage(payload, type: 0x0E)
                XCTAssertEqual(controller.voiceGuidance, guidance)
                XCTAssertEqual(controller.supportedFunctions2, functions)
                XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
            }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x48, 1, 1] })
        }
    }

    @MainActor
    func testAutomaticSimulationConfirmsGuidanceOnlyThroughTransmittedReadback() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        controller.setVoiceGuidance(false)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x46, 1] })
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
        controller.setVoiceGuidanceVolume(-2)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x48, 0x20, 0xFE, 1] })
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x46, 0x20] })
        XCTAssertNil(controller.pendingChanges[.voiceGuidanceVolume])
        XCTAssertEqual(controller.voiceGuidance.volume, -2)
        let guidance = controller.voiceGuidance
        controller.simulateProtocolMessage([7, 0, 1, 0x42, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance, guidance)
    }

    @MainActor
    private func negotiateGuidance(to controller: SonyHeadphonesController) {
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let name = Array("WF-1000XM5".utf8)
        for payload: [UInt8] in [[0x05, 1, UInt8(name.count)] + name, [0x05, 3, 0, 1], [0x07, 0, 0]] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x06, 0] })
        controller.simulateProtocolMessage([0x07, 0, 1, 0x42, 1], type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    private func negotiateGuidanceAndConnection(to controller: SonyHeadphonesController, mode: UInt8) {
        acknowledgeSimulatedCommands(controller)
        let name = Array("WF-1000XM5".utf8)
        for payload: [UInt8] in [[0x05, 1, UInt8(name.count)] + name, [0x05, 3, 0, 1],
                                 [0x07, 0, 3, 0x6B, 0, 0x90, 0, 0xE7, 0]] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 0, 0, 10])
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x05, 2, 5] + Array("1.0.0".utf8), [0xE1, 5, 3, 0, 1, 2, 1, 0],
                                 [0xE3, 5, 0, 0], [0xE7, 5, mode]] {
            controller.simulateProtocolMessage(payload)
        }
        controller.simulateProtocolMessage([0x07, 0, 1, 0x42, 1], type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [syntheticCapability, [0x43, 1, 0, 0], [0x47, 0x20, 0]] {
            controller.simulateProtocolMessage(payload, type: 0x0E)
        }
        acknowledgeSimulatedCommands(controller)
    }

    @MainActor
    func testLegacyGuidanceDoesNotOpenTableTwoWithoutFunction39() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        negotiateLegacyGuidance(to: controller, functions: [0x62, 0x42])
        XCTAssertFalse(controller.voiceGuidance.supportsGuidance)
        XCTAssertFalse(controller.voiceGuidance.supportsVolume)
        controller.simulateProtocolMessage([0x41, 1, 1, 0], type: 0x0E)
        controller.simulateProtocolMessage([0x49, 1, 1, 1], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.enabled)
        controller.setVoiceGuidance(true)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E })
    }

    @MainActor
    func testQueuedLegacyGuidanceWriteRevalidatesAvailabilityBeforeTransmission() {
        for status: UInt8 in [1, 0xFF] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            negotiateLegacyGuidance(to: controller)
            controller.simulateProtocolMessage([0x41, 1, 1, 0], type: 0x0E)
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0x43, 1, 1, 0], type: 0x0E)
            controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
            let session = controller.simulatedControlSession
            controller.refresh()
            controller.setVoiceGuidance(false)
            XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
            controller.simulateProtocolMessage([0x45, 1, 1, status], type: 0x0E)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x48 })
            XCTAssertNil(controller.pendingChanges[.voiceGuidance])
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNotNil(controller.settingErrors[.voiceGuidance])
        }
    }

    @MainActor
    func testUnknownOwnedLegacyGuidanceReplyCountsAsReceivedWithoutConfirmingWrite() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        negotiateLegacyGuidance(to: controller)
        controller.simulateProtocolMessage([0x41, 1, 1, 0], type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x43, 1, 1, 0], type: 0x0E)
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        controller.setVoiceGuidance(false)
        acknowledgeSimulatedCommands(controller)
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1, 1] }.count, 2)
        controller.simulateProtocolMessage([0x47, 1, 1, 0xFF], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.enabled)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        let session = controller.simulatedControlSession
        controller.simulateVoiceGuidanceReadTimeout([0x46, 1, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateSettingTimeout(.voiceGuidance)
        for _ in 0..<4 { await Task.yield() }
        acknowledgeSimulatedCommands(controller)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        XCTAssertNotNil(controller.settingErrors[.voiceGuidance])
        controller.simulateProtocolMessage([0x49, 1, 1, 0xFF], type: 0x0E)
        XCTAssertNotNil(controller.settingErrors[.voiceGuidance])
        controller.simulateProtocolMessage([0x49, 1, 1, 0], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
        XCTAssertNil(controller.settingErrors[.voiceGuidance])
        controller.simulateProtocolMessage([0x45, 1, 1, 0xFF], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.available)
        controller.setVoiceGuidance(true)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
    }

    @MainActor
    func testAdvertisedV1GuidanceUsesSubtypedTableTwoReadsAndFreshConfirmation() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        negotiateLegacyGuidance(to: controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x40, 1] })
        controller.simulateProtocolMessage([0x41, 1, 1, 0], type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x42, 1, 1] })
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x46, 1, 1] })
        controller.simulateProtocolMessage([0x43, 1, 1, 0], type: 0x0E)
        controller.simulateProtocolMessage([0x47, 1, 1, 1])
        XCTAssertNil(controller.voiceGuidance.enabled)
        controller.simulateProtocolMessage([0x47, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertNil(controller.voiceGuidance.currentLanguage)
        XCTAssertNil(controller.voiceGuidance.volume)
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1, 1] }.count, 2)
        controller.setVoiceGuidance(false)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(frame.type, 0x0E)
        XCTAssertEqual(frame.payload, [0x48, 1, 1, 0])
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains(frame))
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        controller.simulateProtocolMessage([0x47, 1, 1, 0], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [1])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x46, 1, 1] }.count, 3)
        controller.simulateProtocolMessage([0x47, 1, 1, 0], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, false)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
        controller.setVoiceGuidanceVolume(1)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.count > 1 && $0.payload[1] == 0x20 })
        controller.defersSimulatedWrites = true
        controller.setVoiceGuidance(true)
        controller.defersSimulatedWrites = false
        controller.simulateProtocolMessage([0x49, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [0])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x48, 1, 1, 1] })
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x49, 1, 1, 0xFF], type: 0x0E)
        XCTAssertNil(controller.voiceGuidance.enabled)
        XCTAssertEqual(controller.pendingChanges[.voiceGuidance], [0])
        controller.simulateProtocolMessage([0x49, 1, 1, 1], type: 0x0E)
        XCTAssertEqual(controller.voiceGuidance.enabled, true)
        XCTAssertNil(controller.pendingChanges[.voiceGuidance])
    }

    @MainActor
    private func negotiateLegacyGuidance(to controller: SonyHeadphonesController, functions: [UInt8] = [0x62, 0x39]) {
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 2, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let name = Array("WH-1000XM3".utf8)
        for payload: [UInt8] in [[5, 1, UInt8(name.count)] + name, [5, 3, 0x20, 0], [7, 0, UInt8(functions.count)] + functions] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], [0x63, 2, 0], [0x67, 2, 1, 2, 0, 1, 0, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.isReady)
    }

    private func readyGuidance() -> SonyVoiceGuidance {
        var guidance = SonyVoiceGuidance(supportedFunctions: [0x42])
        for payload in [syntheticCapability, [0x43, 1, 0, 0], [0x47, 1, 0, 1], [0x47, 0x20, 0]] {
            XCTAssertTrue(guidance.update(payload))
        }
        return guidance
    }

    private var syntheticCapability: [UInt8] { [0x41, 1, 0, 0, 0, 0, 1, 2, 1, 0x10] }
}
