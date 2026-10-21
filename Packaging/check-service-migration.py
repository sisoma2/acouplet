import os
import plistlib
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
source = (repo / "Sources/SettingsStore.swift").read_text()
implementation = source[source.index("enum LegacyBackgroundService {") :].removesuffix(
    "#endif\n"
)
entry = (repo / "Sources/AppMain.swift").read_text()
helper_entry = (
    'if CommandLine.arguments.contains("--migrate-background-service") {'
    + entry.split(
        '        if CommandLine.arguments.contains("--migrate-background-service") {', 1
    )[1].split("        #endif", 1)[0]
)
assert "NSApplication" not in helper_entry
assert "handOffPlainLaunchToService" not in entry
assert (
    "LegacyBackgroundService.prepareInBackground"
    in (
        (repo / "Sources/AppDelegate.swift")
        .read_text()
        .split("    override init() {", 1)[1]
        .split("    func applicationWillFinishLaunching", 1)[0]
    )
)
domain = f"gui/{os.getuid()}"
label = "dev.baglayan.Acouplet.migration-check." + uuid.uuid4().hex
helper_label = label + ".helper"
preference_suite = label + ".preferences"
target = f"{domain}/{label}"
helper_target = f"{domain}/{helper_label}"


def ctl(*arguments):
    return subprocess.run(
        ["/bin/launchctl", *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )


def wait_for(predicate):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(
        "The disposable migration did not finish within twelve seconds"
    )


with tempfile.TemporaryDirectory(prefix="acouplet-service-migration-") as directory:
    root = Path(directory)
    binary = root / "migration"
    plist = root / f"Library/LaunchAgents/{label}.plist"
    plist.parent.mkdir(parents=True)
    implementation = (
        implementation.replace(
            'static let label = "dev.baglayan.Acouplet.agent"',
            f'static let label = "{label}"',
        )
        .replace(
            'static let migrationLabel = "dev.baglayan.Acouplet.agent.migration"',
            f'static let migrationLabel = "{helper_label}"',
        )
        .replace(
            'static let executablePath = "/Applications/Acouplet.app/Contents/MacOS/Acouplet"',
            f'static let executablePath = "{binary}"',
        )
        .replace("Bundle.main.bundleIdentifier", '"dev.baglayan.Acouplet"')
        .replace("Bundle.main.executableURL?.path", "Optional(executablePath)")
        .replace("NSHomeDirectory()", f'"{root}"')
        .replace(
            "FileManager.default.temporaryDirectory",
            f'URL(fileURLWithPath: "{root}")',
        )
        .replace(
            "UserDefaults.standard", f'UserDefaults(suiteName: "{preference_suite}")!'
        )
    )
    implementation = implementation.replace(
        "        let process = Process()\n",
        f'''        if executable == "/bin/launchctl", arguments.first == "bootstrap",
           FileManager.default.fileExists(atPath: "{root / "fail-bootstrap"}") {{ throw failure(91) }}
        if executable == "/bin/launchctl", arguments.first == "bootout",
           FileManager.default.fileExists(atPath: "{root / "fail-bootout"}") {{ throw failure(92) }}
        if executable == "/usr/bin/open" {{
            precondition(arguments == ["-n", "/Applications/Acouplet.app"])
            try Data("normal-app".utf8).write(to: URL(fileURLWithPath: "{root / "reopened"}"))
            return
        }}
        let process = Process()
''',
        1,
    )
    swift = root / "migration.swift"
    swift.write_text(
        "import Foundation\nimport AppKit\n"
        + f'''
enum SMAppService {{
    enum Status: Sendable {{ case enabled, notRegistered }}
    struct MainApp: Sendable {{ let status = Status.notRegistered }}
    static let mainApp = MainApp()
    static func statusForLegacyPlist(at url: URL) -> Status {{
        FileManager.default.fileExists(atPath: "{root / "disabled"}") ? .notRegistered : .enabled
    }}
}}
'''
        + implementation
        + f'''
final class Outcome: @unchecked Sendable {{
    var finished = false
    var error: (any Error)?
}}
@main
struct Check {{
    static func main() throws {{
        if ProcessInfo.processInfo.environment["FIXTURE_LEGACY_WORKER"] == "1" {{
            try Data("ready".utf8).write(to: URL(fileURLWithPath: "{root / "worker-ready"}"))
            RunLoop.main.run()
            return
        }}
        {helper_entry}
        let defaults = UserDefaults(suiteName: "{preference_suite}")!
        if CommandLine.arguments.contains("--cleanup") {{
            defaults.removePersistentDomain(forName: "{preference_suite}")
            return
        }}
        if CommandLine.arguments.contains("--retry") {{ defaults.removeObject(forKey: LegacyBackgroundService.attemptKey) }}
        let outcome = Outcome()
        let heartbeat = Timer(timeInterval: 0.05, repeats: true) {{ _ in }}
        RunLoop.main.add(heartbeat, forMode: .default)
        let migrating = LegacyBackgroundService.prepareInBackground(defaults: defaults) {{ error in
            precondition(Thread.isMainThread)
            outcome.error = error
            outcome.finished = true
        }}
        precondition(!outcome.finished)
        while migrating && !outcome.finished {{
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }}
        heartbeat.invalidate()
        if let error = outcome.error {{ throw error }}
        let key = LegacyBackgroundService.launchAtLoginPreferenceKey
        if let value = defaults.object(forKey: key) as? Bool {{ print("launchAtLogin=\\(value)") }}
        print("normal-startup-completed")
    }}
}}
'''
    )
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-swift-version",
            "6",
            "-parse-as-library",
            str(swift),
            "-o",
            str(binary),
        ],
        check=True,
        timeout=60,
    )

    def invoke(*arguments, successful=True):
        result = subprocess.run(
            [str(binary), *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert (result.returncode == 0) == successful, result.stdout + result.stderr
        return result

    def configure(keepalive, worker=False):
        invoke("--cleanup")
        (root / "reopened").unlink(missing_ok=True)
        (root / "worker-ready").unlink(missing_ok=True)
        plist.write_bytes(
            plistlib.dumps(
                {
                    "Label": label,
                    "RunAtLoad": True,
                    "KeepAlive": keepalive,
                    "ProgramArguments": [str(binary), "--background-service"],
                    "EnvironmentVariables": {"FIXTURE_LEGACY_WORKER": "1"}
                    if worker
                    else {},
                }
            )
        )

    try:
        invoke()
        assert not plist.exists()
        for enabled in (True, False):
            configure(True)
            if not enabled:
                (root / "disabled").touch()
            result = invoke()
            assert f"launchAtLogin={str(enabled).lower()}" in result.stdout
            assert not plist.exists() and ctl("print", target).returncode != 0
            (root / "disabled").unlink(missing_ok=True)
            wait_for(lambda: ctl("print", helper_target).returncode != 0)
        configure(True, worker=True)
        assert ctl("bootstrap", domain, str(plist)).returncode == 0
        wait_for(lambda: (root / "worker-ready").exists())
        invoke()
        assert not plist.exists() and ctl("print", target).returncode != 0
        wait_for(lambda: ctl("print", helper_target).returncode != 0)
        for keepalive in (True, {"SuccessfulExit": False}):
            configure(keepalive)
            assert ctl("bootstrap", domain, str(plist)).returncode == 0
            wait_for(lambda: (root / "reopened").exists())
            assert not plist.exists() and ctl("print", target).returncode != 0
            wait_for(lambda: ctl("print", helper_target).returncode != 0)
            result = invoke()
            assert "launchAtLogin=true" in result.stdout
        for failure in ("fail-bootstrap", "fail-bootout"):
            configure(True, worker=True)
            if failure == "fail-bootout":
                assert ctl("bootstrap", domain, str(plist)).returncode == 0
                wait_for(lambda: (root / "worker-ready").exists())
            before = plist.read_bytes()
            (root / failure).touch()
            invoke(successful=False)
            assert plist.read_bytes() == before
            if failure == "fail-bootout":
                assert ctl("print", target).returncode == 0
            (root / failure).unlink()
            wait_for(lambda: ctl("print", helper_target).returncode != 0)
            invoke("--retry")
            assert not plist.exists()
            wait_for(lambda: ctl("print", helper_target).returncode != 0)
        configure(True)
        foreign = plistlib.loads(plist.read_bytes())
        foreign["Program"] = "/bin/sh"
        plist.write_bytes(plistlib.dumps(foreign))
        before = plist.read_bytes()
        invoke(successful=False)
        assert plist.read_bytes() == before
        plist.unlink()
        unrelated = root / "unrelated.plist"
        unrelated.write_bytes(before)
        plist.symlink_to(unrelated)
        invoke(successful=False)
        assert plist.is_symlink() and unrelated.read_bytes() == before
        plist.unlink()
        invoke("--migrate-background-service", successful=False)
        assert not list(root.glob(helper_label + ".*"))
    finally:
        ctl("bootout", target)
        ctl("bootout", helper_target)
        invoke("--cleanup")
print(
    "Legacy service retirement passed: normal and managed startup, login preference, real launchd removal, failure/retry and ownership checks."
)
