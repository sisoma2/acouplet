import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from ui_test_vm import require_guest, run_in_vm


def main(arguments=None):
    parser = argparse.ArgumentParser(
        description="Run GUI tests in an isolated macOS VM."
    )
    parser.add_argument("--ui-vm")
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--jobs", type=int, default=1)
    options = parser.parse_args(arguments)
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    selectors = options.only_testing or ["AcoupletUITests"]
    if any(selector.split("/")[0] != "AcoupletUITests" for selector in selectors):
        parser.error("GUI selectors must belong to AcoupletUITests")
    repo = Path(__file__).resolve().parent.parent
    if options.ui_vm:
        run_in_vm(repo, options.ui_vm, selectors, options.jobs)
        return
    require_guest()
    sparkle = repo / ".build/Sparkle-2.10.0"
    if not (sparkle / "Sparkle.framework/Resources/Info.plist").is_file():
        raise ValueError("Fetch the test dependency first: Packaging/fetch-sparkle.sh")
    derived = repo / ".build/check-all"
    results = derived / "Results"
    results.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix="gui-", dir=results)) / "Acouplet.xcresult"
    command = [
        "/usr/bin/xcrun",
        "xcodebuild",
        "-project",
        str(repo / "Acouplet.xcodeproj"),
        "-scheme",
        "Acouplet UI Tests",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(derived),
        "-resultBundlePath",
        str(result),
        "-parallel-testing-enabled",
        "NO",
        "ACOUPLET_PUBLIC_APIS_ONLY=NO",
        "ACOUPLET_NO_SONY_ARTWORK=YES",
        "ACOUPLET_SONY_ARTWORK_DIR=",
        "ACOUPLET_DISTRIBUTION=development",
        "ENABLE_DEBUG_DYLIB=NO",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual",
        "DEVELOPMENT_TEAM=",
        *["-only-testing:" + selector for selector in selectors],
        "test",
    ]
    subprocess.run(
        command,
        cwd=repo,
        check=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    summary = json.loads(
        subprocess.check_output(
            [
                "/usr/bin/xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                str(result),
            ],
            cwd=repo,
        )
    )
    if summary["passedTests"] <= 0 or summary["failedTests"] != 0:
        raise ValueError(
            "GUI XCTest must execute passing tests with no failures: " + str(result)
        )
    print("GUI checks passed. Results: " + str(result))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
