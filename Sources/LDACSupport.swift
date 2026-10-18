import Foundation

enum LDACSupport: String, Equatable, Sendable {
    case supported, unsupported, unknown

    /// The one place that decides. Sources, strongest first:
    /// 1. The model is known to offer LDAC in some configuration (`offersLDACOnlyWithoutMultipoint`). A DISCOVER taken
    ///    while multipoint was on lists only SBC and AAC for those models, so it cannot rule them out.
    /// 2. What the last real AVDTP DISCOVER found for this device: `true` when it listed the LDAC endpoint, `false` when
    ///    it ended with `LDAC_UNAVAILABLE` without having seen one.
    static func decide(modelImpliesLDAC: Bool, discovered: Bool?) -> LDACSupport {
        if modelImpliesLDAC { return .supported }
        switch discovered {
        case true?: return .supported
        case false?: return .unsupported
        case nil: return .unknown
        }
    }

    func allowsStart(requested: Bool) -> Bool { requested && self != .unsupported }
}

struct LDACCapabilityContext: Codable, Equatable, Sendable {
    var firmware: String? = nil
    var connectionMode: String? = nil
    var multipoint: Bool? = nil
    var endpointMayBeHidden = false
}

struct LDACCapabilityRecord: Codable, Equatable, Sendable {
    let supported: Bool
    let observedAt: Date
    let context: LDACCapabilityContext

    func observation(in current: LDACCapabilityContext, now: Date = Date()) -> Bool? {
        guard context == current, now >= observedAt,
              now.timeIntervalSince(observedAt) < (supported ? 30 : 1) * 24 * 3600,
              supported || !context.endpointMayBeHidden else { return nil }
        return supported
    }
}

struct LDACSupportStore {
    static let key = "ldac.discoveredSupport"
    static let recordsKey = "ldac.capabilityRecords"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) { self.defaults = defaults }

    var all: [String: LDACCapabilityRecord] {
        guard let data = defaults?.data(forKey: Self.recordsKey),
              let records = try? JSONDecoder().decode([String: LDACCapabilityRecord].self, from: data) else { return [:] }
        return records
    }

    private func normalized(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    func discovered(forAddress address: String, context: LDACCapabilityContext = .init(), now: Date = Date()) -> Bool? {
        all[normalized(address)]?.observation(in: context, now: now)
    }

    func record(_ supported: Bool, forAddress address: String, context: LDACCapabilityContext = .init(), now: Date = Date()) {
        var values = all
        values[normalized(address)] = LDACCapabilityRecord(supported: supported, observedAt: now, context: context)
        persist(values)
    }

    func clear(forAddress address: String) {
        var values = all
        values.removeValue(forKey: normalized(address))
        persist(values)
        var legacy = defaults?.dictionary(forKey: Self.key) ?? [:]
        legacy.removeValue(forKey: address)
        legacy.removeValue(forKey: normalized(address))
        defaults?.set(legacy, forKey: Self.key)
    }

    private func persist(_ records: [String: LDACCapabilityRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults?.set(data, forKey: Self.recordsKey)
    }
}

/// The line logged at `.notice` (persisted) for each MDR support-function list the app already receives.
/// It carries the model name and protocol version, never the Bluetooth address.
enum SonySupportFunctionsLog {
    static func line(generation: String, table: Int, model: String, protocolVersion: UInt32?, functions: Set<UInt8>) -> String {
        let version = protocolVersion.map { String(format: "%08X", $0) } ?? "unknown"
        let list = functions.sorted().map { String(format: "%02X", $0) }.joined(separator: " ")
        return "MDR support list generation=\(generation) table=\(table) model=\(model) protocol=\(version) count=\(functions.count) functions=\(list)"
    }
}
