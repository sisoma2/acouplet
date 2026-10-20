import os
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / "Sources/LDACUpdateHandoff.swift").read_text()
fixture = r"""
@main
enum Check {
    static func main() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HANDOFF_CHECK_ROOT"]!)
        let store = LDACUpdateHandoff(directory: directory.appendingPathComponent("handoff"))
        if CommandLine.arguments.count == 3 {
            try store.recover(id: UUID(uuidString: CommandLine.arguments[2])!, timeout: 0.2, parentIsRunning: { _ in false })
            return
        }
        let helper = directory.appendingPathComponent("helper")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let pending = store.directory.appendingPathComponent("pending.json")
        let restored = directory.appendingPathComponent("restored")
        let address = "02-00-00-00-00-01"

        try store.prepare(address: address, helper: helper, executable: executable, previousPID: 99999)
        let wrongClaim = try store.claim(address: "02-00-00-00-00-02")
        precondition(!wrongClaim)
        let claimed = try store.claim(address: address)
        precondition(claimed)
        Thread.sleep(forTimeInterval: 0.6)
        precondition(!FileManager.default.fileExists(atPath: restored.path))
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        print("PASS replacement claims only its headphones and cancels fallback")

        try store.prepare(address: address, helper: helper, executable: executable, previousPID: 99999)
        store.cancel(address: address)
        Thread.sleep(forTimeInterval: 0.6)
        precondition(!FileManager.default.fileExists(atPath: restored.path))
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        print("PASS explicit disconnect and LDAC Off cancel the pending fallback")

        try store.prepare(address: address, helper: helper, executable: executable)
        let previousClaim = try store.claim(address: address)
        precondition(!previousClaim)
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: pending.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let restoredArguments = try String(contentsOf: restored, encoding: .utf8)
        precondition(restoredArguments == "--address \(address) --restore\n")
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        print("PASS absent replacement restores ordinary Bluetooth audio with the copied helper")

        try FileManager.default.removeItem(at: restored)
        try store.prepare(address: address, helper: helper, executable: URL(fileURLWithPath: "/usr/bin/true"))
        var ticket = try JSONDecoder().decode(LDACUpdateHandoff.Pending.self, from: Data(contentsOf: pending))
        ticket = .init(id: ticket.id, address: address, previousPID: getpid(), createdAt: Date().addingTimeInterval(-121), configuration: nil)
        try JSONEncoder().encode(ticket).write(to: pending, options: .atomic)
        try store.recover(id: ticket.id, timeout: 0, parentIsRunning: { _ in true })
        precondition(!FileManager.default.fileExists(atPath: restored.path))
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        print("PASS declined quit expires without interrupting the live app")

        do {
            try store.prepare(address: address, helper: helper, executable: directory.appendingPathComponent("missing"))
            preconditionFailure("Missing recovery executable accepted")
        } catch {}
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        print("PASS failed recovery launch leaves normal quit restoration enabled")
    }
}
"""

with tempfile.TemporaryDirectory(prefix="acouplet-update-handoff-") as temporary:
    directory = Path(temporary)
    swift = directory / "Check.swift"
    swift.write_text(source + fixture)
    helper = directory / "helper"
    helper.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" > "$HANDOFF_CHECK_ROOT/restored"\n'
    )
    helper.chmod(0o755)
    executable = directory / "check"
    environment = {**os.environ, "HANDOFF_CHECK_ROOT": str(directory)}
    subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-swift-version",
            "6",
            "-parse-as-library",
            str(swift),
            "-o",
            str(executable),
        ],
        check=True,
    )
    subprocess.run([str(executable)], check=True, env=environment, timeout=15)
