import Foundation

enum LDACSupport: String, Equatable, Sendable {
    case supported, unsupported, unknown

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
    var rateMask: UInt8? = nil
    var channelMask: UInt8? = nil

    func supports(sampleRate: Int) -> Bool? {
        guard let rateMask, let channelMask else { return nil }
        let bit: UInt8
        switch sampleRate {
        case 44100: bit = 0x20
        case 48000: bit = 0x10
        case 88200: bit = 0x08
        case 96000: bit = 0x04
        default: return false
        }
        return rateMask & bit != 0 && channelMask & 1 != 0
    }

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

    func recordCapabilities(rates: UInt8, channels: UInt8, forAddress address: String, context: LDACCapabilityContext) {
        var values = all
        let key = normalized(address)
        let previous = values[key]
        let matching = previous?.context == context
        values[key] = LDACCapabilityRecord(supported: true, observedAt: Date(), context: context,
            rateMask: (matching ? previous?.rateMask ?? 0 : 0) | (channels & 1 != 0 ? rates : 0),
            channelMask: (matching ? previous?.channelMask ?? 0 : 0) | channels)
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
