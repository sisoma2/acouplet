#if !ACOUPLET_PUBLIC_APIS_ONLY
import Foundation

@MainActor
final class LDACVolumeSession {
    struct Context {
        let sessionID: UUID
        let binding: LDACMusicBinding.Status
        let hasRawTransport: Bool
        let volumeRange: ClosedRange<Int>?
        let canWrite: Bool
        let headphoneVolume: Int?
        let nativeVolume: Int?
    }

    struct Operations {
        let context: @MainActor () -> Context?
        let write: @MainActor (Int, @escaping @MainActor () -> Bool) async throws -> Void
        let configure: @MainActor (Int, ClosedRange<Int>) async throws -> Void
        let record: @MainActor (String, String) -> Void
        let failed: @MainActor (Error, LDACMusicBinding.Status) -> Void
        let deferred: @MainActor () -> Void
    }

    enum Failure: LocalizedError {
        case unavailable, unconfirmed

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "The headphone volume controls became unavailable. LDAC stopped.")
            case .unconfirmed: String(localized: "The headphones did not confirm the requested volume. LDAC stopped.")
            }
        }
    }

    var pendingVolume: Int?
    var isWriting: Bool { task != nil }
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
    }

    func send(using operations: Operations) {
        guard task == nil, pendingVolume != nil, let context = operations.context() else { return }
        let identifier = context.sessionID
        let volumeIdentifier = UUID()
        taskID = volumeIdentifier
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskID == volumeIdentifier {
                    self.task = nil
                    self.taskID = nil
                }
            }
            guard operations.context()?.sessionID == identifier else { return }
            do {
                while let volume = self.pendingVolume {
                    try Task.checkCancellation()
                    guard let context = operations.context(), context.sessionID == identifier else { return }
                    if case .held = context.binding {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    guard context.binding == .current, context.volumeRange?.contains(volume) == true else {
                        throw Failure.unavailable
                    }
                    if !context.canWrite {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    self.pendingVolume = nil
                    if context.headphoneVolume != volume {
                        operations.record("volume-write", "requested=\(volume)")
                        try await operations.write(volume) { [weak self] in
                            guard let self, let context = operations.context() else { return false }
                            return context.sessionID == identifier && self.taskID == volumeIdentifier
                                && self.task?.isCancelled == false && context.hasRawTransport && context.binding == .current
                        }
                    }
                    try Task.checkCancellation()
                    guard let confirmed = operations.context(), confirmed.sessionID == identifier,
                          confirmed.binding.acceptsConfirmation, confirmed.headphoneVolume == volume else {
                        throw Failure.unconfirmed
                    }
                    operations.record("volume-confirmed", "confirmed=\(volume)")
                    if self.pendingVolume == nil, let range = confirmed.volumeRange, let nativeVolume = confirmed.nativeVolume,
                       nativeVolume != volume {
                        try await operations.configure(volume, range)
                        try Task.checkCancellation()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let context = operations.context(), context.sessionID == identifier, self.taskID == volumeIdentifier else { return }
                if case .held = context.binding {
                    operations.record("volume-deferred", error.localizedDescription)
                    if self.pendingVolume == nil { self.pendingVolume = context.nativeVolume }
                    self.task = nil
                    self.taskID = nil
                    operations.deferred()
                } else {
                    operations.failed(error, context.binding)
                }
            }
        }
    }
}
#endif
