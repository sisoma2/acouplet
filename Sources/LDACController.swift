#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers
@preconcurrency import IOBluetooth

@MainActor
final class LDACController: ObservableObject {
    @Published private(set) var state: LDACState = .off {
        didSet {
            syncStreamingFlag()
            updateWaitingDeadline()
        }
    }
    @Published private(set) var targetAddress: String?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecovering = false
    @Published private(set) var isAwaitingAutomaticRetry = false
    @Published private(set) var isSuspendedForMicrophone = false
    @Published private(set) var audioCaptureAccess: LDACAudioCaptureAccess = .unchecked
    @Published private(set) var transportHealth = LDACTransportHealth()
    private var healthAddress: String?
    @Published private(set) var runtimeStatus = LDACRuntimeStatus()
    @Published private(set) var diagnosticExportError: String?
    @Published private(set) var driverState: LDACDriverInstaller.State
    @Published private(set) var discoveredSupport: [String: LDACCapabilityRecord]
    @Published private(set) var driverInstallationError: String?
    @Published private(set) var isOpeningDriverInstaller = false
    @Published private(set) var multipointConflictAddress: String?
    @Published private(set) var multipointShutdownAddress: String?
    private var multipointConflictConfiguration: LDACConfiguration?
    private var multipointShutdownTask: Task<Void, Never>?
    private let bundle: Bundle
    private let defaults: UserDefaults?
    @Published private var pendingConnectionModes: [String: UUID] = [:] {
        didSet { defaults?.set(pendingConnectionModes.mapValues(\.uuidString), forKey: "ldac.pendingConnectionPreferences") }
    }
    private let driverService: LDACDriverService
    private let isDriverInspectionEnabled: () -> Bool
    private let preferredConfiguration: (String) -> LDACConfiguration?
    private var codecPreferences: [String: Bool]
    private var automaticStartAttempts: [ObjectIdentifier: UInt64] = [:]
    private var automaticSelectionAddress: String?
    private let isClassicConnected: (String) -> Bool
    private let localBluetoothAddress: () -> String?
    private var session: LDACOwnerSession?
    private var sessionID = UUID()
    private var requestedAddress: String? {
        didSet {
            if oldValue != requestedAddress { clearWaitingDeadline() }
            callAudio?.monitor(address: requestedAddress)
            if requestedAddress == nil { isSuspendedForMicrophone = false }
            updateWaitingDeadline()
        }
    }
    private let now: () -> Date
    private let requestWaitTimeout: TimeInterval
    private var waitingDeadline: Date?
    private var waitingTask: Task<Void, Never>?
    private let callAudio: LDACCallAudio?
    var microphoneHandoffIssue: String? { callAudio?.issue }
    private var requestedConfiguration = LDACConfiguration()
    private var playbackSettingsRestartAddress: String?
    private var directStartRequested = false
    private var startingDirectly = false
    private var connectOrdinaryAfterCleanup = false
    var currentConfiguration: LDACConfiguration { requestedConfiguration }
    var microphoneActivities: [LDACMicrophoneActivity] { callAudio?.microphoneActivities ?? [] }
    var manualCallHandoffRequested: Bool { callAudio?.manualHandoffRequested == true }

    func setManualCallHandoff(_ enabled: Bool) {
        callAudio?.setManualHandoff(enabled)
        _ = synchronizeMicrophoneHandoff()
        resumeIfReady()
    }
    private var nativeOutput: LDACOwnerOutput?
    private var outputID: UUID?
    private var headphones: SonyHeadphonesController? {
        didSet {
            if oldValue !== headphones { oldValue?.isLDACStreaming = false }
            syncStreamingFlag()
        }
    }

    private func syncStreamingFlag() {
        if case .active = state { headphones?.isLDACStreaming = true } else { headphones?.isLDACStreaming = false }
    }
    private var controlObservation: AnyCancellable?
    private var availabilityObservations = Set<AnyCancellable>()
    private var disconnectionObservations: [ObjectIdentifier: AnyCancellable] = [:]
    private let audioRoute: MacAudioRouteObserver?
    private var resumeOutputUID: String?
    private var lastResumeBlockers: String?
    private var suspensionRequested = false
    private var deferredConnectionModes: [String: UUID] = [:]
    private var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    private var connectionModeRestoreID: UUID?
    private var connectionModeConfirmed = false
    private var startTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private let volumeSession = LDACVolumeSession()
    private var cleanupTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UUID?
    /// Automatic retries used by the current LDAC request. Only one is allowed until playback stays stable for 30 s.
    private var recoveryAttempt = 0
    /// Set when a recoverable abort falls back to ordinary audio with a retry still available; `finish` schedules it.
    private var retryAfterRestoration = false
    private var automaticRetryDelay: Duration = .seconds(10)
    /// When the current binding hold began; a hold without a pending transition ends in recovery after `bindingHoldLimit`.
    private var bindingHeldSince: Date?
    private var bindingHoldTask: Task<Void, Never>?
    private let bindingHoldLimit: TimeInterval = 10
    private var restoreAudioOnStop = true
    private var stoppingForUpdate = false
    private var updateResumeTask: Task<Void, Never>?
    private var stableSince: Date?
    private var initialReadbackID: UUID?
    private var controlSession: UInt64?
    private var sourceAddress: String?
    private var volumeRange: ClosedRange<Int>?
    private var transportFormat: LDACFormat?
    private var usable = false
    private var requestedOutputGain = 0.0
    private var volumeError: String?
    private var stopCompletions: [@MainActor () -> Void] = []
    private let helpers: LDACNativeSession.Helpers
    private let devices: SonyDeviceCoordinator?
    private nonisolated static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "LDACLifecycle")

    init(bundle: Bundle = .main, devices: SonyDeviceCoordinator? = nil, audioRoute: MacAudioRouteObserver? = nil, defaults: UserDefaults? = nil,
         inspectDriver: ((Bundle) -> LDACDriverInstaller.State)? = nil,
         callAudio: LDACCallAudio? = nil,
         isDriverInspectionEnabled: @escaping () -> Bool = { true },
         preferredConfiguration: @escaping (String) -> LDACConfiguration? = { _ in nil },
         localBluetoothAddress: @escaping () -> String? = { IOBluetoothHostController.default()?.addressAsString() },
         now: @escaping () -> Date = Date.init,
         requestWaitTimeout: TimeInterval = 60,
         isClassicConnected: @escaping (String) -> Bool = { IOBluetoothDevice(addressString: $0)?.isClassicConnected() == true }) {
        self.bundle = bundle
        self.defaults = defaults
        discoveredSupport = LDACSupportStore(defaults: defaults).all
        driverService = LDACDriverService(bundle: bundle, inspect: inspectDriver)
        self.callAudio = callAudio ?? (inspectDriver == nil ? LDACCallAudio() : nil)
        self.isDriverInspectionEnabled = isDriverInspectionEnabled
        self.preferredConfiguration = preferredConfiguration
        codecPreferences = defaults?.dictionary(forKey: "ldac.codecPreferences") as? [String: Bool] ?? [:]
        self.isClassicConnected = isClassicConnected
        self.localBluetoothAddress = localBluetoothAddress
        self.now = now
        self.requestWaitTimeout = requestWaitTimeout
        driverState = driverService.state
        helpers = LDACNativeSession.Helpers(bundle: bundle)
        self.devices = devices
        self.audioRoute = audioRoute
        driverService.$state.sink { [weak self] in self?.driverState = $0 }.store(in: &availabilityObservations)
        driverService.$installationError.sink { [weak self] in self?.driverInstallationError = $0 }.store(in: &availabilityObservations)
        driverService.$isOpeningInstaller.sink { [weak self] in self?.isOpeningDriverInstaller = $0 }.store(in: &availabilityObservations)
        devices?.$controllers.sink { [weak self] controllers in
            self?.observeDisconnectionRequests(controllers)
        }.store(in: &availabilityObservations)
        devices?.$selectedAddress.removeDuplicates().dropFirst().sink { [weak self] address in
            self?.automaticSelectionAddress = address
            Task { @MainActor [weak self] in
                guard let self, let address, self.devices?.selectedAddress == address else { return }
                if let requested = self.requestedAddress, requested != address {
                    self.recordRecovery("request-cancelled", reason: "selected headphones changed")
                    self.stop(reason: "selected headphones changed")
                }
                self.refreshPreferredCodec()
            }
        }.store(in: &availabilityObservations)
        if let saved = defaults?.dictionary(forKey: "ldac.pendingConnectionPreferences") as? [String: String] {
            for (address, value) in saved where SonyBLEIdentity.normalizedAddress(address) == address {
                if let request = UUID(uuidString: value) { pendingConnectionModes[address] = request }
            }
        }
        for changes in [devices?.objectWillChange, audioRoute?.objectWillChange, self.callAudio?.objectWillChange].compactMap({ $0 }) {
            changes.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                    self?.resumeIfReady()
                    self?.refreshPreferredCodec()
                }
            }.store(in: &availabilityObservations)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.installer" else { return }
                self?.refreshDriverStateInBackground()
            }.store(in: &availabilityObservations)
        if inspectDriver == nil { refreshDriverStateInBackground() }
        Task { @MainActor [weak self] in self?.refreshPreferredCodec() }
    }

    var needsStopBeforeTermination: Bool { isSessionRunning || !preferenceRestoreTasks.isEmpty }

    func canChangePlaybackSettings(forAddress address: String) -> Bool {
        if case .active = state { return targetAddress == SonyBLEIdentity.normalizedAddress(address) }
        return !needsStopBeforeTermination && state != .waitingForDevice
    }

    func updatePlaybackConfiguration(_ configuration: LDACConfiguration, forAddress address: String) {
        guard let address = SonyBLEIdentity.normalizedAddress(address), requestedAddress == address,
              targetAddress == address, case .active = state,
              sampleRateUnavailableReason(configuration.sampleRate, forAddress: address) == nil,
              requestedConfiguration.sampleRate != configuration.sampleRate || requestedConfiguration.quality != configuration.quality else { return }
        requestedConfiguration.sampleRate = configuration.sampleRate
        requestedConfiguration.quality = configuration.quality
        playbackSettingsRestartAddress = address
        recoveryAttempt = 0
        stopSession(reason: "playback settings changed")
    }

    private func observeDisconnectionRequests(_ controllers: [SonyHeadphonesController]) {
        let identifiers = Set(controllers.map(ObjectIdentifier.init))
        disconnectionObservations = disconnectionObservations.filter { identifiers.contains($0.key) }
        for controller in controllers where disconnectionObservations[ObjectIdentifier(controller)] == nil {
            controller.preferredAudioConnection = { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.connectDirectly(forAddress: controller.address)
            }
            disconnectionObservations[ObjectIdentifier(controller)] = controller.disconnectionRequests.sink { [weak self, weak controller] in
                guard let self, let controller else { return }
                let address = controller.address
                LDACUpdateHandoff().cancel(address: address)
                if self.multipointConflictAddress == address {
                    self.multipointConflictAddress = nil
                    self.multipointConflictConfiguration = nil
                }
                if self.targetAddress == address || self.requestedAddress == address {
                    self.stop(restoreAudio: false, reason: "user disconnected or powered off headphones")
                }
            }
        }
    }

    #if DEBUG
    func simulateConnectionPreferenceRestoration(_ headphones: SonyHeadphonesController, request: UUID) async -> String? {
        await restoreConnectionPreference(headphones, address: headphones.address, request: request)
    }

    func simulateConnectionPreferencePreparation(_ headphones: SonyHeadphonesController) async throws {
        try await prepareConnectionMode(headphones, address: headphones.address, identifier: sessionID)
    }

    func simulatedDeferredConnectionMode(forAddress address: String) -> UUID? {
        deferredConnectionModes[address]
    }

    func simulateRecoverySession(_ headphones: SonyHeadphonesController) {
        self.headphones = headphones
        resumeOutputUID = audioRoute?.route?.uid
        requestedAddress = headphones.address
        targetAddress = headphones.address
        isSessionRunning = true
        state = .connecting
    }

    func simulateActiveSession(_ headphones: SonyHeadphonesController, configuration: LDACConfiguration = LDACConfiguration()) {
        simulateRecoverySession(headphones)
        requestedConfiguration = configuration
        state = .active(configuration.format)
        if let output = nativeOutput, simulatedStarts != nil {
            let identifier = sessionID
            let session = LDACOwnerSession(id: identifier, output: output, configuration: configuration,
                recoveryAttempt: false, restoringOnly: false, receive: { _ in })
            session.simulatedStop = { [weak self] restoreAudio in
                Task { @MainActor [weak self] in
                    guard let self, self.session?.id == identifier else { return }
                    self.simulateSessionFinished(.init(message: nil, canRetry: false, requiresAttention: false,
                        targetDisconnected: !restoreAudio, waitForReconnect: false))
                }
            }
            self.session = session
        }
    }

    var simulatedOutputID: UUID? { outputID }

    var simulatedLaunches: [(address: String, restoringOnly: Bool)]?
    var simulatedStarts: [String]?

    func simulateHelpers(retryDelay: Duration = .milliseconds(10)) {
        simulatedLaunches = []
        simulatedStarts = []
        automaticRetryDelay = retryDelay
    }

    func simulateSessionFinished(_ completion: LDACNativeSession.Completion, stableSince: Date? = nil, at date: Date = Date()) {
        guard let address = targetAddress else { return }
        self.stableSince = stableSince
        if completion.canRetry, !isRecovering { beginRecovery(reason: "simulated connection loss", at: date) }
        session = nil
        sessionFinished(completion, address: address)
    }

    var simulatedRequestedAddress: String? { requestedAddress }
    var simulatedStartingDirectly: Bool { startingDirectly }
    var simulatedRestoresAudioOnStop: Bool { restoreAudioOnStop }
    var simulatedRecoveryAttempt: Int { recoveryAttempt }
    #endif

    var canStartOrInstallDriver: Bool {
        switch driverState {
        case .missing, .outdated, .current: !isOpeningDriverInstaller
        case .restartRequired, .unavailable: false
        }
    }

    func refreshDriverState() {
        guard !isSessionRunning else { return }
        driverService.refresh()
    }

    func refreshDriverStateInBackground() {
        guard isDriverInspectionEnabled(), !isSessionRunning else { return }
        driverService.refreshInBackground(canUpdate: { [weak self] in
            self?.isSessionRunning == false
        }, didRefresh: { [weak self] in
            self?.refreshPreferredCodec()
        })
    }

    func installDriver() {
        guard !isSessionRunning, !isOpeningDriverInstaller else { return }
        driverService.install()
    }

    func updateDriver() {
        guard !isSessionRunning, !isOpeningDriverInstaller else { return }
        driverService.update()
    }

    func deviceUnavailableReason(forAddress address: String) -> String? {
        guard let headphones = devices?.controller(for: address), headphones.deviceModel != .unknown else {
            return String(localized: "Connect the headphone controls in Acouplet before starting LDAC.")
        }
        switch headphones.deviceModel {
        case .wfXM3, .whCH720N:
            return String(localized: "This model does not support the LDAC codec.")
        default: break
        }
        guard headphones.isReady, !headphones.isReconnectPaused else {
            return String(localized: "Connect the headphone controls in Acouplet before starting LDAC.")
        }
        guard headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else {
            return String(localized: "Stop the locating sound before starting LDAC.")
        }
        guard headphones.playback.isSupported,
              !headphones.playback.hasReceivedCapabilities || headphones.playback.musicVolumeRange != nil else {
            return String(localized: "This app does not yet support LDAC with this device's volume controls.")
        }
        return nil
    }

    func support(forAddress address: String) -> LDACSupport {
        LDACSupport.decide(modelImpliesLDAC: devices?.controller(for: address)?.deviceModel.offersLDACOnlyWithoutMultipoint == true,
                           discovered: SonyBLEIdentity.normalizedAddress(address).flatMap { discoveredSupport[$0]?.observation(in: capabilityContext(forAddress: address)) })
    }

    private func capabilityContext(forAddress address: String) -> LDACCapabilityContext {
        let headphones = devices?.controller(for: address)
        let mode = headphones?.connectionMode
        return LDACCapabilityContext(firmware: headphones?.firmwareVersion,
            connectionMode: mode.map { String(describing: $0) }, multipoint: headphones?.systemFeatures.multipoint?.enabled,
            endpointMayBeHidden: mode == .stableConnection || mode == .lowLatency || headphones?.ldacRequiresMultipointOff == true)
    }

    func advertisedSampleRates(forAddress address: String) -> Set<Int> {
        guard let record = discoveredSupport[address], record.observation(in: capabilityContext(forAddress: address)) == true else { return [] }
        return Set(LDACSampleRate.allCases.filter { record.supports(sampleRate: $0.rawValue) == true }.map(\.rawValue))
    }

    func sampleRateUnavailableReason(_ rate: LDACSampleRate, forAddress address: String) -> String? {
        guard let record = discoveredSupport[address], record.observation(in: capabilityContext(forAddress: address)) == true,
              record.supports(sampleRate: rate.rawValue) == false else { return nil }
        return String(localized: "The headphones did not advertise stereo LDAC at this sample rate.")
    }

    func exportDiagnostics(forAddress address: String, configuration: LDACConfiguration? = nil) {
        guard let headphones = devices?.controller(for: address) else { return }
        diagnosticExportError = nil
        let driver = LDACDriverInstaller.snapshot(bundle: bundle)
        let configuration = configuration ?? requestedConfiguration
        var health = healthAddress == address ? transportHealth : LDACTransportHealth()
        health.lastReason = health.lastReason.map(LDACDiagnosticReport.redacted)
        var runtime = healthAddress == address ? runtimeStatus : LDACRuntimeStatus()
        runtime.message = runtime.message.map(LDACDiagnosticReport.redacted)
        let report = LDACDiagnosticReport(appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString, deviceModel: headphones.deviceModel.name,
            firmware: headphones.firmwareVersion, driverState: LDACDiagnosticReport.redacted(String(describing: driverState)), bundledDriverRevision: driver.bundled,
            installedDriverRevision: driver.installed, loadedDriverRevision: driver.loaded,
            sampleRate: configuration.sampleRate.rawValue, quality: configuration.quality.rawValue,
            pcmReserveMilliseconds: configuration.pcmReserveMilliseconds,
            microphonePolicy: configuration.microphonePolicy.rawValue,
            selectedApplicationCount: configuration.routing.bundleIDs.count, health: health, runtime: runtime)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = LDACDiagnosticReport.filename()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch { self?.diagnosticExportError = error.localizedDescription }
        }
    }

    func checkSupportAgain(forAddress address: String, configuration: LDACConfiguration) {
        guard let address = SonyBLEIdentity.normalizedAddress(address), !isSessionRunning,
              requestedAddress == nil, deviceUnavailableReason(forAddress: address) == nil else { return }
        let store = LDACSupportStore(defaults: defaults)
        store.clear(forAddress: address)
        discoveredSupport.removeValue(forKey: address)
        setEnabled(true, forAddress: address, configuration: configuration)
    }

    private func recordDiscoveredSupport(_ supported: Bool, address: String) {
        let store = LDACSupportStore(defaults: defaults)
        let context = capabilityContext(forAddress: address)
        let now = Date()
        store.record(supported, forAddress: address, context: context, now: now)
        discoveredSupport[address] = LDACCapabilityRecord(supported: supported, observedAt: now, context: context)
        record("ldac-support", reason: supported ? "endpoint listed" : "no endpoint listed")
        if !supported, support(forAddress: address) == .unsupported, requestedAddress == address {
            requestedAddress = nil
        }
    }

    func canEnable(forAddress address: String) -> Bool {
        support(forAddress: address) != .unsupported && deviceUnavailableReason(forAddress: address) == nil && helpers.isAvailable && !isSessionRunning
            && preferenceRestoreTasks[address] == nil
    }

    private func canStartDirectly(forAddress address: String) -> Bool {
        guard let devices, !devices.isSystemSleeping, !devices.isTerminating,
              devices.selectedAddress == address, let headphones = devices.controller(for: address),
              headphones.deviceModel != .unknown, !headphones.isReconnectPaused,
              headphones.connectionMode != .lowLatency, headphones.pendingControlTransition == nil,
              headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true,
              !headphones.ldacRequiresMultipointOff, support(forAddress: address) != .unsupported else { return false }
        switch headphones.deviceModel {
        case .wfXM3, .whCH720N: return false
        default: break
        }
        if headphones.isReady, deviceUnavailableReason(forAddress: address) != nil { return false }
        if headphones.isReady, headphones.multipoint.selectedSource != nil,
           !headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()) { return false }
        return true
    }

    func connectDirectly(forAddress address: String) -> Bool {
        if isSessionRunning, targetAddress == SonyBLEIdentity.normalizedAddress(address) { return true }
        guard let address = SonyBLEIdentity.normalizedAddress(address), codecPreferences[address] != false,
              !isSessionRunning, requestedAddress == nil, state != .stopping,
              cleanupTask == nil, recoveryTask == nil, preferenceRestoreTasks[address] == nil,
              multipointConflictAddress == nil, multipointShutdownAddress == nil,
              let configuration = preferredConfiguration(address), configuration.isValid,
              helpers.isAvailable, !isClassicConnected(address), canStartDirectly(forAddress: address) else { return false }
        refreshDriverState()
        guard driverState == .current else { return false }
        setEnabled(true, forAddress: address, configuration: configuration, directly: true)
        return requestedAddress == address && isSessionRunning
    }

    func refreshPreferredCodec(resetAttempts: Bool = false) {
        guard reconcileRequestedDevice() else { return }
        switch state {
        case .off:
            if resetAttempts { automaticStartAttempts.removeAll() }
        case .failed: break
        default: return
        }
        guard !isSessionRunning, requestedAddress == nil,
              cleanupTask == nil, recoveryTask == nil,
              multipointConflictAddress == nil, multipointShutdownAddress == nil,
              let devices, !devices.isSystemSleeping, !devices.isTerminating,
              let address = devices.selectedAddress, codecPreferences[address] != false,
              let configuration = preferredConfiguration(address),
              let headphones = devices.controller(for: address), headphones.isDeviceConnected,
              helpers.isAvailable, driverState == .current, preferenceRestoreTasks[address] == nil else { return }
        if automaticSelectionAddress == address {
            automaticSelectionAddress = nil
            automaticStartAttempts.removeValue(forKey: ObjectIdentifier(headphones))
        }
        guard automaticStartAttempts[ObjectIdentifier(headphones)] != headphones.notificationSession else { return }
        if canStartDirectly(forAddress: address) {
            setEnabled(true, forAddress: address, configuration: configuration, directly: true)
        } else if let route = audioRoute?.route, let uid = route.uid, let transport = route.transport,
                  LDACNativeOutput.canTransferControls(uid: uid, transport: transport.rawValue, address: address),
                  canEnable(forAddress: address), headphones.pendingControlTransition == nil,
                  headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()) {
            setEnabled(true, forAddress: address, configuration: configuration)
        }
    }

    func setEnabled(_ enabled: Bool, forAddress address: String, configuration: LDACConfiguration? = nil, directly: Bool = false) {
        guard let address = SonyBLEIdentity.normalizedAddress(address) else { return }
        if !enabled { LDACUpdateHandoff().cancel(address: address) }
        if automaticSelectionAddress == address { automaticSelectionAddress = nil }
        codecPreferences[address] = enabled
        defaults?.set(codecPreferences, forKey: "ldac.codecPreferences")
        if let headphones = devices?.controller(for: address) {
            automaticStartAttempts[ObjectIdentifier(headphones)] = headphones.notificationSession
        }
        if enabled {
            guard requestedAddress != address else { return }
            guard preferenceRestoreTasks[address] == nil else { return }
            guard support(forAddress: address).allowsStart(requested: true) else { return }
            guard directly ? canStartDirectly(forAddress: address) : deviceUnavailableReason(forAddress: address) == nil else { return }
            if let configuration { requestedConfiguration = configuration }
            if let reason = sampleRateUnavailableReason(requestedConfiguration.sampleRate, forAddress: address) {
                targetAddress = address
                state = .failed(reason)
                return
            }
            guard requestedConfiguration.isValid else {
                targetAddress = address
                state = .failed(String(localized: "The application routing settings are invalid."))
                return
            }
            if !isSessionRunning {
                refreshDriverState()
                guard driverState == .current else {
                    state = .off
                    targetAddress = nil
                    installDriver()
                    return
                }
            }
            guard helpers.isAvailable else {
                targetAddress = address
                state = .failed(String(localized: "LDAC playback is unavailable in this installation of Acouplet."))
                return
            }
            if !isSessionRunning, devices?.controller(for: address)?.ldacRequiresMultipointOff == true {
                guard multipointShutdownAddress == nil else { return }
                multipointConflictConfiguration = configuration
                multipointConflictAddress = address
                return
            }
            callAudio?.configure(policy: requestedConfiguration.microphonePolicy, externalMicrophoneUID: requestedConfiguration.externalMicrophoneUID)
            directStartRequested = directly
            requestedAddress = address
            recoveryAttempt = 0
            cancelAutomaticRetry()
            if !isSessionRunning { startWhenMicrophoneIsIdle(address) }
            else { stopSession(reason: "target changed") }
        } else if targetAddress == address || requestedAddress == address {
            connectOrdinaryAfterCleanup = false
            requestedAddress = nil
            suspensionRequested = false
            if isSessionRunning { stopSession(reason: "user disabled LDAC") }
            else { cancelAutomaticRetry(); state = .off; targetAddress = nil; resumeIfReady() }
        }
    }

    /// Answers the multipoint question for a waiting LDAC request. Keeping multipoint leaves LDAC off;
    /// turning it off waits for the headphones to confirm the change, which restarts them, and then starts LDAC.
    func resolveMultipointConflict(turnOffMultipoint: Bool) {
        guard let address = multipointConflictAddress else { return }
        let configuration = multipointConflictConfiguration
        multipointConflictAddress = nil
        multipointConflictConfiguration = nil
        guard turnOffMultipoint else {
            setEnabled(false, forAddress: address)
            return
        }
        let failure = String(localized: "Multipoint could not be turned off. LDAC did not start.")
        guard let headphones = devices?.controller(for: address), headphones.ldacRequiresMultipointOff else {
            setEnabled(true, forAddress: address, configuration: configuration)
            return
        }
        headphones.setMultipointEnabled(false)
        guard let transition = headphones.multipointTransition, !transition.isFinished, !transition.targetEnabled else {
            targetAddress = address
            state = .failed(headphones.multipointUnavailableReason ?? failure)
            return
        }
        let requestID = transition.requestID
        multipointShutdownAddress = address
        record("multipoint-off-requested", reason: "model=\(headphones.deviceModel.rawValue)")
        multipointShutdownTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(90)
            while !Task.isCancelled, Date() < deadline {
                guard let current = headphones.multipointTransition, current.requestID == requestID, !current.isFinished else { break }
                // The user already chose to turn multipoint off, so confirm the headphones' own prompt for that change.
                if let alert = current.alert {
                    headphones.respondToMultipointAlert(alert, action: alert.availableActions.contains(.positive) ? .positive : nil)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, !Task.isCancelled else { return }
            self.multipointShutdownAddress = nil
            self.multipointShutdownTask = nil
            if headphones.multipointTransition?.requestID == requestID, headphones.multipointTransition?.phase == .complete,
               headphones.systemFeatures.multipoint?.enabled == false {
                self.record("multipoint-off-confirmed", reason: "starting LDAC")
                self.setEnabled(true, forAddress: address, configuration: configuration)
            } else {
                self.targetAddress = address
                self.state = .failed(headphones.multipointTransition?.failureMessage ?? failure)
            }
        }
    }

    func resumeUpdateHandoff(handoff: LDACUpdateHandoff = LDACUpdateHandoff()) {
        guard let pending = handoff.pending(), codecPreferences[pending.address] != false,
              let configuration = pending.configuration.flatMap({ try? JSONDecoder().decode(LDACConfiguration.self, from: $0) })
                ?? preferredConfiguration(pending.address), configuration.isValid else { return }
        updateResumeTask?.cancel()
        updateResumeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updateResumeTask = nil }
            let deadline = Date().addingTimeInterval(45)
            var selected = false
            while !Task.isCancelled, Date() < deadline {
                guard handoff.pending()?.id == pending.id, let devices = self.devices,
                      !devices.isTerminating, !devices.isSystemSleeping,
                      self.codecPreferences[pending.address] != false,
                      self.requestedAddress == nil, !self.isSessionRunning else { return }
                if let headphones = devices.controller(for: pending.address), !headphones.isReconnectPaused {
                    if !selected { devices.selectForWorkflow(address: pending.address); selected = true }
                    guard devices.selectedAddress == pending.address else { return }
                    self.refreshDriverState()
                    if self.driverState == .current, self.canStartDirectly(forAddress: pending.address) {
                        self.record("update-handoff-resuming", reason: "starting the previously active headset directly")
                        self.setEnabled(true, forAddress: pending.address, configuration: configuration, directly: true)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopForUpdate(completion: @escaping @MainActor () -> Void) {
        if case .active = state, let address = targetAddress, let executable = bundle.executableURL {
            do {
                try LDACUpdateHandoff().prepare(address: address, helper: helpers.connection, executable: executable,
                                             configuration: JSONEncoder().encode(requestedConfiguration))
                stoppingForUpdate = true
                devices?.beginTermination()
                record("update-handoff-prepared", reason: "replacement may claim LDAC; ordinary audio fallback armed")
            } catch { record("update-handoff-failed", reason: error.localizedDescription) }
        }
        stop(restoreAudio: !stoppingForUpdate, reason: stoppingForUpdate ? "app update handoff" : "app is terminating", completion: completion)
    }

    func stop(restoreAudio: Bool = true, reason: String = "app requested stop", completion: (@MainActor () -> Void)? = nil) {
        updateResumeTask?.cancel()
        updateResumeTask = nil
        connectOrdinaryAfterCleanup = false
        if let address = requestedAddress ?? targetAddress, let headphones = devices?.controller(for: address) {
            automaticStartAttempts[ObjectIdentifier(headphones)] = headphones.notificationSession
        }
        requestedAddress = nil
        suspensionRequested = false
        if let completion {
            stopCompletions.append(completion)
            objectWillChange.send()
        }
        if !isSessionRunning { cancelAutomaticRetry(); state = .off; targetAddress = nil; resumeIfReady(); completeStop() }
        else { stopSession(restoreAudio: restoreAudio, reason: reason) }
    }

    func suspend(restoreAudio: Bool = false, reason: String = "Mac is going to sleep") {
        guard requestedAddress != nil else { return }
        suspensionRequested = true
        if isSessionRunning { stopSession(restoreAudio: restoreAudio, reason: reason) }
        else { state = .waitingForDevice }
    }

    func hasPendingConnectionPreferenceRestoration(forAddress address: String) -> Bool {
        pendingConnectionModes[address] != nil && requestedAddress != address
            && !(isSessionRunning && targetAddress == address)
    }

    func canRestoreConnectionPreference(forAddress address: String) -> Bool {
        guard hasPendingConnectionPreferenceRestoration(forAddress: address), preferenceRestoreTasks[address] == nil,
              devices?.isSystemSleeping != true, let headphones = devices?.controller(for: address),
              headphones.isDeviceConnected, headphones.isReady, !headphones.isReconnectPaused, headphones.connectionMode == .soundQuality,
              headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else { return false }
        return headphones.connectionModeUnavailableReason(.stableConnection) == nil
    }

    func restorePendingConnectionPreference(forAddress address: String) {
        reconcileConnectionPreferences()
        guard canRestoreConnectionPreference(forAddress: address), let headphones = devices?.controller(for: address) else { return }
        let previous = headphones.lastConnectionModeChangeID
        headphones.setConnectionMode(.stableConnection)
        guard let request = headphones.lastConnectionModeChangeID, request != previous else { return }
        pendingConnectionModes[address] = request
        deferredConnectionModes[address] = nil
        scheduleConnectionPreferenceRestoration(headphones, address: address, request: request, restorationRequested: true)
    }

    func keepConnectionPreference(forAddress address: String) {
        guard hasPendingConnectionPreferenceRestoration(forAddress: address), preferenceRestoreTasks[address] == nil else { return }
        forgetConnectionPreference(forAddress: address)
    }

    private func forgetConnectionPreference(forAddress address: String) {
        pendingConnectionModes[address] = nil
        deferredConnectionModes[address] = nil
        if targetAddress == address {
            connectionModeRestoreID = nil
            connectionModeConfirmed = false
        }
    }

    private func reconcileConnectionPreferences() {
        for (address, request) in pendingConnectionModes {
            guard let headphones = devices?.controller(for: address) else { continue }
            if let latest = headphones.lastConnectionModeChangeID, latest != request {
                forgetConnectionPreference(forAddress: address)
            } else if headphones.isDeviceConnected, headphones.isReady,
                      headphones.connectionTransition?.isFinished != false,
                      let mode = headphones.connectionMode, mode == .stableConnection || mode == .lowLatency {
                forgetConnectionPreference(forAddress: address)
            }
        }
    }

    private func scheduleConnectionPreferenceRestoration(_ headphones: SonyHeadphonesController, address: String,
                                                        request: UUID, restorationRequested: Bool = false) {
        preferenceRestoreTasks[address] = Task { [weak self] in
            guard let self else { return }
            let error = await self.restoreConnectionPreference(headphones, address: address, request: request,
                                                              restorationRequested: restorationRequested)
            self.objectWillChange.send()
            self.preferenceRestoreTasks[address] = nil
            if let error { self.record("preference-restore-failed", reason: error) }
            self.completeStop()
        }
    }

    /// `fromRetryTimer` is true only for the automatic-retry timer; when it cannot start LDAC it records which
    /// clauses failed (L1), so a silent no-op is visible in the log. Other callers stay silent.
    private func resumeIfReady(fromRetryTimer: Bool = false) {
        guard reconcileRequestedDevice() else {
            refreshPreferredCodec()
            return
        }
        guard devices?.isSystemSleeping != true else {
            if fromRetryTimer { recordRecovery("retry-blocked", reason: "failed=systemSleeping") }
            return
        }
        let microphoneIsIdle = synchronizeMicrophoneHandoff()
        updateWaitingDeadline()
        guard microphoneIsIdle else { return }
        reconcileConnectionPreferences()
        for (address, request) in deferredConnectionModes where address != requestedAddress && preferenceRestoreTasks[address] == nil {
            guard let headphones = devices?.controller(for: address), headphones.isDeviceConnected, headphones.isReady, !headphones.isReconnectPaused,
                  headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else { continue }
            deferredConnectionModes[address] = nil
            scheduleConnectionPreferenceRestoration(headphones, address: address, request: request)
        }
        if directStartRequested, state == .waitingForDevice, !isSessionRunning, cleanupTask == nil, recoveryTask == nil,
           let address = requestedAddress, preferenceRestoreTasks[address] == nil,
           canStartDirectly(forAddress: address), canResumeOnCurrentOutput(forAddress: address) {
            refreshDriverState()
            if driverState == .current, helpers.isAvailable { start(address, directly: true) }
            return
        }
        guard state == .waitingForDevice, !isSessionRunning, cleanupTask == nil, recoveryTask == nil,
              let address = requestedAddress, preferenceRestoreTasks[address] == nil,
              let headphones = devices?.controller(for: address),
              devices?.selectedAddress == address, headphones.isDeviceConnected,
              support(forAddress: address).allowsStart(requested: true),
              deviceUnavailableReason(forAddress: address) == nil, !headphones.ldacRequiresMultipointOff,
              canResumeOnCurrentOutput(forAddress: address),
              headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()) else {
            if fromRetryTimer || state == .waitingForDevice && requestedAddress != nil { recordRetryBlocked() }
            return
        }
        refreshDriverState()
        guard driverState == .current, helpers.isAvailable else {
            if fromRetryTimer {
                recordRecovery("retry-blocked", reason: "failed=" + [driverState == .current ? nil : "driverNotCurrent",
                                                                       helpers.isAvailable ? nil : "helpersUnavailable"].compactMap { $0 }.joined(separator: ","))
            }
            return
        }
        start(address)
    }

    private func clearWaitingDeadline() {
        waitingTask?.cancel()
        waitingTask = nil
        waitingDeadline = nil
    }

    private func updateWaitingDeadline() {
        guard state == .waitingForDevice, let address = requestedAddress else {
            clearWaitingDeadline()
            return
        }
        if isSuspendedForMicrophone, devices?.isSystemSleeping != true,
           devices?.controller(for: address)?.isDeviceConnected == true {
            clearWaitingDeadline()
            return
        }
        guard waitingDeadline == nil else { return }
        let deadline = now().addingTimeInterval(requestWaitTimeout)
        waitingDeadline = deadline
        waitingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(deadline.timeIntervalSince(self?.now() ?? deadline))) }
            catch { return }
            guard let self, self.waitingDeadline == deadline else { return }
            self.resumeIfReady()
            self.refreshPreferredCodec()
        }
    }

    private func reconcileRequestedDevice() -> Bool {
        guard let address = requestedAddress, let devices else { return true }
        let headphones = devices.controller(for: address)
        let reason: String?
        if headphones == nil || headphones?.isReconnectPaused == true {
            reason = "headphones disconnected by user or removed"
        } else if let waitingDeadline, now() >= waitingDeadline {
            reason = "pending playback request expired"
        } else { reason = nil }
        if let reason {
            recordRecovery("request-cancelled", reason: reason)
            stop(restoreAudio: !devices.isSystemSleeping && headphones?.isDeviceConnected == true
                && headphones?.isReconnectPaused != true, reason: reason)
            return false
        }
        updateWaitingDeadline()
        return true
    }

    private func startWhenMicrophoneIsIdle(_ address: String) {
        transportHealth = LDACTransportHealth()
        healthAddress = address
        runtimeStatus = LDACRuntimeStatus()
        targetAddress = address
        resumeOutputUID = audioRoute?.route?.uid
        if synchronizeMicrophoneHandoff() { start(address, directly: directStartRequested) }
        else { state = .waitingForDevice }
    }

    private func synchronizeMicrophoneHandoff() -> Bool {
        guard requestedAddress != nil, let callAudio else { return true }
        switch callAudio.activity {
        case .unknown:
            if requestedConfiguration.microphonePolicy == .external, isSessionRunning, !isSuspendedForMicrophone {
                isSuspendedForMicrophone = true
                suspend(restoreAudio: true, reason: "the selected separate microphone could not be verified")
            }
            return false
        case .active:
            if !isSuspendedForMicrophone {
                isSuspendedForMicrophone = true
                record("microphone-active", reason: "restoring ordinary Bluetooth call audio")
                suspend(restoreAudio: true, reason: "an application is using microphone input")
            }
            if !isSessionRunning { callAudio.routeForCall() }
            return false
        case .idle:
            guard !isSuspendedForMicrophone || callAudio.finishCall() else { return false }
            if isSuspendedForMicrophone {
                isSuspendedForMicrophone = false
                record("microphone-idle", reason: "resuming requested LDAC playback")
            }
            return true
        }
    }

    private func canResumeOnCurrentOutput(forAddress address: String) -> Bool {
        guard let resumeOutputUID, let route = audioRoute?.route, let uid = route.uid else { return false }
        if uid == resumeOutputUID { return true }
        guard let transport = route.transport?.rawValue else { return false }
        return LDACNativeOutput.canTransferControls(uid: uid, transport: transport, address: address)
    }

    /// Names the `resumeIfReady` clauses that currently fail. Clause names only, never addresses.
    private func recordRetryBlocked() {
        let address = requestedAddress
        let headphones = address.flatMap { devices?.controller(for: $0) }
        var failed: [String] = []
        if devices?.isSystemSleeping == true { failed.append("systemSleeping") }
        if state != .waitingForDevice { failed.append("state=\(state)") }
        if isSessionRunning { failed.append("sessionRunning") }
        if cleanupTask != nil { failed.append("cleanupTask") }
        if recoveryTask != nil { failed.append("recoveryTask") }
        if address == nil { failed.append("noRequestedAddress") }
        if let address, preferenceRestoreTasks[address] != nil { failed.append("preferenceRestoreTask") }
        if address != nil, headphones == nil { failed.append("noController") }
        if let address {
            if devices?.selectedAddress != address { failed.append("notSelected") }
            if headphones?.isDeviceConnected != true { failed.append("notConnected") }
            if deviceUnavailableReason(forAddress: address) != nil { failed.append("deviceUnavailable") }
            if headphones?.ldacRequiresMultipointOff == true { failed.append("multipointOn") }
        }
        if resumeOutputUID == nil { failed.append("noResumeOutput") }
        else if let address, !canResumeOnCurrentOutput(forAddress: address) { failed.append("macOutputChanged") }
        if headphones?.hasCurrentMusicSourceContext(for: localBluetoothAddress()) != true {
            failed.append("noMusicContext")
        }
        let reason = "failed=" + failed.joined(separator: ",")
        if lastResumeBlockers != reason {
            lastResumeBlockers = reason
            recordRecovery("retry-blocked", reason: reason)
        }
    }

    private func start(_ address: String, directly: Bool = false) {
        startingDirectly = directly
        directStartRequested = false
        lastResumeBlockers = nil
        sessionID = UUID()
        state = .requested
        targetAddress = address
        volumeError = nil
        connectionModeRestoreID = deferredConnectionModes.removeValue(forKey: address)
        connectionModeConfirmed = connectionModeRestoreID != nil
        suspensionRequested = false
        resumeOutputUID = audioRoute?.route?.uid
        isRecovering = false
        isAwaitingAutomaticRetry = false
        bindingHeldSince = nil
        restoreAudioOnStop = true
        stoppingForUpdate = false
        isSessionRunning = true
        record("requested", reason: "enabled; automaticRetriesUsed=\(recoveryAttempt)")
        let identifier = sessionID
        outputID = identifier
        let output = LDACOwnerOutput(id: sessionID, address: address) { [weak self] result in
            guard let self, self.outputID == identifier, self.state != .stopping else { return }
            switch result {
            case let .success(controls):
                self.record("native-controls", reason: "scalar=\(controls.scalar) userMuted=\(controls.muted)")
                if controls.muted { self.setOutputGain(0) }
                if let range = self.volumeRange {
                    self.volumeSession.pendingVolume = controls.volume(in: range)
                    self.sendPendingVolume()
                }
                if self.usable { self.setOutputGain(controls.muted ? 0 : 1) }
            case let .failure(error):
                if error is LDACPriorityCleanupError, let session = self.session,
                   self.requestedAddress == self.targetAddress {
                    self.beginRecovery(reason: error.localizedDescription)
                    session.verifyConnectionLoss(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
        nativeOutput = output
        #if DEBUG
        if simulatedStarts != nil {
            simulatedStarts?.append(address)
            return
        }
        #endif
        startTask = Task { [weak self] in
            guard let self, self.sessionID == identifier else { return }
            do {
                guard let devices = self.devices, let headphones = devices.controller(for: address), headphones.deviceModel != .unknown else {
                    throw ControlError(String(localized: "Connect the headphone controls in Acouplet before starting LDAC."))
                }
                if !directly, let reason = self.deviceUnavailableReason(forAddress: address) { throw ControlError(reason) }
                self.headphones = headphones
                if let request = self.connectionModeRestoreID, headphones.lastConnectionModeChangeID != request {
                    self.connectionModeRestoreID = nil
                    self.connectionModeConfirmed = false
                }
                if headphones.isReady { try await self.prepareConnectionMode(headphones, address: address, identifier: identifier) }
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.requestedAddress == address, self.state != .stopping else {
                    throw CancellationError()
                }
                guard devices.controller(for: address) === headphones else {
                    throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
                }
                try await output.claim(model: headphones.deviceModel.name, targetAddress: address, sampleRate: self.requestedConfiguration.sampleRate)
                if self.requestedConfiguration.routing.isSelective { try await output.configureRouting(self.requestedConfiguration.routing) }
                try await output.priorityControl()
                try Task.checkCancellation()
                if directly {
                    self.observeControls(headphones, devices: devices)
                    self.record("direct-start", reason: "connecting before music source and volume readback")
                    self.startTask = nil
                    self.launch(address)
                    return
                }
                let previousReadback = headphones.musicVolumeReadbackID
                if IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones.refresh() }
                self.record("initial-volume-wait", reason: self.musicControlStatus)
                let deadline = Date().addingTimeInterval(15)
                while !self.hasMusicVolumeForHandoff || !headphones.hasFreshMusicVolumeReadback || headphones.musicVolumeReadbackID == previousReadback {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw ControlError(String(localized: "The headphone volume could not be read. Connect the headphone controls in Acouplet and select this Mac as their audio source, then try LDAC again.")) }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                    throw ControlError("The headphones did not report their music volume range.", userFacing: String(localized: "The headphone volume could not be read. Connect the headphone controls in Acouplet and select this Mac as their audio source, then try LDAC again."))
                }
                self.volumeRange = range
                self.record("initial-volume-admitted", reason: self.musicControlStatus)
                self.initialReadbackID = headphones.musicVolumeReadbackID
                try await output.configure(volume: volume, range: range, preservingUserChange: true)
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.state != .stopping else { throw CancellationError() }
                guard self.hasMusicVolumeForHandoff, headphones.hasFreshMusicVolumeReadback,
                      headphones.musicVolumeReadbackID == self.initialReadbackID,
                      headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                    throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                }
                self.volumeSession.pendingVolume = output.controls.volume(in: range)
                self.observeControls(headphones, devices: devices)
                self.startTask = nil
                self.launch(address)
            } catch is CancellationError {
                guard self.sessionID == identifier else { return }
                self.record("start-cancelled", reason: self.musicControlStatus)
                self.startTask = nil
                self.finish(nil)
            } catch {
                guard self.sessionID == identifier else { return }
                self.record("start-failed", reason: "\(error.localizedDescription); \(self.musicControlStatus)")
                self.startTask = nil
                if directly, self.requestedAddress == address, self.state != .stopping, self.devices?.isSystemSleeping != true {
                    self.connectOrdinaryAfterCleanup = true
                    self.requestedAddress = nil
                    self.finish(error.localizedDescription)
                } else if self.devices?.isSystemSleeping == true || self.headphones?.isDeviceConnected == false {
                    self.suspensionRequested = self.requestedAddress == address
                    self.finish(nil, targetDisconnected: true)
                } else {
                    self.requestedAddress = nil
                    self.finish(error.localizedDescription)
                }
            }
        }
    }

    private func prepareConnectionMode(_ headphones: SonyHeadphonesController, address: String, identifier: UUID) async throws {
        try Task.checkCancellation()
        guard headphones.connectionTransition?.isFinished != false else {
            throw ControlError(String(localized: "Finish the current connection change before starting LDAC."))
        }
        guard headphones.supportsConnectionMode else { return }
        if headphones.connectionMode == .soundQuality { return }
        let original = headphones.connectionMode
        let previous = headphones.lastConnectionModeChangeID
        headphones.setConnectionMode(.soundQuality)
        guard let request = headphones.lastConnectionModeChangeID, request != previous else {
            throw ControlError(headphones.connectionModeError ?? String(localized: "Sound Quality could not be selected for LDAC."))
        }
        if original == .stableConnection {
            connectionModeRestoreID = request
            pendingConnectionModes[address] = request
        }
        guard try await waitForConnectionChange(headphones, address: address, request: request),
              headphones.connectionMode == .soundQuality else {
            throw ControlError(String(localized: "Sound Quality was not confirmed. LDAC did not start."))
        }
        try Task.checkCancellation()
        guard sessionID == identifier, requestedAddress == address, state != .stopping else { throw CancellationError() }
        connectionModeConfirmed = true
    }

    private func waitForConnectionChange(_ headphones: SonyHeadphonesController, address: String, request: UUID,
                                         restoring: Bool = false, timeout: Duration = .seconds(30)) async throws -> Bool {
        try Task.checkCancellation()
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = headphones.objectWillChange.sink { changes.continuation.yield(()) }
        let deviceObservation = devices?.objectWillChange.sink { changes.continuation.yield(()) }
        let stopObservation = objectWillChange.sink { changes.continuation.yield(()) }
        var deadline: Task<Void, Never>?
        var expired = false
        var refreshed = false
        var retried = false
        defer {
            observation.cancel()
            deviceObservation?.cancel()
            stopObservation.cancel()
            deadline?.cancel()
            changes.continuation.finish()
        }
        changes.continuation.yield(())
        for await _ in changes.stream {
            await Task.yield()
            try Task.checkCancellation()
            guard devices?.controller(for: address) === headphones,
                  SonyBLEIdentity.normalizedAddress(headphones.address) == address else {
                throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
            }
            guard headphones.lastConnectionModeChangeID == request else { return false }
            if restoring, headphones.isReconnectPaused || headphones.earbudFinder?.isBusy == true || headphones.earbudFinder?.mayBeRinging == true {
                deferredConnectionModes[address] = request
                pendingConnectionModes[address] = request
                return false
            }
            let sleeping = devices?.isSystemSleeping == true
            if stopCompletions.isEmpty && (sleeping || headphones.connectionTransition?.awaitingUser == true) {
                deadline?.cancel()
                deadline = nil
                expired = false
            } else if deadline == nil {
                deadline = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    expired = true
                    changes.continuation.yield(())
                }
            }
            if expired { throw ControlError(String(localized: "The headphones did not confirm the connection preference.")) }
            if sleeping { continue }
            if restoring, !headphones.isReady, headphones.connectionTransition?.isFinished != false, !refreshed {
                refreshed = true
                headphones.refresh()
            }
            if let transition = headphones.connectionTransition {
                switch transition.phase {
                case .failed:
                    if restoring, !retried, headphones.retryConnectionModeChange(expectedRequestID: request) {
                        retried = true
                        continue
                    }
                    throw ControlError(headphones.connectionModeError ?? String(localized: "The headphones did not confirm the connection preference."))
                case .pairingRequired:
                    throw ControlError(String(localized: "Check the headphone connection in Bluetooth settings before changing its preference."))
                case .cancelled:
                    if !restoring { throw ControlError(String(localized: "The connection preference change was cancelled.")) }
                default:
                    if !transition.isFinished { continue }
                }
            }
            if headphones.isReady, headphones.connectionMode != nil { return true }
        }
        try Task.checkCancellation()
        throw ControlError(String(localized: "The headphones did not confirm the connection preference."))
    }

    private func restoreConnectionMode() async -> String? {
        guard let request = connectionModeRestoreID, let headphones, let address = targetAddress else { return nil }
        defer {
            connectionModeRestoreID = nil
            connectionModeConfirmed = false
        }
        return await restoreConnectionPreference(headphones, address: address, request: request)
    }

    private func restoreConnectionPreference(_ headphones: SonyHeadphonesController, address: String, request: UUID,
                                             restorationRequested: Bool = false) async -> String? {
        var ownedRequest = request
        defer {
            if headphones.lastConnectionModeChangeID.map({ $0 != ownedRequest }) == true
                || (headphones.connectionTransition?.phase == .cancelled && (restorationRequested || ownedRequest != request)) {
                forgetConnectionPreference(forAddress: address)
            }
        }
        do {
            guard try await waitForConnectionChange(headphones, address: address, request: request, restoring: true) else { return nil }
            if headphones.connectionMode == .stableConnection {
                forgetConnectionPreference(forAddress: address)
                return nil
            }
            guard !restorationRequested else {
                throw ControlError(String(localized: "Stable Connection was not confirmed."))
            }
            guard headphones.connectionMode == .soundQuality else {
                throw ControlError(String(localized: "The headphone connection preference could not be verified."))
            }
            headphones.setConnectionMode(.stableConnection)
            guard let restoration = headphones.lastConnectionModeChangeID, restoration != request else {
                throw ControlError(headphones.connectionModeError ?? String(localized: "Stable Connection could not be selected."))
            }
            ownedRequest = restoration
            pendingConnectionModes[address] = restoration
            guard try await waitForConnectionChange(headphones, address: address, request: restoration, restoring: true) else { return nil }
            guard headphones.connectionMode == .stableConnection else {
                throw ControlError(String(localized: "Stable Connection was not confirmed."))
            }
            forgetConnectionPreference(forAddress: address)
            return nil
        } catch {
            if devices?.isSystemSleeping == true || !headphones.isDeviceConnected,
               headphones.lastConnectionModeChangeID == ownedRequest {
                deferredConnectionModes[address] = ownedRequest
                pendingConnectionModes[address] = ownedRequest
                return nil
            }
            return String(localized: "Stable Connection could not be restored. \(error.localizedDescription)")
        }
    }

    private func launch(_ address: String, restoringOnly: Bool = false) {
        if !restoringOnly { audioCaptureAccess = .checking }
        let identifier = sessionID
        record("helpers-started", reason: restoringOnly ? "restoring ordinary Bluetooth audio" : "checking targeted audio permission")
        #if DEBUG
        if simulatedLaunches != nil {
            simulatedLaunches?.append((address, restoringOnly))
            return
        }
        #endif
        let output = nativeOutput!
        let session = LDACOwnerSession(id: identifier, output: output, configuration: requestedConfiguration,
                                       recoveryAttempt: isRecovering, restoringOnly: restoringOnly) { [weak self] event in
            guard let self, self.session?.id == identifier else { return }
            switch event {
            case .handoffReady:
                self.record("handoff-ready", reason: self.musicControlStatus)
                guard self.state != .stopping else { return }
                self.readinessTask = Task {
                    do {
                        if !self.isRecovering && !self.startingDirectly {
                            guard self.hasMusicVolumeForHandoff, let headphones = self.headphones, headphones.hasFreshMusicVolumeReadback,
                                  let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                                throw ControlError("Headphone music controls changed before Bluetooth handoff. Retry LDAC.", userFacing: String(localized: "The headphone audio settings changed. Try LDAC again."))
                            }
                            let readback = headphones.musicVolumeReadbackID
                            let controlSession = headphones.notificationSession
                            try await self.nativeOutput?.configure(volume: volume, range: range, preservingUserChange: true)
                            try Task.checkCancellation()
                            guard self.hasMusicVolumeForHandoff, headphones.hasFreshMusicVolumeReadback,
                                  headphones.notificationSession == controlSession, headphones.musicVolumeReadbackID == readback,
                                  headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                                throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                            }
                            self.initialReadbackID = readback
                            if let output = self.nativeOutput { self.volumeSession.pendingVolume = output.controls.volume(in: range) }
                        } else {
                            try await self.nativeOutput?.validateForRecovery()
                        }
                        try await self.nativeOutput?.selectForHandoff()
                        try Task.checkCancellation()
                        guard self.sessionID == identifier, self.state != .stopping else { return }
                        guard self.startingDirectly || (self.hasMusicVolumeForHandoff
                              && (self.isRecovering || self.headphones?.musicVolumeReadbackID == self.initialReadbackID)) else {
                            throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                        }
                        self.readinessTask = nil
                        self.record("handoff-allowed", reason: "silent native output selected")
                        self.session?.allowHandoff()
                        self.state = .connecting
                    } catch is CancellationError {
                    } catch {
                        if self.devices?.isSystemSleeping == true || self.headphones?.isDeviceConnected == false {
                            self.suspend(restoreAudio: false, reason: "headphones disconnected during handoff")
                        } else { self.fail(error.localizedDescription) }
                    }
                }
            case .connecting:
                self.record("connecting", reason: "owned raw transport setup")
                if self.state != .stopping { self.state = .connecting }
            case .controlsRequired:
                guard self.state != .stopping else { return }
                self.prepareControlsForMedia(address)
            case let .active(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    self.record("raw-ready", reason: self.musicControlStatus)
                    self.waitForControls(address)
                }
            case let .formatChanged(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    if case .active = self.state { self.state = .active(format) }
                }
            case .latencyFrames: break
            case var .health(health):
                health.lastReason = self.transportHealth.lastReason ?? health.lastReason
                self.transportHealth = health
            case let .compatibility(status): self.runtimeStatus = status
            case let .capabilities(rates, channels):
                let store = LDACSupportStore(defaults: self.defaults)
                store.recordCapabilities(rates: rates, channels: channels, forAddress: address, context: self.capabilityContext(forAddress: address))
                if let record = store.all[address] { self.discoveredSupport[address] = record }
            case let .ldacEndpoint(supported):
                self.recordDiscoveredSupport(supported, address: address)
            case let .gainApplied(gain):
                self.record("gain-applied", reason: "gain=\(gain)")
            case let .audioCaptureAccess(access):
                self.audioCaptureAccess = access
                self.record("capture-access", reason: String(describing: access))
            case let .failed(message):
                self.fail(message)
            case let .connectionLost(message):
                if self.requestedAddress == address, self.state != .stopping { self.beginRecovery(reason: message) }
                else { self.session?.stop(restoreAudio: self.restoreAudioOnStop) }
            case let .finished(completion):
                self.session = nil
                self.sessionFinished(completion, address: address)
            }
        }
        self.session = session
        session.start()
    }

    /// Routes a finished LDAC or restoration session. A recoverable abort always returns the headphones to
    /// ordinary Bluetooth audio first (D1); the headphones leaving on their own waits for them to return.
    private func sessionFinished(_ completion: LDACNativeSession.Completion, address: String) {
        if playbackSettingsRestartAddress == address, state == .stopping, completion.message == nil, !completion.canRetry {
            if requestedAddress == address, !suspensionRequested, !completion.waitForReconnect,
               restoreAudioOnStop, canStartDirectly(forAddress: address) {
                restartPlayback(address)
                return
            }
            if requestedAddress == address { suspensionRequested = true }
            if completion.targetDisconnected, restoreAudioOnStop, !completion.waitForReconnect {
                restoreAfterPlaybackRestart(address)
                return
            }
        }
        playbackSettingsRestartAddress = nil
        if completion.waitForReconnect, completion.canRetry, requestedAddress == address {
            suspensionRequested = true
            finish(nil, targetDisconnected: true)
        } else if completion.canRetry, requestedAddress == address, state != .stopping {
            if !isRecovering { beginRecovery(reason: completion.message ?? "Bluetooth connection lost") }
            fallBackToOrdinaryAudio(address, targetDisconnected: completion.targetDisconnected)
        } else if completion.canRetry, !completion.waitForReconnect, restoreAudioOnStop {
            sessionID = UUID()
            launch(address, restoringOnly: true)
        } else {
            finish(completion.requiresAttention ? completion.message : nil, targetDisconnected: completion.targetDisconnected)
        }
    }

    private func restartPlayback(_ address: String) {
        guard let output = nativeOutput, let devices, let headphones = devices.controller(for: address) else {
            suspensionRequested = requestedAddress == address
            restoreAfterPlaybackRestart(address)
            return
        }
        let outputUID = audioRoute?.route?.uid
        guard outputUID == LDACNativeOutput.uid
            || requestedConfiguration.routing.isSelective && outputUID == requestedConfiguration.routing.outputDeviceUID
            || canResumeOnCurrentOutput(forAddress: address) else {
            suspensionRequested = true
            restoreAfterPlaybackRestart(address)
            return
        }
        sessionID = UUID()
        let identifier = sessionID
        state = .connecting
        startingDirectly = true
        isRecovering = false
        stableSince = nil
        transportFormat = nil
        controlSession = nil
        sourceAddress = nil
        volumeRange = nil
        volumeSession.pendingVolume = nil
        initialReadbackID = nil
        transportHealth = LDACTransportHealth()
        runtimeStatus = LDACRuntimeStatus()
        record("playback-settings-restart", reason: "rate=\(requestedConfiguration.sampleRate.rawValue) quality=\(requestedConfiguration.quality.rawValue)")
        #if DEBUG
        if simulatedStarts != nil {
            simulatedStarts?.append(address)
            playbackSettingsRestartAddress = nil
            launch(address)
            return
        }
        #endif
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await output.reconfigure(sampleRate: self.requestedConfiguration.sampleRate)
                try await output.prepareForReconnect()
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.requestedAddress == address, self.state != .stopping,
                      devices.controller(for: address) === headphones else { throw CancellationError() }
                self.headphones = headphones
                self.observeControls(headphones, devices: devices)
                self.startTask = nil
                self.playbackSettingsRestartAddress = nil
                self.launch(address)
            } catch {
                guard self.sessionID == identifier else { return }
                self.startTask = nil
                if !(error is CancellationError) {
                    self.volumeError = error.localizedDescription
                    self.requestedAddress = nil
                }
                self.restoreAfterPlaybackRestart(address)
            }
        }
    }

    private func restoreAfterPlaybackRestart(_ address: String) {
        playbackSettingsRestartAddress = nil
        state = .stopping
        if restoreAudioOnStop {
            sessionID = UUID()
            #if DEBUG
            if simulatedLaunches != nil {
                simulatedLaunches?.append((address, true))
                finish(nil)
                return
            }
            #endif
            launch(address, restoringOnly: true)
        } else { finish(nil, targetDisconnected: true) }
    }

    /// Returns the headphones to ordinary Bluetooth audio after a recoverable abort (D1). The first abort of a
    /// request schedules one LDAC retry after `automaticRetryDelay`; an abort of that retry leaves ordinary audio
    /// playing and tells the user. When LDAC had disconnected the headphones, the restore helper reconnects them;
    /// otherwise their ordinary connection is still up and releasing the output is enough.
    private func fallBackToOrdinaryAudio(_ address: String, targetDisconnected: Bool) {
        if recoveryAttempt >= 1 {
            recordRecovery("retry-exhausted", reason: "attempts=\(recoveryAttempt) targetDisconnected=\(targetDisconnected)")
            volumeError = String(localized: "LDAC stopped again because the Bluetooth connection couldn’t keep up. The headphones are using ordinary Bluetooth audio.")
            requestedAddress = nil
            retryAfterRestoration = false
        } else {
            recoveryAttempt += 1
            suspensionRequested = true
            retryAfterRestoration = true
            recordRecovery("native-fallback", reason: "attempt=\(recoveryAttempt) targetDisconnected=\(targetDisconnected)")
        }
        if targetDisconnected {
            sessionID = UUID()
            launch(address, restoringOnly: true)
        } else {
            finish(nil)
        }
    }

    private var hasMusicVolumeForHandoff: Bool {
        guard let headphones, let address = targetAddress,
              devices?.controller(for: address) === headphones,
              SonyBLEIdentity.normalizedAddress(headphones.address) == address,
              headphones.isDeviceConnected, headphones.hasCurrentMusicVolumeControl else { return false }
        return headphones.playback.generation == .v1
            || headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress())
    }

    private var hasOwnedMusicContext: Bool {
        hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)
    }

    private var hasOtherMusicSource: Bool {
        guard let headphones, headphones.isDeviceConnected, headphones.hasCurrentMusicVolumeControl,
              let address = headphones.multipoint.selectedSource?.address,
              let source = SonyBLEIdentity.normalizedAddress(address),
              let local = SonyBLEIdentity.normalizedAddress(localBluetoothAddress() ?? "") else { return false }
        return source != local
    }

    private func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {
        controlObservation = headphones.objectWillChange.merge(with: devices.objectWillChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.controlsChanged() }
        }
    }

    private var bindingIsCurrent: Bool { bindingCheck == .current }

    private var bindingCheck: LDACMusicBinding.Status {
        let matchesController: Bool
        if let headphones, let address = targetAddress {
            matchesController = devices?.controller(for: address) === headphones
                && SonyBLEIdentity.normalizedAddress(headphones.address) == address
        } else { matchesController = false }
        return LDACMusicBinding.check(.init(
            matchesController: matchesController,
            isConnected: headphones?.isDeviceConnected == true,
            session: headphones?.notificationSession,
            boundSession: controlSession,
            requiresRawTransport: headphones?.playback.generation == .v1,
            hasRawTransport: transportFormat != nil,
            isLeavingConnectionMode: headphones?.isLeavingLDACConnectionMode == true,
            selectedSource: headphones?.multipoint.selectedSource?.address,
            boundSource: sourceAddress,
            inventoryIsStale: headphones?.multipoint.inventoryIsStale == true,
            volumeRange: headphones?.playback.musicVolumeRange,
            boundVolumeRange: volumeRange,
            pendingTransition: headphones?.pendingControlTransition,
            hasOwnedMusicContext: hasOwnedMusicContext,
            hasCurrentVolumeControl: headphones?.hasCurrentMusicVolumeControl == true))
    }

    private var musicControlStatus: String {
        let volume = headphones?.playback.volume
        let range = headphones?.playback.musicVolumeRange
        let rangeDescription = range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unknown"
        let currentSession = headphones.map { String($0.notificationSession) } ?? "none"
        let selectedSource = headphones?.multipoint.selectedSource?.address ?? "none"
        let newReadback = headphones?.musicVolumeReadbackID != nil && headphones?.musicVolumeReadbackID != initialReadbackID
        return "ready=\(headphones?.isReady == true) connected=\(headphones?.isDeviceConnected == true) ownedContext=\(hasOwnedMusicContext) fresh=\(headphones?.hasFreshMusicVolumeReadback == true) canWrite=\(headphones?.canControlMusicVolume == true) canConfirm=\(headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true) newReadback=\(newReadback) controlSession=\(currentSession) bound=\(controlSession != nil) source=\(selectedSource) volume=\(volume.map(String.init) ?? "unknown") range=\(rangeDescription) pendingVolume=\(volumeSession.pendingVolume.map(String.init) ?? "none") writing=\(volumeSession.isWriting) userMuted=\(nativeOutput?.controls.muted ?? true)"
    }

    private func prepareControlsForMedia(_ address: String) {
        let identifier = sessionID
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let self, let headphones = self.headphones else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            var refreshedSession: UInt64?
            var volumeReadback: UUID?
            var statusReadback: UUID?
            var retriedControls = false
            var idleSince: ContinuousClock.Instant?
            self.record("prestream-controls-wait", reason: self.musicControlStatus)
            if IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones.refresh() }
            do {
                while true {
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.requestedAddress == address, self.state != .stopping else { return }
                    guard self.devices?.controller(for: address) === headphones else {
                        throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
                    }
                    if self.hasOtherMusicSource {
                        self.stopForChange("other-music-source")
                        return
                    }
                    guard ContinuousClock.now < deadline else {
                        throw ControlError(String(localized: "The headphone volume could not be read. Connect the headphone controls in Acouplet and select this Mac as their audio source, then try LDAC again."))
                    }
                    if !retriedControls, headphones.retryControlsIfNeeded(allowingSuppressedReconnect: true) { retriedControls = true }
                    if refreshedSession != headphones.notificationSession {
                        idleSince = nil
                        let previousVolume = headphones.musicVolumeReadbackID
                        let previousStatus = headphones.musicStatusReadbackID
                        if headphones.refreshMusicVolume() {
                            refreshedSession = headphones.notificationSession
                            volumeReadback = previousVolume
                            statusReadback = previousStatus
                        }
                    }
                    if headphones.isControlChannelIdle {
                        if idleSince == nil { idleSince = ContinuousClock.now }
                    } else { idleSince = nil }
                    if refreshedSession == headphones.notificationSession, headphones.isReady,
                       headphones.playback.hasReceivedCapabilities, headphones.playback.musicVolumeRange != nil,
                       headphones.playback.volume != nil,
                       headphones.musicVolumeReadbackID != nil, headphones.musicVolumeReadbackID != volumeReadback,
                       headphones.musicStatusReadbackID != nil, headphones.musicStatusReadbackID != statusReadback,
                       let idleSince, ContinuousClock.now >= idleSince.advanced(by: .milliseconds(500)) {
                        if self.startingDirectly {
                            guard !headphones.ldacRequiresMultipointOff else {
                                throw ControlError(String(localized: "Turn off multipoint before starting LDAC."))
                            }
                            try await self.prepareConnectionMode(headphones, address: address, identifier: identifier)
                            guard let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume,
                                  headphones.hasFreshMusicVolumeReadback else {
                                refreshedSession = nil
                                continue
                            }
                            let readback = headphones.musicVolumeReadbackID
                            let controlSession = headphones.notificationSession
                            try await self.nativeOutput?.configure(volume: volume, range: range, preservingUserChange: true)
                            try Task.checkCancellation()
                            guard self.sessionID == identifier, self.state != .stopping else { return }
                            guard headphones.notificationSession == controlSession, headphones.musicVolumeReadbackID == readback,
                                  headphones.hasFreshMusicVolumeReadback, headphones.pendingControlTransition == nil,
                                  headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                                refreshedSession = nil
                                continue
                            }
                            self.volumeRange = range
                            self.initialReadbackID = readback
                            self.volumeSession.pendingVolume = self.nativeOutput?.controls.volume(in: range)
                        }
                        self.record("prestream-controls-ready", reason: self.musicControlStatus)
                        self.readinessTask = nil
                        headphones.isLDACStreaming = true
                        self.session?.allowMediaSetup()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier, self.state != .stopping else { return }
                self.beginRecovery(reason: error.localizedDescription)
                self.session?.recoverConnection(reason: error.localizedDescription)
            }
        }
    }

    private func waitForControls(_ address: String) {
        let identifier = sessionID
        if (headphones?.isReady != true || headphones?.hasFreshMusicVolumeReadback != true
            || headphones?.playback.generation != .v1 && headphones?.musicVolumeReadbackID == initialReadbackID),
           IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones?.refresh() }
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            var previousStatus = ""
            var refreshedLegacySession: UInt64?
            var initialStatusReadbackID: UUID?
            var retriedControls = false
            do {
                while !self.usable {
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.state != .stopping else { return }
                    let status = self.musicControlStatus
                    if status != previousStatus { self.record("volume-wait", reason: status); previousStatus = status }
                    guard Date() < deadline else { throw ControlError(String(localized: "The headphone volume could not be confirmed after LDAC started. Reconnect the headphone controls and try LDAC again.")) }
                    if self.controlSession == nil, !retriedControls,
                       self.headphones?.retryControlsIfNeeded(allowingSuppressedReconnect: true) == true { retriedControls = true }
                    if let headphones = self.headphones, headphones.playback.generation == .v1,
                       refreshedLegacySession != headphones.notificationSession {
                        let volumeReadback = headphones.musicVolumeReadbackID
                        let statusReadback = headphones.musicStatusReadbackID
                        if headphones.refreshMusicVolume() {
                            refreshedLegacySession = headphones.notificationSession
                            self.initialReadbackID = volumeReadback
                            initialStatusReadbackID = statusReadback
                        }
                    }
                    if self.controlSession == nil, self.hasOwnedMusicContext, let headphones = self.headphones, headphones.hasFreshMusicVolumeReadback,
                       let readback = headphones.musicVolumeReadbackID, readback != self.initialReadbackID,
                       headphones.playback.generation != .v1 || (refreshedLegacySession == headphones.notificationSession
                           && headphones.musicStatusReadbackID != nil && headphones.musicStatusReadbackID != initialStatusReadbackID),
                       let range = headphones.playback.musicVolumeRange, headphones.playback.volume != nil {
                        self.controlSession = headphones.notificationSession
                        self.sourceAddress = headphones.multipoint.selectedSource?.address
                        self.volumeRange = range
                        self.record("volume-bound", reason: self.musicControlStatus)
                        if self.isRecovering || self.volumeSession.pendingVolume == nil, let output = self.nativeOutput { self.volumeSession.pendingVolume = output.controls.volume(in: range) }
                    }
                    if self.controlSession != nil {
                        switch self.bindingCheck {
                        case .current: break
                        case .held:
                            try await Task.sleep(for: .milliseconds(100))
                            continue
                        case let .sourceChanged(reason):
                            self.stopForChange(reason)
                            return
                        case let .lost(reason):
                            self.recordRecovery("binding-lost", reason: reason)
                            throw ControlError(String(localized: "The headphone audio source or connection changed. LDAC stopped."))
                        }
                        self.sendPendingVolume()
                        if self.volumeSession.pendingVolume == nil, !self.volumeSession.isWriting,
                           self.headphones?.canControlMusicVolume == true,
                           self.headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true,
                           let format = self.transportFormat {
                            try await self.nativeOutput?.finishPreparation()
                            try Task.checkCancellation()
                            guard self.sessionID == identifier, self.state != .stopping, self.bindingIsCurrent,
                                  self.volumeSession.pendingVolume == nil, !self.volumeSession.isWriting else {
                                self.nativeOutput?.silence()
                                continue
                            }
                            if let output = self.nativeOutput, let range = self.volumeRange,
                               self.headphones?.playback.volume != output.controls.volume(in: range) {
                                output.silence()
                                self.volumeSession.pendingVolume = output.controls.volume(in: range)
                                continue
                            }
                            self.usable = true
                            self.isRecovering = false
                            self.stableSince = Date()
                            self.record("volume-admitted", reason: self.musicControlStatus)
                            self.setOutputGain(self.nativeOutput?.controls.muted == false ? 1 : 0)
                            self.state = .active(format)
                        }
                    }
                    if !self.usable { try await Task.sleep(for: .milliseconds(100)) }
                }
                if self.sessionID == identifier { self.readinessTask = nil }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier else { return }
                if error is ControlError, !self.hasOtherMusicSource {
                    self.beginRecovery(reason: error.localizedDescription)
                    self.session?.recoverConnection(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
    }

    private func controlsChanged() {
        guard state != .stopping else { return }
        if let request = connectionModeRestoreID, let headphones,
           headphones.lastConnectionModeChangeID != request
            || (connectionModeConfirmed && headphones.connectionMode != nil && headphones.connectionMode != .soundQuality) {
            if let address = targetAddress { forgetConnectionPreference(forAddress: address) }
        }
        if let address = targetAddress, let headphones, devices?.controller(for: address) !== headphones {
            suspend(restoreAudio: false, reason: "headphone controller changed")
            return
        }
        if hasOtherMusicSource {
            stopForChange("other-music-source")
            return
        }
        guard controlSession != nil else { return }
        switch bindingCheck {
        case .current:
            if bindingHeldSince != nil { recordRecovery("binding-restored", reason: "current") }
            bindingHeldSince = nil
            bindingHoldTask?.cancel()
            bindingHoldTask = nil
        case let .held(reason, transition):
            holdBinding(reason, transition: transition)
            return
        case let .sourceChanged(reason):
            stopForChange(reason)
            return
        case let .lost(reason):
            recoverBinding(reason)
            return
        }
        // Only a volume that differs from the Mac's own controls is news. Re-confirming the same volume on every
        // `objectWillChange` sent an owner request each time and caused the `volume-confirmed` bursts (L6).
        if volumeSession.pendingVolume == nil, !volumeSession.isWriting, let headphones, let range = volumeRange,
           let volume = headphones.playback.volume, let output = nativeOutput, output.controls.volume(in: range) != volume {
            volumeSession.pendingVolume = volume
        }
        sendPendingVolume()
    }

    /// Keeps LDAC playing while the binding is only held. Unfinished transitions hold it for as long as they run;
    /// lost freshness alone gets `bindingHoldLimit` seconds to return before LDAC recovers (L4).
    private func holdBinding(_ reason: String, transition: Bool, at date: Date = Date()) {
        if bindingHeldSince == nil { recordRecovery("binding-held", reason: reason) }
        if transition || bindingHeldSince == nil { bindingHeldSince = date }
        guard let since = bindingHeldSince else { return }
        let remaining = bindingHoldLimit - date.timeIntervalSince(since)
        guard remaining > 0 else {
            recoverBinding("binding-hold-expired \(reason)")
            return
        }
        guard bindingHoldTask == nil else { return }
        let identifier = sessionID
        bindingHoldTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            guard let self, self.sessionID == identifier else { return }
            self.bindingHoldTask = nil
            self.controlsChanged()
        }
    }

    private func recoverBinding(_ reason: String) {
        recordRecovery("binding-lost", reason: reason)
        let message = String(localized: "The headphone controls temporarily disconnected.")
        beginRecovery(reason: "\(reason): \(message)")
        session?.recoverConnection(reason: message)
    }

    private func stopForChange(_ reason: String) {
        if reason != "connection-mode", let selected = headphones?.multipoint.selectedSource?.address,
           headphones?.requestedSourceSwitchAddress != selected {
            if let address = requestedAddress ?? targetAddress {
                codecPreferences[address] = false
                defaults?.set(codecPreferences, forKey: "ldac.codecPreferences")
            }
            recordRecovery("source-takeover", reason: reason)
            stop(restoreAudio: true, reason: "another headphone music source is active")
            return
        }
        transportHealth.lastReason = LDACDiagnosticReport.redacted(reason)
        recordRecovery("source-changed", reason: reason)
        fail(reason == "connection-mode"
             ? String(localized: "The headphones left Sound Quality mode. LDAC stopped and ordinary Bluetooth audio was restored.")
             : String(localized: "Another device became the headphones’ audio source. LDAC stopped and ordinary Bluetooth audio was restored."))
    }

    private func sendPendingVolume() {
        volumeSession.send(using: .init(
            context: { [weak self] in
                guard let self, self.controlSession != nil, self.state != .stopping, let headphones = self.headphones else { return nil }
                return LDACVolumeSession.Context(
                    sessionID: self.sessionID, binding: self.bindingCheck, hasRawTransport: self.transportFormat != nil,
                    volumeRange: self.volumeRange,
                    canWrite: headphones.canControlMusicVolume && headphones.canPerformConfirmedSettingChange(.playbackVolume),
                    headphoneVolume: headphones.playback.volume,
                    nativeVolume: self.volumeRange.flatMap { self.nativeOutput?.controls.volume(in: $0) })
            },
            write: { [weak self] volume, isCurrent in
                guard let headphones = self?.headphones else { throw CancellationError() }
                try await headphones.performConfirmedSettingChange(.playbackVolume) {
                    headphones.setPlaybackVolume(volume, isCurrent: isCurrent)
                }
            },
            configure: { [weak self] volume, range in
                guard let self, let output = self.nativeOutput else { return }
                do { try await output.configure(volume: volume, range: range) }
                catch is LDACOwnerTimeoutError {
                    self.record("volume-configure-late", reason: "confirmed=\(volume)")
                }
            },
            record: { [weak self] event, reason in self?.record(event, reason: reason) },
            failed: { [weak self] error, binding in
                guard let self else { return }
                switch binding {
                case let .sourceChanged(reason): self.stopForChange(reason)
                case let .lost(reason): self.recoverBinding("\(reason) after volume error")
                case .current: self.fail(error.localizedDescription)
                case .held: break
                }
            },
            deferred: { [weak self] in self?.controlsChanged() }))
    }

    private func setOutputGain(_ gain: Double) {
        guard requestedOutputGain != gain else { return }
        requestedOutputGain = gain
        record("gain-requested", reason: "gain=\(gain) usable=\(usable) userMuted=\(nativeOutput?.controls.muted ?? true)")
        session?.updateGain(gain)
    }

    private func fail(_ message: String) {
        transportHealth.lastReason = LDACDiagnosticReport.redacted(message)
        guard state != .stopping else { return }
        record("failed", reason: "\(message); \(musicControlStatus)")
        volumeError = message
        requestedAddress = nil
        stopSession(reason: "coordinator failed: \(message)")
    }

    private func beginRecovery(reason: String, at date: Date = Date()) {
        guard requestedAddress == targetAddress, requestedAddress != nil, state != .stopping else { return }
        recordRecovery("recovering", reason: reason)
        if let stableSince, date.timeIntervalSince(stableSince) >= 30 { recoveryAttempt = 0 }
        stableSince = nil
        isRecovering = true
        state = .connecting
        usable = false
        nativeOutput?.silence()
        setOutputGain(0)
        readinessTask?.cancel()
        readinessTask = nil
        volumeSession.cancel()
        bindingHoldTask?.cancel()
        bindingHoldTask = nil
        bindingHeldSince = nil
        controlSession = nil
        sourceAddress = nil
        transportFormat = nil
    }

    /// Waits `automaticRetryDelay` with ordinary audio playing, then lets `resumeIfReady` start the single LDAC
    /// retry as soon as the headphones, source and Mac output allow it. Every exit clears `recoveryTask` (L10).
    private func scheduleRecovery(_ address: String) {
        guard recoveryTask == nil else { return }
        let taskID = UUID()
        recoveryTaskID = taskID
        isAwaitingAutomaticRetry = true
        recordRecovery("retry-scheduled", reason: "delay=\(automaticRetryDelay) attempt=\(recoveryAttempt)")
        recoveryTask = Task { [weak self] in
            defer { self?.endRetryWait(taskID) }
            guard let delay = self?.automaticRetryDelay else { return }
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self else { return }
            self.endRetryWait(taskID)
            guard self.requestedAddress == address, self.state == .waitingForDevice, !self.isSessionRunning else { return }
            self.recordRecovery("retry-due", reason: "attempt=\(self.recoveryAttempt)")
            self.resumeIfReady(fromRetryTimer: true)
        }
    }

    private func endRetryWait(_ taskID: UUID) {
        guard recoveryTaskID == taskID else { return }
        recoveryTask = nil
        recoveryTaskID = nil
        isAwaitingAutomaticRetry = false
    }

    private func cancelAutomaticRetry() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryTaskID = nil
        isAwaitingAutomaticRetry = false
    }

    private func stopSession(restoreAudio: Bool = true, reason: String) {
        record("stopping", reason: "\(reason); restoreAudio=\(restoreAudio) usable=\(usable) requestedGain=\(requestedOutputGain); \(musicControlStatus)")
        restoreAudioOnStop = restoreAudioOnStop && restoreAudio
        guard cleanupTask == nil else { return }
        cancelAutomaticRetry()
        bindingHoldTask?.cancel()
        bindingHoldTask = nil
        state = .stopping
        usable = false
        nativeOutput?.silence()
        setOutputGain(0)
        readinessTask?.cancel()
        readinessTask = nil
        volumeSession.cancel()
        controlObservation = nil
        if let session {
            if stoppingForUpdate {
                session.stopForUpdate()
            } else if let playbackSettingsRestartAddress, playbackSettingsRestartAddress == targetAddress, requestedAddress == targetAddress,
               !suspensionRequested, restoreAudio {
                session.stopForRestart()
            } else { session.stop(restoreAudio: restoreAudio) }
        }
        else if let startTask { startTask.cancel() }
        else if isRecovering, restoreAudioOnStop, let address = targetAddress {
            sessionID = UUID()
            launch(address, restoringOnly: true)
        } else { finish(nil) }
    }

    private func finish(_ message: String?, targetDisconnected: Bool = false) {
        guard cleanupTask == nil else { return }
        record("restoring", reason: "raw=\(message ?? "clean") coordinator=\(volumeError ?? "none")")
        state = .stopping
        usable = false
        cancelAutomaticRetry()
        bindingHoldTask?.cancel()
        bindingHoldTask = nil
        bindingHeldSince = nil
        readinessTask?.cancel()
        readinessTask = nil
        volumeSession.cancel()
        controlObservation = nil
        let output = nativeOutput
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            let disconnected = targetDisconnected || self.devices?.isSystemSleeping == true || !self.restoreAudioOnStop
            let restoreError = await output?.restoreAndRelease(targetDisconnected: disconnected)
            let connectionRestoreError: String?
            if disconnected || self.suspensionRequested {
                if let address = self.targetAddress, let request = self.connectionModeRestoreID {
                    self.deferredConnectionModes[address] = request
                    self.pendingConnectionModes[address] = request
                }
                self.connectionModeRestoreID = nil
                self.connectionModeConfirmed = false
                connectionRestoreError = nil
            } else {
                connectionRestoreError = await self.restoreConnectionMode()
            }
            self.record("restored", reason: restoreError ?? "routes restored and output lease released")
            self.nativeOutput = nil
            self.outputID = nil
            self.headphones = nil
            self.transportFormat = nil
            self.controlSession = nil
            self.sourceAddress = nil
            self.volumeRange = nil
            self.volumeSession.pendingVolume = nil
            self.initialReadbackID = nil
            self.startingDirectly = false
            self.requestedOutputGain = 0
            self.isSessionRunning = false
            self.isRecovering = false
            self.stableSince = nil
            if self.audioCaptureAccess == .checking { self.audioCaptureAccess = .unchecked }
            let messages = [message, self.volumeError, restoreError, connectionRestoreError].compactMap { $0 }
                .reduce(into: [String]()) { messages, message in
                    guard !messages.contains(where: { $0.contains(message) }) else { return }
                    messages.removeAll { message.contains($0) }
                    messages.append(message)
                }
            self.volumeError = nil
            self.cleanupTask = nil
            let retry = self.retryAfterRestoration
            self.retryAfterRestoration = false
            let playbackSettingsRestartAddress = self.playbackSettingsRestartAddress
            self.playbackSettingsRestartAddress = nil
            if !messages.isEmpty {
                self.requestedAddress = nil
                self.state = .failed(messages.joined(separator: " "))
            } else if let next = self.requestedAddress {
                if self.suspensionRequested || playbackSettingsRestartAddress == next {
                    self.targetAddress = next
                    self.state = .waitingForDevice
                    if retry { self.scheduleRecovery(next) }
                } else { self.startWhenMicrophoneIsIdle(next) }
            } else {
                if let address = self.targetAddress, let headphones = self.devices?.controller(for: address) {
                    self.automaticStartAttempts[ObjectIdentifier(headphones)] = headphones.notificationSession
                }
                self.targetAddress = nil
                self.state = .off
            }
            if self.connectOrdinaryAfterCleanup {
                self.connectOrdinaryAfterCleanup = false
                if !disconnected, self.restoreAudioOnStop, restoreError == nil, connectionRestoreError == nil,
                   self.devices?.isSystemSleeping != true, self.devices?.isTerminating != true,
                   let address = self.targetAddress, self.devices?.selectedAddress == address,
                   !self.isClassicConnected(address), let headphones = self.devices?.controller(for: address),
                   !headphones.isReconnectPaused {
                    headphones.connect(preferLDAC: false)
                }
            }
            self.resumeIfReady()
            self.refreshPreferredCodec()
            if !self.isSessionRunning { self.completeStop() }
        }
    }

    private func record(_ event: String, reason: String) {
        Self.logger.notice("LDAC controller \(event, privacy: .public); target=\(self.targetAddress ?? "none", privacy: .private(mask: .hash)) session=\(self.sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .private)")
    }

    /// Logs a recovery decision with a public reason. Callers pass only clause names, counters and fixed
    /// messages, never addresses, so the log can say which binding condition failed; the control status that
    /// contains the source address stays private.
    private func recordRecovery(_ event: String, reason: String) {
        transportHealth.lastReason = LDACDiagnosticReport.redacted(reason)
        Self.logger.notice("LDAC controller \(event, privacy: .public); target=\(self.targetAddress ?? "none", privacy: .private(mask: .hash)) session=\(self.sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .public) status=\(self.musicControlStatus, privacy: .private)")
    }

    private func completeStop() {
        guard !needsStopBeforeTermination else { return }
        let completions = stopCompletions
        stopCompletions = []
        for completion in completions { completion() }
    }

    private struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String, userFacing: String? = nil) {
            self.message = userFacing ?? message
            if userFacing != nil { LDACController.logger.error("\(message, privacy: .private)") }
        }
    }
}
#endif
