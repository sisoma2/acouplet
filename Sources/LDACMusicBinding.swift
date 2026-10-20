#if !ACOUPLET_PUBLIC_APIS_ONLY
import Foundation

enum LDACMusicBinding {
    enum Status: Equatable {
        case current
        case held(String, transition: Bool)
        case sourceChanged(String)
        case lost(String)

        var acceptsConfirmation: Bool {
            switch self {
            case .current, .held: true
            case .sourceChanged, .lost: false
            }
        }
    }

    struct Context {
        var matchesController: Bool
        var isConnected: Bool
        var session: UInt64?
        var boundSession: UInt64?
        var requiresRawTransport: Bool
        var hasRawTransport: Bool
        var isLeavingConnectionMode: Bool
        var selectedSource: String?
        var boundSource: String?
        var inventoryIsStale: Bool
        var volumeRange: ClosedRange<Int>?
        var boundVolumeRange: ClosedRange<Int>?
        var pendingTransition: String?
        var hasOwnedMusicContext: Bool
        var hasCurrentVolumeControl: Bool
    }

    static func check(_ context: Context) -> Status {
        guard context.matchesController else { return .lost("controller-changed") }
        guard context.isConnected else { return .lost("device-disconnected") }
        guard context.boundSession != nil, context.session == context.boundSession else { return .lost("control-session-changed") }
        guard !context.requiresRawTransport || context.hasRawTransport else { return .lost("raw-transport-missing") }
        if context.isLeavingConnectionMode { return .sourceChanged("connection-mode") }
        if let bound = context.boundSource, let selected = context.selectedSource, selected != bound, !context.inventoryIsStale {
            return .sourceChanged("selected-source")
        }
        if let range = context.volumeRange, range != context.boundVolumeRange { return .lost("volume-range-changed") }
        if let transition = context.pendingTransition { return .held("transition=\(transition)", transition: true) }
        if context.inventoryIsStale { return .held("inventory-stale", transition: false) }
        if context.selectedSource != context.boundSource { return .held("source-unconfirmed", transition: false) }
        if context.volumeRange == nil { return .held("volume-range-unknown", transition: false) }
        guard context.hasOwnedMusicContext else {
            return .held(context.hasCurrentVolumeControl ? "source-context-stale" : "volume-controls-stale", transition: false)
        }
        return .current
    }
}
#endif
