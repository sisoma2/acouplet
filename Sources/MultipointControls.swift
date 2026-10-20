import AppKit
import SwiftUI

struct MultipointControls: View {
    var compact = false
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.multipoint
        VStack(alignment: .leading, spacing: 10) {
            if !state.devices.isEmpty {
                deviceGroup("Connected", devices: state.devices.filter(\.isConnected))
                if state.devices.contains(where: \.isConnected), state.devices.contains(where: { !$0.isConnected }) {
                    Divider()
                }
                deviceGroup("Saved", devices: state.devices.filter { !$0.isConnected })
            }
            if state.supportsSourceControl, let keeping = state.keeping {
                if !state.devices.isEmpty { Divider() }
                Toggle(isOn: Binding(get: { keeping }, set: headphones.setSourceKeeping)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep current audio source")
                        Text("Don’t switch when another device starts playing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(headphones.sourceControlUnavailableReason != nil || (!keeping && state.selectedSource == nil))
                .accessibilityIdentifier("multipoint.keeping")
                .help("Prevents automatic switching to another connected device. Choosing another device turns this off.")
            }
            if let message = headphones.sourceTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.error")
            }
            if let message = headphones.deviceActionTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.deviceError")
            }
            if state.inventoryIsStale {
                Label("The device list could not be read. Refresh to try again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if !compact {
                Divider()
                Button("Refresh Devices") { headphones.refreshDevices() }
                    .headphoneButtonStyle()
                    .tint(nil)
                    .controlSize(.small)
                    .disabled(!headphones.canRefreshDevices)
                    .accessibilityIdentifier("multipoint.refresh")
            }
        }
    }

    static func isVisible(for state: SonyMultipoint) -> Bool {
        !state.devices.isEmpty || (state.supportsSourceControl && state.keeping != nil)
    }

    @ViewBuilder
    private func deviceGroup(_ title: LocalizedStringKey, devices: [SonyMultipointDevice]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                ForEach(devices) { device in
                    MultipointDeviceRow(device: device)
                }
            }
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }.count > 1
            ? "\(device.name) · \(device.address)" : device.name
    }
}

private struct MultipointDeviceRow: View {
    let device: SonyMultipointDevice
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var hovered = false
    @FocusState private var sourceFocused: Bool
    @FocusState private var actionFocused: Bool

    private var title: String { MultipointControls.title(for: device, among: headphones.multipoint.devices) }
    private var selected: Bool {
        !headphones.multipoint.inventoryIsStale && headphones.multipoint.selectedSource?.id == device.id
    }
    private var status: String {
        selected ? String(localized: "Selected for audio") : device.isConnected ? String(localized: "Connected") : String(localized: "Saved")
    }
    private var pendingAction: SonyPeripheralAction? {
        guard let transition = headphones.deviceActionTransition, !transition.isFinished,
              transition.targetAddress == device.id else { return nil }
        return transition.action
    }
    private var showsAction: Bool { hovered || sourceFocused || actionFocused || voiceOverEnabled || pendingAction != nil }
    private var progressLabel: String? {
        if let pendingAction {
            return pendingAction == .connect ? String(localized: "Connecting device…") : String(localized: "Disconnecting device…")
        }
        if let transition = headphones.sourceTransition, !transition.isFinished,
           (transition.targetAddress ?? headphones.multipoint.selectedSource?.id) == device.id {
            return String(localized: "Changing audio source…")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if device.isConnected, headphones.multipoint.supportsSourceControl {
                Button { headphones.selectAudioSource(device) } label: { deviceLabel }
                    .buttonStyle(.plain)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .disabled(headphones.sourceControlUnavailableReason != nil)
                    .help(headphones.sourceControlUnavailableReason ?? title)
                    .accessibilityLabel("Use \(title) for Audio")
                    .accessibilityValue(progressLabel ?? status)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("multipoint.select.\(device.id)")
            } else {
                deviceLabel
                    .focusable(headphones.multipoint.supportsInventory)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(progressLabel ?? status)
            }
            if headphones.multipoint.supportsInventory {
                let action: SonyPeripheralAction = pendingAction ?? (device.isConnected ? .disconnect : .connect)
                let reason = headphones.deviceActionUnavailableReason(action, device: device)
                Button {
                    headphones.changeDeviceConnection(action, device: device)
                } label: {
                    Text(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect"))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                .tint(nil)
                .controlSize(.small)
                .focused($actionFocused)
                .disabled(reason != nil)
                .help(reason ?? (device.isConnected ? String(localized: "Disconnect this device from the headphones") : String(localized: "Connect this device to the headphones")))
                .accessibilityLabel("\(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect")) \(title)")
                .accessibilityIdentifier("multipoint.\(action == .disconnect ? "disconnect" : "connect").\(device.id)")
                #if DEBUG
                .accessibilityValue(Text(verbatim: CommandLine.arguments.contains("-ui-testing") && actionFocused ? "Keyboard focused" : ""))
                #endif
                .accessibilityHidden(pendingAction != nil)
                .opacity(showsAction && pendingAction == nil ? 1 : 0)
                .fixedSize()
                .overlay {
                    if let pendingAction {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(pendingAction == .connect ? String(localized: "Connecting device…") : String(localized: "Disconnecting device…"))
                            .accessibilityIdentifier("multipoint.progress.\(device.id)")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(showsAction ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, -8)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multipoint.row.\(device.id)")
    }

    private var deviceLabel: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1))
                if pendingAction == nil, progressLabel != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(device.isConnected ? .primary : .secondary)
            if selected {
                Image(systemName: "checkmark").accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(title)
    }
}

struct MultipointSourcePicker: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.multipoint
        let connected = state.devices.filter(\.isConnected)
        let selectedID = state.inventoryIsStale ? nil : state.selectedSource?.id
        if state.supportsSourceControl, connected.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(connected) { device in
                        let selected = selectedID == device.id
                        Button { headphones.selectAudioSource(device) } label: {
                            Text(Self.title(for: device, among: connected))
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity)
                        }
                        .headphoneSelectionButtonStyle(selected: selected)
                        .help(headphones.sourceControlUnavailableReason ?? MultipointControls.title(for: device, among: state.devices))
                        .accessibilityLabel(MultipointControls.title(for: device, among: state.devices))
                        .accessibilityValue(selected ? String(localized: "Selected for audio") : String(localized: "Not selected"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("multipoint.sourcePicker.\(device.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Multipoint")
                .accessibilityIdentifier("multipoint.sourcePicker")
                if selectedID == nil {
                    Text("Not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
            .tint(nil)
            .disabled(headphones.sourceControlUnavailableReason != nil)
            .help(headphones.sourceControlUnavailableReason ?? String(localized: "Multipoint"))
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        let matching = devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }
        guard matching.count > 1 else { return device.name }
        let suffix = String(device.address.suffix(5))
        let identifier = matching.filter { $0.address.hasSuffix(suffix) }.count > 1 ? device.address : suffix
        return "\(device.name) · \(identifier)"
    }
}

struct MultipointSettingControl: View {
    var compact = false
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var presentedSoundQualityWarning = false

    var body: some View {
        let enabled = Self.enabled(for: headphones)
        if compact || enabled != nil {
            VStack(alignment: .leading, spacing: 6) {
                if compact {
                    HStack(spacing: 12) {
                        Text("Multipoint").font(.headline).fontWeight(.semibold)
                        Spacer()
                        Button { headphones.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .tint(nil)
                            .foregroundStyle(.secondary)
                            .disabled(!headphones.canRefreshDevices)
                            .accessibilityLabel("Refresh Devices")
                            .accessibilityIdentifier("multipoint.refresh")
                            .help("Refresh Devices")
                            .frame(width: 16, height: 16)
                        if let enabled {
                            Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(headphones.multipointUnavailableReason != nil)
                                .help(headphones.multipointUnavailableReason ?? "")
                                .accessibilityIdentifier("multipoint.enabled")
                        }
                    }
                } else if let enabled {
                    Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                        .disabled(headphones.multipointUnavailableReason != nil)
                        .help(headphones.multipointUnavailableReason ?? "")
                        .accessibilityIdentifier("multipoint.enabled")
                }
                if let transition = headphones.multipointTransition {
                    if let failure = transition.failureMessage {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator()
                            Text(failure).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("multipoint.settingError")
                            Spacer(minLength: 0)
                            if transition.canRetryRecovery {
                                Button("Retry") { headphones.checkMultipointChange() }
                                    .controlSize(.small)
                                    .disabled(!headphones.canCheckMultipointChange)
                                    .accessibilityIdentifier("multipoint.checkSetting")
                            }
                        }
                    } else if !transition.isFinished && !transition.awaitingUser {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator(isLoading: true)
                            Text(transition.phase == .recovering ? String(localized: "Reconnecting controls…") : String(localized: "Checking device connections…"))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("multipoint.settingProgress")
                    }
                }
            }
            .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
                guard !compact else { return }
                presentedAlert = alert
                presentedSoundQualityWarning = alert?.format == .fixed && alert?.messageID == 0x07
                    && alert?.actionType == .positiveNegative && headphones.multipointTransition?.targetEnabled == true
                    && headphones.connectionMode == .soundQuality
                showsAlert = alert != nil
            }
            .alert(alertTitle, isPresented: $showsAlert, presenting: presentedAlert) { alert in
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToMultipointAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") {
                        headphones.respondToMultipointAlert(alert, action: .positive, confirmsSoundQualityWarning: presentedSoundQualityWarning)
                    }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToMultipointAlert(alert, action: nil) }
                }
            } message: { alert in
                Text(alertMessage(alert))
            }
        }
    }

    /// Whether the menu shows the multipoint entry. MDR v1 headphones such as the WH-1000XM4 list no
    /// audio sources, so their entry appears whenever the multipoint setting itself is known.
    static func showsMenuEntry(for headphones: SonyHeadphonesController) -> Bool {
        if headphones.multipoint.supportsSourceControl {
            return headphones.multipoint.devices.filter(\.isConnected).count > 1
        }
        return headphones.systemFeatures.generation == .v1 && enabled(for: headphones) != nil
    }

    static func enabled(for headphones: SonyHeadphonesController) -> Bool? {
        headphones.systemFeatures.multipoint?.enabled
            ?? headphones.multipointTransition.flatMap { $0.isFinished ? nil : $0.originalEnabled }
    }

    private var alertTitle: String {
        if presentedAlert?.format == .fixed, presentedAlert?.messageID == 0x70 { return String(localized: "Audio may cut out") }
        guard presentedAlert?.actionType == .positiveNegative else { return String(localized: "Device Connection Change") }
        return headphones.multipointTransition?.targetEnabled == true ? String(localized: "Enable multipoint?") : String(localized: "Use one device at a time?")
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        if alert.format == .fixed, alert.messageID == 0x70 {
            return String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        var message = String(localized: "Changing this setting may briefly disconnect the headphones. Reconnect them if needed.")
        if presentedSoundQualityWarning {
            message += "\n\n" + String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        if alert.format == .fixed || alert.format == .legacyFixed, alert.messageID == 0x06 {
            message += String(localized: "\n\nThe headphones report that LDAC will be unavailable with this change.")
        }
        if alert.format == .flexible {
            let known = alert.affectedFeatures.filter { $0.title != String(localized: "Unknown feature") }.map(\.title)
            if !known.isEmpty { message += String(localized: "\n\nUnavailable with this change: ") + known.joined(separator: ", ") + "." }
            if known.count != alert.affectedFeatures.count {
                message += String(localized: "\n\nThe headphones also report an affected feature this app cannot identify.")
            }
        }
        return message
    }
}
