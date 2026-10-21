import Combine
import CoreAudio
import XCTest
@testable import Acouplet

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class LDACDriverInstallerTests: XCTestCase {
    func testPrivateCertificateRequirementIsLimitedToDevelopmentBuilds() throws {
        let certificate = String(repeating: "A", count: 40)
        XCTAssertEqual(try LDACDriverInstaller.signerRequirement(team: nil, certificate: certificate, development: true),
                       "certificate leaf = H\"\(certificate)\"")
        XCTAssertThrowsError(try LDACDriverInstaller.signerRequirement(team: nil, certificate: certificate, development: false))
        for invalid in ["short", String(repeating: "A", count: 39), String(repeating: "A", count: 39) + "\"", String(repeating: "G", count: 40)] {
            XCTAssertThrowsError(try LDACDriverInstaller.signerRequirement(team: nil, certificate: invalid, development: true))
        }
    }

    func testAppleTeamRequirementRemainsAvailableAndAdHocIsRejected() throws {
        XCTAssertEqual(try LDACDriverInstaller.signerRequirement(team: "ABCDE12345", certificate: nil, development: true),
                       "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertThrowsError(try LDACDriverInstaller.signerRequirement(team: nil, certificate: nil, development: true))
    }

    func testInstallationDoesNotClaimLoadedDriverIsUpdated() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 8, installed: 7, loaded: 7), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 8, installed: 8, loaded: 7), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 8, installed: 8, loaded: 8), .current)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: nil), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: 1), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 0, loaded: 0), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: nil), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 0), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 1), .current)
    }

    func testCompatibleDriverDoesNotRequireReinstallationForAppUpdates() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 2, loaded: 2), .current)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 1, loaded: 1), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 2, loaded: 1), .restartRequired)
    }

    func testRefreshDistinguishesInstallationFromRestart() {
        var installed: Int? = 2
        var loaded: Int? = 2
        var inspections = 0
        let controller = LDACController(inspectDriver: { _ in
            inspections += 1
            return LDACDriverInstaller.state(required: 3, installed: installed, loaded: loaded)
        })
        var changes = 0
        let observation = controller.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 1)

        controller.refreshDriverState()
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(changes, 0)

        installed = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 3)
        XCTAssertEqual(changes, 1)

        loaded = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 4)
        XCTAssertEqual(changes, 1)

        loaded = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .current)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 5)
        XCTAssertEqual(changes, 2)

        installed = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .missing)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 6)
        XCTAssertEqual(changes, 3)
    }

    func testBackgroundRefreshOnlyInspectsWhenLDACIsEnabled() {
        var enabled = false
        var inspections = 0
        let controller = LDACController(inspectDriver: { _ in
            inspections += 1
            return .current
        }, isDriverInspectionEnabled: { enabled })
        XCTAssertEqual(inspections, 1)

        controller.refreshDriverStateInBackground()
        XCTAssertEqual(inspections, 1)

        enabled = true
        controller.refreshDriverStateInBackground()
        XCTAssertEqual(inspections, 2)
    }

    func testRefreshAfterCancelledInstallationStillRequiresUpdate() {
        let controller = LDACController(inspectDriver: { _ in
            LDACDriverInstaller.state(required: 3, installed: 2, loaded: 2)
        })
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
    }

    func testUntrustedBundleCannotOpenAnInstaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Untrusted.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "example.untrusted", "CFBundlePackageType": "APPL", "AcoupletDistribution": "development"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("untrusted package".utf8).write(to: resources.appendingPathComponent("Acouplet LDAC Output.pkg"))
        try Data("untrusted package".utf8).write(to: resources.appendingPathComponent("Acouplet LDAC Removal.pkg"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        if case .unavailable = LDACDriverInstaller.inspect(bundle: bundle) {} else { XCTFail("Unsigned app must fail validation") }
        for removal in [false, true] {
            let package = resources.appendingPathComponent(removal ? "Acouplet LDAC Removal.pkg" : "Acouplet LDAC Output.pkg")
            for kind in ["unsigned", "missing", "linked"] {
                if kind == "missing" { try FileManager.default.removeItem(at: package) }
                if kind == "linked" {
                    let outside = directory.appendingPathComponent("outside.pkg")
                    try Data("untrusted package".utf8).write(to: outside)
                    try FileManager.default.createSymbolicLink(at: package, withDestinationURL: outside)
                }
                do {
                    if removal { try await LDACDriverInstaller.openUninstaller(bundle: bundle) }
                    else { try await LDACDriverInstaller.openInstaller(bundle: bundle) }
                    XCTFail("Untrusted package must not open Installer")
                } catch {
                    XCTAssertEqual((error as NSError).domain, kind == "missing" ? NSCocoaErrorDomain : "LDACDriverInstaller")
                }
            }
        }
    }
}

@MainActor
final class LDACDefaultCodecTests: XCTestCase {
    private let address = "02:53:4F:4E:59:01"

    func testActivePlaybackSettingsRestartLDACAndPreserveOtherConfiguration() async throws {
        for changeSampleRate in [true, false] {
            let (ldac, headphones, _) = try prepared()
            defer { ldac.stop(); headphones.simulateControlLoss() }
            await drainTasks()
            var original = LDACConfiguration(latencyOffsetMilliseconds: 70)
            original.bufferProfile = .video
            ldac.simulateActiveSession(headphones, configuration: original)
            let outputID = ldac.simulatedOutputID
            XCTAssertTrue(ldac.canChangePlaybackSettings(forAddress: address))
            var updated = LDACConfiguration()
            if changeSampleRate { updated.sampleRate = .hz96000 }
            else { updated.quality = .quality }

            ldac.updatePlaybackConfiguration(updated, forAddress: address)

            XCTAssertEqual(ldac.state, .stopping)
            XCTAssertFalse(ldac.canChangePlaybackSettings(forAddress: address))
            XCTAssertEqual(ldac.simulatedRequestedAddress, address)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address, address])
            XCTAssertEqual(ldac.simulatedOutputID, outputID)
            XCTAssertEqual(ldac.simulatedLaunches?.map(\.restoringOnly), [false])
            XCTAssertEqual(ldac.currentConfiguration.sampleRate, updated.sampleRate)
            XCTAssertEqual(ldac.currentConfiguration.quality, updated.quality)
            XCTAssertEqual(ldac.currentConfiguration.latencyOffsetMilliseconds, 70)
            XCTAssertEqual(ldac.currentConfiguration.bufferProfile, .video)
        }
    }

    func testUnchangedPlaybackSettingsAndOtherDevicesDoNotRestartLDAC() async throws {
        let (ldac, headphones, _) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        ldac.simulateActiveSession(headphones)
        var configuration = LDACConfiguration(latencyOffsetMilliseconds: 90)
        configuration.bufferProfile = .video
        ldac.updatePlaybackConfiguration(configuration, forAddress: address)
        XCTAssertEqual(ldac.currentConfiguration, LDACConfiguration())

        let otherAddress = "02:53:4F:4E:59:02"
        XCTAssertFalse(ldac.canChangePlaybackSettings(forAddress: otherAddress))
        configuration.sampleRate = .hz96000
        ldac.updatePlaybackConfiguration(configuration, forAddress: otherAddress)
        await drainTasks()
        XCTAssertEqual(ldac.state, .active(LDACConfiguration().format))
        XCTAssertEqual(ldac.currentConfiguration, LDACConfiguration())
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testRepeatedPlaybackChangesKeepOneOutputAndOneRestartPerChange() async throws {
        let (ldac, headphones, _) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        let outputID = try XCTUnwrap(ldac.simulatedOutputID)
        let configurations = [LDACConfiguration(sampleRate: .hz96000),
                              LDACConfiguration(sampleRate: .hz96000, quality: .balanced),
                              LDACConfiguration(sampleRate: .hz44100, quality: .balanced),
                              LDACConfiguration(sampleRate: .hz44100, quality: .quality)]
        for (index, configuration) in configurations.enumerated() {
            ldac.simulateActiveSession(headphones, configuration: ldac.currentConfiguration)
            ldac.updatePlaybackConfiguration(configuration, forAddress: address)
            await drainTasks()
            XCTAssertEqual(ldac.currentConfiguration, configuration)
            XCTAssertEqual(ldac.simulatedOutputID, outputID)
            XCTAssertEqual(ldac.simulatedStarts?.count, index + 2)
            XCTAssertEqual(ldac.simulatedLaunches?.map(\.restoringOnly), Array(repeating: false, count: index + 1))
        }
    }

    func testPlaybackSettingsRestartKeepsOutputWhileHeadphoneControlsReconnect() async throws {
        for configuration in [LDACConfiguration(sampleRate: .hz96000), LDACConfiguration(quality: .quality)] {
            let (ldac, headphones, route) = try prepared()
            defer { ldac.stop(); headphones.simulateControlLoss() }
            await drainTasks()
            ldac.simulateActiveSession(headphones)
            let outputID = ldac.simulatedOutputID

            ldac.updatePlaybackConfiguration(configuration, forAddress: address)
            headphones.simulateControlLoss(deviceConnected: false)
            await drainTasks()

            XCTAssertEqual(ldac.state, .connecting)
            XCTAssertEqual(ldac.simulatedRequestedAddress, address)
            XCTAssertTrue(ldac.isSessionRunning)
            XCTAssertEqual(ldac.simulatedStarts, [address, address])
            XCTAssertEqual(ldac.simulatedOutputID, outputID)
            XCTAssertTrue(ldac.simulatedStartingDirectly)
            XCTAssertEqual(ldac.simulatedLaunches?.map(\.restoringOnly), [false])
            XCTAssertEqual(ldac.currentConfiguration, configuration)

            headphones.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: address, galleryModel: .wfXM5)
            route.simulateRoute(sonyOutput)
            await drainTasks()

            XCTAssertEqual(ldac.simulatedStarts, [address, address])
            XCTAssertTrue(ldac.isSessionRunning)
            XCTAssertEqual(ldac.currentConfiguration, configuration)
            route.simulateRoute(sonyOutput)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address, address])
        }
    }

    func testPlaybackSettingsRestartDoesNotTakeOverAnotherMacOutput() async throws {
        let (ldac, headphones, route) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        ldac.simulateActiveSession(headphones)
        ldac.updatePlaybackConfiguration(LDACConfiguration(sampleRate: .hz96000), forAddress: address)
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        await drainTasks()

        XCTAssertEqual(ldac.state, .waitingForDevice)
        XCTAssertEqual(ldac.simulatedStarts, [address])
        route.simulateRoute(sonyOutput)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address, address])
    }

    func testDisablingLDACWhilePlaybackSettingsReconnectPreventsResume() async throws {
        let (ldac, headphones, route) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        ldac.simulateActiveSession(headphones)
        ldac.updatePlaybackConfiguration(LDACConfiguration(quality: .quality), forAddress: address)
        headphones.simulateControlLoss(deviceConnected: false)
        await drainTasks()
        XCTAssertEqual(ldac.state, .connecting)

        ldac.setEnabled(false, forAddress: address)
        headphones.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: address, galleryModel: .wfXM5)
        route.simulateRoute(sonyOutput)
        await drainTasks()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertEqual(ldac.simulatedStarts, [address, address])
    }

    func testPlaybackSettingsCannotChangeWhileConnecting() async throws {
        let (ldac, headphones, _) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        ldac.simulateRecoverySession(headphones)
        XCTAssertFalse(ldac.canChangePlaybackSettings(forAddress: address))

        ldac.updatePlaybackConfiguration(LDACConfiguration(sampleRate: .hz96000, quality: .quality), forAddress: address)

        XCTAssertEqual(ldac.state, .connecting)
        XCTAssertEqual(ldac.currentConfiguration, LDACConfiguration())
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testDisablingLDACDuringPlaybackSettingsRestartPreventsResume() async throws {
        let (ldac, headphones, _) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        ldac.simulateActiveSession(headphones)
        ldac.updatePlaybackConfiguration(LDACConfiguration(quality: .quality), forAddress: address)

        ldac.setEnabled(false, forAddress: address)
        await drainTasks()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertFalse(ldac.isSessionRunning)
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertTrue(ldac.canChangePlaybackSettings(forAddress: address))
    }

    func testRecognizedSonyModelsAutomaticallyAttemptLDACWhenControlsAreAvailable() async throws {
        var automaticallyStartedModels: [SonyDeviceModel] = []
        for model in SonyDeviceModel.allCases where model != .unknown {
            let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)
            settings.selectLDACDevice(address: address)
            XCTAssertTrue(settings.ldacProfile(forAddress: address).automaticallyEnable, model.name)
            let (ldac, headphones, route) = try prepared(defaults: defaults, model: model,
                preferredConfiguration: { settings.automaticLDACConfiguration(forAddress: $0) })
            defer { ldac.stop(); headphones.simulateControlLoss() }
            await drainTasks()
            guard ldac.deviceUnavailableReason(forAddress: address) == nil else {
                XCTAssertEqual(ldac.simulatedStarts, [], model.name)
                continue
            }
            XCTAssertEqual(ldac.simulatedStarts, [address], model.name)
            automaticallyStartedModels.append(model)

            ldac.stop(restoreAudio: false)
            headphones.simulateControlLoss(deviceConnected: false)
            for _ in 0..<100 where ldac.isSessionRunning { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(ldac.isSessionRunning)
            headphones.simulateDeviceConnection(named: model.name, simulatedAddress: address, galleryModel: model)
            route.simulateRoute(sonyOutput)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address, address], model.name)

            ldac.setEnabled(false, forAddress: address)
            for _ in 0..<100 where ldac.isSessionRunning { try await Task.sleep(for: .milliseconds(5)) }
            route.simulateRoute(sonyOutput)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address, address], model.name)
            XCTAssertNil(ldac.simulatedRequestedAddress)
        }
        for model in [SonyDeviceModel.wfXM5, .whXM5, .wfXM6, .whXM6, .whULT900N, .wh1000XX] {
            XCTAssertTrue(automaticallyStartedModels.contains(model), model.name)
        }
    }

    func testStartsLDACForTheSelectedSonyOutputWithoutAManualRequest() async throws {
        let (ldac, headphones, route) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertEqual(ldac.simulatedRequestedAddress, address)
        route.simulateRoute(sonyOutput)
        ldac.refreshPreferredCodec()
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testFailedAutomaticStartAttemptsAgainOnTheNextHeadphoneConnection() async throws {
        let (ldac, headphones, route) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        ldac.simulateSessionFinished(.init(message: "Startup failed", canRetry: false, requiresAttention: true,
            targetDisconnected: false, waitForReconnect: false))
        await drainTasks()
        XCTAssertEqual(ldac.state, .failed("Startup failed"))
        XCTAssertNil(ldac.simulatedRequestedAddress)
        route.simulateRoute(sonyOutput)
        ldac.refreshPreferredCodec(resetAttempts: true)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])

        headphones.simulateControlLoss(deviceConnected: false)
        await drainTasks()
        headphones.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: address, galleryModel: .wfXM5)
        route.simulateRoute(sonyOutput)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address, address])
        XCTAssertEqual(ldac.simulatedRequestedAddress, address)
    }

    func testAutomaticallyStartsWithoutTheMatchingBluetoothOutput() async throws {
        for output in [nil, output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn),
                       output(uid: "02:53:4F:4E:59:02", transport: kAudioDeviceTransportTypeBluetooth),
                       output(uid: address, transport: kAudioDeviceTransportTypeUSB)] {
            let (ldac, headphones, route) = try prepared()
            defer { ldac.stop(); headphones.simulateControlLoss() }
            route.simulateRoute(output)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address])
            XCTAssertTrue(ldac.simulatedStartingDirectly)
            route.simulateRoute(sonyOutput)
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [address])
        }
    }

    func testConnectStartsLDACBeforeClassicAudioOrControlsAreAvailable() async throws {
        let (ldac, headphones, route) = try prepared(isClassicConnected: { _ in false }, prepareDevices: { devices in
            devices.selectedController.simulateControlLoss(deviceConnected: false)
        })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(headphones.isReady)
        XCTAssertFalse(headphones.isDeviceConnected)
        headphones.connect()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertTrue(ldac.simulatedStartingDirectly)
        headphones.connect()
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testAutomaticDirectStartDoesNotWaitForTheNativeHeadphoneOutput() async throws {
        let (ldac, headphones, route) = try prepared(isClassicConnected: { _ in false }, prepareDevices: { devices in
            devices.selectedController.simulateControlLoss(deviceConnected: false)
        })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        headphones.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: address, galleryModel: .wfXM5)
        headphones.simulateControlLoss(deviceConnected: true)
        await drainTasks()
        XCTAssertFalse(headphones.isReady)
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertTrue(ldac.simulatedStartingDirectly)
    }

    func testAlreadyConnectedHeadphonesAutomaticallyStartDuringControlStartup() async throws {
        let (ldac, headphones, route) = try prepared(prepareDevices: { devices in
            devices.selectedController.simulateControlLoss(deviceConnected: true)
        })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        await drainTasks()
        XCTAssertFalse(headphones.isReady)
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertTrue(ldac.simulatedStartingDirectly)
        route.simulateRoute(sonyOutput)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testUpdateHandoffResumesDisconnectedHeadphonesAndExplicitStopCancelsIt() async throws {
        for cancelled in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let handoff = LDACUpdateHandoff(directory: directory)
            let configuration = LDACConfiguration(sampleRate: .hz96000, quality: .quality)
            let helper = URL(fileURLWithPath: "/usr/bin/true")
            try handoff.prepare(address: address, helper: helper, executable: helper, previousPID: 99999,
                                configuration: JSONEncoder().encode(configuration))
            let (ldac, headphones, route) = try prepared(preferredConfiguration: { _ in nil },
                isClassicConnected: { _ in false }, prepareDevices: { devices in
                    devices.selectedController.simulateControlLoss(deviceConnected: false)
                })
            defer { ldac.stop(restoreAudio: false); headphones.simulateControlLoss() }
            route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
            ldac.resumeUpdateHandoff(handoff: handoff)
            if cancelled { ldac.stop() }
            await drainTasks()
            XCTAssertFalse(headphones.isDeviceConnected)
            XCTAssertEqual(ldac.simulatedStarts, cancelled ? [] : [address])
            if !cancelled {
                XCTAssertTrue(ldac.simulatedStartingDirectly)
                XCTAssertEqual(ldac.currentConfiguration, configuration)
            }
        }
    }

    func testDirectConnectWithoutAnAutomaticProfileDoesNotInspectBluetooth() async throws {
        var bluetoothReads = 0
        let (ldac, headphones, _) = try prepared(preferredConfiguration: { _ in nil }, isClassicConnected: { _ in
            bluetoothReads += 1
            return false
        })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertFalse(ldac.connectDirectly(forAddress: address))
        headphones.connect()
        XCTAssertEqual(bluetoothReads, 0)
        XCTAssertEqual(ldac.simulatedStarts, [])
    }

    func testDirectConnectRespectsOptOutDriverAvailabilityAndUnsupportedModels() async throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([address: false], forKey: "ldac.codecPreferences")
        for model in [SonyDeviceModel.wfXM3, .whCH720N, .wfXM5] {
            let (ldac, headphones, _) = try prepared(defaults: model == .wfXM5 ? defaults : nil, model: model,
                isClassicConnected: { _ in false }, prepareDevices: { devices in
                    devices.selectedController.simulateControlLoss(deviceConnected: false)
                })
            defer { ldac.stop(); headphones.simulateControlLoss() }
            XCTAssertFalse(ldac.connectDirectly(forAddress: address))
            XCTAssertEqual(ldac.simulatedStarts, [])
        }
        let (ldac, headphones, _) = try prepared(inspectDriver: { _ in .missing }, isClassicConnected: { _ in false },
            prepareDevices: { $0.selectedController.simulateControlLoss(deviceConnected: false) })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        XCTAssertFalse(ldac.connectDirectly(forAddress: address))
        XCTAssertEqual(ldac.simulatedStarts, [])
        XCTAssertFalse(ldac.isOpeningDriverInstaller)
    }

    func testWaitsForTheDriverWithoutOpeningTheInstaller() async throws {
        var driver = LDACDriverInstaller.State.missing
        let (ldac, headphones, route) = try prepared(inspectDriver: { _ in driver })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        for state in [LDACDriverInstaller.State.missing, .outdated, .restartRequired, .unavailable("test")] {
            driver = state
            ldac.refreshDriverStateInBackground()
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [])
            XCTAssertFalse(ldac.isOpeningDriverInstaller)
        }
        driver = .current
        ldac.refreshDriverStateInBackground()
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testHidingLDACControlsDisablesAutomaticStartup() async throws {
        var enabled = false
        let (ldac, headphones, route) = try prepared(preferredConfiguration: { _ in enabled ? LDACConfiguration() : nil })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [])
        enabled = true
        ldac.refreshPreferredCodec()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testAnotherAudioSourceBlocksAutomaticStartup() async throws {
        let (ldac, headphones, _) = try prepared(localBluetoothAddress: { "02:00:00:00:00:02" })
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [])
    }

    func testDeviceOptOutPersistsAcrossRelaunchAndManualEnableOverridesIt() async throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (first, firstHeadphones, _) = try prepared(defaults: defaults)
        defer { first.stop(); firstHeadphones.simulateControlLoss() }
        first.setEnabled(false, forAddress: address.replacingOccurrences(of: ":", with: "-").lowercased())
        await drainTasks()
        XCTAssertEqual(first.simulatedStarts, [])

        let (relaunched, headphones, route) = try prepared(defaults: defaults)
        defer { relaunched.stop(); headphones.simulateControlLoss() }
        route.simulateRoute(output(uid: "built-in-output", transport: kAudioDeviceTransportTypeBuiltIn))
        await drainTasks()
        XCTAssertEqual(relaunched.simulatedStarts, [])
        relaunched.setEnabled(true, forAddress: address)
        XCTAssertEqual(relaunched.simulatedStarts, [address])
        XCTAssertEqual(defaults.dictionary(forKey: "ldac.codecPreferences")?[address] as? Bool, true)
    }

    func testUnavailableModelsDoNotStartLDACAndControlStartupCanBeDeferred() async throws {
        for model in [SonyDeviceModel.wfXM3, .whCH720N] {
            let (ldac, headphones, _) = try prepared(model: model)
            defer { ldac.stop(); headphones.simulateControlLoss() }
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [])
        }
        let (ldac, headphones, _) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        headphones.simulateControlLoss()
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        XCTAssertTrue(ldac.simulatedStartingDirectly)
    }

    func testAnOptOutForAnotherSonyDeviceDoesNotChangeTheDefault() async throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["02:53:4F:4E:59:02": false], forKey: "ldac.codecPreferences")
        let (ldac, headphones, _) = try prepared(defaults: defaults)
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
    }

    func testSleepingAndTerminatingBlockAutomaticStartup() async throws {
        for terminating in [false, true] {
            let (ldac, headphones, _) = try prepared(prepareDevices: { devices in
                if terminating { devices.beginTermination() }
                else { devices.isSystemSleeping = true }
            })
            defer { ldac.stop(); headphones.simulateControlLoss() }
            await drainTasks()
            XCTAssertEqual(ldac.simulatedStarts, [])
        }
    }

    func testStopDoesNotImmediatelyStartTheDefaultCodecAgain() async throws {
        let (ldac, headphones, route) = try prepared()
        defer { ldac.stop(); headphones.simulateControlLoss() }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        ldac.stop()
        for _ in 0..<100 where ldac.isSessionRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(ldac.isSessionRunning)
        route.simulateRoute(sonyOutput)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [address])
        ldac.refreshPreferredCodec(resetAttempts: true)
        XCTAssertEqual(ldac.simulatedStarts, [address, address])
    }

    func testPendingDefaultCodecTasksAllowEnvironmentSettingsToBeReleased() async throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        var environment: AppEnvironment? = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: headphones,
                                                         audioRoute: MacAudioRouteObserver(startAutomatically: false))
        weak var settings = environment?.settings
        let ldac = try XCTUnwrap(environment?.ldac)
        environment = nil
        await drainTasks()
        XCTAssertNil(settings)
        ldac.refreshDriverStateInBackground()
        ldac.refreshPreferredCodec(resetAttempts: true)
    }

    private var sonyOutput: MacAudioRoute { output(uid: address, transport: kAudioDeviceTransportTypeBluetooth) }

    private func output(uid: String, transport: UInt32) -> MacAudioRoute {
        MacAudioRoute(deviceID: 1, name: nil, uid: uid, transport: MacAudioTransport(rawValue: transport),
                      outputChannels: 2, nominalSampleRate: 48000)
    }

    private func drainTasks() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func prepared(defaults: UserDefaults? = nil, model: SonyDeviceModel = .wfXM5,
                          inspectDriver: @escaping (Bundle) -> LDACDriverInstaller.State = { _ in .current },
                          preferredConfiguration: @escaping (String) -> LDACConfiguration? = { _ in LDACConfiguration() },
                          localBluetoothAddress: @escaping () -> String? = { "02:00:00:00:00:01" },
                          isClassicConnected: @escaping (String) -> Bool = { _ in true },
                          prepareDevices: (SonyDeviceCoordinator) -> Void = { _ in }) throws -> (LDACController, SonyHeadphonesController, MacAudioRouteObserver) {
        let devices = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let headphones = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            headphones.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: model)
            return headphones
        }
        devices.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: model.name, model: model))])
        prepareDevices(devices)
        let headphones = try XCTUnwrap(devices.controller(for: address))
        let route = MacAudioRouteObserver(startAutomatically: false)
        route.simulateRoute(sonyOutput)
        let ldac = LDACController(devices: devices, audioRoute: route, defaults: defaults, inspectDriver: inspectDriver,
                                  preferredConfiguration: preferredConfiguration, localBluetoothAddress: localBluetoothAddress,
                                  isClassicConnected: isClassicConnected)
        ldac.simulateHelpers()
        return (ldac, headphones, route)
    }
}

@MainActor
final class LDACRequestLifecycleTests: XCTestCase {
    private let first = "02:53:4F:4E:59:01"
    private let second = "02:53:4F:4E:59:02"

    func testSelectingEarbudsReplacesTheOvernightHeadphoneRequest() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let (ldac, devices, _) = try prepared(now: { date })
        defer { stop(ldac, devices) }
        await drainTasks()
        XCTAssertEqual(ldac.simulatedStarts, [first])
        devices.isSystemSleeping = true
        ldac.suspend()
        await drainTasks()
        XCTAssertEqual(ldac.state, .waitingForDevice)
        devices.controller(for: first)?.simulateControlLoss(deviceConnected: false)
        date = date.addingTimeInterval(12 * 60 * 60)
        devices.isSystemSleeping = false
        devices.reconcileConnectedDevices([device(second, model: .wfXM5)])
        await drainTasks()

        XCTAssertEqual(ldac.simulatedRequestedAddress, second)
        XCTAssertEqual(ldac.simulatedStarts, [first, second])
    }

    func testSelectingDifferentHeadphonesCancelsWaitingWithoutWaitingForExpiry() async throws {
        let (ldac, devices, _) = try prepared()
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.controller(for: first)?.simulateControlLoss(deviceConnected: false)
        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
            targetDisconnected: true, waitForReconnect: true))
        await drainTasks()
        XCTAssertEqual(ldac.state, .waitingForDevice)

        devices.reconcileConnectedDevices([device(second, model: .wfXM5)])
        await drainTasks()

        XCTAssertEqual(ldac.simulatedRequestedAddress, second)
        XCTAssertEqual(ldac.simulatedStarts, [first, second])
    }

    func testChangingSelectionDuringPlaybackStartsTheNewAutomaticProfileAfterCleanup() async throws {
        let (ldac, devices, _) = try prepared()
        defer { stop(ldac, devices) }
        await drainTasks()
        let headphones = try XCTUnwrap(devices.controller(for: first))
        ldac.simulateActiveSession(headphones)
        devices.reconcileConnectedDevices([device(first, model: .whXM5), device(second, model: .wfXM5)])
        devices.select(address: second)
        await drainTasks()

        XCTAssertEqual(ldac.simulatedRequestedAddress, second)
        XCTAssertEqual(ldac.simulatedStarts, [first, second])
    }

    func testSwitchingPlaybackBackAndForthKeepsBothHeadphonesConnected() async throws {
        let (ldac, devices, _) = try prepared()
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.reconcileConnectedDevices([device(first, model: .whXM5), device(second, model: .wfXM5)])
        var expectedStarts = [first]

        for address in [second, first, second, first] {
            ldac.simulateActiveSession(devices.selectedController)
            devices.select(address: address)
            await drainTasks()
            expectedStarts.append(address)

            XCTAssertEqual(ldac.simulatedRequestedAddress, address)
            XCTAssertEqual(ldac.simulatedStarts, expectedStarts)
            XCTAssertEqual(Set(devices.connectedDevices.map(\.address)), Set([first, second]))
            XCTAssertTrue(devices.controllers.allSatisfy(\.isDeviceConnected))
        }
    }

    func testSwitchingBackToHeadphonesWithLDACDisabledKeepsItOff() async throws {
        let (ldac, devices, _) = try prepared()
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.reconcileConnectedDevices([device(first, model: .whXM5), device(second, model: .wfXM5)])
        ldac.simulateActiveSession(devices.selectedController)
        ldac.setEnabled(false, forAddress: first)
        await drainTasks()
        devices.select(address: second)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedRequestedAddress, second)
        ldac.simulateActiveSession(devices.selectedController)

        devices.select(address: first)
        await drainTasks()

        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertEqual(ldac.state, .off)
        XCTAssertEqual(ldac.simulatedStarts, [first, second])
        XCTAssertEqual(Set(devices.connectedDevices.map(\.address)), Set([first, second]))
    }

    func testSwitchingBackDuringCleanupResumesOnlyTheLatestSelection() async throws {
        let (ldac, devices, _) = try prepared()
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.reconcileConnectedDevices([device(first, model: .whXM5), device(second, model: .wfXM5)])
        ldac.simulateActiveSession(devices.selectedController)
        var switchedBack = false
        let observation = ldac.$state.sink { state in
            guard state == .stopping, !switchedBack else { return }
            switchedBack = true
            devices.select(address: self.first)
        }
        defer { observation.cancel() }

        devices.select(address: second)
        await drainTasks()

        XCTAssertTrue(switchedBack)
        XCTAssertEqual(devices.selectedAddress, first)
        XCTAssertEqual(ldac.simulatedRequestedAddress, first)
        XCTAssertEqual(ldac.simulatedStarts, [first, first])
    }

    func testDisconnectedRequestExpiresAtSixtySecondsAndReconnectionStartsFresh() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let (ldac, devices, route) = try prepared(now: { date })
        defer { stop(ldac, devices) }
        await drainTasks()
        let headphones = try XCTUnwrap(devices.controller(for: first))
        headphones.simulateControlLoss(deviceConnected: false)
        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
            targetDisconnected: true, waitForReconnect: true))
        await drainTasks()
        XCTAssertEqual(ldac.state, .waitingForDevice)

        date = date.addingTimeInterval(59.9)
        ldac.refreshPreferredCodec()
        XCTAssertEqual(ldac.simulatedRequestedAddress, first)
        date = date.addingTimeInterval(0.1)
        ldac.refreshPreferredCodec()
        await drainTasks()
        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertNil(ldac.targetAddress)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry)
        XCTAssertEqual(ldac.simulatedStarts, [first])

        headphones.simulateDeviceConnection(named: "WH-1000XM5", simulatedAddress: first, galleryModel: .whXM5)
        route.simulateRoute(output)
        await drainTasks()
        XCTAssertEqual(ldac.simulatedRequestedAddress, first)
        XCTAssertEqual(ldac.simulatedStarts, [first, first])
    }

    func testBriefDisconnectionResumesTheSameRequest() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let (ldac, devices, route) = try prepared(now: { date })
        defer { stop(ldac, devices) }
        await drainTasks()
        let headphones = try XCTUnwrap(devices.controller(for: first))
        headphones.simulateControlLoss(deviceConnected: false)
        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
            targetDisconnected: true, waitForReconnect: true))
        await drainTasks()
        date = date.addingTimeInterval(59)
        headphones.simulateDeviceConnection(named: "WH-1000XM5", simulatedAddress: first, galleryModel: .whXM5)
        route.simulateRoute(output)
        await drainTasks()

        XCTAssertEqual(ldac.simulatedRequestedAddress, first)
        XCTAssertEqual(ldac.simulatedStarts, [first, first])
        date = date.addingTimeInterval(120)
        ldac.refreshPreferredCodec()
        XCTAssertEqual(ldac.simulatedRequestedAddress, first)
        XCTAssertTrue(ldac.isSessionRunning)
    }

    func testSleepCountsTowardsExpiryBeforeTheOldRequestCanResume() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let (ldac, devices, _) = try prepared(now: { date })
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.isSystemSleeping = true
        ldac.suspend()
        await drainTasks()
        XCTAssertEqual(ldac.state, .waitingForDevice)
        date = date.addingTimeInterval(12 * 60 * 60)
        devices.isSystemSleeping = false
        await drainTasks()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertEqual(ldac.simulatedStarts, [first])
    }

    func testDeadlineTimerExpiresWithoutAnotherDeviceEvent() async throws {
        let (ldac, devices, _) = try prepared(timeout: 0.02)
        defer { stop(ldac, devices) }
        await drainTasks()
        devices.controller(for: first)?.simulateControlLoss(deviceConnected: false)
        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
            targetDisconnected: true, waitForReconnect: true))
        await drainTasks()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
    }

    private var output: MacAudioRoute {
        MacAudioRoute(deviceID: 1, name: nil, uid: first,
            transport: MacAudioTransport(rawValue: kAudioDeviceTransportTypeBluetooth),
            outputChannels: 2, nominalSampleRate: 48000)
    }

    private func device(_ address: String, model: SonyDeviceModel) -> SonyConnectedDevice {
        SonyConnectedDevice(address: address, name: model.name, model: model)!
    }

    private func prepared(now: @escaping () -> Date = Date.init, timeout: TimeInterval = 60) throws
        -> (LDACController, SonyDeviceCoordinator, MacAudioRouteObserver) {
        let devices = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let headphones = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            headphones.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: device.model)
            return headphones
        }
        devices.reconcileConnectedDevices([device(first, model: .whXM5)])
        let route = MacAudioRouteObserver(startAutomatically: false)
        route.simulateRoute(output)
        let ldac = LDACController(devices: devices, audioRoute: route, inspectDriver: { _ in .current },
            preferredConfiguration: { _ in LDACConfiguration() }, localBluetoothAddress: { "02:00:00:00:00:01" },
            now: now, requestWaitTimeout: timeout)
        ldac.simulateHelpers()
        return (ldac, devices, route)
    }

    private func drainTasks() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func stop(_ ldac: LDACController, _ devices: SonyDeviceCoordinator) {
        ldac.stop(restoreAudio: false)
        for headphones in devices.controllers { headphones.simulateControlLoss() }
    }
}

@MainActor
final class LDACConnectionPreferenceTests: XCTestCase {
    func testFinderDefersOwnedRestorationUntilStopIsConfirmed() async throws {
        for phase in [EarbudFindingSession.Phase.connecting, .starting, .ringing, .stopping, .unconfirmed] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            if phase != .connecting { await openUnwornEarbud(finder, headphones: headphones) }
            if phase == .ringing {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
            } else if phase == .stopping { finder.stop() }
            else if phase == .unconfirmed { finder.simulateTransportFailure() }
            XCTAssertEqual(finder.session?.phase, phase)

            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionMode, .soundQuality)

            headphones.simulateProtocolMessage([0x13, 1, 1, 1])
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)

            if phase == .unconfirmed {
                finder.retryStop()
                finder.simulateConnectionOpened()
            } else { finder.stop() }
            if finder.mayBeRinging {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
            XCTAssertNotEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionTransition?.targetMode, .stableConnection)
            headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(headphones.connectionMode, .stableConnection)
            XCTAssertEqual(headphones.connectionTransition?.phase, .confirmed)
        }
    }

    func testFinderDoesNotRetainSupersededConnectionPreferenceOwnership() async throws {
        let (coordinator, headphones, finder, _) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        await openUnwornEarbud(finder, headphones: headphones)
        let currentRequest = headphones.lastConnectionModeChangeID

        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: UUID())

        XCTAssertNil(error)
        XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
        XCTAssertEqual(headphones.lastConnectionModeChangeID, currentRequest)
        XCTAssertEqual(finder.session?.phase, .starting)
    }

    func testStopWaitsForRunningPreferenceRestorationAndCompletesEveryHandlerOnce() async throws {
        for action in [SonyConnectionAlertAction.positive, .negative] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            finder.stop()
            for _ in 0..<20 { await Task.yield() }
            let alert = try XCTUnwrap(headphones.connectionTransition?.alert)
            XCTAssertFalse(ldac.isSessionRunning)
            XCTAssertTrue(ldac.needsStopBeforeTermination)
            var firstCompletions = 0
            var secondCompletions = 0

            ldac.stop { firstCompletions += 1 }
            ldac.stop { secondCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 0)
            XCTAssertEqual(secondCompletions, 0)

            headphones.respondToConnectionAlert(alert, action: action)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(ldac.needsStopBeforeTermination)
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            var laterCompletions = 0
            ldac.stop { laterCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            XCTAssertEqual(laterCompletions, 1)
        }
    }

    func testStopDoesNotStartDeferredRestorationWhileFinderSoundIsUnconfirmed() async throws {
        let (coordinator, headphones, finder, request) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        await openUnwornEarbud(finder, headphones: headphones)
        finder.simulateTransportFailure()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
        XCTAssertNil(error)
        var completions = 0

        ldac.stop { completions += 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(completions, 1)
        XCTAssertFalse(ldac.needsStopBeforeTermination)
        XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
        XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
        XCTAssertTrue(finder.mayBeRinging)
    }

    func testDeferredPreferenceSurvivesQuitWithoutRestoringUntilRequestedAfterRelaunch() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        headphones.setConnectionMode(.stableConnection)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
        XCTAssertEqual(headphones.connectionMode, .stableConnection)
        var ldac: LDACController? = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
        ldac?.simulateRecoverySession(headphones)
        let preparation = Task { try await ldac?.simulateConnectionPreferencePreparation(headphones) }
        for _ in 0..<20 { await Task.yield() }
        let request = try XCTUnwrap(headphones.lastConnectionModeChangeID)
        XCTAssertEqual(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address] as? String, request.uuidString)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
        try await preparation.value
        headphones.simulateControlLoss()
        ldac?.suspend()
        for _ in 0..<20 { await Task.yield() }
        ldac?.stop()
        XCTAssertFalse(try XCTUnwrap(ldac).needsStopBeforeTermination)
        ldac = nil

        let (nextCoordinator, nextHeadphones) = try preparedHeadphones()
        defer { finish(nextHeadphones) }
        let relaunched = LDACController(devices: nextCoordinator, defaults: defaults, inspectDriver: { _ in .current })
        nextCoordinator.objectWillChange.send()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(relaunched.hasPendingConnectionPreferenceRestoration(forAddress: nextHeadphones.address))
        XCTAssertTrue(relaunched.canRestoreConnectionPreference(forAddress: nextHeadphones.address))
        XCTAssertNil(nextHeadphones.lastConnectionModeChangeID)
        XCTAssertNil(nextHeadphones.connectionTransition)
        relaunched.stop()
        XCTAssertNil(nextHeadphones.lastConnectionModeChangeID)

        relaunched.restorePendingConnectionPreference(forAddress: nextHeadphones.address)
        let restoration = try XCTUnwrap(nextHeadphones.lastConnectionModeChangeID)
        XCTAssertNotEqual(restoration, request)
        XCTAssertEqual(nextHeadphones.connectionTransition?.targetMode, .stableConnection)
        nextHeadphones.respondToConnectionAlert(try XCTUnwrap(nextHeadphones.connectionTransition?.alert), action: .positive)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(relaunched.needsStopBeforeTermination)
        XCTAssertEqual(nextHeadphones.connectionMode, .stableConnection)
        XCTAssertFalse(relaunched.hasPendingConnectionPreferenceRestoration(forAddress: nextHeadphones.address))
        XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[nextHeadphones.address])
    }

    func testRelaunchDoesNotOverwriteLaterPhonePreferenceOrAnotherDevice() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        let otherAddress = "02:53:4F:4E:59:02"
        defaults.set([headphones.address: UUID().uuidString, otherAddress: UUID().uuidString], forKey: "ldac.pendingConnectionPreferences")
        let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })

        headphones.simulateProtocolMessage([0xE9, 5, 1, 0])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(headphones.connectionMode, .stableConnection)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertTrue(ldac.hasPendingConnectionPreferenceRestoration(forAddress: otherAddress))
        XCTAssertFalse(ldac.canRestoreConnectionPreference(forAddress: otherAddress))
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        headphones.simulateProtocolMessage([0xE9, 5, 0, 0])
        for _ in 0..<20 { await Task.yield() }
        ldac.restorePendingConnectionPreference(forAddress: headphones.address)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertNotNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[otherAddress])
    }

    func testRelaunchRespectsNewLocalChoiceAndCancelledExplicitRestoration() async throws {
        for explicitRestore in [false, true] {
            let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let (coordinator, headphones) = try preparedHeadphones()
            defer { finish(headphones) }
            defaults.set([headphones.address: UUID().uuidString], forKey: "ldac.pendingConnectionPreferences")
            let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
            if explicitRestore { ldac.restorePendingConnectionPreference(forAddress: headphones.address) }
            else { headphones.setConnectionMode(.stableConnection) }
            let request = headphones.lastConnectionModeChangeID
            headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .negative)
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(headphones.connectionMode, .soundQuality)
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
            XCTAssertFalse(ldac.needsStopBeforeTermination)
            XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address])
        }
    }

    func testKeepCurrentPreferenceClearsOnlyThatDeviceAndInvalidRecordsAreIgnored() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        let otherAddress = "02:53:4F:4E:59:02"
        defaults.set([headphones.address: UUID().uuidString, otherAddress: UUID().uuidString,
                      "not-an-address": UUID().uuidString, "02:53:4F:4E:59:03": "not-a-request"],
                     forKey: "ldac.pendingConnectionPreferences")
        let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: "not-an-address"))
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: "02:53:4F:4E:59:03"))
        ldac.keepConnectionPreference(forAddress: headphones.address)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertTrue(ldac.hasPendingConnectionPreferenceRestoration(forAddress: otherAddress))
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address])
    }

    private func preparedHeadphones() throws -> (SonyDeviceCoordinator, SonyHeadphonesController) {
        let address = "02:53:4F:4E:59:01"
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5,
                                                simulatedTable2Functions: [0x31, 0x32, 0x42, 0x53, 0xF0])
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let firmware = Array("6.1.0".utf8)
        headphones.simulateProtocolMessage([0x05, 2, UInt8(firmware.count)] + firmware)
        return (coordinator, headphones)
    }

    private func preparedFinder() throws -> (SonyDeviceCoordinator, SonyHeadphonesController, EarbudFinderController, UUID) {
        let (coordinator, headphones) = try preparedHeadphones()
        headphones.setConnectionMode(.stableConnection)
        let request = try XCTUnwrap(headphones.lastConnectionModeChangeID)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .negative)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertTrue(headphones.beginEarbudFinder())
        return (coordinator, headphones, try XCTUnwrap(headphones.earbudFinder), request)
    }

    private func openUnwornEarbud(_ finder: EarbudFinderController, headphones: SonyHeadphonesController) async {
        finder.simulateConnectionOpened()
        for _ in 0..<200 {
            guard let frame = headphones.simulatedPendingFrame else { break }
            headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertNil(headphones.simulatedPendingFrame)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        headphones.simulateProtocolMessage([0xF3, 0, 4], type: 0x0E)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(headphones.wearingStatus.leftWorn, false)
        XCTAssertEqual(finder.session?.phase, .starting)
    }

    private func finish(_ headphones: SonyHeadphonesController) {
        headphones.earbudFinder?.dismiss()
        headphones.earbudFinder?.simulateTransportFailure()
        headphones.simulateControlLoss()
    }
}

@MainActor
final class LDACRecoveryTests: XCTestCase {
    private let abort = LDACNativeSession.Completion(message: nil, canRetry: true, requiresAttention: false,
                                                     targetDisconnected: true, waitForReconnect: false)
    private let restored = LDACNativeSession.Completion(message: nil, canRetry: false, requiresAttention: true,
                                                        targetDisconnected: false, waitForReconnect: false)

    func testRecoverableAbortRestoresOrdinaryAudioBeforeTheSingleRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }

        ldac.simulateSessionFinished(abort)
        XCTAssertEqual(ldac.simulatedLaunches?.map { $0.restoringOnly }, [true],
                       "A recoverable abort left the headphones disconnected instead of restoring ordinary audio")
        XCTAssertEqual(ldac.simulatedRecoveryAttempt, 1)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry, "The retry was scheduled before ordinary audio returned")

        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ldac.state, .waitingForDevice)
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
        XCTAssertFalse(ldac.isSessionRunning)

        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry, "The retry delay did not end")
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
    }

    func testAbortOfTheRetryKeepsOrdinaryAudioAndTellsTheUser() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.simulateSessionFinished(abort)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort)
        XCTAssertEqual(ldac.simulatedLaunches?.map { $0.restoringOnly }, [true, true],
                       "The second abort did not restore ordinary audio")
        XCTAssertNil(ldac.simulatedRequestedAddress, "A second abort retried LDAC again")
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }

        guard case let .failed(message) = ldac.state else { return XCTFail("No notice after the retry failed: \(ldac.state)") }
        XCTAssertTrue(message.contains("ordinary Bluetooth audio"), message)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry)
        XCTAssertFalse(ldac.isSessionRunning)
    }

    func testAbortWithoutDisconnectingReleasesTheOutputWithoutTheRestoreHelper() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }

        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
                                           targetDisconnected: false, waitForReconnect: false))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(ldac.simulatedLaunches?.count, 0, "Ordinary audio was still connected, yet the restore helper ran")
        XCTAssertEqual(ldac.state, .waitingForDevice)
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)
    }

    func testShortActivePeriodDoesNotRenewTheRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        let start = Date(timeIntervalSince1970: 1_000)
        ldac.simulateSessionFinished(abort, at: start)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort, stableSince: start, at: start.addingTimeInterval(29.9))
        XCTAssertNil(ldac.simulatedRequestedAddress)
    }

    func testThirtySecondsOfStablePlaybackRenewsTheRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        let start = Date(timeIntervalSince1970: 1_000)
        ldac.simulateSessionFinished(abort, at: start)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort, stableSince: start, at: start.addingTimeInterval(30))
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
        XCTAssertEqual(ldac.simulatedRecoveryAttempt, 1)
    }

    func testExplicitStopCancelsThePendingRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.simulateSessionFinished(abort)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)

        ldac.stop()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry)
    }

    func testPhoneSourceSuspensionRestoresOrdinaryAudioWhileSleepDoesNot() async throws {
        for restoreAudio in [true, false] {
            let (ldac, headphones) = try preparedRecovery()
            defer { headphones.simulateControlLoss() }

            if restoreAudio { ldac.suspend(restoreAudio: true, reason: "another headphone music source is active") }
            else { ldac.suspend() }
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(ldac.simulatedRestoresAudioOnStop, restoreAudio)
            XCTAssertEqual(ldac.state, .waitingForDevice)
            XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
            XCTAssertFalse(ldac.isSessionRunning)
        }
    }

    func testExplicitStopCancelsRememberedRecoveryIntent() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.suspend(restoreAudio: true, reason: "another headphone music source is active")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ldac.state, .waitingForDevice)

        ldac.stop()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.targetAddress)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertFalse(ldac.isSessionRunning)
    }

    private func preparedRecovery(isClassicConnected: ((String) -> Bool)? = nil) throws -> (LDACController, SonyHeadphonesController) {
        let address = "02:53:4F:4E:59:01"
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5)
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current },
                                  localBluetoothAddress: { "02:00:00:00:00:01" },
                                  isClassicConnected: isClassicConnected ?? { _ in headphones.isDeviceConnected })
        ldac.simulateHelpers()
        ldac.simulateRecoverySession(headphones)
        return (ldac, headphones)
    }
}
#endif

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class LDACDriverServiceTests: XCTestCase {
    func testUpdateOnlyOpensOutdatedDriver() async {
        for state in [LDACDriverInstaller.State.missing, .current, .restartRequired, .unavailable("Unavailable")] {
            var openings = 0
            let service = LDACDriverService(inspect: { _ in state }, openInstaller: { _ in openings += 1 })
            service.update()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(service.state, state)
            XCTAssertFalse(service.isOpeningInstaller)
            XCTAssertEqual(openings, 0)
        }
    }

    func testInstallationCoalescesRequestsAndAllowsRetryAfterFailure() async {
        var openings = 0
        let service = LDACDriverService(inspect: { _ in .outdated }, openInstaller: { _ in
            openings += 1
            if openings == 1 {
                throw NSError(domain: "LDACDriverServiceTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Installer could not open"])
            }
        })
        service.update()
        service.install()
        XCTAssertTrue(service.isOpeningInstaller)
        for _ in 0..<100 where service.isOpeningInstaller { await Task.yield() }
        XCTAssertFalse(service.isOpeningInstaller)
        XCTAssertEqual(service.installationError, "Installer could not open")
        XCTAssertEqual(openings, 1)
        service.install()
        XCTAssertNil(service.installationError)
        for _ in 0..<100 where service.isOpeningInstaller { await Task.yield() }
        XCTAssertFalse(service.isOpeningInstaller)
        XCTAssertEqual(openings, 2)
    }

    func testBackgroundInspectionCoalescesAndDiscardsResultDuringPlayback() async throws {
        var continuation: CheckedContinuation<LDACDriverInstaller.State, Never>?
        var inspections = 0
        var canUpdate = true
        var completions = 0
        let service = LDACDriverService(inspectInBackground: { _ in
            inspections += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        service.refreshInBackground(canUpdate: { canUpdate }, didRefresh: { completions += 1 })
        service.refreshInBackground(canUpdate: { canUpdate }, didRefresh: { completions += 1 })
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        canUpdate = false
        pending.resume(returning: .outdated)
        for _ in 0..<100 where completions == 0 { await Task.yield() }
        XCTAssertEqual(inspections, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(service.state, .unavailable(""))
        continuation = nil
        canUpdate = true
        service.refreshInBackground(canUpdate: { canUpdate }, didRefresh: { completions += 1 })
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        try XCTUnwrap(continuation).resume(returning: .current)
        for _ in 0..<100 where completions == 1 { await Task.yield() }
        XCTAssertEqual(service.state, .current)
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(completions, 2)
    }
}
#endif
