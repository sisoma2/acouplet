#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Darwin
import Foundation
import OSLog

struct SonyNativeBatteryPublication: Equatable, Codable {
    struct Part: Equatable, Codable {
        let level: Int
        let isCharging: Bool
        let observedAt: TimeInterval

        init(_ reading: SonyNativeBatterySnapshot.Reading) {
            level = reading.level
            isCharging = reading.isCharging
            observedAt = reading.observedAt.timeIntervalSince1970
        }
    }

    struct Identity: Hashable {
        let address: String
        let identifier: UUID
        let controlSession: UInt64
    }

    let address: String
    let identifier: UUID
    let controlSession: UInt64
    let name: String
    let left: Part
    let right: Part
    var caseBattery: Part?

    var identity: Identity { Identity(address: address, identifier: identifier, controlSession: controlSession) }
    var expiresAt: Date { Date(timeIntervalSince1970: min(left.observedAt, right.observedAt) + 45) }

    init?(address: String, controlSession: UInt64, snapshot: SonyNativeBatterySnapshot, at date: Date) {
        guard let address = SonyBLEIdentity.normalizedAddress(address),
              let left = snapshot.left, let right = snapshot.right,
              left.level > 0, right.level > 0,
              left.isFresh(at: date), right.isFresh(at: date) else { return nil }
        self.address = address
        identifier = snapshot.identifier
        self.controlSession = controlSession
        name = snapshot.name
        self.left = Part(left)
        self.right = Part(right)
        caseBattery = snapshot.caseBattery.flatMap { $0.isFresh(at: date) ? Part($0) : nil }
    }

    func canReplace(_ previous: Self) -> Bool {
        let samePair = left == previous.left && right == previous.right
        let newerPair = left.observedAt > previous.left.observedAt && right.observedAt > previous.right.observedAt
        let validCase = caseBattery == previous.caseBattery
            || (caseBattery.map { $0.observedAt > (previous.caseBattery?.observedAt ?? -.infinity) } ?? true)
        return identity == previous.identity && (samePair || newerPair) && validCase
            && (!samePair || caseBattery != previous.caseBattery)
    }

    func withdrawingExpiredCase(at date: Date) -> Self {
        var value = self
        if let caseBattery, date.timeIntervalSince1970 >= caseBattery.observedAt + 45 { value.caseBattery = nil }
        return value
    }
}

struct SonyNativeCaseBatteryPublication: Equatable, Codable {
    let address: String
    let identifier: UUID
    let controlSession: UInt64
    let name: String
    let caseBattery: SonyNativeBatteryPublication.Part

    var identity: SonyNativeBatteryPublication.Identity {
        SonyNativeBatteryPublication.Identity(address: address, identifier: identifier, controlSession: controlSession)
    }
    var expiresAt: Date { Date(timeIntervalSince1970: caseBattery.observedAt + 45) }

    init?(address: String, controlSession: UInt64, snapshot: SonyNativeBatterySnapshot, at date: Date) {
        guard let address = SonyBLEIdentity.normalizedAddress(address),
              let caseBattery = snapshot.caseBattery, caseBattery.isFresh(at: date) else { return nil }
        self.address = address
        identifier = snapshot.identifier
        self.controlSession = controlSession
        name = snapshot.name
        self.caseBattery = SonyNativeBatteryPublication.Part(caseBattery)
    }

    func canReplace(_ previous: Self) -> Bool {
        identity == previous.identity && caseBattery.observedAt > previous.caseBattery.observedAt
    }
}

@MainActor
final class SonyNativeBatteryPublisher {
    struct Connection {
        let send: (Data) throws -> Void
        let close: () -> Void
        let isRunning: () -> Bool
        var didExitWithoutPublishing: () -> Bool = { false }
        var didExitSuccessfully: () -> Bool = { false }
        var didWithdrawAfterNativeDisconnect: () -> Bool = { false }
        var exitStatus: () -> Int32? = { nil }
        var didWithdrawAfterLeaseExpiry: () -> Bool = { false }
    }

    private struct Session {
        let connection: Connection
        let attempt: Int
        var publication: SonyNativeBatteryPublication
        var pending: SonyNativeBatteryPublication?
        var queued: SonyNativeBatteryPublication?
        var update: UInt64 = 0
        var acknowledgmentDeadline: Date?
        var acknowledgmentExpiry: AnyCancellable?
        var expiry: AnyCancellable?
        var caseExpiry: AnyCancellable?
        var lastCaseObservation: TimeInterval?
        var output = Data()
    }

    private struct Attempt {
        let publication: SonyNativeBatteryPublication
        let date: Date
        let count: Int
        var retryCount = 1
        var retry = false
        var resumeAfterWithdrawal = false
        var exitedSuccessfully = false
        var withdrewAfterNativeDisconnect = false
    }

    private struct Acknowledgment: Decodable {
        let sample: SonyNativeBatteryPublication
        let update: UInt64
    }

    private struct CaseSession {
        let connection: Connection
        let attempt: Int
        var publication: SonyNativeCaseBatteryPublication
        var pending: SonyNativeCaseBatteryPublication?
        var queued: SonyNativeCaseBatteryPublication?
        var update: UInt64 = 0
        var expiry: AnyCancellable?
        var acknowledgmentExpiry: AnyCancellable?
        var acknowledgmentDeadline: Date?
        var output = Data()
        var closing = false
        var outputComplete = false
        var protocolFailed = false
        var resumeAfterWithdrawal = false
        var allowPrerequisiteRetry = true
    }

    private struct CaseAttempt {
        let publication: SonyNativeCaseBatteryPublication
        let date: Date
        let count: Int
        var successful = false
        var retry = false
        var resumeAfterWithdrawal = false
    }

    private struct CaseAcknowledgment: Decodable {
        let sample: SonyNativeCaseBatteryPublication
        let update: UInt64
    }

    private let launchCase: (SonyNativeCaseBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection
    private var caseSessions: [String: CaseSession] = [:]
    private var caseAttempts: [String: CaseAttempt] = [:]
    private let launch: (SonyNativeBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection
    private let schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable
    private let now: () -> Date
    private var sessions: [String: Session] = [:]
    private var closing: [String: (connection: Connection, publication: SonyNativeBatteryPublication, date: Date, retry: Bool, resumeAfterWithdrawal: Bool, attempt: Int, output: Data, outputComplete: Bool, protocolFailed: Bool, allowLeaseExpiryResume: Bool)] = [:]
    private var attempts: [String: Attempt] = [:]
    private var isStopped = false
    private static let maximumSubmissionAge: TimeInterval = 18
    private static let minimumSubmissionLifetime = 45 - maximumSubmissionAge
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "NativeBatteryPublisher")

    var ownedAddresses: Set<String> { Set(sessions.keys) }
    var ownedCaseAddresses: Set<String> { Set(caseSessions.filter { !$0.value.closing }.keys) }

    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable = SonyNativeBatteryPublisher.scheduleExpiry,
         launchCase: @escaping (SonyNativeCaseBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection,
         launch: @escaping (SonyNativeBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection) {
        self.now = now
        self.schedule = schedule
        self.launch = launch
        self.launchCase = launchCase
    }

    convenience init(executableURL: URL) {
        self.init(launchCase: { publication, receive in
            let pipe = try SonyNativeBatteryPipe(executableURL: executableURL,
                arguments: ["--case", publication.identifier.uuidString, UUID().uuidString], receive: receive)
            return Connection(send: pipe.send, close: pipe.close, isRunning: { pipe.process.isRunning }, didExitWithoutPublishing: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 75
            }, didExitSuccessfully: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && [0, 76].contains(pipe.process.terminationStatus)
            }, didWithdrawAfterNativeDisconnect: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 76
            }, exitStatus: { pipe.process.isRunning ? nil : pipe.process.terminationStatus })
        }) { publication, receive in
            let pipe = try SonyNativeBatteryPipe(executableURL: executableURL,
                arguments: ["--publish", publication.identifier.uuidString, UUID().uuidString], receive: receive)
            return Connection(send: pipe.send, close: pipe.close, isRunning: { pipe.process.isRunning }, didExitWithoutPublishing: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 75
            }, didExitSuccessfully: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && [0, 76, 78].contains(pipe.process.terminationStatus)
            }, didWithdrawAfterNativeDisconnect: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 76
            }, exitStatus: {
                pipe.process.isRunning ? nil : pipe.process.terminationStatus
            }, didWithdrawAfterLeaseExpiry: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 78
            })
        }
    }

    func reconcile(_ publications: [SonyNativeBatteryPublication], cases: [SonyNativeCaseBatteryPublication] = []) {
        let date = now()
        let publications = publications.map { publication in
            var value = publication.withdrawingExpiredCase(at: date)
            let session = sessions[value.address]
            let latest = session?.queued ?? session?.pending ?? session?.publication
            if let caseBattery = value.caseBattery, caseBattery != latest?.caseBattery,
               date.timeIntervalSince1970 - caseBattery.observedAt > Self.maximumSubmissionAge {
                value.caseBattery = latest?.identity == value.identity ? latest?.withdrawingExpiredCase(at: date).caseBattery : nil
            }
            return value
        }
        guard !isStopped else { return }
        reconcileCases(cases, at: date)
        let current = Dictionary(uniqueKeysWithValues: publications.map { ($0.address, $0) })
        for address in Array(sessions.keys) {
            guard let session = sessions[address] else { continue }
            guard session.connection.didExitWithoutPublishing()
                || (session.publication.expiresAt > date && (session.acknowledgmentDeadline.map({ date < $0 }) ?? true)) else {
                close(address)
                continue
            }
            if !session.connection.isRunning() {
                close(address, retryIfUnpublished: true)
                continue
            }
            guard var publication = current[address] else {
                close(address, resumeAfterWithdrawal: true)
                continue
            }
            guard publication.expiresAt > date else {
                close(address)
                continue
            }
            guard publication.identity == session.publication.identity else {
                close(address, resumeAfterWithdrawal: true)
                continue
            }
            let latest = session.queued ?? session.pending ?? session.publication
            if publication.identity == latest.identity, publication.left == latest.left, publication.right == latest.right, publication.caseBattery == latest.caseBattery { continue }
            if let caseBattery = publication.caseBattery, caseBattery != latest.caseBattery,
               caseBattery.observedAt <= (session.lastCaseObservation ?? -.infinity) {
                publication.caseBattery = latest.caseBattery
            }
            if publication.left == latest.left, publication.right == latest.right, publication.caseBattery == latest.caseBattery { continue }
            guard publication.canReplace(latest) else { close(address); continue }
            if let caseBattery = publication.caseBattery { sessions[address]?.lastCaseObservation = caseBattery.observedAt }
            if session.pending != nil {
                sessions[address]?.queued = publication
            } else {
                send(publication)
            }
        }
        for address in Array(closing.keys) {
            guard let retired = closing[address], !retired.connection.isRunning(), retired.outputComplete else { continue }
            let disconnected = retired.connection.didWithdrawAfterNativeDisconnect()
            let successful = !retired.protocolFailed && retired.connection.didExitSuccessfully()
                && (!disconnected || retired.retry || retired.resumeAfterWithdrawal)
            let expiredLease = retired.allowLeaseExpiryResume && retired.connection.didWithdrawAfterLeaseExpiry()
            if (disconnected || expiredLease) && successful, let previous = attempts[address] {
                attempts[address] = Attempt(publication: retired.publication, date: retired.date, count: previous.count)
            }
            attempts[address]?.retry = !retired.protocolFailed && retired.retry && retired.connection.didExitWithoutPublishing()
            attempts[address]?.exitedSuccessfully = successful
            attempts[address]?.withdrewAfterNativeDisconnect = disconnected && successful
            attempts[address]?.resumeAfterWithdrawal = (retired.resumeAfterWithdrawal || (retired.retry && disconnected)
                || expiredLease) && successful
            Self.logger.info("Native battery helper retired: status=\(retired.connection.exitStatus() ?? -1, privacy: .public) successful=\(successful, privacy: .public) protocolFailed=\(retired.protocolFailed, privacy: .public) disconnected=\(disconnected, privacy: .public) resume=\(self.attempts[address]?.resumeAfterWithdrawal == true, privacy: .public)")
            closing.removeValue(forKey: address)
        }
        for publication in publications where sessions[publication.address] == nil && closing[publication.address] == nil {
            guard publication.expiresAt.timeIntervalSince(date) >= Self.minimumSubmissionLifetime else { continue }
            let previous = attempts[publication.address]
            if let previous, previous.resumeAfterWithdrawal || previous.publication.identity == publication.identity || !previous.exitedSuccessfully {
                guard previous.resumeAfterWithdrawal || (previous.retry && previous.retryCount < 3),
                      date.timeIntervalSince(previous.date) >= 15,
                      publication.left.observedAt > previous.publication.left.observedAt,
                      publication.right.observedAt > previous.publication.right.observedAt else { continue }
            }
            let attempt = (previous?.count ?? 0) + 1
            attempts[publication.address] = Attempt(publication: publication, date: date, count: attempt,
                retryCount: previous?.exitedSuccessfully == true ? 1 : (previous?.retryCount ?? 0) + 1)
            do {
                let connection = try launch(publication) { [weak self] data in
                    self?.receive(data, identity: publication.identity, attempt: attempt)
                }
                sessions[publication.address] = Session(connection: connection, attempt: attempt, publication: publication, lastCaseObservation: publication.caseBattery?.observedAt)
                setExpiry(publication)
                send(publication)
            } catch {
                Self.logger.error("Native battery launch failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func revoke() {
        for address in Array(caseSessions.keys) { closeCase(address) }
        for address in Array(caseSessions.keys) {
            caseSessions[address]?.resumeAfterWithdrawal = false
            caseSessions[address]?.allowPrerequisiteRetry = false
        }
        for address in Array(caseAttempts.keys) {
            caseAttempts[address]?.resumeAfterWithdrawal = false
            caseAttempts[address]?.retry = false
        }
        for address in Array(sessions.keys) { close(address) }
        for address in Array(closing.keys) {
            closing[address]?.retry = false
            closing[address]?.resumeAfterWithdrawal = false
            closing[address]?.allowLeaseExpiryResume = false
        }
        for address in Array(attempts.keys) {
            if attempts[address]?.withdrewAfterNativeDisconnect == true { attempts[address]?.exitedSuccessfully = false }
            attempts[address]?.retry = false
            attempts[address]?.resumeAfterWithdrawal = false
        }
    }

    func stop() {
        isStopped = true
        revoke()
    }

    private func send(_ publication: SonyNativeBatteryPublication) {
        var publication = publication
        let address = publication.address, date = now()
        guard let session = sessions[address], session.publication.expiresAt > date else { close(address); return }
        guard (session.update > 0 && publication.left == session.publication.left && publication.right == session.publication.right)
            || publication.expiresAt.timeIntervalSince(date) >= Self.minimumSubmissionLifetime else {
            if session.update == 0 { close(address, retryIfUnpublished: true) }
            return
        }
        if let caseBattery = publication.caseBattery, caseBattery != session.publication.caseBattery,
           date.timeIntervalSince1970 - caseBattery.observedAt > Self.maximumSubmissionAge {
            publication.caseBattery = session.publication.withdrawingExpiredCase(at: date).caseBattery
            if publication == session.publication { return }
        }
        do {
            var data = try JSONEncoder().encode(publication)
            data.append(0x0A)
            let deadline = min(date.addingTimeInterval(10), session.publication.expiresAt)
            sessions[address]?.pending = publication
            sessions[address]?.update += 1
            sessions[address]?.acknowledgmentDeadline = deadline
            sessions[address]?.acknowledgmentExpiry = schedule(deadline) { [weak self] in
                guard let self, self.sessions[address]?.pending == publication else { return }
                self.close(address)
            }
            try session.connection.send(data)
        } catch {
            Self.logger.error("Native battery update failed: \(error.localizedDescription, privacy: .private)")
            close(address)
        }
    }

    private func receive(_ data: Data, identity: SonyNativeBatteryPublication.Identity, attempt: Int) {
        let address = identity.address
        if let retired = closing[address], retired.publication.identity == identity, retired.attempt == attempt {
            if data.isEmpty {
                closing[address]?.outputComplete = true
                if !retired.output.isEmpty { closing[address]?.protocolFailed = true }
                return
            }
            closing[address]?.output.append(data)
            while let newline = closing[address]?.output.firstIndex(of: 0x0A) {
                guard let line = closing[address]?.output.prefix(upTo: newline) else { return }
                closing[address]?.output.removeSubrange(...newline)
                guard line.count <= 8192, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    closing[address]?.protocolFailed = true
                    continue
                }
                logHelperEvent(object)
            }
            if let count = closing[address]?.output.count, count > 8192 {
                closing[address]?.protocolFailed = true
                closing[address]?.output = Data()
            }
            return
        }
        guard let session = sessions[address], session.publication.identity == identity, session.attempt == attempt else { return }
        let date = now()
        guard session.connection.didExitWithoutPublishing()
            || (session.publication.expiresAt > date && (session.acknowledgmentDeadline.map({ date < $0 }) ?? true)) else { close(address, outputComplete: data.isEmpty); return }
        guard !data.isEmpty else { close(address, retryIfUnpublished: session.output.isEmpty, outputComplete: true, protocolFailed: !session.output.isEmpty); return }
        sessions[address]?.output.append(data)
        while let newline = sessions[address]?.output.firstIndex(of: 0x0A) {
            guard let line = sessions[address]?.output.prefix(upTo: newline), line.count <= 8192 else { close(address, protocolFailed: true); return }
            sessions[address]?.output.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { close(address, protocolFailed: true); return }
            logHelperEvent(object)
            guard object["event"] as? String == "refresh-completed" else { continue }
            guard let sample = object["sample"] as? [String: Any],
                  Set(sample.keys) == Set(["address", "identifier", "controlSession", "name", "left", "right"]
                    + (sample["caseBattery"] == nil ? [] : ["caseBattery"])),
                  (["left", "right"] + (sample["caseBattery"] == nil ? [] : ["caseBattery"])).allSatisfy({ key in
                      guard let part = sample[key] as? [String: Any] else { return false }
                      return Set(part.keys) == ["level", "isCharging", "observedAt"]
                  }),
                  let acknowledgment = try? JSONDecoder().decode(Acknowledgment.self, from: Data(line)),
                  let session = sessions[address], let pending = session.pending,
                  acknowledgment.sample == pending, acknowledgment.update == session.update,
                  let deadline = session.acknowledgmentDeadline,
                  now() < deadline, now() < session.publication.expiresAt else { close(address, protocolFailed: true); return }
            guard session.connection.isRunning() else {
                sessions[address]?.output = Data()
                close(address, retryIfUnpublished: true)
                if !session.output.isEmpty { receive(session.output, identity: identity, attempt: attempt) }
                return
            }
            session.acknowledgmentExpiry?.cancel()
            sessions[address]?.acknowledgmentExpiry = nil
            sessions[address]?.acknowledgmentDeadline = nil
            sessions[address]?.pending = nil
            sessions[address]?.queued = nil
            sessions[address]?.publication = pending
            setExpiry(pending)
            if let queued = session.queued { send(queued) }
        }
        if let count = sessions[address]?.output.count, count > 8192 { close(address, protocolFailed: true) }
    }

    private func logHelperEvent(_ object: [String: Any]) {
        let report = object["event"] as? String == "child-report" ? object["report"] as? [String: Any] : object
        guard let report, let event = report["event"] as? String,
              ["guard-lost", "native-unavailable", "native-disconnected", "components-absent", "source-disposal-unconfirmed", "final-inventory", "child-exit", "supervisor-exit", "child-terminated", "prerequisite-unavailable"].contains(event) else { return }
        let phase = report["phase"] as? String ?? "none"
        let knownPhase = ["child", "supervisor", "supervisor-refresh"].contains(phase) ? phase : "none"
        Self.logger.info("Native battery withdrawal: event=\(event, privacy: .public) phase=\(knownPhase, privacy: .public) result=\((report["result"] as? Int) ?? -1, privacy: .public) status=\((report["status"] as? Int) ?? -1, privacy: .public) nativeSingle=\((report["nativeSingle"] as? Bool) ?? false, privacy: .public) disconnected=\((report["nativeDisconnected"] as? Bool) ?? false, privacy: .public)")
    }

    private func setExpiry(_ publication: SonyNativeBatteryPublication) {
        sessions[publication.address]?.expiry?.cancel()
        sessions[publication.address]?.caseExpiry?.cancel()
        sessions[publication.address]?.expiry = schedule(publication.expiresAt) { [weak self] in
            guard let self, self.sessions[publication.address]?.publication == publication else { return }
            self.close(publication.address)
        }
        if let caseBattery = publication.caseBattery {
            sessions[publication.address]?.caseExpiry = schedule(Date(timeIntervalSince1970: caseBattery.observedAt + 45)) { [weak self] in
                guard let self, let session = self.sessions[publication.address] else { return }
                let latest = session.queued ?? session.pending ?? session.publication
                let next = latest.withdrawingExpiredCase(at: self.now())
                guard next != latest else { return }
                if session.pending != nil { self.sessions[publication.address]?.queued = next }
                else { self.send(next) }
            }
        }
    }

    private func close(_ address: String, retryIfUnpublished: Bool = false, resumeAfterWithdrawal: Bool = false, outputComplete: Bool = false, protocolFailed: Bool = false) {
        guard let session = sessions.removeValue(forKey: address) else { return }
        session.expiry?.cancel()
        session.caseExpiry?.cancel()
        session.acknowledgmentExpiry?.cancel()
        session.connection.close()
        if resumeAfterWithdrawal {
            attempts[address] = Attempt(publication: session.queued ?? session.pending ?? session.publication,
                date: now(), count: session.attempt)
        }
        let sampleExpired = session.pending == nil && session.publication.expiresAt <= now()
        let classification = resumeAfterWithdrawal ? "intentional-withdrawal" : retryIfUnpublished ? "process-exit" : sampleExpired ? "sample-expired" : "failure"
        Self.logger.info("Native battery closing: classification=\(classification, privacy: .public)")
        closing[address] = (session.connection, session.queued ?? session.pending ?? session.publication, now(), retryIfUnpublished, resumeAfterWithdrawal, session.attempt, session.output, outputComplete, protocolFailed, true)
    }

    private func reconcileCases(_ publications: [SonyNativeCaseBatteryPublication], at date: Date) {
        let current = Dictionary(uniqueKeysWithValues: publications.map { ($0.address, $0) })
        for address in Array(caseSessions.keys) {
            guard let session = caseSessions[address] else { continue }
            if session.closing {
                guard !session.connection.isRunning(), session.outputComplete else { continue }
                caseAttempts[address]?.successful = !session.protocolFailed && session.connection.didExitSuccessfully()
                caseAttempts[address]?.retry = !session.protocolFailed && session.allowPrerequisiteRetry && session.connection.didExitWithoutPublishing()
                caseAttempts[address]?.resumeAfterWithdrawal = session.resumeAfterWithdrawal
                caseSessions.removeValue(forKey: address)
                continue
            }
            guard session.publication.expiresAt > date else { closeCase(address, resumeAfterWithdrawal: true); continue }
            guard session.acknowledgmentDeadline.map({ date < $0 }) ?? true else { closeCase(address); continue }
            guard session.connection.isRunning() else {
                closeCase(address, resumeAfterWithdrawal: session.connection.didExitWithoutPublishing()
                    || session.connection.didWithdrawAfterNativeDisconnect())
                continue
            }
            guard let publication = current[address], publication.identity == session.publication.identity else {
                closeCase(address, resumeAfterWithdrawal: true)
                continue
            }
            let latest = session.queued ?? session.pending ?? session.publication
            if publication.identity == latest.identity, publication.caseBattery == latest.caseBattery { continue }
            guard publication.canReplace(latest) else { closeCase(address); continue }
            if session.pending != nil { caseSessions[address]?.queued = publication }
            else { sendCase(publication) }
        }
        for publication in publications where caseSessions[publication.address] == nil {
            guard publication.expiresAt.timeIntervalSince(date) >= Self.minimumSubmissionLifetime else { continue }
            let previous = caseAttempts[publication.address]
            if let previous {
                guard previous.successful || previous.retry,
                      previous.retry || previous.resumeAfterWithdrawal || previous.publication.identity != publication.identity,
                      date.timeIntervalSince(previous.date) >= 15,
                      publication.caseBattery.observedAt > previous.publication.caseBattery.observedAt else { continue }
            }
            let attempt = (previous?.count ?? 0) + 1
            caseAttempts[publication.address] = CaseAttempt(publication: publication, date: date, count: attempt)
            do {
                let connection = try launchCase(publication) { [weak self] data in
                    self?.receiveCase(data, identity: publication.identity, attempt: attempt)
                }
                caseSessions[publication.address] = CaseSession(connection: connection, attempt: attempt, publication: publication)
                setCaseExpiry(publication)
                sendCase(publication)
            } catch {
                Self.logger.error("Native Case battery launch failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func sendCase(_ publication: SonyNativeCaseBatteryPublication) {
        let address = publication.address, date = now()
        guard let session = caseSessions[address], !session.closing, session.publication.expiresAt > date else { closeCase(address); return }
        guard publication.expiresAt.timeIntervalSince(date) >= Self.minimumSubmissionLifetime else {
            if session.update == 0 { closeCase(address) }
            return
        }
        do {
            var data = try JSONEncoder().encode(publication)
            data.append(0x0A)
            let deadline = min(date.addingTimeInterval(10), session.publication.expiresAt)
            caseSessions[address]?.pending = publication
            caseSessions[address]?.update += 1
            caseSessions[address]?.acknowledgmentDeadline = deadline
            caseSessions[address]?.acknowledgmentExpiry = schedule(deadline) { [weak self] in
                guard let self, self.caseSessions[address]?.pending == publication else { return }
                self.closeCase(address)
            }
            try session.connection.send(data)
        } catch { closeCase(address) }
    }

    private func receiveCase(_ data: Data, identity: SonyNativeBatteryPublication.Identity, attempt: Int) {
        let address = identity.address
        guard let session = caseSessions[address], session.publication.identity == identity, session.attempt == attempt else { return }
        if data.isEmpty {
            closeCase(address, resumeAfterWithdrawal: session.connection.didExitWithoutPublishing()
                || session.connection.didWithdrawAfterNativeDisconnect() || (session.publication.expiresAt <= now() && session.pending == nil))
            caseSessions[address]?.outputComplete = true
            if !session.output.isEmpty { caseSessions[address]?.protocolFailed = true }
            return
        }
        caseSessions[address]?.output.append(data)
        while let newline = caseSessions[address]?.output.firstIndex(of: 0x0A) {
            guard let line = caseSessions[address]?.output.prefix(upTo: newline), line.count <= 8192,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                closeCase(address, protocolFailed: true)
                return
            }
            caseSessions[address]?.output.removeSubrange(...newline)
            guard let session = caseSessions[address], !session.closing,
                  object["event"] as? String == "refresh-completed" else { continue }
            guard let sample = object["sample"] as? [String: Any],
                  Set(sample.keys) == ["address", "identifier", "controlSession", "name", "caseBattery"],
                  let part = sample["caseBattery"] as? [String: Any], Set(part.keys) == ["level", "isCharging", "observedAt"],
                  let acknowledgment = try? JSONDecoder().decode(CaseAcknowledgment.self, from: Data(line)),
                  let pending = session.pending, acknowledgment.sample == pending, acknowledgment.update == session.update,
                  let deadline = session.acknowledgmentDeadline, now() < deadline,
                  now() < session.publication.expiresAt else {
                closeCase(address, protocolFailed: true)
                return
            }
            guard session.connection.isRunning() else {
                closeCase(address, resumeAfterWithdrawal: session.connection.didWithdrawAfterNativeDisconnect()
                    || session.connection.didExitWithoutPublishing())
                continue
            }
            session.acknowledgmentExpiry?.cancel()
            caseSessions[address]?.acknowledgmentExpiry = nil
            caseSessions[address]?.acknowledgmentDeadline = nil
            caseSessions[address]?.publication = pending
            caseSessions[address]?.pending = nil
            caseSessions[address]?.queued = nil
            setCaseExpiry(pending)
            if let queued = session.queued { sendCase(queued) }
        }
        if let count = caseSessions[address]?.output.count, count > 8192 { closeCase(address, protocolFailed: true) }
    }

    private func setCaseExpiry(_ publication: SonyNativeCaseBatteryPublication) {
        caseSessions[publication.address]?.expiry?.cancel()
        caseSessions[publication.address]?.expiry = schedule(publication.expiresAt) { [weak self] in
            guard let self, self.caseSessions[publication.address]?.publication == publication else { return }
            self.closeCase(publication.address, resumeAfterWithdrawal: true)
        }
    }

    private func closeCase(_ address: String, resumeAfterWithdrawal: Bool = false, protocolFailed: Bool = false) {
        guard let session = caseSessions[address] else { return }
        if protocolFailed { caseSessions[address]?.protocolFailed = true }
        guard !session.closing else { return }
        session.expiry?.cancel()
        session.acknowledgmentExpiry?.cancel()
        caseSessions[address]?.closing = true
        caseSessions[address]?.resumeAfterWithdrawal = resumeAfterWithdrawal
        caseAttempts[address] = CaseAttempt(publication: session.queued ?? session.pending ?? session.publication,
            date: now(), count: session.attempt)
        session.connection.close()
    }

    private static func scheduleExpiry(_ date: Date, action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}

final class SonyNativeBatteryPipe {
    let process = Process()
    private var input: FileHandle?
    private var output: FileHandle?

    init(executableURL: URL, arguments: [String], receive: @escaping @MainActor @Sendable (Data) -> Void = { _ in }) throws {
        let pipe = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        input = pipe.fileHandleForWriting
        self.output = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { receive(data) }
        }
        try pipe.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }

    func send(_ data: Data) throws {
        guard let input, process.isRunning else { throw POSIXError(.EPIPE) }
        try input.write(contentsOf: data)
    }

    func close() {
        try? input?.close()
        input = nil
    }

    deinit {
        close()
        output?.readabilityHandler = nil
        try? output?.close()
    }
}
#endif
