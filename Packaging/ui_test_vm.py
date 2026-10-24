import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path


def require_guest():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 or result.stdout.strip() != "1":
        raise ValueError(
            "GUI tests require an isolated macOS VM. Apple XCTest automation has crashed Code, Chrome and Finder on this desktop. Use --ui-vm NAME with a prepared local Tart VM, or run the GUI suite inside a macOS guest. See Docs/GUIIsolation.md. No GUI automation was started."
        )


def validate_vm(name):
    if not name or name.startswith("-") or "/" in name:
        raise ValueError("--ui-vm must name a prepared local Tart VM.")
    tart = shutil.which("tart")
    if tart is None:
        raise ValueError(
            "Tart is required for --ui-vm. Install Tart and prepare a macOS VM with Xcode; see Docs/GUIIsolation.md."
        )
    result = subprocess.run(
        [tart, "list", "--source", "local", "--format", "json"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    matches = [vm for vm in json.loads(result.stdout) if vm["Name"] == name]
    if len(matches) != 1 or matches[0]["State"] != "stopped":
        raise ValueError(
            "The GUI-test base VM must exist locally and be stopped: " + name
        )
    return tart


def snapshot(repo, destination):
    files = subprocess.check_output(
        [
            "/usr/bin/git",
            "-C",
            str(repo),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ]
    ).split(b"\0")
    with tarfile.open(destination, "w") as archive:
        for encoded in sorted(set(files) - {b""}):
            name = os.fsdecode(encoded)
            path = repo / name
            if path.is_file() or path.is_symlink():
                archive.add(path, arcname=name, recursive=False)
        dependency = repo / ".build/Sparkle-2.10.0"
        if dependency.is_dir():
            archive.add(dependency, arcname=".build/Sparkle-2.10.0")


def wait_for_guest(tart, name, process, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("The GUI-test VM exited during startup; see tart.log.")
        try:
            ready = subprocess.run(
                [tart, "exec", name, "/usr/bin/true"],
                check=False,
                capture_output=True,
                timeout=10,
            )
            if ready.returncode == 0:
                return
        except subprocess.TimeoutExpired:
            pass
        time.sleep(2)
    raise RuntimeError(
        "The GUI-test VM did not start its Tart guest agent within 180 seconds; see tart.log."
    )


def run_in_vm(repo, base, selectors, jobs):
    tart = validate_vm(base)
    directory = repo / ".build/ui-test-vm"
    directory.mkdir(parents=True, exist_ok=True)
    run_directory = Path(tempfile.mkdtemp(prefix="run-", dir=directory))
    source = run_directory / "source"
    results = run_directory / "results"
    source.mkdir()
    results.mkdir()
    snapshot(repo, source / "source.tar")
    name = "acouplet-ui-" + uuid.uuid4().hex
    print("GUI tests in isolated VM; results: " + str(results), flush=True)
    environment = {**os.environ, "TART_NO_AUTO_PRUNE": "1"}
    process = None
    cloned = False

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGTERM, signal.SIGHUP)
    }
    try:
        subprocess.run([tart, "clone", base, name], check=True, env=environment)
        cloned = True
        with (run_directory / "tart.log").open("w") as log:
            process = subprocess.Popen(
                [
                    tart,
                    "run",
                    name,
                    "--no-graphics",
                    "--no-clipboard",
                    "--no-audio",
                    "--no-usb-accessories",
                    "--dir=source:" + str(source) + ":ro",
                    "--dir=results:" + str(results),
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            wait_for_guest(tart, name, process)
            arguments = ["--jobs", str(jobs)]
            for selector in selectors:
                arguments.extend(["--only-testing", selector])
            script = """set -eu
work="$(mktemp -d /private/tmp/acouplet-ui.XXXXXX)"
tar -xf '/Volumes/My Shared Files/source/source.tar' -C "$work"
cd "$work"
python3 Packaging/ui_test_vm.py --require-guest
set +e
python3 Packaging/check-ui.py "$@" > '/Volumes/My Shared Files/results/xctest.log' 2>&1
result=$?
set -e
if [ -d .build/check-all/Results ]; then
    cp -R .build/check-all/Results '/Volumes/My Shared Files/results/XCTest'
fi
if [ -d .build/check-all/Logs ]; then
    cp -R .build/check-all/Logs '/Volumes/My Shared Files/results/Logs'
fi
exit "$result"
"""
            result = subprocess.run(
                [
                    tart,
                    "exec",
                    name,
                    "/bin/zsh",
                    "-lc",
                    script,
                    "acouplet-ui",
                    *arguments,
                ],
                check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    "GUI tests failed in the VM; log: " + str(results / "xctest.log")
                )
            if not list(results.glob("XCTest/*/Acouplet.xcresult/Info.plist")):
                raise RuntimeError(
                    "The GUI-test VM did not return a completed XCTest result bundle: "
                    + str(results)
                )
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        failed = sys.exc_info()[0] is not None
        if cloned:
            try:
                subprocess.run(
                    [tart, "stop", name, "--timeout", "15"], check=False, timeout=30
                )
                if process is not None:
                    process.wait(timeout=30)
                subprocess.run([tart, "delete", name], check=True, timeout=30)
            except (OSError, subprocess.SubprocessError) as error:
                message = "Could not remove GUI-test VM " + name + ": " + str(error)
                if not failed:
                    raise RuntimeError(message) from error
                print(message, file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Verify that GUI automation runs inside a macOS guest."
    )
    parser.add_argument("--require-guest", action="store_true", required=True)
    parser.parse_args()
    try:
        require_guest()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
