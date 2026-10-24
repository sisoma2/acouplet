import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
fixture = r"""
@MainActor
enum MacMediaPlayback {
    static func pause() {
        let path = ProcessInfo.processInfo.environment["PLAYBACK_CHECK_ROOT"]! + "/paused"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        precondition(descriptor >= 0)
        let record = "\(getpid())\n"
        record.withCString { pointer in
            precondition(write(descriptor, pointer, strlen(pointer)) == strlen(pointer))
        }
        close(descriptor)
    }
}

@main
@MainActor
enum PlaybackCheck {
    static func main() throws {
        let root = ProcessInfo.processInfo.environment["PLAYBACK_CHECK_ROOT"]!
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--media-playback-watch" {
            try String(getpid()).write(toFile: root + "/worker", atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["PLAYBACK_CHECK_DELAY"] == "1" {
                Thread.sleep(forTimeInterval: 0.5)
            }
            MacMediaPlaybackExitWorker.run(parent: pid_t(CommandLine.arguments[2])!)
            return
        }
        let lifetime = MacMediaPlaybackLifetime.shared
        lifetime.start()
        guard let command = readLine() else { return }
        switch command {
        case "quit", "restart":
            lifetime.pauseForTermination()
            lifetime.pauseForTermination()
            lifetime.finishTermination()
        case "cancel":
            lifetime.pauseForTermination()
            lifetime.cancelTermination()
            lifetime.pauseForTermination()
            lifetime.finishTermination()
        case "duplicate":
            lifetime.disarm()
        default:
            break
        }
    }
}
"""


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("Timed out waiting for playback exit handling")


def is_running(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


with tempfile.TemporaryDirectory(prefix="acouplet-playback-exit-") as temporary:
    directory = Path(temporary)
    swift = directory / "Check.swift"
    swift.write_text(
        (repo / "Sources/MacMediaPlaybackLifetime.swift").read_text() + fixture
    )
    executable = directory / "check"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-sdk",
            sdk,
            "-swift-version",
            "6",
            "-parse-as-library",
            str(swift),
            "-o",
            str(executable),
        ],
        check=True,
    )
    for mode in [
        "quit",
        "restart",
        "cancel",
        "duplicate",
        "unexpected",
        "term",
        "kill",
        "early-kill",
    ]:
        case = directory / mode
        case.mkdir()
        environment = {
            **os.environ,
            "PLAYBACK_CHECK_ROOT": str(case),
            "PLAYBACK_CHECK_DELAY": "1" if mode == "early-kill" else "0",
        }
        process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, text=True, env=environment
        )
        worker = None
        try:
            wait_for(
                lambda case=case: (
                    (case / "worker").exists() and (case / "worker").stat().st_size > 0
                )
            )
            worker = int((case / "worker").read_text())
            time.sleep(0.1)
            assert not (case / "paused").exists(), mode
            if mode in ["term", "kill", "early-kill"]:
                process.send_signal(
                    signal.SIGTERM if mode == "term" else signal.SIGKILL
                )
            else:
                process.stdin.write(mode + "\n")
                process.stdin.flush()
            process.wait(timeout=5)
            wait_for(lambda worker=worker: not is_running(worker))
            pauses = (
                (case / "paused").read_text().splitlines()
                if (case / "paused").exists()
                else []
            )
            expected = 0 if mode == "duplicate" else 2 if mode == "cancel" else 1
            assert len(pauses) == expected, (mode, pauses)
            if mode in ["quit", "restart", "cancel"]:
                assert all(int(pid) == process.pid for pid in pauses), (mode, pauses)
            elif expected:
                assert pauses == [str(worker)], (mode, pauses)
            print(f"PASS playback lifetime {mode}: {expected} pause request(s)")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdin.close()
            if worker is not None and is_running(worker):
                os.kill(worker, signal.SIGKILL)
