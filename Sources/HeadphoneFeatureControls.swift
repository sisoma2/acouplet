import AppKit
import SwiftUI

struct VoiceGuidanceControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.voiceGuidance
        if state.supportsGuidance {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setVoiceGuidance($0) }
                        )) {
                            HStack {
                                Text("Voice guidance")
                                if headphones.pendingChanges[.voiceGuidance] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating voice guidance")
                                }
                            }
                        }
                        .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                                  || headphones.pendingChanges[.voiceGuidance] != nil
                                  || state.setEnabledPayload(!enabled) == nil)
                        .accessibilityIdentifier("guidance.enabled")
                    } else {
                        LabeledContent("Voice guidance") { Text("Unknown").foregroundStyle(.primary) }
                    }
                }
                if let error = headphones.settingErrors[.voiceGuidance] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.supportsVolume {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker(selection: Binding(
                            get: { state.volume },
                            set: { if let volume = $0 { headphones.setVoiceGuidanceVolume(volume) } }
                        )) {
                            unsetSelectionRow(String(localized: "Unknown"), for: state.volume)
                            ForEach(SonyVoiceGuidance.volumeRange, id: \.self) { volume in
                                Text([String(localized: "Very low"), String(localized: "Low"), String(localized: "Medium"), String(localized: "High"), String(localized: "Very high")][volume + 2])
                                    .tag(Optional(volume))
                                    .disabled(state.setVolumePayload(volume) == nil)
                            }
                        } label: {
                            HStack {
                                Text("Guidance volume")
                                if headphones.pendingChanges[.voiceGuidanceVolume] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating guidance volume")
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                                  || headphones.pendingChanges[.voiceGuidanceVolume] != nil
                                  || !SonyVoiceGuidance.volumeRange.contains(where: { state.setVolumePayload($0) != nil }))
                        .accessibilityIdentifier("guidance.volume")
                    }
                    if let error = headphones.settingErrors[.voiceGuidanceVolume] {
                        Text(error).font(.caption).foregroundStyle(.primary)
                    } else if state.volumeAvailable == false {
                        Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct SoundPressureControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Listening level") {
                HStack {
                    Text(reading).monospacedDigit().foregroundStyle(.primary)
                    if headphones.soundPressure.intervalSeconds == nil || headphones.soundPressureReadError != nil
                        || headphones.soundPressureAutomaticRefreshSuspended {
                        Button("Refresh") { headphones.refreshSoundPressure() }
                            .disabled(!headphones.canRefreshSoundPressure)
                            .tint(.primary)
                    }
                }
            }
            .accessibilityIdentifier("audio.listeningLevel")
            .help("Reported by the headphones for the current audio source.")
            if let error = headphones.soundPressureReadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var reading: String {
        if headphones.soundPressure.isStopped { return String(localized: "Measurement is off") }
        if headphones.soundPressure.available == false { return String(localized: "Unavailable") }
        guard headphones.soundPressure.available == true else { return "—" }
        return switch headphones.soundPressure.reading {
        case .decibels(let value): String(localized: "\(value) dB")
        case .notPlaying: String(localized: "Not playing")
        case .inCall: String(localized: "In a call")
        case .notWorn: String(localized: "Not worn")
        case .unknown, nil: "—"
        }
    }
}

struct TouchAssignmentControl: View {
    let key: SonyTouchKeyCapability
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if headphones.deviceModel.isEarbuds, key.key <= 0x01 {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 8) {
                    EarbudArtwork(model: headphones.deviceModel, side: key.key == 0x00 ? .left : .right,
                                  usesProductArtwork: headphones.usesProductArtwork, artworkSuffix: headphones.productArtworkSuffix)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                }
                .frame(maxWidth: .infinity)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(key.title(generation: headphones.touchAssignments.generation)) assignment")
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var gestures: some View {
        if let actions = headphones.touchAssignments.reportedActions(key: key.key) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.action) { action in
                    let title = String(localized: "\(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)): \(action.functionTitle(generation: headphones.touchAssignments.generation))")
                    let isTouch = key.keyType == 0x00 || key.keyType == 0x02
                    let usesMark = isTouch && [0x00, 0x01, 0x02, 0x10, 0x11].contains(action.action)
                    HStack(alignment: .top, spacing: 8) {
                        if isTouch {
                            HStack(spacing: 3) {
                                if usesMark, action.action <= 0x02 {
                                    ForEach(0...Int(action.action), id: \.self) { _ in
                                        Circle().frame(width: 6, height: 6)
                                    }
                                } else if usesMark {
                                    if action.action == 0x11 {
                                        Circle().frame(width: 6, height: 6)
                                    }
                                    Capsule().frame(width: 18, height: 6)
                                }
                            }
                            .frame(width: 28, height: 20)
                            .accessibilityHidden(true)
                        }
                        if headphones.touchAssignments.inquiryType == 0x03,
                           let customizable = headphones.touchAssignments.customizableActions(key: key.key)
                            .first(where: { $0.action == action.action }),
                           customizable.functions.contains(where: { (0x01...0x04).contains($0) }) {
                            gesturePicker(action, capability: customizable)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.functionTitle(generation: headphones.touchAssignments.generation))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(title)
                                    .accessibilityIdentifier("touch.gesture.\(key.key).\(action.action)")
                                if !usesMark {
                                    Text(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .help(title)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
        } else if headphones.touchAssignments.selectedPreset(key: key.key) != nil {
            Text("Gesture details not reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func gesturePicker(_ action: SonyTouchActionSetting, capability: SonyTouchCustomizableAction) -> some View {
        let state = headphones.touchAssignments
        let functions = capability.functions.filter { (0x01...0x04).contains($0) }
        let sharedKeys = state.selectedPreset(key: key.key).map { state.keysUsingPreset($0) } ?? []
        let scope = sharedKeys.count > 1 ? sharedKeys.map(\.title).joined(separator: ", ") : key.title(generation: headphones.touchAssignments.generation)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation), selection: Binding(
                get: { action.function },
                set: { headphones.setTouchAction(key: key.key, action: action.action, function: $0) }
            )) {
                if !functions.contains(action.function) {
                    Text(action.functionTitle(generation: headphones.touchAssignments.generation)).tag(action.function).disabled(true)
                }
                ForEach(functions, id: \.self) { function in
                    Text(SonyTouchActionSetting(action: action.action, function: function).functionTitle)
                        .tag(function)
                        .disabled(state.setActionPayload(key: key.key, action: action.action, function: function) == nil)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("\(scope) \(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)) action")
            .accessibilityIdentifier("touch.action.\(key.key).\(action.action)")
            .disabled(!headphones.canSetTouchAction(key: key.key, action: action.action))
            if sharedKeys.count > 1 {
                Text("Shared: \(scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("touch.shared.\(key.key).\(action.action)")
            }
        }
    }

    private var assignmentPicker: some View {
        let state = headphones.touchAssignments
        let selected = state.selectedPreset(key: key.key)
        return Picker(key.title(generation: headphones.touchAssignments.generation), selection: Binding(
            get: { selected },
            set: { if let preset = $0 { headphones.setTouchAssignment(key: key.key, preset: preset) } }
        )) {
            if let selected, !key.presets.contains(where: { $0.preset == selected }) {
                Text(String(localized: "Unsupported assignment")).tag(Optional(selected)).disabled(true)
            }
            unsetSelectionRow(String(localized: "Not reported"), for: selected)
            ForEach(key.presets, id: \.preset) { preset in
                Text(preset.title(generation: state.generation)).tag(Optional(preset.preset))
                    .disabled(state.setPayload(key: key.key, preset: preset.preset) == nil)
            }
        }
        .disabled(!headphones.canSetTouchAssignment(key: key.key))
    }
}

struct ConnectionModeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var requestedMode: SonyConnectionMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connection preference")
                if headphones.connectionTransition?.isFinished == false && headphones.connectionTransition?.awaitingUser == false
                    && headphones.connectionTransition?.phase != .pairingRequired {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Changing connection preference")
                }
                Spacer()
                Picker("Connection preference", selection: Binding(
                    get: { headphones.connectionMode },
                    set: { mode in
                        guard let mode else { return }
                        if headphones.protocolInformation?.generation == .v1 {
                            requestedMode = mode
                            showsAlert = true
                        } else {
                            headphones.setConnectionMode(mode)
                        }
                    }
                )) {
                    if let current = headphones.connectionMode, current.sonyValue == nil {
                        Text("Unknown").tag(Optional(current))
                    }
                    unsetSelectionRow(String(localized: "Loading…"), for: headphones.connectionMode)
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.title).tag(Optional(mode))
                            .disabled(headphones.connectionModeUnavailableReason(mode) != nil)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!modes.contains { $0 != headphones.connectionMode && headphones.connectionModeUnavailableReason($0) == nil })
                .accessibilityIdentifier("audio.connectionMode")
            }
            if let error = headphones.connectionModeError {
                Text(error).font(.caption).foregroundStyle(.primary)
                if headphones.connectionTransition?.phase == .failed,
                   !headphones.isReady || headphones.connectionTransition?.generation == .v1 {
                    Button(headphones.isReady ? String(localized: "Check Preference") : String(localized: "Retry Connection")) { headphones.connect() }
                        .accessibilityIdentifier("audio.retryConnection")
                }
            } else if let status = transitionStatus {
                Text(status).font(.caption).foregroundStyle(.primary)
            }
            if headphones.connectionTransition?.awaitingUser == true {
                Button("Review Change…") { showsAlert = true }
                    .accessibilityIdentifier("audio.reviewConnectionChange")
            }
            if let transition = headphones.connectionTransition, transition.phase == .pairingRequired {
                Text("Pair the headphones with this Mac in Bluetooth settings, then check the connection.")
                    .font(.caption).foregroundStyle(.primary)
                Text("Last reported preference: \((headphones.connectionMode ?? transition.originalMode).title)")
                    .font(.caption).foregroundStyle(.primary)
                HStack {
                    Button("Bluetooth Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }
                    .foregroundStyle(Color.accentColor)
                    Button("Check Connection") { headphones.connect() }
                        .accessibilityIdentifier("audio.checkPairedConnection")
                }
            }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            presentedAlert = alert
            showsAlert = alert != nil
        }
        .alert(alertTitle, isPresented: $showsAlert) {
            if let mode = requestedMode {
                Button("Cancel", role: .cancel) { requestedMode = nil }
                Button("Change Preference") {
                    requestedMode = nil
                    headphones.setConnectionMode(mode)
                }
            } else if let alert = presentedAlert {
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToConnectionAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") { headphones.respondToConnectionAlert(alert, action: .positive) }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToConnectionAlert(alert, action: nil) }
                }
            }
        } message: {
            if requestedMode != nil {
                Text("The audio connection may briefly disconnect while the headphones apply this preference.")
            } else if let alert = presentedAlert {
                Text(alertMessage(alert))
            }
        }
    }

    private var alertTitle: String {
        if let requestedMode { return String(localized: "Use \(requestedMode.title)?") }
        guard let alert = presentedAlert else { return String(localized: "Connection Change") }
        if alert.isLegacyConnectionChange { return String(localized: "Use Stable Connection?") }
        if alert.actionType == .confirmationOnly { return String(localized: "Connection Change") }
        return String(localized: "Use \((alert.requestedMode ?? headphones.connectionTransition?.targetMode)?.title ?? String(localized: "this connection"))?")
    }

    private var modes: [SonyConnectionMode] {
        var modes = (headphones.supportedConnectionModes ?? []).filter { $0.sonyValue != nil && $0 != .lowLatency }
        if let current = headphones.connectionMode, current.sonyValue != nil, !modes.contains(current) {
            modes.insert(current, at: 0)
        }
        return modes
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        let message = switch (alert.format, alert.messageID) {
        case (.legacyFixed, 0x01):
            String(localized: "The headphones require Stable Connection to change these settings. The audio connection will reconnect and music will stop.")
        case (.flexible, 0x10):
            String(localized: "This change requires LE Audio pairing. Pair the headphones with this Mac before using LE Audio.")
        case (.flexible, 0x11):
            String(localized: "This connection uses LE Audio. This Mac also needs an LE Audio connection for playback.")
        default:
            String(localized: "This connection uses Classic Bluetooth. Reconnect the headphones to this Mac to resume audio.")
        }
        let features = alert.affectedFeatures.map(\.title)
        return features.isEmpty ? message : message + String(localized: "\n\nUnavailable with this connection: ") + features.joined(separator: ", ") + "."
    }

    private var transitionStatus: String? {
        guard let transition = headphones.connectionTransition else { return nil }
        switch transition.phase {
        case .queued: return String(localized: "Waiting to send…")
        case .awaitingResponse: return String(localized: "Changing connection preference…")
        case .awaitingUser: return String(localized: "The headphones need your confirmation.")
        case .replyQueued: return String(localized: "Sending your response…")
        case .pairingRequired: return String(localized: "Pairing required.")
        case .reconnecting, .recovering: return String(localized: "Reconnecting controls…")
        case .verifying: return String(localized: "Checking connection preference…")
        case .cancelled: return String(localized: "Change cancelled.")
        case .confirmed, .failed: return nil
        }
    }
}

struct NoiseAdaptationControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.noiseControlDisplayState, let adaptationEnabled = state.adaptationEnabled,
           let sensitivity = state.sensitivity {
            HStack {
                Toggle(isOn: Binding(
                    get: { headphones.noiseControlDisplayState?.adaptationEnabled ?? adaptationEnabled },
                    set: { headphones.setNoiseAdaptation(enabled: $0) }
                )) {
                    HStack {
                        Text("Noise adaptation")
                        if headphones.pendingChanges[.noiseControl] != nil {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("Updating noise control")
                        }
                    }
                }
                .disabled(!headphones.canChangeNoiseControl || headphones.pendingChanges[.noiseControl] != nil)
                .accessibilityIdentifier("noise.adaptation")
            }
            Picker("Sensitivity", selection: Binding(
                get: { headphones.noiseControlDisplayState?.sensitivity ?? sensitivity },
                set: headphones.setNoiseAdaptationSensitivity
            )) {
                ForEach(SonyNoiseControl.Sensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canChangeNoiseControl || !adaptationEnabled || headphones.pendingChanges[.noiseControl] != nil)
            .accessibilityIdentifier("noise.sensitivity")
            if let error = headphones.settingErrors[.noiseControl] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if headphones.noiseControl?.canSet != true {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Noise adaptation", value: String(localized: "Unavailable"))
        }
    }
}

struct LegacySoundEffectControl: View {
    let kind: SonyLegacySoundEffect.Kind
    @EnvironmentObject private var headphones: SonyHeadphonesController

    private var effect: SonyLegacySoundEffect { headphones.legacySoundEffect(kind) }
    private var setting: SonyHeadphonesController.Setting { .legacySoundEffect(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                if headphones.pendingChanges[setting] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(kind.title)")
                }
                Spacer()
                Picker(kind.title, selection: Binding(
                    get: { effect.presetID },
                    set: { if let preset = $0 { headphones.setLegacySoundEffect(kind, preset: preset) } }
                )) {
                    let unavailableTitle = effect.selectedTitle ?? (headphones.settingErrors[setting] == nil ? String(localized: "Loading…") : String(localized: "Unknown"))
                    if let current = effect.presetID, !effect.selectablePresets.contains(where: { $0.id == current }) {
                        Text(unavailableTitle).tag(Optional(current)).disabled(true)
                    }
                    unsetSelectionRow(unavailableTitle, for: effect.presetID)
                    ForEach(effect.selectablePresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(maxWidth: 180, alignment: .trailing)
                .disabled(!headphones.canSetLegacySoundEffect(kind))
                .accessibilityIdentifier(kind == .surround ? "audio.surround" : "audio.soundPosition")
            }
            if let error = headphones.settingErrors[setting] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if effect.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DSEEControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(headphones.dseeType?.title ?? "DSEE")
                if headphones.pendingChanges[.dsee] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(headphones.dseeType?.title ?? "DSEE")")
                }
                Spacer()
                Picker(headphones.dseeType?.title ?? "DSEE", selection: Binding(
                    get: { headphones.dseeMode },
                    set: { if let mode = $0 { headphones.setDSEE(mode) } }
                )) {
                    if let current = headphones.dseeMode, current.sonyValue == nil {
                        Text("Unknown").tag(Optional(current))
                    }
                    unsetSelectionRow(headphones.settingErrors[.dsee] == nil ? String(localized: "Loading…") : String(localized: "Unknown"), for: headphones.dseeMode)
                    ForEach(SonyDSEEMode.allCases) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!headphones.canSetDSEE)
                .accessibilityIdentifier("audio.dsee")
            }
            if let error = headphones.settingErrors[.dsee] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if headphones.dseeAvailable == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SystemFeatureControl: View {
    let feature: SonySystemFeature
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatureState(feature), state.isVisible != false {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSystemFeature(feature, enabled: $0) }
                        )) {
                            HStack {
                                Text(feature.title)
                                if headphones.pendingChanges[.system(feature)] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating \(feature.title)")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSystemFeature(feature))
                        .accessibilityIdentifier("system.\(feature.rawValue)")
                    } else {
                        LabeledContent(feature.title) {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.system(feature)] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if feature == .speakToChat {
                SpeakToChatOptionsControl()
            }
        }
    }
}

struct SpeakToChatOptionsControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let options = headphones.systemFeatures.speakToChatOptions {
            Group {
                Picker(selection: Binding(
                    get: { options.sensitivity },
                    set: { if let sensitivity = $0, let delay = options.delay {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if let current = options.sensitivity, current.sonyValue == nil {
                        Text("Unknown").tag(Optional(current)).disabled(true)
                    }
                    unsetSelectionRow(String(localized: "Unknown"), for: options.sensitivity)
                    ForEach(SonySpeechSensitivity.options, id: \.self) { sensitivity in
                        Text(sensitivity.title).tag(Optional(sensitivity))
                    }
                } label: {
                    HStack {
                        Text("Voice detection sensitivity")
                        if headphones.pendingChanges[.speakToChatOptions] != nil {
                            ProgressView().controlSize(.mini).accessibilityLabel("Updating Speak-to-Chat")
                        }
                    }
                }
                .help("Choose High if speech is missed, or Low if Speak-to-Chat starts unintentionally.")
                .accessibilityIdentifier("system.speechSensitivity")
                Picker("End Speak-to-Chat", selection: Binding(
                    get: { options.delay },
                    set: { if let delay = $0, let sensitivity = options.sensitivity {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if let current = options.delay, current.sonyValue == nil {
                        Text("Unknown").tag(Optional(current)).disabled(true)
                    }
                    unsetSelectionRow(String(localized: "Unknown"), for: options.delay)
                    ForEach(SonySpeakToChatDelay.options, id: \.self) { delay in
                        Text(delay.title).tag(Optional(delay))
                    }
                }
                .help("The delay begins when you stop speaking.")
                .accessibilityIdentifier("system.speakToChatDelay")
                if let error = headphones.settingErrors[.speakToChatOptions] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetSpeakToChatOptions)
        }
    }
}

struct VoiceAssistantControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.voiceAssistant {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setVoiceAssistant(option) } }
                    )) {
                        if let current = state.knownCurrent, !options.contains(current) {
                            Text(current.title).tag(Optional(current)).disabled(true)
                        }
                        unsetSelectionRow(String(localized: "Unknown"), for: state.knownCurrent)
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Voice assistant")
                            if headphones.pendingChanges[.voiceAssistant] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating voice assistant")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetVoiceAssistant)
                    .help(headphones.audioFeatures.codec == .lc3
                          ? String(localized: "Voice assistant selection is unavailable with LE Audio.")
                          : String(localized: "Assistant setup is managed in Sony Sound Connect on your phone."))
                    .accessibilityIdentifier("system.voiceAssistant")
                }
                if let error = headphones.settingErrors[.voiceAssistant] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AutomaticPowerOffControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.automaticPowerOff {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setAutomaticPowerOff(option) } }
                    )) {
                        if let current = state.knownCurrent, !options.contains(current) {
                            Text(current.title).tag(Optional(current)).disabled(true)
                        }
                        unsetSelectionRow(String(localized: "Unknown"), for: state.knownCurrent)
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Automatic power off")
                            if headphones.pendingChanges[.automaticPowerOff] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating automatic power off")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetAutomaticPowerOff)
                    .accessibilityIdentifier("system.automaticPowerOff")
                }
                if let error = headphones.settingErrors[.automaticPowerOff] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct BatteryCareControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.batteryCare {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setBatteryCare($0) }
                        )) {
                            HStack {
                                Text("Battery Care")
                                if headphones.pendingChanges[.batteryCare] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating Battery Care")
                                }
                            }
                        }
                        .disabled(!headphones.canSetBatteryCare)
                        .accessibilityIdentifier("power.batteryCare")
                    } else {
                        LabeledContent("Battery Care", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    LabeledContent("Charging limit", value: "\(threshold)%").font(.caption)
                }
                if let error = headphones.settingErrors[.batteryCare] {
                    Text(error).font(.caption)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AutoPowerSaveControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.autoPowerSave {
            let pending = headphones.pendingChanges[.autoPowerSave] != nil || headphones.pendingChanges[.powerSaveEffect] != nil
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setAutoPowerSave($0) }
                        )) {
                            HStack {
                                Text("Auto Power Save")
                                if pending {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating power saving")
                                }
                            }
                        }
                        .disabled(!headphones.canSetAutoPowerSave)
                        .accessibilityIdentifier("power.autoPowerSave")
                    } else {
                        LabeledContent("Auto Power Save", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    Text("Activates at \(threshold)% battery.").font(.caption)
                }
                if state.effectActive == true {
                    Text("Power saving is active.").font(.caption)
                    Button("Turn Off Power Saving for Now") { headphones.cancelPowerSaveEffect() }
                        .disabled(!headphones.canCancelPowerSaveEffect)
                        .accessibilityIdentifier("power.cancelEffect")
                        .help("Auto Power Save remains on.")
                }
                if let error = headphones.settingErrors[.autoPowerSave] ?? headphones.settingErrors[.powerSaveEffect] {
                    Text(error).font(.caption)
                }
            }
        }
    }
}

struct SidetoneControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.sidetone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSidetone($0) }
                        )) {
                            HStack {
                                Text("Hear your voice during calls")
                                if headphones.pendingChanges[.sidetone] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating own voice during calls")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSidetone)
                        .accessibilityIdentifier("system.sidetone")
                    } else {
                        LabeledContent("Hear your voice during calls") {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.sidetone] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
