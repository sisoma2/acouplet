struct SonyNoiseControl: Equatable, Sendable {
    enum Sensitivity: UInt8, CaseIterable, Identifiable, Sendable {
        case standard = 0, high = 1, low = 2

        var id: Self { self }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .high: "High"
            case .low: "Low"
            }
        }
    }

    struct AmbientCapability: Equatable, Sendable {
        let ambientMode: UInt8
        let minimum: Int
        let maximum: Int
        let step: Int

        init?(ambientMode: UInt8, minimum: UInt8, maximum: UInt8, step: UInt8) {
            guard ambientMode <= 1, minimum < 255, maximum > 0, minimum <= maximum, step > 0 else { return nil }
            self.ambientMode = ambientMode
            self.minimum = Int(minimum)
            self.maximum = Int(maximum)
            self.step = Int(step)
        }

        var range: ClosedRange<Int> { minimum...(minimum + (maximum - minimum) / step * step) }

        func contains(_ value: Int) -> Bool {
            range.contains(value) && (value - minimum) % step == 0
        }

        func normalized(_ value: Int) -> Int {
            let value = max(range.lowerBound, min(range.upperBound, value))
            return minimum + (value - minimum + step / 2) / step * step
        }
    }

    struct State: Equatable, Sendable {
        let inquiryType: UInt8
        let effectEnabled: Bool
        let ncAsmMode: UInt8
        let ambientMode: UInt8
        let ambientLevel: Int
        let adaptationEnabled: Bool?
        let sensitivity: Sensitivity?

        init?(payload: [UInt8]) {
            guard payload.count >= 2, [0x17, 0x19].contains(payload[1]),
                  payload.count == (payload[1] == 0x19 ? 9 : 7), [0x67, 0x68, 0x69].contains(payload[0]),
                  payload[2] == 1, payload[3] <= 1, payload[4] <= 1, payload[5] <= 1 else { return nil }
            inquiryType = payload[1]
            if inquiryType == 0x19 {
                guard payload[7] <= 1, let sensitivity = Sensitivity(rawValue: payload[8]) else { return nil }
                adaptationEnabled = payload[7] == 1
                self.sensitivity = sensitivity
            } else {
                adaptationEnabled = nil
                sensitivity = nil
            }
            effectEnabled = payload[3] == 1
            ncAsmMode = payload[4]
            ambientMode = payload[5]
            ambientLevel = Int(payload[6])
        }

        var mode: NoiseControlMode { !effectEnabled ? .off : ncAsmMode == 0 ? .anc : .ambient }
        var focusOnVoice: Bool? { ambientMode == 1 }
        var payload: [UInt8] {
            var payload: [UInt8] = [0x67, inquiryType, 1, effectEnabled ? 1 : 0, ncAsmMode, ambientMode, UInt8(ambientLevel)]
            if let adaptationEnabled, let sensitivity { payload += [adaptationEnabled ? 1 : 0, sensitivity.rawValue] }
            return payload
        }
    }

    let inquiryType: UInt8

    init(inquiryType: UInt8 = 0x19) {
        precondition(inquiryType == 0x17 || inquiryType == 0x19)
        self.inquiryType = inquiryType
    }

    private(set) var capabilities: [UInt8: AmbientCapability]?
    private(set) var available: Bool?
    private(set) var state: State?

    var canSet: Bool {
        available == true && state.map { capabilities?[$0.ambientMode]?.contains($0.ambientLevel) == true } == true
    }

    func ambientCapability(focusOnVoice: Bool) -> AmbientCapability? {
        capabilities?[focusOnVoice ? 1 : 0]
    }

    func ambientRange(focusOnVoice: Bool) -> ClosedRange<Int>? {
        ambientCapability(focusOnVoice: focusOnVoice)?.range
    }

    func ambientStep(focusOnVoice: Bool) -> Int? {
        ambientCapability(focusOnVoice: focusOnVoice)?.step
    }

    func validatedMode(_ payload: [UInt8]) -> NoiseControlMode? {
        guard let state = State(payload: payload), state.inquiryType == inquiryType,
              capabilities?[state.ambientMode]?.contains(state.ambientLevel) == true else { return nil }
        return state.mode
    }

    func confirms(_ value: [UInt8]?, expected: [UInt8]) -> Bool {
        guard let value, let received = State(payload: [0x67] + value),
              let requested = State(payload: [0x68] + expected),
              received.inquiryType == inquiryType, requested.inquiryType == inquiryType,
              received.mode == requested.mode else { return false }
        guard received.adaptationEnabled == requested.adaptationEnabled,
              received.sensitivity == requested.sensitivity else { return false }
        return received.mode == .off || received.mode == .anc
            || (received.ambientMode == requested.ambientMode && received.ambientLevel == requested.ambientLevel)
    }

    func setPayload(mode: NoiseControlMode? = nil, ambientLevel: Int? = nil, focusOnVoice: Bool? = nil,
                    adaptationEnabled: Bool? = nil, sensitivity: Sensitivity? = nil) -> [UInt8]? {
        guard canSet, let state else { return nil }
        if adaptationEnabled != nil || sensitivity != nil { guard inquiryType == 0x19 else { return nil } }
        var payload = state.payload
        payload[0] = 0x68
        if mode == .off {
            payload[3] = 0
            return payload
        }
        if let mode {
            guard mode == .anc || mode == .ambient else { return nil }
            payload[3] = 1
            payload[4] = mode == .anc ? 0 : 1
        }
        if let ambientLevel {
            guard let level = UInt8(exactly: ambientLevel) else { return nil }
            payload[6] = level
        }
        if let focusOnVoice { payload[5] = focusOnVoice ? 1 : 0 }
        if let adaptationEnabled { payload[7] = adaptationEnabled ? 1 : 0 }
        if let sensitivity { payload[8] = sensitivity.rawValue }
        return validatedMode(payload) == nil ? nil : payload
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x61:
            capabilities = nil
            guard payload.count >= 3, payload.count == 3 + Int(payload[2]) * 4 else { return true }
            var records: [UInt8: AmbientCapability] = [:]
            for offset in stride(from: 3, to: payload.count, by: 4) {
                let mode = payload[offset]
                guard records[mode] == nil,
                      let record = AmbientCapability(ambientMode: mode, minimum: payload[offset + 1],
                                                     maximum: payload[offset + 2], step: payload[offset + 3]) else { return true }
                records[mode] = record
            }
            capabilities = records
        case 0x63, 0x65:
            available = payload.count == 3 && payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x67, 0x69:
            state = State(payload: payload)
        default:
            return false
        }
        return true
    }
}
