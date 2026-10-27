import CoreAudio
import XCTest
@testable import Acouplet

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class LDACCallAudioTests: XCTestCase {
    private let address = "02:53:4F:4E:59:01"

    func testPowerOffAndDisconnectCancelLDACWithoutReconnecting() async throws {
        for powerOff in [true, false] {
            var pauses = 0
            let (controller, headphones) = try controller(audio: Hardware().audio(), pausePlayback: { pauses += 1 })
            controller.simulateActiveSession(headphones)
            if powerOff {
                headphones.powerOff(expectedSession: try XCTUnwrap(headphones.powerOffSession))
            } else {
                headphones.disconnect()
            }
            XCTAssertNil(controller.simulatedRequestedAddress)
            XCTAssertEqual(pauses, 1)
            XCTAssertFalse(controller.simulatedRestoresAudioOnStop)
            await drainTasks()
            XCTAssertEqual(controller.state, .off)
            XCTAssertNil(controller.targetAddress)
            XCTAssertFalse(controller.isSessionRunning)
            XCTAssertFalse(controller.isAwaitingAutomaticRetry)
            XCTAssertTrue(controller.simulatedLaunches?.isEmpty == true)
            XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
            controller.refreshPreferredCodec(resetAttempts: true)
            XCTAssertEqual(controller.state, .off)
            headphones.simulateControlLoss()
        }
    }

    func testPowerOffAndDisconnectCancelWaitingLDACRequest() async throws {
        for powerOff in [true, false] {
            let hardware = Hardware()
            let audio = hardware.audio()
            let (controller, headphones) = try controller(audio: audio)
            hardware.active = true
            audio.refresh()
            await drainTasks()
            XCTAssertEqual(controller.state, .waitingForDevice)
            if powerOff {
                headphones.powerOff(expectedSession: try XCTUnwrap(headphones.powerOffSession))
            } else {
                headphones.disconnect()
            }
            XCTAssertEqual(controller.state, .off)
            XCTAssertNil(controller.simulatedRequestedAddress)
            XCTAssertNil(controller.targetAddress)
            hardware.active = false
            hardware.time = 10
            audio.refresh()
            await drainTasks()
            XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
            headphones.simulateControlLoss()
        }
    }

    func testAcoupletCaptureHelpersDoNotTriggerCallHandoff() {
        let otherPID = ProcessInfo.processInfo.processIdentifier + 1
        for bundleID in ["dev.baglayan.Acouplet", "dev.baglayan.Acouplet.debug", "dev.baglayan.Acouplet.ldac-audio"] {
            XCTAssertTrue(LDACCallHardware.isAcouplet(pid: otherPID, bundleID: bundleID))
        }
        XCTAssertTrue(LDACCallHardware.isAcouplet(pid: ProcessInfo.processInfo.processIdentifier, bundleID: nil))
        XCTAssertFalse(LDACCallHardware.isAcouplet(pid: otherPID, bundleID: "us.zoom.xos"))
        XCTAssertFalse(LDACCallHardware.isAcouplet(pid: otherPID, bundleID: nil))
    }

    func testOutputTapsDoNotTriggerCallsButAggregatedMicrophonesDo() throws {
        let devices: [AudioObjectID: [AudioObjectID]] = [1: [], 2: [3, 1], 3: [7], 4: [4], 5: [1, 6]]
        let channels: [AudioObjectID: UInt32] = [1: 2, 3: 0, 6: 0, 7: 1]
        func usesMicrophone(_ device: AudioObjectID) throws -> Bool {
            try LDACCallHardware.containsMicrophone([device], channels: { channels[$0] ?? 0 }, subdevices: { devices[$0] })
        }
        XCTAssertFalse(try usesMicrophone(1))
        XCTAssertTrue(try usesMicrophone(2))
        XCTAssertFalse(try usesMicrophone(4))
        XCTAssertFalse(try usesMicrophone(5))
    }

    func testSeparateMicrophoneKeepsLDACButHeadsetActivityRequiresHandoff() {
        let hardware = Hardware()
        hardware.observations = []
        let audio = hardware.audio()
        audio.configure(policy: .external, externalMicrophoneUID: "usb-input")
        audio.monitor(address: address)
        XCTAssertEqual(hardware.input, "usb-input")
        hardware.observations = [.init(processID: 123, processName: "Call", bundleID: "com.test.call", inputUID: "usb-input", inputName: "USB", isBluetooth: false)]
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
        XCTAssertEqual(audio.microphoneActivities.count, 1)
        hardware.observations = [.init(processID: 124, processName: "Restarted call", bundleID: "com.test.call", inputUID: "headset-input", inputName: "Headset", isBluetooth: true)]
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
        hardware.observations = []
        audio.refresh()
        hardware.time = 4
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
        audio.monitor(address: nil)
        XCTAssertEqual(hardware.input, "built-in-input")
    }

    func testSeparateMicrophoneDoesNotReplaceManualInputChangesOrClaimUnknownActivityIsSafe() {
        let hardware = Hardware()
        hardware.observations = []
        let audio = hardware.audio()
        audio.configure(policy: .external, externalMicrophoneUID: "usb-input")
        audio.monitor(address: address)
        hardware.input = "another-input"
        audio.refresh()
        XCTAssertEqual(audio.activity, .unknown)
        audio.monitor(address: nil)
        XCTAssertEqual(hardware.input, "another-input")
    }

    func testManualHandoffRespondsToExplicitChoiceAndHeadsetMicrophone() {
        let hardware = Hardware()
        hardware.observations = [.init(processID: 10, processName: "Call", bundleID: "com.test.call", inputUID: "built-in-input", inputName: "Mac", isBluetooth: false)]
        let audio = hardware.audio()
        audio.configure(policy: .manual, externalMicrophoneUID: nil)
        audio.monitor(address: address)
        XCTAssertEqual(audio.activity, .idle)
        audio.setManualHandoff(true)
        XCTAssertEqual(audio.activity, .active)
        audio.routeForCall()
        XCTAssertEqual(hardware.input, "headset-input")
        audio.setManualHandoff(false)
        hardware.time = 4
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.input, "built-in-input")
        hardware.observations = [.init(processID: 11, processName: "Call", bundleID: "com.test.call", inputUID: "headset-input", inputName: "Headset", isBluetooth: true)]
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
    }

    func testMicrophoneReleaseMustStayIdleForThreeSeconds() {
        let hardware = Hardware()
        let audio = hardware.audio()
        audio.monitor(address: address)
        XCTAssertEqual(audio.activity, .idle)
        hardware.active = true
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
        hardware.active = false
        hardware.time = 2.99
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
        hardware.active = true
        audio.refresh()
        hardware.active = false
        hardware.time = 5
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
        hardware.time = 8
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
    }

    func testRoutingWaitsForNativeDevicesAndRestoresAllDefaults() {
        let hardware = Hardware()
        hardware.active = true
        hardware.available = false
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertTrue(hardware.selections.isEmpty)
        XCTAssertTrue(hardware.systemSelections.isEmpty)
        hardware.available = true
        audio.refresh()
        XCTAssertEqual(hardware.input, "headset-input")
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertEqual(hardware.systemOutput, "headset-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.input, "built-in-input")
        XCTAssertEqual(hardware.output, "built-in-output")
        XCTAssertEqual(hardware.systemOutput, "built-in-output")
    }

    func testManualRouteChangesDuringCallAreKept() {
        let hardware = Hardware()
        hardware.active = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        hardware.input = "usb-input"
        hardware.output = "usb-output"
        hardware.systemOutput = "display-output"
        audio.refresh()
        XCTAssertEqual(hardware.input, "usb-input")
        XCTAssertEqual(hardware.output, "usb-output")
        XCTAssertEqual(hardware.systemOutput, "display-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.input, "usb-input")
        XCTAssertEqual(hardware.output, "usb-output")
        XCTAssertEqual(hardware.systemOutput, "display-output")
    }

    func testCallRoutesSoundEffectsEvenWhenMainOutputAlreadyUsesHeadset() {
        let hardware = Hardware()
        hardware.input = "headset-input"
        hardware.output = "headset-output"
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertTrue(hardware.selections.isEmpty)
        XCTAssertEqual(hardware.systemSelections, ["headset-output"])
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertEqual(hardware.systemOutput, "built-in-output")
    }

    func testCallRestoresSeparateSoundEffectsOutputAfterProfileChanges() {
        let hardware = Hardware()
        hardware.active = true
        hardware.systemOutput = "display-output"
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        hardware.headsetOutput = "headset-call-output"
        hardware.systemOutput = "built-in-output"
        audio.refresh()
        XCTAssertEqual(hardware.systemOutput, "headset-call-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.systemOutput, "display-output")
    }

    func testSoundEffectsRoutingRetriesAfterFailureWithoutLosingOriginalOutput() {
        let hardware = Hardware()
        hardware.active = true
        hardware.rejectSystemWrites = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertEqual(hardware.input, "headset-input")
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertEqual(hardware.systemOutput, "built-in-output")
        XCTAssertNotNil(audio.issue)
        hardware.rejectSystemWrites = false
        audio.refresh()
        XCTAssertEqual(hardware.systemOutput, "headset-output")
        XCTAssertNil(audio.issue)
        hardware.rejectSystemWrites = true
        XCTAssertFalse(audio.finishCall())
        hardware.rejectSystemWrites = false
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.systemOutput, "built-in-output")
    }

    func testSoundEffectsDefaultIsCapturedBeforeMicrophoneChangesIt() {
        let hardware = Hardware()
        hardware.systemOutput = "display-output"
        hardware.systemOutputAfterInputSelection = "headset-output"
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertEqual(hardware.systemOutput, "headset-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.systemOutput, "display-output")
    }

    func testHeadsetOutputIsSelectedAfterMicrophoneChangesTheOutputRoute() {
        let hardware = Hardware()
        hardware.output = "usb-output"
        hardware.outputAfterInputSelection = "built-in-output"
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertEqual(hardware.selections, ["headset-input", "headset-output"])
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.output, "usb-output")
    }

    func testHeadsetOutputIsSelectedEvenWhenMicrophoneSelectionFails() {
        let hardware = Hardware()
        hardware.rejectInputWrites = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertNotNil(audio.issue)
        hardware.rejectInputWrites = false
        hardware.outputAfterInputSelection = "built-in-output"
        audio.routeForCall()
        XCTAssertEqual(hardware.input, "headset-input")
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertNil(audio.issue)
    }

    func testBluetoothProfileChangeSelectsNewHeadsetOutputAndRestoresOriginal() {
        let hardware = Hardware()
        hardware.active = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        hardware.headsetOutput = "headset-call-output"
        hardware.output = "built-in-output"
        audio.refresh()
        XCTAssertEqual(hardware.output, "headset-call-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.output, "built-in-output")
    }

    func testHeadsetReconnectionRetriesRoutingAndPreservesOriginalDefaults() {
        let hardware = Hardware()
        hardware.active = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        hardware.available = false
        hardware.input = "fallback-input"
        hardware.output = "fallback-output"
        hardware.systemOutput = "fallback-output"
        audio.refresh()
        hardware.available = true
        audio.refresh()
        XCTAssertEqual(hardware.input, "headset-input")
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertEqual(hardware.systemOutput, "headset-output")
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.input, "built-in-input")
        XCTAssertEqual(hardware.output, "built-in-output")
        XCTAssertEqual(hardware.systemOutput, "built-in-output")
    }

    func testExistingHeadsetDefaultsAreNotChangedOrRestored() {
        let hardware = Hardware()
        hardware.input = "headset-input"
        hardware.output = "headset-output"
        hardware.systemOutput = "headset-output"
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        XCTAssertTrue(audio.finishCall())
        XCTAssertTrue(hardware.selections.isEmpty)
        XCTAssertTrue(hardware.systemSelections.isEmpty)
    }

    func testMonitoringFailuresDoNotReportIdle() {
        let hardware = Hardware()
        hardware.active = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        hardware.unreadable = true
        hardware.active = false
        hardware.time = 10
        audio.refresh()
        XCTAssertEqual(audio.activity, .unknown)
        XCTAssertNotNil(audio.issue)
        hardware.unreadable = false
        audio.refresh()
        hardware.time = 14
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
        XCTAssertNil(audio.issue)
    }

    func testRoutingFailuresDoNotPreventDetectingTheEndOfACall() {
        let hardware = Hardware()
        hardware.active = true
        hardware.rejectWrites = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        audio.refresh()
        XCTAssertEqual(audio.activity, .active)
        hardware.active = false
        audio.refresh()
        hardware.time = 4
        audio.refresh()
        XCTAssertEqual(audio.activity, .idle)
        XCTAssertTrue(audio.finishCall())
    }

    func testRestorationFailureWaitsForRecoveryOrUserSelection() {
        let hardware = Hardware()
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        hardware.rejectWrites = true
        XCTAssertFalse(audio.finishCall())
        XCTAssertNotNil(audio.issue)
        hardware.input = "usb-input"
        hardware.output = "usb-output"
        hardware.systemOutput = "usb-output"
        XCTAssertTrue(audio.finishCall())
        XCTAssertEqual(hardware.input, "usb-input")
        XCTAssertEqual(hardware.output, "usb-output")
    }

    func testDisablingLDACDuringCallKeepsCallAudioAndStopsMonitoring() {
        let hardware = Hardware()
        hardware.active = true
        let audio = hardware.audio()
        audio.monitor(address: address)
        audio.routeForCall()
        audio.monitor(address: nil)
        hardware.available = false
        hardware.active = false
        hardware.time = 20
        audio.refresh()
        XCTAssertEqual(hardware.input, "headset-input")
        XCTAssertEqual(hardware.output, "headset-output")
        XCTAssertEqual(audio.activity, .unknown)
    }

    func testControllerSuspendsForMicrophoneAndResumesWithoutUsingRecoveryRetry() async throws {
        let hardware = Hardware()
        let audio = hardware.audio()
        let (controller, headphones) = try controller(audio: audio)
        defer { controller.stop(); headphones.simulateControlLoss() }
        hardware.active = true
        audio.refresh()
        await drainTasks()
        XCTAssertEqual(controller.state, .waitingForDevice)
        XCTAssertTrue(controller.isSuspendedForMicrophone)
        XCTAssertFalse(controller.isSessionRunning)
        XCTAssertEqual(controller.simulatedRequestedAddress, address)
        XCTAssertEqual(controller.simulatedRecoveryAttempt, 0)
        XCTAssertTrue(controller.simulatedRestoresAudioOnStop)
        XCTAssertEqual(hardware.input, "headset-input")
        hardware.active = false
        hardware.time = 2
        audio.refresh()
        await drainTasks()
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
        hardware.time = 6
        audio.refresh()
        await drainTasks()
        XCTAssertFalse(controller.isSuspendedForMicrophone)
        XCTAssertEqual(controller.simulatedStarts, [address])
        XCTAssertEqual(hardware.input, "built-in-input")
        XCTAssertEqual(hardware.output, "built-in-output")
    }

    func testExplicitStopDuringCallCannotResumeLDAC() async throws {
        let hardware = Hardware()
        let audio = hardware.audio()
        let (controller, headphones) = try controller(audio: audio)
        defer { headphones.simulateControlLoss() }
        hardware.active = true
        audio.refresh()
        await drainTasks()
        controller.stop()
        hardware.active = false
        hardware.time = 10
        audio.refresh()
        await drainTasks()
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(controller.simulatedRequestedAddress)
        XCTAssertFalse(controller.isSuspendedForMicrophone)
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
        XCTAssertEqual(hardware.input, "headset-input")
    }

    func testLongCallKeepsRequestWhileConnectedButDisconnectExpiresIt() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let hardware = Hardware()
        let audio = hardware.audio()
        let (controller, headphones) = try controller(audio: audio, now: { date })
        defer { controller.stop(); headphones.simulateControlLoss() }
        hardware.active = true
        audio.refresh()
        await drainTasks()
        date = date.addingTimeInterval(60 * 60)
        controller.refreshPreferredCodec()
        XCTAssertEqual(controller.simulatedRequestedAddress, address)
        XCTAssertTrue(controller.isSuspendedForMicrophone)

        headphones.simulateControlLoss(deviceConnected: false)
        await drainTasks()
        date = date.addingTimeInterval(60)
        controller.refreshPreferredCodec()
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(controller.simulatedRequestedAddress)
        XCTAssertFalse(controller.isSuspendedForMicrophone)
        hardware.active = false
        hardware.time = 10
        audio.refresh()
        await drainTasks()
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
    }

    func testEnablingLDACDuringACallWaitsWithoutStartingPlayback() async throws {
        let hardware = Hardware()
        let audio = hardware.audio()
        let (controller, headphones) = try controller(audio: audio)
        defer { controller.stop(); headphones.simulateControlLoss() }
        controller.stop()
        await drainTasks()
        hardware.active = true
        controller.setEnabled(true, forAddress: address)
        await drainTasks()
        XCTAssertTrue(controller.isSuspendedForMicrophone)
        XCTAssertEqual(controller.state, .waitingForDevice)
        XCTAssertFalse(controller.isSessionRunning)
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
        XCTAssertEqual(hardware.input, "headset-input")
    }

    func testSelectingAnotherOutputDuringACallBlocksAutomaticResume() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let hardware = Hardware()
        let audio = hardware.audio()
        let route = MacAudioRouteObserver(startAutomatically: false)
        let (controller, headphones) = try controller(audio: audio, route: route, now: { date })
        defer { controller.stop(); headphones.simulateControlLoss() }
        hardware.active = true
        audio.refresh()
        await drainTasks()
        hardware.output = "usb-output"
        route.simulateRoute(MacAudioRoute(deviceID: 2, name: nil, uid: "usb-output",
                                         transport: MacAudioTransport(rawValue: kAudioDeviceTransportTypeUSB),
                                         outputChannels: 2, nominalSampleRate: 48000))
        hardware.active = false
        audio.refresh()
        hardware.time = 4
        audio.refresh()
        await drainTasks()
        XCTAssertFalse(controller.isSuspendedForMicrophone)
        XCTAssertEqual(controller.state, .waitingForDevice)
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
        XCTAssertEqual(hardware.output, "usb-output")
        date = date.addingTimeInterval(60)
        controller.refreshPreferredCodec()
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(controller.simulatedRequestedAddress)
        XCTAssertEqual(hardware.output, "usb-output")
    }

    func testUnknownMicrophoneStateBlocksControllerResume() async throws {
        let hardware = Hardware()
        let audio = hardware.audio()
        let (controller, headphones) = try controller(audio: audio)
        defer { controller.stop(); headphones.simulateControlLoss() }
        hardware.active = true
        audio.refresh()
        await drainTasks()
        hardware.active = false
        hardware.time = 10
        hardware.unreadable = true
        audio.refresh()
        await drainTasks()
        XCTAssertTrue(controller.isSuspendedForMicrophone)
        XCTAssertTrue(controller.simulatedStarts?.isEmpty == true)
        hardware.unreadable = false
        audio.refresh()
        hardware.time = 14
        audio.refresh()
        await drainTasks()
        XCTAssertEqual(controller.simulatedStarts, [address])
    }

    private func drainTasks() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func controller(audio: LDACCallAudio, route: MacAudioRouteObserver? = nil,
                            now: @escaping () -> Date = Date.init,
                            pausePlayback: @escaping () -> Void = {}) throws -> (LDACController, SonyHeadphonesController) {
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5)
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let route = route ?? MacAudioRouteObserver(startAutomatically: false)
        route.simulateRoute(MacAudioRoute(deviceID: 1, name: nil, uid: "built-in-output",
                                         transport: MacAudioTransport(rawValue: kAudioDeviceTransportTypeBuiltIn),
                                         outputChannels: 2, nominalSampleRate: 48000))
        let controller = LDACController(devices: coordinator, audioRoute: route, inspectDriver: { _ in .current }, callAudio: audio,
                                        localBluetoothAddress: { "02:00:00:00:00:01" }, now: now)
        controller.simulateHelpers(pausePlayback: pausePlayback)
        controller.simulateRecoverySession(headphones)
        return (controller, headphones)
    }

    @MainActor
    private final class Hardware {
        var active = false
        var observations: [LDACMicrophoneActivity]?
        var available = true
        var unreadable = false
        var rejectWrites = false
        var rejectInputWrites = false
        var rejectSystemWrites = false
        var input = "built-in-input"
        var output = "built-in-output"
        var systemOutput = "built-in-output"
        var headsetOutput = "headset-output"
        var outputAfterInputSelection: String?
        var systemOutputAfterInputSelection: String?
        var time: TimeInterval = 0
        var selections: [String] = []
        var systemSelections: [String] = []

        func audio() -> LDACCallAudio {
            LDACCallAudio(access: .init(microphoneIsActive: {
                if self.unreadable { throw Failure() }
                return self.active
            }, defaultInputUID: { self.input }, headsetInputUID: { _ in self.available ? "headset-input" : nil }, selectInput: {
                if self.rejectWrites || self.rejectInputWrites { throw Failure() }
                self.input = $0
                self.selections.append($0)
                if $0 == "headset-input", let output = self.outputAfterInputSelection { self.output = output }
                if $0 == "headset-input", let output = self.systemOutputAfterInputSelection { self.systemOutput = output }
            }, defaultOutputUID: { self.output }, headsetOutputUID: { _ in self.available ? self.headsetOutput : nil }, selectOutput: {
                if self.rejectWrites { throw Failure() }
                self.output = $0
                self.selections.append($0)
            }, defaultSystemOutputUID: { self.systemOutput }, selectSystemOutput: {
                if self.rejectWrites || self.rejectSystemWrites { throw Failure() }
                self.systemOutput = $0
                self.systemSelections.append($0)
            }, microphoneActivity: observations == nil ? nil : { self.observations ?? [] }), pollsAutomatically: false, now: { self.time })
        }

        struct Failure: Error {}
    }
}
#endif
