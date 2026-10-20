#if !ACOUPLET_PUBLIC_APIS_ONLY
import Darwin
import Foundation

struct LDACUpdateHandoff: Sendable {
    struct Pending: Codable, Sendable {
        let id: UUID
        let address: String
        let previousPID: pid_t
        let createdAt: Date
        let configuration: Data?
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.baglayan.Acouplet")
            .appendingPathComponent("LDAC Update Handoff")
    }

    static func installerRequestsHandoff(now: Date = Date()) -> Bool {
        let request = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.baglayan.Acouplet/ldac-update-request")
        guard let text = try? String(contentsOf: request, encoding: .utf8) else { return false }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, let installer = pid_t(fields[0]), installer > 1,
              let timestamp = TimeInterval(fields[1]), (0...120).contains(now.timeIntervalSince1970 - timestamp),
              fields.dropFirst(2).contains(Substring(String(getpid()))), kill(installer, 0) == 0 else { return false }
        return true
    }

    func pending(now: Date = Date()) -> Pending? {
        guard let pending = readPending(), pending.previousPID != getpid(),
              (0...180).contains(now.timeIntervalSince(pending.createdAt)) else { return nil }
        return pending
    }

    func prepare(address: String, helper: URL, executable: URL, previousPID: pid_t = getpid(), configuration: Data? = nil) throws {
        try withLock {
            let pending = Pending(id: UUID(), address: address, previousPID: previousPID, createdAt: Date(), configuration: configuration)
            let recoveryDirectory = directory.appendingPathComponent(pending.id.uuidString)
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            do {
                try FileManager.default.copyItem(at: helper, to: recoveryDirectory.appendingPathComponent("SonyAudioConnection"))
                try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
                let process = Process()
                process.executableURL = executable
                process.arguments = ["--ldac-update-recovery", pending.id.uuidString]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: pendingURL)
                try? FileManager.default.removeItem(at: recoveryDirectory)
                throw error
            }
        }
    }

    func claim(address: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return false }
        return try withLock {
            guard let pending = readPending(), pending.address == address, pending.previousPID != getpid() else { return false }
            try FileManager.default.removeItem(at: pendingURL)
            return true
        }
    }

    func cancel(address: String) {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        try? withLock(wait: false) {
            guard readPending()?.address == address else { return }
            try FileManager.default.removeItem(at: pendingURL)
        }
    }

    func recover(id: UUID, timeout: TimeInterval = 60, parentIsRunning: (pid_t) -> Bool = { kill($0, 0) == 0 }) throws {
        let recoveryDirectory = directory.appendingPathComponent(id.uuidString)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        var deadline: Date?
        while true {
            let finished = try withLock {
                guard let pending = readPending(), pending.id == id else { return true }
                if parentIsRunning(pending.previousPID) {
                    if Date().timeIntervalSince(pending.createdAt) > 120 {
                        try FileManager.default.removeItem(at: pendingURL)
                        return true
                    }
                    return false
                }
                if deadline == nil { deadline = Date().addingTimeInterval(timeout) }
                guard Date() >= deadline! else { return false }
                let process = Process()
                process.executableURL = recoveryDirectory.appendingPathComponent("SonyAudioConnection")
                process.arguments = ["--address", pending.address, "--restore"]
                process.standardInput = FileHandle.nullDevice
                let log = recoveryDirectory.appendingPathComponent("recovery.log")
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                try FileManager.default.removeItem(at: pendingURL)
                NSLog("LDAC update fallback completed with status %d", process.terminationStatus)
                return true
            }
            if finished { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }

    private func readPending() -> Pending? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    private func withLock<T>(wait: Bool = true, _ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("handoff.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
#endif
