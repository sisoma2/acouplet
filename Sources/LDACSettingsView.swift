import AppKit
import CoreAudio
import SwiftUI

#if !ACOUPLET_PUBLIC_APIS_ONLY
struct LDACAdvancedSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController
    @State private var inputs: [LDACAudioDevice] = []
    @State private var outputs: [LDACAudioDevice] = []
    @State private var applications: [String: String] = [:]
    @State private var inventoryError: String?

    private var isBusy: Bool { ldac.needsStopBeforeTermination || ldac.state == .waitingForDevice }
    private var profile: LDACDeviceProfile { settings.ldacProfile(forAddress: headphones.address) }

    var body: some View {
        DisclosureGroup("LDAC device profile") {
            Group {
                Toggle("Automatically enable LDAC for these headphones", isOn: Binding(
                    get: { profile.automaticallyEnable },
                    set: { enabled in settings.updateLDACProfile(forAddress: headphones.address) { $0.automaticallyEnable = enabled } }
                ))
                Text("Automatic activation follows the selected Mac output. Turning LDAC off or another source taking over suppresses it.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Playback preset", selection: Binding(
                    get: { settings.ldacConfiguration.quality == .adaptive && settings.ldacConfiguration.sampleRate == .hz48000
                        ? settings.ldacConfiguration.bufferProfile : .custom },
                    set: { settings.applyLDACPreset($0, forAddress: headphones.address) }
                )) {
                    ForEach(LDACBufferProfile.allCases, id: \.self) { preset in Text(preset.displayName).tag(preset) }
                }
                Picker("Buffer profile", selection: $settings.ldacConfiguration.bufferProfile) {
                    ForEach(LDACBufferProfile.allCases, id: \.self) { profile in Text(profile.displayName).tag(profile) }
                }
                if settings.ldacConfiguration.bufferProfile == .custom {
                    Stepper(value: $settings.ldacConfiguration.customReserveMilliseconds, in: 50...500, step: 10) {
                        Text("PCM reserve: \(settings.ldacConfiguration.pcmReserveMilliseconds) ms")
                    }
                }
                Text("Music keeps the established reserve. Video and custom reserves need hardware qualification; smaller buffers may underrun.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Microphone policy", selection: $settings.ldacConfiguration.microphonePolicy) {
                    ForEach(LDACMicrophonePolicy.allCases, id: \.self) { policy in Text(policy.displayName).tag(policy) }
                }
                if settings.ldacConfiguration.microphonePolicy == .external {
                    Picker("Separate microphone", selection: Binding(
                        get: { settings.ldacConfiguration.externalMicrophoneUID ?? "" },
                        set: { settings.ldacConfiguration.externalMicrophoneUID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Choose a microphone").tag("")
                        ForEach(inputs.filter { !$0.isBluetooth }) { input in Text(verbatim: input.name).tag(input.id) }
                    }
                    Text("LDAC continues only while the selected separate microphone is used. Headset microphone use still requires call audio. Check echo behavior in your calling app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Route selected applications through LDAC", isOn: $settings.ldacConfiguration.routing.enabled)
                if settings.ldacConfiguration.routing.enabled {
                    Picker("Output for other applications", selection: Binding(
                        get: { settings.ldacConfiguration.routing.outputDeviceUID ?? "" },
                        set: { settings.ldacConfiguration.routing.outputDeviceUID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Choose a separate output").tag("")
                        ForEach(outputs.filter { !$0.isBluetooth }) { output in Text(verbatim: output.name).tag(output.id) }
                    }
                    Text("Selected apps play through LDAC. Other apps stay audible on this output. Selected apps must use System Default output.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(applications.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }), id: \.key) { application in
                        Toggle(isOn: Binding(
                            get: { settings.ldacConfiguration.routing.bundleIDs.contains(application.key) },
                            set: { enabled in
                                var selected = settings.ldacConfiguration.routing.bundleIDs
                                if enabled && !selected.contains(application.key) && selected.count < 32 { selected.append(application.key) }
                                if !enabled { selected.removeAll { $0 == application.key } }
                                settings.ldacConfiguration.routing.bundleIDs = selected.sorted()
                            }
                        )) { Text(verbatim: application.value) }
                        .disabled(!settings.ldacConfiguration.routing.bundleIDs.contains(application.key) && settings.ldacConfiguration.routing.bundleIDs.count >= 32)
                    }
                    if settings.ldacConfiguration.routing.bundleIDs.isEmpty {
                        Text("Choose at least one application before starting LDAC.").foregroundStyle(.secondary)
                    }
                }
                Button("Refresh audio devices and applications") { refreshInventory() }
                if let inventoryError { Text(inventoryError).font(.caption) }
                if profile.consecutiveFailures >= 2, profile.lastSuccessfulConfiguration != nil {
                    Button("Use last successful LDAC settings") {
                        settings.useLastSuccessfulLDACConfiguration(forAddress: headphones.address)
                    }
                    Text("Your fixed quality choice is kept until you choose to restore these settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(isBusy || headphones.address.isEmpty)
        }
        DisclosureGroup("LDAC setup and compatibility") { LDACSetupStatusView() }
        DisclosureGroup("LDAC transport health") { LDACTransportHealthView() }
            .onAppear { refreshInventory() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshApplications() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshApplications() }
    }

    private func refreshInventory() {
        do {
            inputs = try LDACCallHardware.audioDevices(scope: kAudioObjectPropertyScopeInput)
            outputs = try LDACCallHardware.audioDevices(scope: kAudioObjectPropertyScopeOutput)
            inventoryError = nil
        } catch { inventoryError = String(localized: "Audio devices could not be listed. Refresh to try again.") }
        refreshApplications()
    }

    private func refreshApplications() {
        var choices: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            guard let identifier = application.bundleIdentifier, !identifier.hasPrefix("dev.baglayan.Acouplet") else { continue }
            choices[identifier] = application.localizedName ?? identifier
        }
        for identifier in settings.ldacConfiguration.routing.bundleIDs where choices[identifier] == nil {
            choices[identifier] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension().lastPathComponent ?? identifier
        }
        applications = choices
    }
}

struct LDACSetupStatusView: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController
    @State private var driver: LDACDriverInstaller.Snapshot?

    var body: some View {
        LabeledContent("Bundled driver", value: driver?.bundled.map(String.init) ?? String(localized: "Unknown"))
        LabeledContent("Installed driver", value: driver?.installed.map(String.init) ?? String(localized: "Not installed"))
        LabeledContent("Loaded driver", value: driver?.loaded.map(String.init) ?? String(localized: "Not loaded"))
        LDACDriverGuidance()
        LabeledContent("Headphone controls", value: headphones.isReady ? String(localized: "Ready") : String(localized: "Not ready"))
        LabeledContent("Sound Quality mode", value: headphones.connectionMode == .soundQuality ? String(localized: "Enabled") : String(localized: "Checked during startup"))
        LabeledContent("System audio access", value: ldac.audioCaptureAccess.displayName)
        LabeledContent("Bluetooth ownership observations", value: ldac.runtimeStatus.ownershipObservationsVerified ? String(localized: "Verified") : String(localized: "Checked during connection"))
        if let message = ldac.runtimeStatus.message { Text(message).font(.caption) }
        ForEach(LDACSampleRate.allCases, id: \.self) { rate in
            LabeledContent(rate.displayName, value: ldac.sampleRateUnavailableReason(rate, forAddress: headphones.address)
                ?? (ldac.advertisedSampleRates(forAddress: headphones.address).contains(rate.rawValue)
                    ? String(localized: "Advertised") : String(localized: "Not checked")))
        }
        if headphones.deviceModel.offersLDACOnlyWithoutMultipoint {
            Text("This model requires multipoint off for LDAC. Other models are checked independently.").font(.caption)
        }
        Text("Passive checks do not interrupt playback. Checking LDAC support starts playback and can disconnect ordinary audio.")
            .font(.caption).foregroundStyle(.secondary)
            .task { driver = LDACDriverInstaller.snapshot() }
            .onReceive(ldac.$driverState) { _ in driver = LDACDriverInstaller.snapshot() }
    }
}

struct LDACTransportHealthView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ldac: LDACController
    @EnvironmentObject private var headphones: SonyHeadphonesController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Underruns: \(ldac.transportHealth.underruns) · stalls: \(ldac.transportHealth.stalls)")
            Text("Skipped frames: \(ldac.transportHealth.skippedFrames)")
            if !compact {
                Text("Queued audio: \(ldac.transportHealth.queuedMilliseconds.formatted()) ms · peak: \(ldac.transportHealth.peakQueuedMilliseconds.formatted()) ms")
                Text("Bitrate changes: \(ldac.transportHealth.bitrateTransitions) · encoder resets: \(ldac.transportHealth.encoderResets)")
                Text("Local transport observations; receiver delivery and radio packet loss are not measured.")
                    .foregroundStyle(.secondary)
                if let reason = ldac.transportHealth.lastReason { Text(reason) }
            }
            Button("Export LDAC report…") { ldac.exportDiagnostics(forAddress: headphones.address, configuration: settings.ldacConfiguration(forAddress: headphones.address)) }
            if let error = ldac.diagnosticExportError { Text(error) }
        }
        .font(.caption)
    }
}
#endif
