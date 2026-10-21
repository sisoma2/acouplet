import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var headphones: SonyHeadphonesController
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    @State private var showsDriverRemovalConfirmation = false
    @State private var isOpeningDriverRemoval = false
    @State private var driverRemovalError: String?
    #endif
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif

    var body: some View {
        Form {
            Section {
                Picker("App language", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.setAppLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.appLanguage")
                if settings.appLanguageNeedsRestart {
                    Text("Restart Acouplet to apply the language change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.appLanguageRestart")
                    Button("Restart Acouplet") { settings.restartApp?() }
                        .disabled(settings.restartApp == nil)
                        .accessibilityIdentifier("settings.appLanguageRestartButton")
                }
                Toggle("Use system accent color", isOn: $settings.useSystemAccentColor)
                    .accessibilityIdentifier("settings.systemAccent")
            }
            Section("Menu Bar") {
                Toggle("Keep icon visible when disconnected", isOn: $settings.keepMenuBarIconWhenDisconnected)
                    .accessibilityIdentifier("menuBar.keepIcon")
                Toggle("Show battery percentage", isOn: $settings.showBatteryInMenuBar)
            }
            Section("Connection") {
                Toggle("Reconnect automatically", isOn: $settings.reconnectAutomatically)
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
                if let error = settings.backgroundServiceMigrationError ?? settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if settings.backgroundServiceMigrationError != nil {
                        Button("Retry") { settings.retryBackgroundServiceMigration?() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Keyboard") {
                Toggle("Global ANC / Ambient shortcut", isOn: $settings.globalShortcutEnabled)
                    .help("Available while Acouplet is running.")
                LabeledContent("Shortcut") {
                    Text("⌥⌘A").foregroundStyle(.primary)
                }
                if let error = settings.globalShortcutError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            Section("Alerts") {
                Toggle("Low battery", isOn: $settings.lowBatteryNotificationsEnabled)
                .accessibilityIdentifier("notifications.lowBattery")
                Toggle("Firmware updates", isOn: $settings.firmwareNotificationsEnabled)
                .accessibilityIdentifier("notifications.firmware")
            }
            Section("Experimental Features") {
                Toggle("Show LDAC controls", isOn: $settings.experimentalLDACEnabled)
                    .accessibilityIdentifier("experimental.ldac")
                if settings.experimentalLDACEnabled {
                    Picker("Sample Rate", selection: $settings.ldacConfiguration.sampleRate) {
                        ForEach(LDACSampleRate.allCases, id: \.self) { rate in
                            Text(rate.displayName).tag(rate)
                                .disabled(ldac.sampleRateUnavailableReason(rate, forAddress: headphones.address) != nil)
                                .help(ldac.sampleRateUnavailableReason(rate, forAddress: headphones.address) ?? "")
                        }
                    }
                    .disabled(!ldac.canChangePlaybackSettings(forAddress: headphones.address))
                    .accessibilityIdentifier("ldac.sampleRate")
                    Picker("Playback Quality", selection: $settings.ldacConfiguration.quality) {
                        ForEach(LDACQuality.allCases, id: \.self) { quality in
                            let configuration = LDACConfiguration(sampleRate: settings.ldacConfiguration.sampleRate, quality: quality)
                            Text(configuration.qualityDisplayName).tag(quality)
                        }
                    }
                    .disabled(!ldac.canChangePlaybackSettings(forAddress: headphones.address))
                    .accessibilityIdentifier("ldac.quality")
                    Stepper(value: Binding(
                        get: { settings.ldacConfiguration(forAddress: headphones.address).latencyOffsetMilliseconds },
                        set: { settings.setLDACLatencyOffset($0, forAddress: headphones.address) }
                    ), in: -500...500, step: 10) {
                        Text("Latency offset: \(settings.ldacConfiguration(forAddress: headphones.address).latencyOffsetMilliseconds) ms")
                    }
                    .disabled(ldac.needsStopBeforeTermination || ldac.state == .waitingForDevice || headphones.address.isEmpty)
                    .help("Applied to this device on the next LDAC start.")
                    .accessibilityIdentifier("ldac.latencyOffset")
                    Button("Check LDAC support again") {
                        ldac.checkSupportAgain(forAddress: headphones.address, configuration: settings.ldacConfiguration(forAddress: headphones.address))
                    }
                    .disabled(ldac.needsStopBeforeTermination || ldac.state == .waitingForDevice || !ldac.canStartOrInstallDriver
                              || ldac.deviceUnavailableReason(forAddress: headphones.address) != nil)
                    .help("Checks support by starting LDAC playback.")
                    .accessibilityIdentifier("ldac.checkSupport")
                    if !ldac.isSessionRunning { LDACDriverGuidance() }
                    LDACAdvancedSettingsView()
                }
                if settings.experimentalLDACEnabled, ldac.support(forAddress: headphones.address) != .unsupported,
                   ldac.targetAddress == headphones.address, ldac.audioCaptureAccess == .permissionRequired {
                    LDACPermissionGuidance()
                }
                if hasInstalledLDACDriver {
                    Button("Remove LDAC Audio Driver…") { showsDriverRemovalConfirmation = true }
                        .disabled(ldac.needsStopBeforeTermination || ldac.isOpeningDriverInstaller || isOpeningDriverRemoval
                                  || settings.backgroundServiceMigrationError != nil)
                        .alert("Remove LDAC Audio Driver?", isPresented: $showsDriverRemovalConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Continue") {
                                isOpeningDriverRemoval = true
                                driverRemovalError = nil
                                Task {
                                    do {
                                        try await LDACDriverInstaller.openUninstaller()
                                        NSApp.terminate(nil)
                                    } catch {
                                        driverRemovalError = error.localizedDescription
                                    }
                                    isOpeningDriverRemoval = false
                                }
                            }
                        } message: {
                            Text("Acouplet will quit and open the removal installer. Restart your Mac after removing the driver.")
                        }
                    if let driverRemovalError {
                        Text(driverRemovalError).font(.caption).foregroundStyle(.primary)
                    }
                }
            }
            #endif
            #if ACOUPLET_SPARKLE
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(!updater.isEnabled)
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.isEnabled || !updater.allowsAutomaticUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if !updater.isEnabled {
                    Text("Updates are off in development builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.updatesOff")
                }
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Version \(version)")
                        .accessibilityIdentifier("settings.version")
                }
                if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    Text("Build \(build)")
                        .accessibilityIdentifier("settings.build")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var hasInstalledLDACDriver: Bool {
        switch ldac.driverState {
        case .current, .outdated, .restartRequired: true
        case .missing, .unavailable: false
        }
    }
    #endif

}
