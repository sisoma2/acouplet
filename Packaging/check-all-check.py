import importlib.util
import json
import os
import plistlib
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "local_runner", Path(__file__).with_name("check-all.py")
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

with tempfile.TemporaryDirectory(prefix="acouplet-check-all-check-") as temporary:
    repo = Path(temporary)
    commands = []

    def run(*arguments, **options):
        commands.append(([str(argument) for argument in arguments], options))

    def output(arguments, **options):
        return json.dumps({"passedTests": 1, "failedTests": 0}).encode()

    with (
        patch.object(runner, "repo", repo),
        patch.object(runner, "run", side_effect=run),
        patch.dict(os.environ, DEVELOPER_DIR="/mock/Developer", SDKROOT="/mock/SDK"),
    ):
        listing = StringIO()
        with redirect_stdout(listing):
            runner.main(["--list"])
        for name in runner.python_checks:
            assert name in listing.getvalue()
        assert not commands and not (repo / ".build").exists()
        runner.main(
            ["--fixtures-only", "--filter", "*check-build-cache.py", "--jobs", "2"]
        )
        assert len(commands) == 1 and commands[0][0][1] == str(
            repo / "Packaging/check-build-cache.py"
        )
        assert commands[0][1]["environment"]["ACOUPLET_CHECK_JOBS"] == "1"
        commands.clear()
        for arguments in (
            ["--jobs", "0"],
            ["--only-testing", "AcoupletUITests"],
            ["--fixtures-only", "--clean"],
            ["--fixtures-only", "--filter", "*nothing*"],
            ["--xctest-only", "--exclude", "*native*"],
        ):
            with redirect_stderr(StringIO()):
                try:
                    runner.main(arguments)
                except SystemExit as error:
                    assert error.code == 2
                else:
                    raise AssertionError("Invalid runner selection was accepted")
        assert not commands
        try:
            runner.main(["--xctest-only"])
        except ValueError as error:
            assert "fetch-sparkle.sh" in str(error)
        else:
            raise AssertionError("Missing build dependency was accepted")
        dependency = repo / ".build/Sparkle-2.10.0"
        for name in (
            "Sparkle.framework/Resources/Info.plist",
            "bin/generate_appcast",
            "bin/sign_update",
            "LICENSE",
        ):
            path = dependency / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(
                plistlib.dumps({"CFBundleShortVersionString": "2.10.0"})
                if path.suffix == ".plist"
                else b"fixture"
            )
        extraction = (
            repo
            / ".build/check-all/Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal/arm64/Acouplet.SwiftFileList"
        )
        extraction.parent.mkdir(parents=True)
        extraction.touch()
        with patch.object(runner.subprocess, "check_output", side_effect=output):
            runner.main(
                ["--xctest-only", "--only-testing", "AcoupletTests/SonyPlaybackTests"]
            )
        command = commands[0][0]
        assert command[command.index("-parallel-testing-enabled") + 1] == "NO"
        assert (
            "-only-testing:AcoupletTests/SonyPlaybackTests" in command
            and "clean" not in command
        )
        assert "-test-timeouts-enabled" in command and "60" in command
        assert all("AcoupletUITests" not in argument for argument in command)
        for summary in (
            {"passedTests": 0, "failedTests": 0},
            {"passedTests": 1, "failedTests": 1},
        ):
            with patch.object(
                runner.subprocess,
                "check_output",
                return_value=json.dumps(summary).encode(),
            ):
                try:
                    runner.main(["--xctest-only"])
                except ValueError as error:
                    assert "execute passing tests" in str(error)
                else:
                    raise AssertionError("Invalid XCTest results were accepted")
        commands.clear()
        with patch.object(runner.subprocess, "check_output", side_effect=output):
            runner.main(["--xctest-only", "--clean", "--jobs", "2"])
        command = commands[0][0]
        assert (
            "clean" in command
            and command[command.index("-parallel-testing-worker-count") + 1] == "2"
        )
    with (
        patch.object(runner, "repo", repo),
        patch.object(runner, "run", side_effect=RuntimeError("child failed")),
        patch.dict(os.environ, DEVELOPER_DIR="/mock/Developer", SDKROOT="/mock/SDK"),
    ):
        try:
            runner.main(["--fixtures-only", "--filter", "*check-build-cache.py"])
        except RuntimeError as error:
            assert "child failed" in str(error)
        else:
            raise AssertionError("Failed fixture was accepted")
print(
    "Runner checks passed: inventory, selection, prerequisites, unit-only execution, worker bounds, incremental builds, result admission and failure propagation."
)
