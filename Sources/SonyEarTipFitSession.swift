import Combine
import Foundation

@MainActor
final class SonyEarTipFitSession: ObservableObject {
    struct Reception {
        let owned: Bool
        let parsed: Bool
    }

    @Published private(set) var model = SonyEarTipFit()
    @Published private(set) var transition: SonyEarTipFitTransition?
    private var timeout: DispatchWorkItem?
    private var timeoutID: UUID?
    private var timeoutPhase: SonyEarTipFitTransition.Phase?

    var hasTimeout: Bool { timeout != nil }

    func configure(supportedFunctions: Set<UInt8> = []) {
        model = SonyEarTipFit(supportedFunctions: supportedFunctions)
    }

    func begin(session: UInt64, supportedFunctions: Set<UInt8>) {
        guard transition == nil else { return }
        configure(supportedFunctions: supportedFunctions)
        transition = SonyEarTipFitTransition(session: session, supportsEarpieceSelection: model.supportsEarpieceSelection)
    }

    func start(id: UUID) -> Bool {
        guard transition?.id == id else { return false }
        return transition?.start(model: model) == true
    }

    func cancel(id: UUID, dismissWhenFinished: Bool) {
        guard transition?.id == id else { return }
        transition?.cancel(dismissWhenFinished: dismissWhenFinished)
    }

    func prepareAgain(id: UUID) {
        guard transition?.id == id else { return }
        transition?.prepareAgain()
    }

    func dismiss(id: UUID) {
        guard transition?.id == id, transition?.canDismiss == true,
              transition?.phase != .interrupted else { return }
        clear()
    }

    func clear() {
        cancelTimeout()
        timeoutPhase = nil
        transition = nil
    }

    func controlLost() {
        transition?.controlLost()
        cancelTimeout()
        timeoutPhase = nil
        if let transition, transition.dismissWhenFinished, transition.phase == .finished {
            dismiss(id: transition.id)
        }
    }

    func transmitted(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = 0) {
        transition?.transmitted(payload, session: session, transmissionOrdinal: transmissionOrdinal)
    }

    func receive(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = .max) -> Reception? {
        guard payload.count >= 2, payload[1] == 0x06 || payload[1] == 0x07,
              [0xF1, 0xF3, 0xF5, 0xF7, 0xF9, 0xFB, 0xFD].contains(payload[0]) else { return nil }
        let owned = transition?.accepts(payload, session: session, transmissionOrdinal: transmissionOrdinal) == true
        let parsed = owned && model.update(payload)
        if parsed { transition?.receive(payload, model: model) }
        return Reception(owned: owned, parsed: parsed)
    }

    func advance(session: UInt64, isReady: Bool, canStart: Bool, commandPending: Bool,
                 isCurrent: @escaping @MainActor () -> Bool, onTimeout: @escaping @MainActor () -> Void) -> [[UInt8]] {
        guard let transition else { return [] }
        if transition.shouldStartAgain, transition.session == session, canStart, start(id: transition.id) {
            return advance(session: session, isReady: isReady, canStart: false, commandPending: commandPending,
                           isCurrent: isCurrent, onTimeout: onTimeout)
        }
        let changed = timeoutPhase != transition.phase
        if changed {
            cancelTimeout()
            timeoutPhase = transition.phase
        }
        if transition.dismissWhenFinished, transition.phase == .finished {
            dismiss(id: transition.id)
            return []
        }
        if transition.waitingForReport, timeout == nil {
            let seconds = transition.phase == .measuring ? max(30, (model.capability?.durationSeconds ?? 0) + 15) : 8
            let identifier = UUID()
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, transition.session == session, isCurrent(), self.timeoutID == identifier,
                          self.transition?.id == transition.id, self.transition?.phase == transition.phase else { return }
                    onTimeout()
                }
            }
            timeoutID = identifier
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: timeout)
        }
        guard transition.session == session, isReady else { return [] }
        var payloads = changed && transition.phase == .checking ? transition.initialQueries : []
        if let payload = transition.expectedPayload, !transition.commandTransmitted, !commandPending {
            payloads.append(payload)
        }
        return payloads
    }

    func finishTimeout() {
        transition?.timeout()
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
        timeoutID = nil
    }

    #if DEBUG
    var simulatedTimeout: DispatchWorkItem? { timeout }
    #endif
}
