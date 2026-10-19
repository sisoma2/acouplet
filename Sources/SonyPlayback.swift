import Foundation

@MainActor
enum MacMediaPlayback {
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private static let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_LOCAL)
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let pauseCommand: UInt32 = 1
    #endif

    static func pause() {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        guard let library, let symbol = dlsym(library, "MRMediaRemoteSendCommand") else { return }
        let send = unsafeBitCast(symbol, to: SendCommand.self)
        _ = send(pauseCommand, nil)
        #endif
    }
}

enum SonyPlaybackState: UInt8, Sendable {
    case unsettled = 0, playing, paused, stopped
}

enum SonyPlaybackCommand: UInt8, Sendable {
    case pause = 1, next, previous
    case play = 7
}

struct SonyTrack: Equatable, Sendable {
    let title: String?
    let album: String?
    let artist: String?

    init?(payload: [UInt8]) {
        var offset = 2
        var names: [String?] = []
        for _ in 0..<4 {
            guard offset + 2 <= payload.count else { return nil }
            let status = payload[offset]
            let end = offset + 2 + Int(payload[offset + 1])
            guard end <= payload.count,
                  let name = String(bytes: payload[(offset + 2)..<end], encoding: .utf8) else { return nil }
            names.append(status == 2 && !name.isEmpty ? name : nil)
            offset = end
        }
        guard offset == payload.count else { return nil }
        title = names[0]
        album = names[1]
        artist = names[2]
    }
}

struct SonyPlayback: Equatable, Sendable {
    let generation: SonyProtocolInfo.Generation
    let isSupported: Bool
    private(set) var hasReceivedCapabilities = false
    private(set) var available: Bool?
    private(set) var state: SonyPlaybackState?
    private(set) var musicCallStatus: UInt8?
    private(set) var musicVolumeRange: ClosedRange<Int>?
    private(set) var callVolumeRange: ClosedRange<Int>?
    private var reportedMusicVolume: Int?
    private var reportedCallVolume: Int?
    private(set) var track: SonyTrack?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.generation = generation
        isSupported = supportedFunctions.contains(0xA1)
    }

    var capabilityQueryPayload: [UInt8] { [0xA0, 0x01] }
    var statusQueryPayload: [UInt8] { [0xA2, 0x01] }
    var musicVolumeQueryPayload: [UInt8] { generation == .v1 ? [0xA6, 0x01, 0x20] : [0xA6, 0x20] }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return generation == .v1 ? [capabilityQueryPayload, statusQueryPayload, musicVolumeQueryPayload]
            : [capabilityQueryPayload, statusQueryPayload, [0xA6, 0x01], musicVolumeQueryPayload, [0xA6, 0x21]]
    }

    func queryPayload(for payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 2 else { return nil }
        switch payload[0] {
        case 0xA1: return payload[1] == 1 ? capabilityQueryPayload : nil
        case 0xA3, 0xA5: return payload[1] == 1 ? statusQueryPayload : nil
        case 0xA6, 0xA7, 0xA8, 0xA9:
            if generation == .v1 {
                guard payload.count == (payload[0] == 0xA6 ? 3 : 4), payload[1...2] == [1, 0x20] else { return nil }
                return musicVolumeQueryPayload
            }
            return [1, 0x20, 0x21].contains(payload[1]) ? [0xA6, payload[1]] : nil
        default: return nil
        }
    }

    var volume: Int? {
        guard let reportedMusicVolume, musicVolumeRange?.contains(reportedMusicVolume) == true else { return nil }
        return reportedMusicVolume
    }

    var callVolume: Int? {
        guard let reportedCallVolume, callVolumeRange?.contains(reportedCallVolume) == true else { return nil }
        return reportedCallVolume
    }

    var canControl: Bool {
        generation == .v2 && isSupported && available == true && musicCallStatus == 0 && state != nil && state != .unsettled
    }

    var canControlMusicVolume: Bool {
        isSupported && available == true && (generation == .v1 || musicCallStatus == 0) && volume != nil
    }

    var canControlCallVolume: Bool {
        isSupported && available == true && musicCallStatus == 1 && callVolume != nil
    }

    func commandPayload(_ command: SonyPlaybackCommand) -> [UInt8]? {
        canControl ? [0xA4, 0x01, 0x00, command.rawValue] : nil
    }

    func volumePayload(_ value: Int) -> [UInt8]? {
        guard canControlMusicVolume, musicVolumeRange?.contains(value) == true else { return nil }
        return [0xA8] + musicVolumeQueryPayload.dropFirst() + [UInt8(value)]
    }

    func callVolumePayload(_ value: Int) -> [UInt8]? {
        guard canControlCallVolume, callVolumeRange?.contains(value) == true else { return nil }
        return [0xA8, 0x21, UInt8(value)]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 2 else { return false }
        if generation == .v1 {
            switch (payload[0], payload[1]) {
            case (0xA1, 0x01):
                guard payload.count == 5 else { return false }
                hasReceivedCapabilities = true
                musicVolumeRange = payload[2] > 0 ? 0...(Int(payload[2]) - 1) : nil
            case (0xA3, 0x01), (0xA5, 0x01):
                guard payload.count == 4 else { return false }
                available = payload[2] <= 1 ? payload[2] == 0 : nil
                state = SonyPlaybackState(rawValue: payload[3])
            case (0xA7, 0x01), (0xA9, 0x01):
                guard payload.count == 4, payload[2] == 0x20 else { return false }
                reportedMusicVolume = Int(payload[3])
            default: return false
            }
            return true
        }
        switch (payload[0], payload[1]) {
        case (0xA1, 0x01):
            guard payload.count == 4, payload[2] > 0, payload[3] > 0 else { return false }
            hasReceivedCapabilities = true
            musicVolumeRange = 0...(Int(payload[2]) - 1)
            callVolumeRange = 0...(Int(payload[3]) - 1)
        case (0xA3, 0x01), (0xA5, 0x01):
            guard payload.count == 5 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
            state = SonyPlaybackState(rawValue: payload[3])
            musicCallStatus = payload[4]
        case (0xA7, 0x01), (0xA9, 0x01):
            guard let track = SonyTrack(payload: payload) else { return false }
            self.track = track
        case (0xA7, 0x20), (0xA9, 0x20):
            guard payload.count == 3 else { return false }
            reportedMusicVolume = Int(payload[2])
        case (0xA7, 0x21), (0xA9, 0x21):
            guard payload.count == 3 else { return false }
            reportedCallVolume = Int(payload[2])
        default:
            return false
        }
        return true
    }
}
