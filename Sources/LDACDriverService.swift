#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Foundation

@MainActor
final class LDACDriverService: ObservableObject {
    @Published private(set) var state: LDACDriverInstaller.State
    @Published private(set) var installationError: String?
    @Published private(set) var isOpeningInstaller = false
    private let bundle: Bundle
    private let inspect: ((Bundle) -> LDACDriverInstaller.State)?
    private let inspectInBackground: (Bundle) async -> LDACDriverInstaller.State
    private let openInstaller: (Bundle) async throws -> Void
    private var inspectionTask: Task<Void, Never>?

    init(bundle: Bundle = .main, inspect: ((Bundle) -> LDACDriverInstaller.State)? = nil,
         inspectInBackground: @escaping (Bundle) async -> LDACDriverInstaller.State = { await LDACDriverInstaller.inspectInBackground(bundle: $0) },
         openInstaller: @escaping (Bundle) async throws -> Void = { try await LDACDriverInstaller.openInstaller(bundle: $0) }) {
        self.bundle = bundle
        self.inspect = inspect
        self.inspectInBackground = inspectInBackground
        self.openInstaller = openInstaller
        state = inspect?(bundle) ?? .unavailable("")
    }

    func refresh() {
        updateState(inspect?(bundle) ?? LDACDriverInstaller.inspect(bundle: bundle))
    }

    func refreshInBackground(canUpdate: @escaping @MainActor () -> Bool, didRefresh: @escaping @MainActor () -> Void) {
        guard inspect == nil else {
            refresh()
            didRefresh()
            return
        }
        guard inspectionTask == nil else { return }
        inspectionTask = Task {
            let state = await inspectInBackground(bundle)
            if canUpdate() { updateState(state) }
            inspectionTask = nil
            didRefresh()
        }
    }

    func install() {
        guard !isOpeningInstaller else { return }
        LDACDriverInstaller.invalidateCache()
        refresh()
        guard state == .missing || state == .outdated else { return }
        open()
    }

    func update() {
        guard !isOpeningInstaller else { return }
        refresh()
        guard state == .outdated else { return }
        open()
    }

    private func updateState(_ state: LDACDriverInstaller.State) {
        if self.state != state { self.state = state }
    }

    private func open() {
        installationError = nil
        isOpeningInstaller = true
        Task {
            defer { isOpeningInstaller = false }
            do { try await openInstaller(bundle) }
            catch { installationError = error.localizedDescription }
        }
    }
}
#endif
