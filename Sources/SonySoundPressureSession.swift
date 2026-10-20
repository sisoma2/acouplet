import Combine
import Foundation

@MainActor
final class SonySoundPressureSession: ObservableObject {
    private struct Read {
        let id = UUID()
        let generation: UInt64
        var transmitted = false
        var timedOut = false
    }

    @Published private(set) var soundPressure = SonySoundPressure()
    @Published private(set) var error: String?
    @Published private(set) var automaticRefreshSuspended = false
    @Published private var read: Read?
    private var generation: UInt64 = 0
    private var timeout: DispatchWorkItem?
    private var lastRequest: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    var hasPendingRead: Bool { read != nil }
    var hasTimedOutRead: Bool { read?.timedOut == true }
    var isReading: Bool { hasPendingRead && !hasTimedOutRead }

    func configure(supportedFunctions: Set<UInt8> = []) {
        soundPressure = SonySoundPressure(supportedFunctions: supportedFunctions)
    }

    func request(automatically: Bool) -> Bool {
        guard !hasPendingRead, !automatically || (!automaticRefreshSuspended
            && error == nil && soundPressure.intervalSeconds != nil) else { return false }
        if let interval = soundPressure.intervalSeconds, let lastRequest,
           lastRequest.duration(to: now()) < .seconds(interval) { return false }
        if !automatically { automaticRefreshSuspended = false }
        error = nil
        read = Read(generation: generation)
        return true
    }

    func didTransmit(isCurrent: @escaping @MainActor () -> Bool = { true }, onTimeout: @escaping @MainActor () -> Void) {
        guard let read else { return }
        self.read?.transmitted = true
        lastRequest = now()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, isCurrent(), self.read?.id == read.id else { return }
                self.read?.timedOut = true
                self.timeout = nil
                onTimeout()
                guard read.generation == self.generation else { return }
                self.soundPressure.invalidateReading()
                self.error = String(localized: "The listening level was not received. Reconnect the headphones to try again.")
            }
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func receive(_ payload: [UInt8], acceptsReading: Bool) -> Bool {
        var updated = soundPressure
        guard updated.update(payload) else { return false }
        if payload[0] == 0x5B {
            guard let read, read.transmitted else { return true }
            timeout?.cancel()
            timeout = nil
            self.read = nil
            guard !read.timedOut, read.generation == generation,
                  soundPressure.available == true, !soundPressure.isStopped, acceptsReading else { return true }
        } else if updated.available != soundPressure.available
            || updated.measurementEnabled != soundPressure.measurementEnabled
            || updated.previewEnabled != soundPressure.previewEnabled
            || (payload[0] == 0x59 && (payload[2] > 1 || payload[3] > 1)) {
            generation += 1
        }
        soundPressure = updated
        return true
    }

    func invalidateReading() {
        generation += 1
        soundPressure.invalidateReading()
    }

    func suspendAutomaticRefresh() {
        automaticRefreshSuspended = true
    }

    func resetRead() {
        timeout?.cancel()
        timeout = nil
        read = nil
        error = nil
        lastRequest = nil
        invalidateReading()
    }

    #if DEBUG
    func simulateReadTimeout() { timeout?.perform() }
    #endif
}
