import AppKit
import SwiftUI

extension SettingsStore {
    var controlAccentColor: NSColor {
        if useSystemAccentColor { return .controlAccentColor }
        return NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 170.0 / 255, green: 137.0 / 255, blue: 64.0 / 255, alpha: 1)
            }
            return NSColor(srgbRed: 140.0 / 255, green: 107.0 / 255, blue: 10.0 / 255, alpha: 1)
        }
    }
    var tintColor: Color { Color(nsColor: controlAccentColor) }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        let _ = SettingsLifecycleProbe.recordBody()
        #endif
        TabView(selection: $settings.selectedSettingsPane) {
            Tab("General", systemImage: "gear", value: "general") {
                GeneralSettingsView()
            }
            Tab(headphones.deviceModel.isSpeaker ? String(localized: "Speakers") : String(localized: "Headphones"),
                systemImage: headphones.deviceModel.systemSymbol, value: "headphones") {
                HeadphoneSettingsView()
            }
            Tab("Advanced", systemImage: "gearshape.2", value: "advanced") {
                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .accessibilityIdentifier("settings.form")
        .onAppear {
            headphones.refreshForPresentation()
            settings.refreshLaunchStatus()
            settings.refreshAppLanguage()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.appearances += 1 }
            #endif
        }
        .task(id: soundPressureRefreshInterval) {
            guard let interval = soundPressureRefreshInterval else { return }
            while !Task.isCancelled {
                headphones.refreshSoundPressure(automatically: true)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        .onChange(of: soundPressureRefreshInterval) { _, interval in
            if interval == nil { headphones.invalidateSoundPressureReading() }
        }
        .onDisappear {
            headphones.invalidateSoundPressureReading()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.disappearances += 1 }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                headphones.refreshForPresentation()
                settings.refreshLaunchStatus()
                settings.refreshAppLanguage()
            }
            else { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: settings.selectedSettingsPane) { _, pane in
            headphones.refreshForPresentation()
            if pane != "headphones" { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
        .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
    }

    private var soundPressureRefreshInterval: Int? {
        guard scenePhase == .active, settings.selectedSettingsPane == "headphones", headphones.isReady, headphones.powerOffState == nil, !headphones.isRunningHeadphoneTest,
              headphones.soundPressure.available == true, !headphones.soundPressure.isStopped,
              !headphones.soundPressureAutomaticRefreshSuspended,
              headphones.connectionTransition?.isFinished != false, headphones.sourceTransition?.isFinished != false,
              headphones.multipointTransition?.isFinished != false, headphones.deviceActionTransition?.isFinished != false else { return nil }
        return headphones.soundPressure.intervalSeconds
    }
}
