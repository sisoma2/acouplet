import AppKit
import SwiftUI

struct MenuBarView: View {
    let showSettings: () -> Void
    var closeMenu: (() -> Void)? = nil
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var settings: SettingsStore
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableHeight: CGFloat
    @State private var isHeightConstrained = false
    @State private var powerOffTarget: PowerOffTarget?
    @State private var showsPowerOffConfirmation = false
    @State private var showsMultipoint = false

    private struct PowerOffTarget {
        let controller: SonyHeadphonesController
        let session: UInt64
        let name: String
    }

    init(showSettings: @escaping () -> Void, closeMenu: (() -> Void)? = nil, initialScreenHeight: CGFloat? = nil) {
        self.showSettings = showSettings
        self.closeMenu = closeMenu
        _availableHeight = State(initialValue: (initialScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 720) - 16)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !showsConnectOnly {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
            }
            // One ScrollView instead of ViewThatFits, which built and measured every control twice (G9).
            // The panel size still comes from the ideal height of the VStack below: `.fixedSize(vertical:)` asks
            // the ScrollView for its content height, and `.frame(maxHeight:)` clamps it to the screen. It does not
            // depend on the height the popover currently has, so there is no feedback loop with the measurement.
            ScrollView {
                controls
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(isHeightConstrained ? .automatic : .never)
            .accessibilityIdentifier("headphones.controlsScroll")
            ForEach(devicesNeedingConfirmation, id: \.address) { controller in
                Divider()
                Button {
                    dismissMenu()
                    devices.selectForWorkflow(address: controller.address)
                    settings.selectedSettingsPane = "headphones"
                    showSettings()
                } label: {
                    Label("\(controller.deviceName) Needs Confirmation…", systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .accessibilityIdentifier("menu.otherDeviceConfirmation")
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            if needsLDACDriverUpdate, !showsLDACControl {
                Divider()
                Button {
                    dismissMenu()
                    ldac.updateDriver()
                } label: {
                    Label("Update LDAC Driver…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .disabled(ldac.isOpeningDriverInstaller)
                .help("This version of Acouplet includes a newer LDAC audio driver.")
                .accessibilityIdentifier("menu.updateLDACDriver")
            }
            #endif
            #if ACOUPLET_SPARKLE
            if updater.hasPendingUpdate {
                Divider()
                Button {
                    dismissMenu()
                    updater.checkForUpdates()
                } label: {
                    Label("Update Available…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .accessibilityIdentifier("menu.updateAvailable")
            }
            #endif
            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Bool.self) { $0.size.height >= maximumHeight - 1 } action: {
            isHeightConstrained = $0
        }
        .windowResizeAnchorIfAvailable(.topLeading)
        .background(PanelScreenHeightReader { availableHeight = $0 }.accessibilityHidden(true))
        .font(.body)
        .controlSize(.regular)
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("headphones.dashboard")
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: showsConnectOnly)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: showsHeadphoneControls)
        .alert("Turn Off \(powerOffTarget?.name ?? "")?", isPresented: $showsPowerOffConfirmation, presenting: powerOffTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Turn Off") { target.controller.powerOff(expectedSession: target.session) }
        } message: { _ in
            Text("Audio will stop on all connected devices. You’ll need to turn the headphones on again before reconnecting.")
        }
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
    }

    private var showsHeadphoneControls: Bool {
        headphones.isReady && headphones.powerOffState == nil && !headphones.headphoneTestNeedsRecovery
    }

    private var devicesNeedingConfirmation: [SonyHeadphonesController] {
        devices.controllers.filter {
            $0 !== headphones && ($0.connectionTransition?.alert != nil || $0.multipointTransition?.alert != nil)
        }
    }

    private var showsConnectOnly: Bool {
        headphones.linkState == .disconnected && !headphones.isDeviceConnected
            && headphones.powerOffState == nil && !headphones.headphoneTestNeedsRecovery
            && headphones.lastErrorMessage == nil && !showsLDACSession && !devices.hasOtherSelectableDevices
    }

    private var showsLDACSession: Bool {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        return ldac.targetAddress == headphones.address && ldac.state.keepsMenuBarVisible(isSessionRunning: ldac.isSessionRunning)
        #else
        return false
        #endif
    }

    private var maximumHeight: CGFloat {
        #if DEBUG
        if CommandLine.arguments.contains("--compact-panel") { return 480 }
        #endif
        return availableHeight
    }

    private var controls: some View {
        let controlsDisabled = (headphones.isRunningHeadphoneTest && !headphones.headphoneTestNeedsRecovery)
            || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false
        return VStack(alignment: .leading, spacing: 16) {
            if !showsLDACSession {
                HeadphoneConnectionView(connectOnly: showsConnectOnly)
                    .disabled(controlsDisabled)
            }
            Group {
                if showsHeadphoneControls {
                    if headphones.isRunningHeadphoneTest {
                        Text("A headphone test is open in Settings.").font(.caption)
                    }
                    if !headphones.availableNoiseModes.isEmpty {
                        NoiseControlView(headphones: headphones, tint: settings.tintColor)
                    }
                }
            }
            .disabled(controlsDisabled)
            if showsHeadphoneControls, MultipointSettingControl.showsMenuEntry(for: headphones) {
                multipointControl
            }
            if showsHeadphoneControls {
                Group {
                    if headphones.equalizer.isSupported { equalizer }
                    if headphones.legacySurround.isSupported { LegacySoundEffectControl(kind: .surround) }
                    if headphones.legacySoundPosition.isSupported { LegacySoundEffectControl(kind: .soundPosition) }
                    if headphones.supportsDSEE { DSEEControl() }
                }
                .disabled(controlsDisabled)
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            if showsLDACControl {
                ldacControl
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var multipointControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Multipoint")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showsMultipoint = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .tint(nil)
                .controlSize(.small)
                .accessibilityLabel("Manage Devices")
                .accessibilityIdentifier("multipoint.open")
                .help("Manage Devices")
                .background {
                    MultipointPopover(isPresented: $showsMultipoint, headphones: headphones, settings: settings, maximumHeight: min(availableHeight, 480))
                        .accessibilityHidden(true)
                }
            }
            MultipointSourcePicker()
            if let message = headphones.sourceTransition?.failureMessage ?? headphones.deviceActionTransition?.failureMessage {
                Text(message).font(.caption)
            }
            Divider()
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var showsLDACControl: Bool {
        showsLDACSession || (settings.experimentalLDACEnabled
            && ((showsHeadphoneControls && ldac.deviceUnavailableReason(forAddress: headphones.address) == nil)
            || (ldac.targetAddress == headphones.address && ldac.state != .off)))
    }

    private var needsLDACDriverUpdate: Bool {
        settings.experimentalLDACEnabled && ldac.driverState == .outdated && !ldac.isSessionRunning
    }

    private var ldacState: LDACState { ldac.targetAddress == headphones.address ? ldac.state : .off }
    private var isTurningOffMultipointForLDAC: Bool { ldac.multipointShutdownAddress == headphones.address }

    private var ldacIsEnabled: Bool {
        switch ldacState {
        case .waitingForDevice, .requested, .connecting, .active: true
        case .stopping: ldac.isSuspendedForMicrophone
        case .off, .failed: false
        }
    }

    private var ldacStatusText: String {
        switch ldacState {
        case .off: String(localized: "Off")
        case .waitingForDevice:
            ldac.isSuspendedForMicrophone ? String(localized: "Headset call audio · LDAC paused")
                : ldac.isAwaitingAutomaticRetry ? String(localized: "Ordinary audio · retrying LDAC…") : String(localized: "Waiting for headphones…")
        case .requested: ldac.audioCaptureAccess == .checking ? String(localized: "Checking permission…") : String(localized: "Requested…")
        case .connecting: ldac.isRecovering ? String(localized: "Reconnecting…") : String(localized: "Connecting…")
        case .active(let format):
            String(localized: "\((Double(format.sampleRateHz) / 1_000).formatted()) kHz · \(format.bitrateKbps) kb/s")
                + (format.channels == 2 ? "" : String(localized: " · \(format.channels) channels"))
        case .stopping: String(localized: "Restoring audio…")
        case .failed: String(localized: "Failed")
        }
    }

    private var ldacControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LDAC")
                LDACSettingsMenu(
                    address: headphones.address,
                    sampleRate: settings.ldacConfiguration.sampleRate,
                    quality: settings.ldacConfiguration.quality,
                    unavailableSampleRates: Dictionary(uniqueKeysWithValues: LDACSampleRate.allCases.compactMap { rate in
                        ldac.sampleRateUnavailableReason(rate, forAddress: headphones.address).map { (rate, $0) }
                    }),
                    isEnabled: ldac.canChangePlaybackSettings(forAddress: headphones.address),
                    canCheckSupport: !ldac.needsStopBeforeTermination && ldac.canStartOrInstallDriver,
                    setSampleRate: { settings.ldacConfiguration.sampleRate = $0 },
                    setQuality: { settings.ldacConfiguration.quality = $0 },
                    checkSupport: {
                        ldac.checkSupportAgain(forAddress: headphones.address, configuration: settings.ldacConfiguration(forAddress: headphones.address))
                    }
                )
                .equatable()
                Spacer()
                switch ldacState {
                case .requested, .connecting, .stopping:
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                default:
                    if isTurningOffMultipointForLDAC { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                }
                Text(isTurningOffMultipointForLDAC ? String(localized: "Turning off multipoint…") : ldacStatusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio.ldacFormat")
                Toggle("LDAC", isOn: Binding(
                    get: { ldacIsEnabled },
                    set: { ldac.setEnabled($0, forAddress: headphones.address, configuration: settings.ldacConfiguration(forAddress: headphones.address)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
                .disabled(!ldacIsEnabled && (isTurningOffMultipointForLDAC || !ldac.canEnable(forAddress: headphones.address) || !ldac.canStartOrInstallDriver))
                .accessibilityValue(ldacStatusText)
                .accessibilityIdentifier("audio.ldac")
                .alert("Turn off multipoint for LDAC?", isPresented: Binding(
                    get: { ldac.multipointConflictAddress == headphones.address },
                    set: { if !$0, ldac.multipointConflictAddress == headphones.address { ldac.resolveMultipointConflict(turnOffMultipoint: false) } }
                )) {
                    Button("Turn Off Multipoint") { ldac.resolveMultipointConflict(turnOffMultipoint: true) }
                        .accessibilityIdentifier("audio.ldacTurnOffMultipoint")
                    Button("Keep Multipoint", role: .cancel) { ldac.resolveMultipointConflict(turnOffMultipoint: false) }
                        .accessibilityIdentifier("audio.ldacKeepMultipoint")
                } message: {
                    Text("These headphones offer LDAC only when multipoint is off. Turning it off restarts them and disconnects any other device.")
                }
            }
            if !ldac.isSessionRunning, ldacState != .waitingForDevice { LDACDriverGuidance() }
            if ldac.targetAddress == headphones.address, ldac.isSuspendedForMicrophone {
                Text("In calling apps, choose Same as System for the microphone and speaker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ldac.targetAddress == headphones.address {
                if !ldac.microphoneActivities.isEmpty {
                    ForEach(Array(ldac.microphoneActivities.enumerated()), id: \.offset) { _, activity in
                        Text("Microphone: \(activity.processName) · \(activity.inputName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ldac.currentConfiguration.microphonePolicy == .manual {
                    Button(ldac.manualCallHandoffRequested ? String(localized: "Resume LDAC") : String(localized: "Pause for headset call")) {
                        ldac.setManualCallHandoff(!ldac.manualCallHandoffRequested)
                    }
                }
                if ldac.isSessionRunning || ldac.transportHealth.lastUpdated != nil { LDACTransportHealthView(compact: true) }
            }
            if ldac.targetAddress == headphones.address, let issue = ldac.microphoneHandoffIssue {
                Text(issue).font(.caption).foregroundStyle(.primary)
            }
            if case .failed(let error) = ldacState {
                if ldac.audioCaptureAccess == .permissionRequired {
                    LDACPermissionGuidance()
                } else {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
        }
    }

    #endif

    private var header: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(headphones.deviceName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, devices.hasOtherSelectableDevices ? 36 : 0)
                    .accessibilityIdentifier("menu.title")
                    .overlay(alignment: .trailing) {
                        if devices.hasOtherSelectableDevices {
                            ConnectedHeadphonePicker(showsIconOnly: true)
                        }
                    }
                if showsHeadphoneControls {
                    HStack(spacing: 6) {
                        if headphones.isApplyingChange || headphones.isEqualizerUpdatePending {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("Applying headphone changes")
                        }
                        Text(headphones.statusText)
                            .multilineTextAlignment(.center)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if headphones.isReady, headphones.isChargingInCase {
                VStack(spacing: 10) {
                    OpenChargingCaseArtwork(model: headphones.deviceModel, suffix: headphones.productArtworkSuffix)
                    HStack(spacing: 22) {
                        battery("Left", value: headphones.batteries.left)
                        battery("Right", value: headphones.batteries.right)
                        battery("Case", value: headphones.batteries.caseBattery)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if headphones.deviceModel.isEarbuds {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 10) {
                        earbudArtwork
                        if headphones.isReady {
                            HStack(spacing: 12) {
                                battery("Left", value: headphones.batteries.left, connected: headphones.audioFeatures.leftConnected)
                                battery("Right", value: headphones.batteries.right, connected: headphones.audioFeatures.rightConnected)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        Group {
                            if headphones.usesProductArtwork {
                                Image(headphones.deviceModel.rawValue + "CaseProduct" + headphones.productArtworkSuffix)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 104, height: 76)
                            } else {
                                Image(nsImage: DeviceIcon.caseImage(model: headphones.deviceModel))
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 88, height: 76)
                            }
                        }
                        .accessibilityLabel("\(headphones.deviceModel.name) charging case")
                        .accessibilityIdentifier("device.artwork.case")
                        if headphones.isReady { battery("Case", value: headphones.batteries.caseBattery) }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                if headphones.usesProductArtwork, let artwork = headphones.deviceModel.artwork {
                    Image(artwork + headphones.productArtworkSuffix)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityLabel("\(headphones.deviceModel.name) headphones")
                        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
                } else {
                    DeviceIcon(model: headphones.deviceModel, leftConnected: nil, rightConnected: nil)
                        .frame(width: 80, height: 80)
                        .accessibilityLabel(headphones.deviceModel.name)
                        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
                }
                if headphones.isReady { battery("Battery", value: headphones.batteries.single) }
            }
        }
    }

    private var earbudArtwork: some View {
        HStack(spacing: 12) {
            EarbudArtwork(model: headphones.deviceModel, side: .left, usesProductArtwork: headphones.usesProductArtwork,
                          artworkSuffix: headphones.productArtworkSuffix)
                .frame(width: 68, height: 76)
                .opacity(headphones.audioFeatures.leftConnected == false ? 0.35 : 1)
            EarbudArtwork(model: headphones.deviceModel, side: .right, usesProductArtwork: headphones.usesProductArtwork,
                          artworkSuffix: headphones.productArtworkSuffix)
                .frame(width: 68, height: 76)
                .opacity(headphones.audioFeatures.rightConnected == false ? 0.35 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("\(headphones.deviceModel.name) earbuds")
        .accessibilityValue(DeviceIcon.connectionValue(left: headphones.audioFeatures.leftConnected, right: headphones.audioFeatures.rightConnected))
        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
    }

    private func battery(_ title: String, value: BatteryReading?, connected: Bool? = nil) -> some View {
        let reading = connected == false ? nil : value
        let color = DeviceIcon.batteryColor(for: reading).map { Color(nsColor: $0) } ?? .green
        let description = reading.map {
            title == "Case" ? String(localized: "\($0.level) percent, \($0.chargingState.title), last reported")
                : String(localized: "\($0.level) percent\($0.isCharging ? String(localized: ", charging") : "")")
        }
        return VStack(spacing: 6) {
            Gauge(value: Double(reading?.level ?? 0), in: 0...100) {}
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(reading == nil ? Color.secondary : color)
                .fixedSize()
                .scaleEffect(28.0 / 58.0)
                .frame(width: 28, height: 28)
                .overlay {
                    if reading?.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(color)
                    }
                }
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if title == "Left" || title == "Right" {
                    Image(systemName: title == "Right" ? "r.circle.fill" : "l.circle.fill")
                        .font(.caption)
                        .foregroundStyle(title == "Right" ? Color.red.opacity(reading == nil ? 0.5 : 1) : (reading == nil ? Color.secondary : Color.primary))
                } else if title == "Case", let symbol = headphones.deviceModel.caseSymbol {
                    Image(symbol)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 13)
                } else if title == "Battery" {
                    Image(systemName: "headphones")
                        .font(.caption)
                }
                Text(reading.map { "\($0.level)%" } ?? "—")
                    .monospacedDigit()
            }
            .foregroundStyle(reading == nil ? Color.secondary : Color.primary)
            if title == "Case", reading != nil {
                Text("Last reported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Case percentage and charging show the last report received from the headphones.")
            }
        }
        .frame(width: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(batteryTitle(title)), \(description ?? (connected == false ? String(localized: "Disconnected") : String(localized: "Not reported")))"))
        .accessibilityIdentifier("battery.\(title.lowercased())")
    }

    private func batteryTitle(_ title: String) -> String {
        switch title {
        case "Left": String(localized: "Left battery")
        case "Right": String(localized: "Right battery")
        case "Case": String(localized: "Case battery")
        default: String(localized: "Battery")
        }
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Equalizer")
                Spacer()
                Picker("Equalizer", selection: Binding(
                    get: { headphones.equalizer.presetID },
                    set: { if let preset = $0 { headphones.setEqualizerPreset(preset) } }
                )) {
                    if let current = headphones.equalizer.presetID, !equalizerPresets.contains(where: { $0.id == current }) {
                        Text(headphones.equalizer.presetTitle ?? String(localized: "Loading…"))
                            .tag(Optional(current)).disabled(true)
                    }
                    unsetSelectionRow(String(localized: "Loading…"), for: headphones.equalizer.presetID)
                    ForEach(equalizerPresets) { preset in
                        Text(preset.title).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .tint(.primary)
                .disabled(!headphones.equalizer.canSelectPreset)
                .accessibilityIdentifier("equalizer.preset")
            }
            if let error = headphones.settingErrors[.equalizer] {
                Text(error).font(.caption).foregroundStyle(.primary)
            }
        }
    }

    private var equalizerPresets: [SonyEqualizerPreset] {
        headphones.equalizer.capabilities?.presets ?? []
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                dismissMenu()
                showSettings()
            } label: {
                Label("More Settings…", systemImage: "gear")
                    .frame(height: 24)
            }
                .keyboardShortcut(",")
                .accessibilityIdentifier("menu.settings")
            Spacer()
            Button {
                if headphones.address.isEmpty { devices.refreshDiscovery() }
                else { headphones.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
                .help("Refresh headphone status")
                .accessibilityLabel("Refresh headphone status")
                .keyboardShortcut("r")
                .disabled(headphones.powerOffState != nil || headphones.isRunningHeadphoneTest || (showsLDACSession && !headphones.isReady))
            Menu {
                Button("Custom Equalizer…", action: showEqualizer)
                if !settings.equalizerProfiles.isEmpty {
                    Menu("Saved Equalizers") {
                        ForEach(settings.equalizerProfiles) { profile in
                            Button(profile.name) {
                                settings.customEqualizerDraft = profile.settings
                                headphones.setCustomEqualizer(profile.settings)
                            }
                            .disabled(headphones.equalizer.settingsPayload(profile.settings) == nil)
                        }
                    }
                    .disabled(headphones.powerOffState != nil || headphones.isRunningHeadphoneTest)
                }
                Divider()
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: headphones.disconnect)
                    .disabled(!headphones.canDisconnect)
                    .help("Disconnect from this Mac and pause automatic reconnect")
                    .accessibilityIdentifier("headphones.disconnect")
                if headphones.supportedFunctions.contains(0x23) {
                    Button("Turn Off Headphones…", systemImage: "power") {
                        if let session = headphones.powerOffSession {
                            powerOffTarget = .init(controller: headphones, session: session, name: headphones.deviceName)
                            showsPowerOffConfirmation = true
                        }
                    }
                    .disabled(!headphones.canPowerOff)
                    .help(headphones.powerOffUnavailableReason ?? String(localized: "Turn off the headphones on all connected devices"))
                    .accessibilityIdentifier("headphones.powerOff")
                    Divider()
                }
                Button("About Acouplet", action: showAbout)
                .accessibilityIdentifier("menu.about")
                Divider()
                Button("Quit Acouplet") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .help("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 360)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(nil)
        .foregroundStyle(.primary)
    }

    private func showAbout() {
        dismissMenu()
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showEqualizer() {
        openWindow(id: "equalizer")
        dismissMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissMenu() {
        if let closeMenu { closeMenu() }
        else { dismiss() }
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
private struct LDACSettingsMenu: View, Equatable {
    let address: String
    let sampleRate: LDACSampleRate
    let quality: LDACQuality
    let unavailableSampleRates: [LDACSampleRate: String]
    let isEnabled: Bool
    let canCheckSupport: Bool
    let setSampleRate: (LDACSampleRate) -> Void
    let setQuality: (LDACQuality) -> Void
    let checkSupport: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.address == rhs.address && lhs.sampleRate == rhs.sampleRate && lhs.quality == rhs.quality
            && lhs.unavailableSampleRates == rhs.unavailableSampleRates
            && lhs.isEnabled == rhs.isEnabled && lhs.canCheckSupport == rhs.canCheckSupport
    }

    var body: some View {
        Menu {
            Button("Check LDAC support again", action: checkSupport)
                .disabled(!canCheckSupport)
                .help("Checks support by starting LDAC playback.")
            Divider()
            Picker("Sample Rate", selection: Binding(get: { sampleRate }, set: setSampleRate)) {
                ForEach(LDACSampleRate.allCases, id: \.self) { rate in
                    Text(rate.displayName).tag(rate)
                        .disabled(unavailableSampleRates[rate] != nil)
                        .help(unavailableSampleRates[rate] ?? "")
                }
            }
            Picker("Playback Quality", selection: Binding(get: { quality }, set: setQuality)) {
                ForEach(LDACQuality.allCases, id: \.self) { quality in
                    let configuration = LDACConfiguration(sampleRate: sampleRate, quality: quality)
                    Text(configuration.qualityDisplayName).tag(quality)
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .tint(nil)
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityLabel("LDAC Settings")
        .help("LDAC Settings")
        .accessibilityIdentifier("audio.ldacSettings")
    }
}

struct LDACDriverGuidance: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch ldac.driverState {
            case .missing, .outdated:
                Text(ldac.driverState == .missing
                     ? String(localized: "LDAC needs an audio driver. Install it, then restart your Mac.")
                     : String(localized: "An LDAC audio driver update is required. Install it, then restart your Mac."))
                Button(ldac.driverState == .missing ? String(localized: "Install Audio Driver…") : String(localized: "Update Audio Driver…")) {
                    ldac.installDriver()
                }
                .disabled(ldac.isOpeningDriverInstaller || ldac.isSessionRunning)
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("audio.installDriver")
            case .restartRequired:
                Text("The LDAC audio driver is installed. Restart your Mac to activate it.")
            case .unavailable(let message):
                Text(message)
            case .current:
                if let reason = ldac.deviceUnavailableReason(forAddress: headphones.address) {
                    Text(reason)
                }
            }
            if let error = ldac.driverInstallationError { Text(error) }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("audio.driverGuidance")
        .onAppear { ldac.refreshDriverStateInBackground() }
    }
}

struct LDACPermissionGuidance: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Acouplet and Acouplet Audio in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then retry LDAC.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Privacy & Security…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
                .accessibilityIdentifier("audio.ldacPrivacySettings")
                Button("Retry LDAC") { ldac.setEnabled(true, forAddress: headphones.address, configuration: settings.ldacConfiguration(forAddress: headphones.address)) }
                    .disabled(!ldac.canEnable(forAddress: headphones.address))
                    .accessibilityIdentifier("audio.ldacRetry")
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .accessibilityIdentifier("audio.ldacPermissionGuidance")
    }
}
#endif

/// Row for the `nil` selection of a Picker with an optional binding.
///
/// It appears only while `current` is nil, so pickers with a value show no extra row. It is tagged with the exact
/// `Optional<Value>.none` and is never disabled: while the state is being reset the selection is briefly nil, and
/// SwiftUI logs `Picker: the selection "nil" is invalid` when no enabled row carries that tag (G6). The binding's
/// `set` must keep ignoring nil so nothing is written to the headphones.
@ViewBuilder
func unsetSelectionRow<Value: Hashable>(_ title: String, for current: Value?) -> some View {
    if current == nil {
        Text(title).tag(Optional<Value>.none)
    }
}

private struct MultipointPopoverContent: View {
    @ObservedObject var headphones: SonyHeadphonesController
    @ObservedObject var settings: SettingsStore
    let maximumHeight: CGFloat
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MultipointSettingControl(compact: true)
                if MultipointControls.isVisible(for: headphones.multipoint) {
                    Divider()
                    MultipointControls(compact: true)
                }
                Divider()
                Button("Bluetooth Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("multipoint.bluetoothSettings")
            }
            .padding(14)
            .font(.body)
            .fontWeight(.regular)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .environmentObject(headphones)
        .controlSize(.regular)
        .foregroundStyle(Color.primary)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .accessibilityIdentifier("multipoint.popover")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
}

private struct MultipointPopover: NSViewRepresentable {
    @Binding var isPresented: Bool
    let headphones: SonyHeadphonesController
    let settings: SettingsStore
    let maximumHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.schedulePresentation() }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.update(self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.stop()
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var owner: MultipointPopover
        private weak var anchor: AnchorView?
        private let popover = NSPopover()
        private var controller: NSHostingController<MultipointPopoverContent>?
        private var measuredContentSize = NSSize.zero

        init(_ owner: MultipointPopover) {
            self.owner = owner
            super.init()
            popover.behavior = .transient
            popover.delegate = self
        }

        func update(_ owner: MultipointPopover, anchor: AnchorView) {
            self.owner = owner
            self.anchor = anchor
            if owner.isPresented {
                let content = MultipointPopoverContent(headphones: owner.headphones, settings: owner.settings, maximumHeight: owner.maximumHeight) { [weak self] size in
                    self?.measuredContentSize = size
                    self?.schedulePresentation()
                }
                if let controller {
                    controller.rootView = content
                } else {
                    let controller = NSHostingController(rootView: content)
                    controller.sizingOptions = []
                    self.controller = controller
                    popover.contentViewController = controller
                    measuredContentSize = controller.sizeThatFits(in: NSSize(width: 320, height: owner.maximumHeight))
                }
            }
            schedulePresentation()
        }

        func schedulePresentation() {
            DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
        }

        private func updatePresentation() {
            guard owner.isPresented else {
                popover.close()
                popover.contentViewController = nil
                controller = nil
                return
            }
            guard let anchor, let window = anchor.window, window.isVisible,
                  measuredContentSize.width > 0, measuredContentSize.height > 0 else { return }
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.appearance = window.effectiveAppearance
            if measuredContentSize != popover.contentSize { popover.contentSize = measuredContentSize }
            if !popover.isShown {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
                popover.contentViewController?.view.window?.makeKey()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            owner.isPresented = false
            popover.contentViewController = nil
            controller = nil
            measuredContentSize = .zero
        }

        func stop() {
            anchor = nil
            popover.delegate = nil
            popover.close()
            popover.contentViewController = nil
            controller = nil
            let binding = owner.$isPresented
            if binding.wrappedValue {
                DispatchQueue.main.async { binding.wrappedValue = false }
            }
        }
    }
}

private struct HeadphoneSelectionButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: selected ? .textBackgroundColor : .labelColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: selected ? .labelColor : .controlBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

extension View {
    func headphoneSelectionButtonStyle(selected: Bool) -> some View {
        buttonStyle(HeadphoneSelectionButtonStyle(selected: selected))
    }

    @ViewBuilder
    func headphoneButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func windowResizeAnchorIfAvailable(_ anchor: UnitPoint) -> some View {
        if #available(macOS 26.0, *) { windowResizeAnchor(anchor) }
        else { self }
    }
}
