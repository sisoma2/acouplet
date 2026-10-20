import AppKit
import Combine
import CoreAudio
import Foundation
@preconcurrency import IOBluetooth

@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let devices: SonyDeviceCoordinator
    var headphones: SonyHeadphonesController { devices.selectedController }
    let audioRoute: MacAudioRouteObserver
    #if ACOUPLET_SPARKLE
    let updater = AppUpdater()
    #endif
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    let notifications: SonyNotificationService
    let noiseModeHUD = SonyNoiseModeHUD()
    let noiseModeSound = SonyNoiseModeSound()
    let ldac: LDACController
    #endif
    private var cancellables = Set<AnyCancellable>()
    private var equalizerObservation: AnyCancellable?
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var ldacSuccessTask: Task<Void, Never>?
    private var noiseModeObservers: [ObjectIdentifier: [AnyCancellable]] = [:]
    #endif

    convenience init(settings: SettingsStore, headphones: SonyHeadphonesController, audioRoute: MacAudioRouteObserver) {
        self.init(settings: settings, devices: SonyDeviceCoordinator(controller: headphones), audioRoute: audioRoute)
    }

    init(settings: SettingsStore, devices: SonyDeviceCoordinator, audioRoute: MacAudioRouteObserver) {
        self.settings = settings
        self.devices = devices
        self.audioRoute = audioRoute
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldac = LDACController(devices: devices, audioRoute: audioRoute, defaults: settings.defaults,
                              isDriverInspectionEnabled: { [weak settings] in settings?.experimentalLDACEnabled == true },
                              preferredConfiguration: { [weak settings] address in
            settings?.automaticLDACConfiguration(forAddress: address)
        })
        notifications = SonyNotificationService(settings: settings, devices: devices,
                                                presentLowBattery: { [weak devices, noiseModeHUD] warning, _ in
            guard let headphones = devices?.controller(for: warning.deviceID) else { return false }
            return noiseModeHUD.showLowBattery(warning, headphones: headphones)
        }, presentFirmware: { [noiseModeHUD] headphones, version in
            noiseModeHUD.showFirmware(version: version, headphones: headphones)
        }, presentAudioSource: { [noiseModeHUD] headphones, source in
            noiseModeHUD.showAudioSource(source, headphones: headphones)
        })
        noiseModeHUD.onAvailable = { [weak notifications] in notifications?.retryPendingAlerts() }
        devices.$controllers
            .sink { [weak self] controllers in self?.observeNoiseModeChanges(controllers) }
            .store(in: &cancellables)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in self?.noiseModeHUD.dismiss() }
                .store(in: &cancellables)
        }
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        settings.$ldacDeviceProfiles.dropFirst()
            .sink { [weak ldac, weak settings] _ in
                Task { @MainActor [weak ldac, weak settings] in
                    guard let ldac else { return }
                    if let address = ldac.targetAddress, let configuration = settings?.ldacConfiguration(forAddress: address) {
                        ldac.updatePlaybackConfiguration(configuration, forAddress: address)
                    }
                    ldac.refreshPreferredCodec(resetAttempts: true)
                }
            }.store(in: &cancellables)
        ldac.$state.combineLatest(ldac.$targetAddress)
            .map { state, address -> String? in if case .active = state { address } else { nil } }
            .removeDuplicates()
            .sink { [weak self] address in
                self?.ldacSuccessTask?.cancel()
                guard let self, let address else { return }
                let configuration = self.ldac.currentConfiguration
                self.ldacSuccessTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.ldac.targetAddress == address, case .active = self.ldac.state else { return }
                    self.settings.recordLDACSuccess(forAddress: address, configuration: configuration)
                }
            }.store(in: &cancellables)
        ldac.$state.sink { [weak ldac, weak settings] state in
            guard case .failed = state, let address = ldac?.targetAddress else { return }
            settings?.recordLDACFailure(forAddress: address)
        }.store(in: &cancellables)
        settings.$experimentalLDACEnabled
            .removeDuplicates()
            .sink { [weak ldac] enabled in
                if !enabled { ldac?.stop(reason: "experimental LDAC preference disabled") }
                else {
                    Task { @MainActor [weak ldac] in
                        ldac?.refreshDriverStateInBackground()
                        ldac?.refreshPreferredCodec(resetAttempts: true)
                    }
                }
            }
            .store(in: &cancellables)
        settings.$reconnectAutomatically.combineLatest(ldac.$targetAddress, ldac.$isSessionRunning, ldac.$state)
            .map { enabled, address, running, state in
                (enabled, running || state == .requested || state == .stopping ? address : nil)
            }
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak devices] enabled, address in
                devices?.setReconnectAutomatically(enabled, suppressing: address)
            }
            .store(in: &cancellables)
        #else
        settings.$reconnectAutomatically
            .removeDuplicates()
            .sink { [weak devices] enabled in
                devices?.setReconnectAutomatically(enabled)
            }
            .store(in: &cancellables)
        #endif
        devices.$selectedAddress
            .removeDuplicates()
            .sink { [weak self, weak devices, weak settings] address in
                self?.equalizerObservation = nil
                for controller in devices?.controllers ?? [] where controller.address != address {
                    controller.earbudFinder?.dismiss()
                }
                guard let address, let controller = devices?.controller(for: address) else { return }
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                settings?.selectLDACDevice(address: address)
                #endif
                self?.equalizerObservation = controller.$equalizer
                    .removeDuplicates()
                    .sink { [weak settings] equalizer in
                        settings?.selectEqualizerDevice(address: address, defaultDraft: equalizer.settings,
                                                       provisionalDraft: equalizer.flatSettings)
                    }
            }
            .store(in: &cancellables)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private func observeNoiseModeChanges(_ controllers: [SonyHeadphonesController]) {
        noiseModeHUD.dismissIfControllerRemoved(from: controllers)
        let identifiers = Set(controllers.map(ObjectIdentifier.init))
        noiseModeObservers = noiseModeObservers.filter { identifiers.contains($0.key) }
        for controller in controllers where noiseModeObservers[ObjectIdentifier(controller)] == nil {
            let changes = controller.noiseModeChanges.sink { [weak self, weak controller] change in
                guard let controller, controller.isReady, controller.isDeviceConnected,
                      controller.notificationSession == change.session,
                      SonyBLEIdentity.normalizedAddress(controller.address) == change.deviceID else { return }
                self?.noiseModeHUD.show(change, headphones: controller)
            }
            let connection = controller.$linkState.combineLatest(controller.$isDeviceConnected)
                .sink { [weak self, weak controller] state, connected in
                    if let controller, state != .ready || !connected { self?.noiseModeHUD.dismiss(for: controller) }
                }
            let confirmations = controller.confirmedNoiseModeChanges.sink { [weak self, weak controller] mode in
                guard let self, let controller, controller.lowBatteryNotificationDeviceID != nil else { return }
                let uid: String?
                if controller.isLDACStreaming {
                    guard !self.ldac.currentConfiguration.routing.isSelective else { return }
                    uid = LDACNativeOutput.uid
                } else {
                    uid = try? LDACCallHardware.headsetUID(address: controller.address, scope: kAudioObjectPropertyScopeOutput)
                }
                if let uid { self.noiseModeSound.play(mode, deviceUID: uid) }
            }
            noiseModeObservers[ObjectIdentifier(controller)] = [changes, connection, confirmations]
        }
    }

    #endif

    static func live() -> AppEnvironment {
        #if DEBUG
        if CommandLine.arguments.contains("-ui-testing") {
            let suiteName = "dev.baglayan.Acouplet.ui-testing"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            if CommandLine.arguments.contains("--bluetooth-permission-pending") {
                let headphones = SonyHeadphonesController(startAutomatically: false, displayOnly: true)
                headphones.reportBluetoothAuthorization(.notDetermined)
                return AppEnvironment(settings: SettingsStore(defaults: defaults, preferencesDomain: suiteName), headphones: headphones,
                                      audioRoute: MacAudioRouteObserver(startAutomatically: false))
            }
            let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true, simulatedReady: !CommandLine.arguments.contains("--disconnected"))
            if let index = CommandLine.arguments.firstIndex(of: "--gallery-model") {
                precondition(CommandLine.arguments.indices.contains(index + 1))
                guard let model = SonyDeviceModel(rawValue: CommandLine.arguments[index + 1]), model != .unknown else {
                    preconditionFailure("Choose a recognized gallery model.")
                }
                let color: UInt8?
                if let index = CommandLine.arguments.firstIndex(of: "--gallery-color") {
                    precondition(CommandLine.arguments.indices.contains(index + 1))
                    guard let value = UInt8(CommandLine.arguments[index + 1]) else { preconditionFailure("Use a decimal color byte.") }
                    color = value
                } else {
                    color = nil
                }
                let noiseMode: NoiseControlMode
                if let index = CommandLine.arguments.firstIndex(of: "--gallery-noise-mode") {
                    precondition(CommandLine.arguments.indices.contains(index + 1))
                    guard let mode = NoiseControlMode(rawValue: CommandLine.arguments[index + 1]), mode != .wind else {
                        preconditionFailure("Choose off, anc, or ambient for the gallery.")
                    }
                    noiseMode = mode
                } else {
                    noiseMode = .ambient
                }
                let visualFinish: String?
                if let index = CommandLine.arguments.firstIndex(of: "--gallery-finish") {
                    precondition(CommandLine.arguments.indices.contains(index + 1))
                    visualFinish = CommandLine.arguments[index + 1]
                } else {
                    visualFinish = nil
                }
                headphones.simulateGalleryDevice(model: model, color: color, noiseMode: noiseMode, visualFinish: visualFinish)
            }
            if CommandLine.arguments.contains("--multiple-devices") {
                let devices = SonyDeviceCoordinator(fallbackController: headphones) { device in
                    if device.address == headphones.address { return headphones }
                    let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, pinnedAddress: device.address)
                    controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address)
                    return controller
                }
                devices.reconcileConnectedDevices([
                    SonyConnectedDevice(address: headphones.address, name: headphones.deviceName, model: .wfXM5)!,
                    SonyConnectedDevice(address: "02:00:00:00:00:02", name: "WH-1000XM5", model: .whXM5)!,
                ])
                return AppEnvironment(settings: SettingsStore(defaults: defaults, preferencesDomain: suiteName), devices: devices,
                                      audioRoute: MacAudioRouteObserver(startAutomatically: false))
            }
            return AppEnvironment(settings: SettingsStore(defaults: defaults, preferencesDomain: suiteName), headphones: headphones,
                                  audioRoute: MacAudioRouteObserver(startAutomatically: false))
        }
        if ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppEnvironment(settings: SettingsStore(defaults: .standard), headphones: SonyHeadphonesController(startAutomatically: false, simulated: true), audioRoute: MacAudioRouteObserver(startAutomatically: false))
        }
        #endif
        SettingsStore.migrateLegacyPreferences(
            from: UserDefaults.standard.persistentDomain(forName: "local.xm5control.native") ?? [:],
            to: .standard, bundleIdentifier: Bundle.main.bundleIdentifier)
        let devices = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, displayOnly: true)) { device in
            #if ACOUPLET_PUBLIC_APIS_ONLY
            SonyHeadphonesController(startAutomatically: false, identityDefaults: .standard, pinnedAddress: device.address,
                                     advertisedName: device.name)
            #else
            SonyHeadphonesController(startAutomatically: false, identityDefaults: .standard, pinnedAddress: device.address,
                                     advertisedName: device.name, nativeAppearanceRefreshEnabled:
                                        !CommandLine.arguments.contains("--disable-native-identity")
                                            && !CommandLine.arguments.contains("--unregister-login-item"))
            #endif
        }
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        if !CommandLine.arguments.contains("--disable-native-battery"),
           !CommandLine.arguments.contains("--unregister-login-item") {
            devices.nativeBatteryPublisher = SonyNativeBatteryPublisher(executableURL:
                Bundle.main.bundleURL.appending(path: "Contents/Helpers/Acouplet Battery Publisher"))
        }
        #endif
        return AppEnvironment(
            settings: SettingsStore(defaults: .standard, managesLaunchService: true),
            devices: devices,
            audioRoute: MacAudioRouteObserver(startAutomatically: !CommandLine.arguments.contains("--unregister-login-item"))
        )
    }
}
