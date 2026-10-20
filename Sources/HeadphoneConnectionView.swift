import AppKit
import SwiftUI

struct ConnectedHeadphonePicker: View {
    var showsIconOnly = false
    @EnvironmentObject private var devices: SonyDeviceCoordinator

    var body: some View {
        if showsIconOnly {
            Menu {
                selectionPicker.pickerStyle(.inline)
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuIndicator(.hidden)
            .headphoneButtonStyle()
            .buttonBorderShape(.circle)
            .fixedSize()
            .tint(.primary)
            .accessibilityLabel("Choose Headphones")
            .accessibilityValue(devices.selectedController.deviceName)
            .accessibilityIdentifier("headphones.devicePicker")
            .help("Choose headphones")
        } else {
            selectionPicker
                .pickerStyle(.menu)
                .menuIndicator(.visible)
                .tint(.primary)
                .accessibilityIdentifier("headphones.devicePicker")
        }
    }

    private var selectionPicker: some View {
        Picker("Device", selection: Binding(
            get: { devices.selectedAddress },
            set: { if let address = $0 { devices.select(address: address) } }
        )) {
            if let address = devices.selectedAddress, !devices.selectableDevices.contains(where: { $0.address == address }) {
                Text(devices.selectedController.deviceName).tag(Optional(address)).disabled(true)
            }
            unsetSelectionRow(devices.selectedController.deviceName, for: devices.selectedAddress)
            ForEach(devices.connectedDevices) { device in
                Text(Self.title(for: device, among: devices.selectableDevices))
                    .tag(Optional(device.address))
            }
            let disconnected = devices.selectableDevices.filter { device in
                !devices.connectedDevices.contains(where: { $0.address == device.address })
            }
            let possiblyPlaying = disconnected.filter { device in
                let finder = devices.controller(for: device.address)?.earbudFinder
                return finder?.isBusy == true || finder?.mayBeRinging == true
            }
            if !possiblyPlaying.isEmpty {
                Section("Sound may still be playing") {
                    ForEach(possiblyPlaying) { device in
                        Text(Self.title(for: device, among: devices.selectableDevices))
                            .tag(Optional(device.address))
                    }
                }
            }
            let availableForConnection = disconnected.filter { device in
                !possiblyPlaying.contains(where: { $0.address == device.address })
            }
            if !availableForConnection.isEmpty {
                Section("Disconnected") {
                    ForEach(availableForConnection) { device in
                        Text(Self.title(for: device, among: devices.selectableDevices))
                            .tag(Optional(device.address))
                    }
                }
            }
        }
    }

    static func title(for device: SonyConnectedDevice, among devices: [SonyConnectedDevice]) -> String {
        guard devices.contains(where: { $0.address != device.address && ($0.model == device.model || $0.name == device.name) }) else {
            return device.name
        }
        let address = devices.contains { $0.address != device.address && $0.name == device.name && $0.address.suffix(5) == device.address.suffix(5) }
            ? device.address : String(device.address.suffix(5))
        return "\(device.name) · \(address)"
    }
}

struct ConnectionStatusIndicator: View {
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.orange)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffectsRemoved(reduceMotion)
                    .transition(.symbolEffect(.appear))
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct HeadphoneConnectionView: View {
    var connectOnly = false
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator

    var body: some View {
        Group {
            if !headphones.isReady || headphones.powerOffState != nil || headphones.headphoneTestNeedsRecovery {
                if connectOnly {
                    Button("Connect", action: connect)
                        .headphoneButtonStyle(prominent: true)
                        .disabled(headphones.multipointTransition?.isFinished == false)
                        .accessibilityIdentifier("headphones.connect")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            HStack(spacing: 10) {
                                ConnectionStatusIndicator(isLoading: isLoading)
                                Text(connectionTitle).font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("headphones.connectionStatus")
                            Spacer(minLength: 0)
                            if !isLoading && !headphones.isBluetoothAccessDenied {
                                Button(hasConnectionFailure ? String(localized: "Retry") : String(localized: "Connect"), action: connect)
                                    .headphoneButtonStyle()
                                    .accessibilityIdentifier("headphones.connect")
                            }
                        }
                        if isSearching || headphones.powerOffState != nil || headphones.headphoneTestNeedsRecovery {
                            Text(connectionDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 26)
                        } else if headphones.isBluetoothAccessDenied {
                            Text("Allow Acouplet to use Bluetooth in [System Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth).")
                                .foregroundStyle(.secondary)
                                .tint(.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 26)
                        } else if !isLoading {
                            if let message = connectionFailureMessage {
                                Text(message)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.connectionFailure")
                                Link("Bluetooth Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.bluetoothSettings")
                            } else {
                                Text("If this continues, disconnect and reconnect the headphones in [Bluetooth Settings](x-apple.systempreferences:com.apple.BluetoothSettings).")
                                    .foregroundStyle(.secondary)
                                    .tint(.accentColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.bluetoothSettings")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func connect() {
        if headphones.address.isEmpty { devices.refreshDiscovery() }
        else { headphones.connect() }
    }

    private var isLoading: Bool {
        isSearching || isConnecting || isRecoveringMultipoint || headphones.isPoweringOff
    }

    private var isSearching: Bool { headphones.linkState == .searching }

    private var isRecoveringMultipoint: Bool { headphones.multipointTransition?.phase == .recovering }

    private var isConnecting: Bool {
        headphones.linkState == .opening || headphones.linkState == .handshaking
    }

    private var hasConnectionFailure: Bool {
        if case .failed = headphones.linkState { return true }
        return headphones.linkState == .controlBusy || connectionFailureMessage != nil
    }

    private var connectionFailureMessage: String? {
        if let message = headphones.lastErrorMessage { return message }
        if case .failed(let message) = headphones.linkState { return message }
        return nil
    }

    private var connectionTitle: String {
        if headphones.isBluetoothAccessDenied { return String(localized: "Bluetooth access is not allowed.") }
        if headphones.headGesturePracticeTransition?.phase == .interrupted { return String(localized: "Head Gesture Practice Needs Attention") }
        if headphones.earTipFitTransition?.phase == .interrupted { return String(localized: "Fit Test Needs Attention") }
        if headphones.legacyOptimizerTransition?.phase == .interrupted { return String(localized: "Noise Cancelling Optimizer") }
        if isRecoveringMultipoint { return String(localized: "Reconnecting Controls…") }
        return switch headphones.powerOffState {
        case .sending: String(localized: "Sending Power Off…")
        case .acknowledged: String(localized: "Power Off Requested")
        case .disconnected: String(localized: "Headphones Disconnected")
        case .unconfirmed: String(localized: "Power Off Not Confirmed")
        case nil: isSearching ? String(localized: "Checking Bluetooth…") : isConnecting ? String(localized: "Connecting…") : hasConnectionFailure ? String(localized: "Couldn’t connect to controls") : String(localized: "Not Connected")
        }
    }

    private var connectionDescription: String {
        if headphones.headGesturePracticeTransition?.phase == .interrupted, let message = headphones.headGesturePracticeTransition?.message { return message }
        if headphones.earTipFitTransition?.phase == .interrupted, let message = headphones.earTipFitTransition?.message { return message }
        if headphones.legacyOptimizerTransition?.phase == .interrupted, let message = headphones.legacyOptimizerTransition?.message { return message }
        if let state = headphones.powerOffState {
            let outcome: String
            switch state {
            case .sending: return String(localized: "Waiting for the headphones to acknowledge the command…")
            case .acknowledged: outcome = String(localized: "The headphones received the command. Their power state cannot be checked.")
            case .disconnected: outcome = String(localized: "The control connection closed after the power-off request. Their power state cannot be checked.")
            case .unconfirmed: outcome = String(localized: "The headphones did not acknowledge the command. They may already be off.")
            }
            let turnOn = headphones.deviceModel.isEarbuds
                ? String(localized: "To turn them on again, put both earbuds in the case, then take them out.")
                : String(localized: "Turn the headphones on with their power button before reconnecting.")
            return String(localized: "\(outcome) Automatic reconnect is paused. \(turnOn)")
        }
        return headphones.statusText
    }
}
