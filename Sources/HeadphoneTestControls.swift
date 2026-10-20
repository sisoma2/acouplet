import AppKit
import SwiftUI

#if !ACOUPLET_PUBLIC_APIS_ONLY
struct FirmwareUpdateControl: View {
    let firmware: String
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var notifications: SonyNotificationService
    @State private var request: UUID?
    @State private var isChecking = false
    @State private var availability: SonyFirmwareAvailability?

    var body: some View {
        LabeledContent("Firmware") {
            HStack(spacing: 12) {
                Text(firmware).foregroundStyle(.primary)
                    .accessibilityIdentifier("headphones.firmwareVersion")
                Button(isChecking ? String(localized: "Checking…") : String(localized: "Check for Updates")) {
                    isChecking = true
                    availability = nil
                    request = UUID()
                }
                .disabled(isChecking || headphones.firmwareUpdateSession == nil || headphones.firmwareUpdateIdentity == nil)
                .accessibilityIdentifier("headphones.checkFirmware")
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .task(id: headphones.firmwareUpdateSession) {
            headphones.requestFirmwareUpdateIdentity()
            availability = nil
        }
        .task(id: request) {
            guard request != nil else { return }
            defer { isChecking = false }
            guard let session = headphones.firmwareUpdateSession, let identity = headphones.firmwareUpdateIdentity else { return }
            let result = await notifications.checkFirmware(identity: identity, currentVersion: firmware)
            guard !Task.isCancelled, headphones.firmwareUpdateSession == session,
                  headphones.firmwareUpdateIdentity == identity, headphones.firmwareVersion == firmware else { return }
            availability = result
        }
        .onChange(of: firmware) { _, _ in availability = nil }
        if let availability {
            Text(statusText(availability))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusText(availability))
                .accessibilityIdentifier("headphones.firmwareUpdateStatus")
        }
    }

    private func statusText(_ availability: SonyFirmwareAvailability) -> String {
        switch availability {
        case .available(let version): String(localized: "Firmware \(version) is available. Install it with Sony | Sound Connect.")
        case .noUpdate: String(localized: "Firmware is up to date.")
        case .unavailable: String(localized: "Couldn’t check for updates. Try again.")
        }
    }
}
#endif

struct HeadGesturePracticeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsPractice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.headGesturePracticeTransition == nil ? String(localized: "Practice Head Gestures…") : String(localized: "Practice Details…")) {
                if headphones.beginHeadGesturePractice() { showsPractice = true }
            }
            .tint(.primary)
            .disabled(headphones.headGesturePracticeTransition == nil && headphones.headGesturePracticeUnavailableReason != nil)
            .help(headphones.headGesturePracticeUnavailableReason ?? "")
            .accessibilityIdentifier("gesture.open")
            .sheet(isPresented: $showsPractice) {
                if let transition = headphones.headGesturePracticeTransition {
                    HeadGesturePracticeSheet(transitionID: transition.id)
                }
            }
            if headphones.headGesturePracticeTransition?.phase == .interrupted,
               let message = headphones.headGesturePracticeTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeadGesturePracticeSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var target = SonyHeadGesturePractice.Gesture.nod
    @State private var feedbackAfterRevision: UInt64 = 0
    @State private var countAtSelection = 0

    private var detectedGesture: SonyHeadGesturePractice.Gesture? {
        headphones.headGesturePractice.gestureRevision > feedbackAfterRevision ? headphones.headGesturePractice.receivedGesture : nil
    }

    private var matchingGestureCount: Int {
        min(3, max(0, headphones.headGesturePractice.count(for: target) - countAtSelection))
    }

    var body: some View {
        if let transition = headphones.headGesturePracticeTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("Practice Head Gestures").font(.headline)
                        .accessibilityIdentifier("gesture.title")
                    Spacer(minLength: 0)
                    Picker("Gesture", selection: $target) {
                        Text("Nod").tag(SonyHeadGesturePractice.Gesture.nod)
                        Text("Shake").tag(SonyHeadGesturePractice.Gesture.shake)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 136)
                    .disabled(transition.phase != .ready && transition.phase != .practicing)
                    .accessibilityIdentifier("gesture.target")
                }
                GroupBox {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            let head = Image(systemName: "face.smiling.inverse")
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                            if !reduceMotion && scenePhase == .active && matchingGestureCount < 3
                                && transition.phase == .practicing {
                                head.phaseAnimator([0, -1, 0, 1]) { content, phase in
                                    content.offset(x: target == .shake ? CGFloat(phase) * 6 : 0,
                                                   y: target == .nod ? CGFloat(phase) * 6 : 0)
                                } animation: { _ in .easeInOut(duration: 0.35) }
                            } else {
                                head
                            }
                            Image(systemName: target == .nod ? "arrow.up.and.down" : "arrow.left.and.right")
                                .font(.callout.weight(.medium))
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            if let message = transition.message {
                                Text(message).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("gesture.message")
                            } else if transition.phase == .practicing {
                                HStack(spacing: 6) {
                                    Image(systemName: matchingGestureCount == 3 || detectedGesture == target ? "checkmark.circle.fill" : detectedGesture == nil ? "circle.dotted" : "arrow.trianglehead.clockwise")
                                        .foregroundStyle(matchingGestureCount == 3 || detectedGesture == target ? Color.green : Color.secondary)
                                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                        .symbolEffectsRemoved(reduceMotion || detectedGesture != target)
                                        .symbolEffect(.bounce, value: matchingGestureCount)
                                        .accessibilityHidden(true)
                                    if matchingGestureCount == 3 {
                                        Text("All set")
                                    } else if let detectedGesture {
                                        Text("\(detectedGesture.title) detected")
                                    } else {
                                        Text("Waiting for a gesture…")
                                    }
                                }
                                .font(.headline)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(matchingGestureCount == 3 ? "gesture.success" : detectedGesture == nil ? "gesture.waiting" : "gesture.detected")
                            } else if transition.phase == .finished {
                                Text("Practice has ended.").font(.headline)
                            } else {
                                Text("Wear both earbuds and face forward.")
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.message == nil && transition.phase != .finished {
                                Text(target == .nod ? String(localized: "Face forward, then nod your head up and down.") : String(localized: "Face forward, then shake your head from side to side."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.waitingForReport {
                                HeadphoneTestProgress(title: transition.phase == .checking ? String(localized: "Preparing practice…") : transition.phase == .entering ? String(localized: "Starting practice…") : String(localized: "Ending practice…"))
                                    .accessibilityIdentifier("gesture.progress")
                            } else if transition.phase == .practicing {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(matchingGestureCount) of 3 gestures detected")
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("gesture.count")
                                    HStack(spacing: 5) {
                                        ForEach(0..<3) { index in
                                            ProgressView(value: index < matchingGestureCount ? 1 : 0, total: 1)
                                                .progressViewStyle(.linear)
                                                .tint(index < matchingGestureCount ? .green : .clear)
                                                .frame(width: 18)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                    .padding(6)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                Text("If a gesture is not detected, face forward and remain still for a moment before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(transition.message == nil && transition.phase != .finished ? 1 : 0)
                    .accessibilityHidden(transition.message != nil || transition.phase == .finished)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .practicing ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissHeadGesturePractice(id: transitionID)
                            dismiss()
                        } else { headphones.cancelHeadGesturePractice(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .leaving)
                    .accessibilityIdentifier("gesture.cancel")
                    if transition.phase == .ready {
                        Button("Start Practice") { headphones.startHeadGesturePractice(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartHeadGesturePractice)
                            .accessibilityIdentifier("gesture.start")
                    }
                }
            }
            .padding(20)
            .frame(width: 440, height: 296)
            .presentationSizing(.fitted)
            .accessibilityElement(children: .contain)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissHeadGesturePractice(id: transitionID)
                    dismiss()
                }
            }
            .onChange(of: target) { _, _ in
                feedbackAfterRevision = headphones.headGesturePractice.gestureRevision
                countAtSelection = headphones.headGesturePractice.count(for: target)
            }
            .onChange(of: headphones.headGesturePractice.gestureRevision) { _, _ in
                if NSWorkspace.shared.isVoiceOverEnabled, let gesture = headphones.headGesturePractice.receivedGesture {
                    NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                                         userInfo: [.announcement: matchingGestureCount == 3 ? String(localized: "All set") : String(localized: "\(gesture.title) detected"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
            .onDisappear { headphones.cancelHeadGesturePractice(id: transitionID, dismissWhenFinished: true) }
        }
    }
}

struct LegacyOptimizerControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsOptimizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.legacyOptimizerTransition == nil ? String(localized: "Optimize Noise Cancelling…") : String(localized: "Optimizer Details…")) {
                if headphones.beginLegacyOptimizer() { showsOptimizer = true }
            }
            .tint(.primary)
            .disabled(headphones.legacyOptimizerTransition == nil && headphones.legacyOptimizerUnavailableReason != nil)
            .help(headphones.legacyOptimizerUnavailableReason ?? "")
            .accessibilityIdentifier("optimizer.open")
            .sheet(isPresented: $showsOptimizer) {
                if let transition = headphones.legacyOptimizerTransition {
                    LegacyOptimizerSheet(transitionID: transition.id)
                }
            }
            if headphones.legacyOptimizerTransition?.phase == .interrupted,
               let message = headphones.legacyOptimizerTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LegacyOptimizerSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let transition = headphones.legacyOptimizerTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 20) {
                Text("Noise Cancelling Optimizer").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("optimizer.title")
                VStack(alignment: .leading, spacing: 20) {
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("optimizer.message")
                    } else if transition.phase == .checking || transition.phase == .ready {
                        Text("Wear the headphones as you normally do. This test plays sounds. Avoid touching the headphones until it finishes.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.phase == .completed {
                        Label {
                            Text("Optimization Complete")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                            .accessibilityIdentifier("optimizer.result")
                        if let result = transition.result {
                            if result.personalType == 1 {
                                LabeledContent("Personal optimization", value: result.personalMeasured.map { $0 ? String(localized: "Measured") : String(localized: "Not measured") } ?? String(localized: "Unknown"))
                            }
                            if result.pressureType == 1 {
                                LabeledContent("Atmospheric pressure", value: result.pressureAtmospheres.map {
                                    String(localized: "\($0.formatted(.number.precision(.fractionLength(1)))) atm")
                                } ?? (result.pressureValue == 0 ? String(localized: "Not measured") : String(localized: "Unknown")))
                            }
                        }
                    } else if transition.waitingForReport || transition.phase == .checking {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("optimizer.progress")
                    }
                    Spacer(minLength: 0)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    Spacer()
                    Button((transition.canDismiss && transition.phase != .ready) || transition.phase == .completed ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissLegacyOptimizer(id: transitionID)
                            dismiss()
                        } else { headphones.cancelLegacyOptimizer(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .readingResult
                              || (transition.phase == .completed && !transition.canDismiss))
                    .accessibilityIdentifier("optimizer.cancel")
                    if transition.phase == .ready {
                        Button("Start Optimization") { headphones.startLegacyOptimizer(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartLegacyOptimizer)
                            .accessibilityIdentifier("optimizer.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 260)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.shouldDismiss) { _, shouldDismiss in
                if shouldDismiss {
                    headphones.dismissLegacyOptimizer(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear {
                if headphones.legacyOptimizerTransition?.canDismiss != true {
                    headphones.cancelLegacyOptimizer(id: transitionID)
                }
                headphones.dismissLegacyOptimizer(id: transitionID)
            }
        }
    }

    private func progressText(_ phase: SonyLegacyOptimizerTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Checking headphones…")
        case .starting, .running: String(localized: "Optimizing noise cancellation…")
        case .readingResult: String(localized: "Reading results…")
        case .cancelling: String(localized: "Stopping optimization…")
        default: String(localized: "Waiting for headphones…")
        }
    }
}

struct EarTipFitControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsTest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.earTipFitTransition == nil ? String(localized: "Check Earbud Fit…") : String(localized: "Fit Test Details…")) {
                if headphones.beginEarTipFit() { showsTest = true }
            }
            .tint(.primary)
            .disabled(headphones.earTipFitTransition == nil && headphones.earTipFitUnavailableReason != nil)
            .help(headphones.earTipFitUnavailableReason ?? "")
            .accessibilityIdentifier("fit.open")
            .sheet(isPresented: $showsTest) {
                if let transition = headphones.earTipFitTransition {
                    EarTipFitSheet(transitionID: transition.id)
                }
            }
            if headphones.earTipFitTransition?.phase == .interrupted,
               let message = headphones.earTipFitTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EarTipFitSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var resultHasFocus: Bool

    var body: some View {
        if let transition = headphones.earTipFitTransition, transition.id == transitionID {
            let passed = transition.phase == .result && transition.result?.left == .good && transition.result?.right == .good
            VStack(alignment: .leading, spacing: 20) {
                Text("Earbud Fit Test").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("fit.title")
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 32) {
                        earbud(.left, seal: transition.result?.left)
                        earbud(.right, seal: transition.result?.right)
                    }
                    .frame(maxWidth: .infinity)
                    if let selectedSeries = headphones.earTipFit.selectedSeries {
                        LabeledContent("Ear-tip type", value: selectedSeries.title)
                    }
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fit.message")
                    } else if !passed {
                        Text(instructions(transition.phase)).fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.waitingForReport {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("fit.progress")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: transition.phase == .result ? .center : .top)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    if transition.phase == .result {
                        Button("Test Again") { headphones.prepareEarTipFitAgain(id: transitionID) }
                            .keyboardShortcut(passed ? nil : .defaultAction)
                            .tint(passed ? .primary : .accentColor)
                            .accessibilityIdentifier("fit.again")
                    }
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .result ? String(localized: "Done") : String(localized: "Cancel")) {
                        close(transition)
                    }
                    .keyboardShortcut(passed ? .defaultAction : .cancelAction)
                    .tint(passed ? .accentColor : .primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .leaving)
                    .accessibilityIdentifier("fit.cancel")
                    if transition.phase == .ready {
                        Button("Start Test") { headphones.startEarTipFit(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartEarTipFit)
                            .accessibilityIdentifier("fit.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 380)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .focusable(passed, interactions: .edit)
            .focused($resultHasFocus)
            .focusEffectDisabled()
            .onExitCommand(perform: passed ? { close(transition) } : nil)
            .onChange(of: passed, initial: true) { _, passed in resultHasFocus = passed }
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissEarTipFit(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear { headphones.cancelEarTipFit(id: transitionID, dismissWhenFinished: true) }
        }
    }

    private func close(_ transition: SonyEarTipFitTransition) {
        if transition.canDismiss {
            headphones.dismissEarTipFit(id: transitionID)
            dismiss()
        } else { headphones.cancelEarTipFit(id: transitionID) }
    }

    private func earbud(_ side: EarbudSide, seal: SonyEarTipFit.Seal?) -> some View {
        VStack(spacing: 8) {
            EarbudArtwork(model: headphones.deviceModel, side: side, usesProductArtwork: headphones.usesProductArtwork,
                          artworkSuffix: headphones.productArtworkSuffix)
                .frame(width: 100, height: 100 * 103.0 / 137.0).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(side == .left ? String(localized: "Left") : String(localized: "Right")).font(.headline)
                if let seal {
                    Label {
                        Text(seal == .good ? String(localized: "Good seal") : String(localized: "Adjust fit"))
                    } icon: {
                        Image(systemName: seal == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(seal == .good ? Color.green : Color.yellow)
                    }
                        .accessibilityIdentifier(side == .left ? "fit.leftResult" : "fit.rightResult")
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructions(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking, .ready:
            String(localized: "Wear both earbuds in a quiet place. The test plays a short sound.")
        case .entering, .starting, .measuring:
            String(localized: "Keep still and leave both earbuds in your ears.")
        case .result:
            String(localized: "Reposition the earbud or try another tip size, then test again.")
        case .cancelling, .leaving:
            String(localized: "Waiting for the earbuds to finish.")
        case .finished:
            String(localized: "The fit test has ended.")
        case .unavailable, .interrupted:
            String(localized: "The fit test is unavailable.")
        }
    }

    private func progressText(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Reading earbud information…")
        case .entering, .starting: String(localized: "Starting test…")
        case .measuring: String(localized: "Measuring fit…")
        case .cancelling: String(localized: "Cancelling test…")
        default: String(localized: "Finishing test…")
        }
    }
}

private struct HeadphoneTestProgress: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.regular)
            Text(title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
