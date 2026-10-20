import AppKit
import SwiftUI

private enum ListeningPreset: String, CaseIterable, Identifiable {
    case focus, office, aware

    var id: Self { self }
    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .office: String(localized: "Office")
        case .aware: String(localized: "Aware")
        }
    }
    var symbol: String {
        switch self {
        case .focus: "moon"
        case .office: "person.2"
        case .aware: "figure.walk"
        }
    }
    var mode: NoiseControlMode { self == .focus ? .anc : .ambient }
    var level: Int {
        switch self {
        case .focus: 10
        case .office: 8
        case .aware: 20
        }
    }
    var focusOnVoice: Bool { self == .office }
}

struct NoiseControlView: View {
    @ObservedObject var headphones: SonyHeadphonesController
    let tint: Color

    private var noiseControlMode: NoiseControlMode? { headphones.noiseControlMode }

    var body: some View {
        listeningModes
        presets
        modeDetails
    }

    private var listeningModes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise Control")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) { listeningModeButtons }
            } else {
                listeningModeButtons
            }
        }
    }

    private var listeningModeButtons: some View {
        HStack(spacing: 8) {
            ForEach(headphones.availableNoiseModes) { mode in
                modeButton(mode)
                    .headphoneSelectionButtonStyle(selected: noiseControlMode == mode)
            }
        }
    }

    private func modeButton(_ mode: NoiseControlMode) -> some View {
        Button { headphones.setNoiseControl(mode) } label: {
            VStack(spacing: 7) {
                Image(systemName: mode.symbol).font(.title3)
                Text(mode.compactTitle)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!headphones.canChangeNoiseControl)
        .help(headphones.noiseControlUnavailableReason ?? mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityInputLabels([mode.compactTitle, mode.title])
        .accessibilityIdentifier("noiseControl.\(mode.rawValue)")
        .accessibilityAddTraits(noiseControlMode == mode ? .isSelected : [])
    }

    @ViewBuilder
    private var modeDetails: some View {
        if noiseControlMode == .ambient {
            VStack(alignment: .leading, spacing: 10) {
                if let range = headphones.ambientLevelRange, range.lowerBound < range.upperBound {
                    HStack {
                        Text("Ambient Sound")
                        Spacer()
                        Text("\(headphones.ambientLevel)").monospacedDigit().foregroundStyle(Color.primary)
                    }
                    Slider(value: Binding(get: { Double(headphones.ambientLevel) }, set: { headphones.setAmbientLevel(Int($0)) }),
                           in: Double(range.lowerBound)...Double(range.upperBound), step: Double(headphones.ambientLevelStep))
                        .accessibilityLabel("Ambient sound level")
                }
                if headphones.supportsVoiceFocus {
                    HStack {
                        Text("Focus on Voice")
                        Spacer()
                        Toggle("Focus on Voice", isOn: Binding(get: { headphones.focusOnVoice }, set: headphones.setFocusOnVoice))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(tint)
                    }
                }
            }
            .disabled(!headphones.canChangeNoiseControl)
        }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(ListeningPreset.allCases) { preset in
                Button {
                    headphones.applyPreset(mode: preset.mode, ambientLevel: preset.level, focusOnVoice: preset.focusOnVoice)
                } label: {
                    Label(preset.title, systemImage: preset.symbol)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!headphones.canApplyNoisePreset(mode: preset.mode, ambientLevel: preset.level, focusOnVoice: preset.focusOnVoice))
                .help(preset.mode == .anc ? String(localized: "Turn on noise cancellation.")
                      : String(localized: "Set Ambient Sound to \(preset.level), with Focus on Voice \(preset.focusOnVoice ? String(localized: "on") : String(localized: "off"))."))
            }
        }
        .buttonStyle(.bordered)
        .tint(.primary)
    }

}
