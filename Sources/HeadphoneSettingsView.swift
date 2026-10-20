import AppKit
import SwiftUI

struct HeadphoneSettingsView: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var audioRoute: MacAudioRouteObserver
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    #endif

    var body: some View {
        Form {
            Section("Headphones") {
                if devices.hasOtherSelectableDevices {
                    ConnectedHeadphonePicker()
                } else {
                    LabeledContent("Device") {
                        Text(headphones.deviceName)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("headphones.deviceName")
                    }
                }
                if let color = headphones.deviceInformation.color {
                    LabeledContent("Color") {
                        Text(color.title).foregroundStyle(.primary)
                    }
                }
                if let firmware = headphones.firmwareVersion {
                    #if !ACOUPLET_PUBLIC_APIS_ONLY
                    FirmwareUpdateControl(firmware: firmware)
                    #else
                    LabeledContent("Firmware") {
                        Text(firmware).foregroundStyle(.primary)
                    }
                    #endif
                }
                HeadphoneConnectionView()
            }
            Section("Sound") {
                LabeledContent("Mac audio output", value: audioOutputName)
                    .accessibilityIdentifier("audio.macOutput")
                Link("Sound Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    .foregroundStyle(Color.accentColor)
                if headphones.supportsConnectionMode || headphones.connectionTransition != nil {
                    ConnectionModeControl()
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                }
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                if ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restore the previous Stable Connection preference?")
                            .font(.caption)
                        HStack {
                            Button("Restore Stable Connection") {
                                ldac.restorePendingConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(!ldac.canRestoreConnectionPreference(forAddress: headphones.address))
                            Button("Keep Current Preference") {
                                ldac.keepConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(ldac.needsStopBeforeTermination)
                        }
                    }
                }
                #endif
                if headphones.audioFeatures.supportsCodecStatus {
                    LabeledContent("Headphone codec") {
                        Text(headphones.audioFeatures.codec?.title ?? String(localized: "Unknown")).foregroundStyle(.primary)
                    }
                        .accessibilityIdentifier("audio.codec")
                        .help("Reported by the headphones. With two devices connected, this may describe audio from the other device.")
                }
                if headphones.soundPressure.isSupported { SoundPressureControl() }
                if headphones.legacySurround.isSupported { LegacySoundEffectControl(kind: .surround) }
                if headphones.legacySoundPosition.isSupported { LegacySoundEffectControl(kind: .soundPosition) }
                if headphones.supportsDSEE {
                    DSEEControl().disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
                }
            }
            if headphones.legacyOptimizer.isSupported || headphones.legacyOptimizerTransition != nil {
                Section("Noise Cancelling") { LegacyOptimizerControl() }
            }
            if headphones.noiseControl?.inquiryType == 0x19 {
                Section("Noise Adaptation") {
                    NoiseAdaptationControl()
                }
            }
            if headphones.systemFeatures[.headGestures] != nil || headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                Section("Head Gestures") {
                    SystemFeatureControl(feature: .headGestures)
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                    if headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                        HeadGesturePracticeControl()
                    }
                }
            }
            if headphones.earTipFit.isSupported || headphones.earTipFitTransition != nil {
                Section("Earbud Fit") { EarTipFitControl() }
            }
            FindEarbudsControl()
            if MultipointControls.isVisible(for: headphones.multipoint) || MultipointSettingControl.enabled(for: headphones) != nil {
                Section("Devices") {
                    MultipointSettingControl()
                    if MultipointControls.isVisible(for: headphones.multipoint) {
                        MultipointControls()
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
            }
            if SonySystemFeature.allCases.contains(where: { $0 != .headGestures && headphones.systemFeatureState($0) != nil && headphones.systemFeatureState($0)?.isVisible != false })
                || headphones.automaticPowerOff != nil || headphones.systemFeatures.sidetone != nil
                || headphones.systemFeatures.voiceAssistant != nil
                || headphones.voiceGuidance.supportsGuidance {
                Section("Headphone Controls") {
                    ForEach(SonySystemFeature.allCases.filter { $0 != .headGestures && $0 != .voiceAssistantWakeWord }, id: \.self) { feature in
                        SystemFeatureControl(feature: feature)
                    }
                    VoiceAssistantControl()
                    SystemFeatureControl(feature: .voiceAssistantWakeWord)
                    AutomaticPowerOffControl()
                    SidetoneControl()
                    VoiceGuidanceControls()
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
            if headphones.powerFeatures.batteryCare != nil || headphones.powerFeatures.autoPowerSave != nil {
                Section("Battery") {
                    BatteryCareControl()
                    AutoPowerSaveControl()
                }
                .disabled(!headphones.isReady || headphones.isRunningHeadphoneTest || headphones.powerOffState != nil
                          || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false
                          || headphones.deviceActionTransition?.isFinished == false)
            }
            if headphones.touchAssignments.inquiryType != nil {
                Section(headphones.touchAssignments.keys?.allSatisfy { $0.keyType == 1 } == true ? String(localized: "Button Controls") : String(localized: "Touch Controls")) {
                    if let keys = headphones.touchAssignments.keys {
                        if headphones.deviceModel.isEarbuds, keys.contains(where: { $0.key <= 0x01 }) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(keys.filter { $0.key <= 0x01 }.sorted { $0.key < $1.key }, id: \.key) { key in
                                    TouchAssignmentControl(key: key)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                        }
                        ForEach(keys.filter { !headphones.deviceModel.isEarbuds || $0.key > 0x01 }, id: \.key) { key in
                            TouchAssignmentControl(key: key)
                        }
                    } else if headphones.settingErrors[.touchCustomActions] == nil && headphones.settingErrors[.touchAssignments] == nil {
                        Text("Reading touch controls…").foregroundStyle(.primary)
                    }
                    if headphones.pendingChanges[.touchAssignments] != nil || headphones.pendingChanges[.touchCustomActions] != nil {
                        ProgressView("Updating touch controls…").controlSize(.small)
                    }
                    if let error = headphones.settingErrors[.touchCustomActions] ?? headphones.settingErrors[.touchAssignments] {
                        Text(error).font(.caption).foregroundStyle(.primary)
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
        }
    }

    private var audioOutputName: String {
        audioRoute.route?.name ?? (audioRoute.route != nil || audioRoute.error != nil ? String(localized: "Unavailable") : String(localized: "No output selected"))
    }

}
