import AppKit
import CoreAudio
import SwiftUI

struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var audioRoute: MacAudioRouteObserver

    var body: some View {
        Form {
            Section("Mac Audio Output") {
                LabeledContent("Device", value: audioOutputName)
                if let route = audioRoute.route {
                    LabeledContent("Transport", value: route.transport?.title ?? String(localized: "Unknown"))
                    LabeledContent("Audio format", value: route.pcmFormatDescription)
                        .help(route.transport?.rawValue == kAudioDeviceTransportTypeUSB
                              ? String(localized: "A USB Bluetooth transmitter controls its wireless connection and codec.")
                              : String(localized: "The Mac’s output format does not identify the Bluetooth wireless codec."))
                }
                if audioRoute.error != nil {
                    Text("Some audio output details are unavailable. Copy diagnostics for details.")
                        .font(.caption)
                }
            }
            Section("Connection") {
                if !headphones.usesBluetoothLE {
                    LabeledContent("Bluetooth address") {
                        Text(headphones.address.isEmpty ? String(localized: "Not found") : headphones.address).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Headphone controls") {
                    Text(headphones.isReady && headphones.powerOffState == nil ? String(localized: "Ready") : headphones.statusText).foregroundStyle(.primary)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Bluetooth device") {
                    Text(headphones.isDeviceConnected ? String(localized: "Connected") : String(localized: "Disconnected")).foregroundStyle(.primary)
                }
                LabeledContent("Protocol") {
                    Text(headphones.controlProtocol).foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if let identifier = headphones.controlPeripheralID {
                    LabeledContent("LE peripheral") {
                        Text(identifier.uuidString).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Last sync") {
                    Text(lastSyncText).foregroundStyle(.primary)
                }
                if let error = headphones.lastErrorMessage {
                    LabeledContent("Last issue") {
                        Text(error)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Sync Now") {
                        if headphones.address.isEmpty { devices.refreshDiscovery() }
                        else { headphones.refresh() }
                    }
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                    Spacer()
                    Button("Copy Diagnostics") { copyDiagnostics() }
                }
                if headphones.protocolInformation?.generation != .v1 {
                    HStack {
                        Button("Connect Controls with Bluetooth LE") { headphones.connectBluetoothLE() }
                            .disabled(headphones.usesBluetoothLE || headphones.linkState == .opening || headphones.linkState == .handshaking
                                      || headphones.isPoweringOff
                                      || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        if headphones.usesBluetoothLE {
                            Button("Reconnect Controls") { headphones.connect() }
                                .disabled(headphones.isPoweringOff || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        }
                    }
                }
                if let error = headphones.bluetoothLEError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .tint(.primary)
    }

    private var audioOutputName: String {
        audioRoute.route?.name ?? (audioRoute.route != nil || audioRoute.error != nil ? String(localized: "Unavailable") : String(localized: "No output selected"))
    }

    private var lastSyncText: String {
        headphones.lastSyncDate?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Never")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(headphones.diagnosticReport + "\n" + audioRoute.diagnosticReport, forType: .string)
    }
}
