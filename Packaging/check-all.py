import argparse
import fnmatch
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

from check_runner import CheckCases, default_jobs

repo = Path(__file__).resolve().parent.parent
python_checks = (
    "Packaging/check-localizations-check.py",
    "Packaging/check-no-sony-artwork.py",
    "Packaging/check-sparkle.py",
    "Packaging/check-update-feed.py",
    "Packaging/check-prepare-updates.py",
    "Packaging/check-release-source.py",
    "Packaging/check-ldac-packing.py",
    "Packaging/check-ldac-build.py",
    "Packaging/check-ldac-output-installer.py",
    "Packaging/check-notarize-ldac-installer.py",
    "Packaging/check-package.py",
    "Packaging/check-install.py",
    "Packaging/check-direct.py",
    "Packaging/check-app-store.py",
    "Packaging/check-preference-panes.py",
    "Helpers/SonyBLEWriteCheck.py",
    "Helpers/LDAC/LDACControllerCleanupCheck.py",
    "Helpers/LDAC/LDACControllerVolumeCheck.py",
    "Helpers/LDAC/LDACNativeOutputRestoreCheck.py",
    "Helpers/LDAC/LDACSessionClosureCheck.py",
    "Helpers/LDAC/LDACCaptureStartupCheck.py",
    "Helpers/LDAC/LDACConnectionOwnershipCheck.py",
    "Helpers/LDAC/LDACLogFreeConnectionCheck.py",
    "Helpers/LDAC/LDACOwnerLifecycleCheck.py",
    "Helpers/LDAC/LDACOwnerExitCheck.py",
    "Packaging/check-all-check.py",
    "Packaging/check-build-cache.py",
    "Packaging/check-runner-check.py",
)


def run(*arguments, log=None, environment=None, workers=None):
    command = list(map(str, arguments))
    settings = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", **(environment or {})}
    if workers is not None:
        settings["ACOUPLET_CHECK_JOBS"] = str(workers)
    if log is None:
        print("\nChecking: " + " ".join(command), flush=True)
        subprocess.run(command, cwd=repo, check=True, env=settings)
    else:
        with log.open("w") as output:
            try:
                subprocess.run(
                    command,
                    cwd=repo,
                    check=True,
                    env=settings,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                )
            except subprocess.CalledProcessError as error:
                raise RuntimeError(
                    "Check failed; log: "
                    + str(log)
                    + "\n"
                    + "\n".join(log.read_text(errors="replace").splitlines()[-30:])
                ) from error


def refresh_extraction(derived):
    refreshed = 0
    for file_list in (
        derived
        / "Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal"
    ).glob("*/Acouplet.SwiftFileList"):
        for line in file_list.read_text().splitlines():
            source = Path(line.strip('"'))
            extraction = file_list.parent / (source.stem + ".stringsdata")
            if source.is_file() and (
                not extraction.is_file()
                or extraction.stat().st_mtime_ns < source.stat().st_mtime_ns
            ):
                extraction.unlink(missing_ok=True)
                (file_list.parent / (source.stem + ".o")).unlink(missing_ok=True)
                refreshed += 1
    if refreshed:
        print(
            f"Refreshing {refreshed} outdated compiler string extractions.", flush=True
        )


def run_xctest(options, derived):
    sparkle = repo / ".build/Sparkle-2.10.0"
    required = (
        "Sparkle.framework/Resources/Info.plist",
        "bin/generate_appcast",
        "bin/sign_update",
        "LICENSE",
    )
    if any(not (sparkle / name).is_file() for name in required):
        raise ValueError("Fetch the test dependency first: Packaging/fetch-sparkle.sh")
    if (
        plistlib.loads((sparkle / required[0]).read_bytes())[
            "CFBundleShortVersionString"
        ]
        != "2.10.0"
    ):
        raise ValueError("The cached Sparkle version must be 2.10.0.")
    if not options.clean:
        refresh_extraction(derived)
    results = derived / "Results"
    results.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix="run-", dir=results)) / "Acouplet.xcresult"
    selectors = options.only_testing or ["AcoupletTests"]
    workers = 1 if options.only_testing else min(4, options.jobs)
    run(
        "/usr/bin/xcrun",
        "xcodebuild",
        "-project",
        repo / "Acouplet.xcodeproj",
        "-scheme",
        "Acouplet",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        derived,
        "-resultBundlePath",
        result,
        "-parallel-testing-enabled",
        "YES" if workers > 1 else "NO",
        "-parallel-testing-worker-count",
        workers,
        "-test-timeouts-enabled",
        "YES",
        "-default-test-execution-time-allowance",
        "60",
        "-maximum-test-execution-time-allowance",
        "60",
        *["-only-testing:" + selector for selector in selectors],
        "ACOUPLET_PUBLIC_APIS_ONLY=NO",
        "ACOUPLET_NO_SONY_ARTWORK=YES",
        "ACOUPLET_SONY_ARTWORK_DIR=",
        "ACOUPLET_DISTRIBUTION=development",
        "ENABLE_DEBUG_DYLIB=NO",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual",
        "DEVELOPMENT_TEAM=",
        *(["clean"] if options.clean else []),
        "test",
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
            "XCTest must execute passing tests with no failures. Results: "
            + str(result)
        )
    app = derived / "Build/Products/Debug/Acouplet.app"
    extraction = list(
        (
            derived
            / "Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal"
        ).glob("*/Acouplet.SwiftFileList")
    )
    if not extraction:
        raise ValueError(
            "The test build did not produce the app compiler extraction files."
        )
    for file_list in extraction:
        run(
            sys.executable,
            repo / "Packaging/check-localizations.py",
            app,
            file_list.parent,
        )
    run(sys.executable, repo / "Packaging/check-sparkle-bundle.py", app)
    run(
        sys.executable,
        repo / "Helpers/check-helper.py",
        app / "Contents/Helpers/Acouplet Battery Publisher",
    )
    run(sys.executable, repo / "Packaging/check-ldac-cli.py", app)


def standalone(source, check, directory, environment):
    binary = directory / Path(check).stem
    command = [
        "/usr/bin/xcrun",
        "swiftc",
        "-swift-version",
        "6",
        "-parse-as-library",
        repo / source,
        repo / check,
        "-o",
        binary,
    ]
    run(
        sys.executable,
        repo / "Packaging/build_cache.py",
        "--cache",
        directory / (binary.name + "-cache"),
        "--input",
        repo / source,
        "--input",
        repo / check,
        "--output",
        binary,
        "--",
        *command,
        environment=environment,
    )
    run(binary, environment=environment)


def native_transport(source, directory, environment):
    encoder = repo / "Vendor/libldac"
    binary = directory / Path(source).stem
    arguments = (
        [
            "-I",
            encoder / "inc",
            "-I",
            encoder / "src",
            encoder / "src/ldacBT.c",
            encoder / "src/ldaclib.c",
        ]
        if source.endswith("MediaTests.m")
        else []
    )
    command = [
        "/usr/bin/xcrun",
        "clang",
        "-fobjc-arc",
        "-fblocks",
        "-Werror",
        "-D_DARWIN_C_SOURCE",
        "-DACOUPLET_LDAC_PROBE_ONLY=0",
        "-mmacosx-version-min=15.4",
        "-framework",
        "Foundation",
        "-framework",
        "CoreFoundation",
        "-framework",
        "CoreBluetooth",
        "-framework",
        "IOBluetooth",
        repo / source,
        *arguments,
        "-o",
        binary,
    ]
    run(
        sys.executable,
        repo / "Packaging/build_cache.py",
        "--cache",
        directory / (binary.name + "-cache"),
        "--input",
        repo / "Helpers/LDAC",
        "--input",
        repo / "Helpers/SonyClassicConnection.h",
        "--input",
        encoder,
        "--output",
        binary,
        "--",
        *command,
        environment=environment,
    )
    run(binary, environment=environment)


def main(arguments=None):
    parser = argparse.ArgumentParser(
        description="Run unit tests and independent offline fixtures."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fixtures-only", action="store_true")
    mode.add_argument("--xctest-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=default_jobs())
    parser.add_argument("--filter", default="*")
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--list", action="store_true")
    options = parser.parse_args(arguments)
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    if options.fixtures_only and (options.only_testing or options.clean):
        parser.error("--only-testing and --clean require XCTest")
    if options.xctest_only and (options.filter != "*" or options.exclude):
        parser.error("--filter and --exclude select independent fixtures")
    if any(
        selector.split("/")[0] != "AcoupletTests" for selector in options.only_testing
    ):
        parser.error("--only-testing selectors must belong to AcoupletTests")
    derived = repo / ".build/check-all"
    logs = derived / "Logs"
    directory = derived / "Standalone"
    environment = {
        "CLANG_MODULE_CACHE_PATH": str(derived / "ModuleCache"),
        "ACOUPLET_CHECK_JOBS": "1",
        "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR")
        or subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True).strip(),
        "SDKROOT": os.environ.get("SDKROOT")
        or subprocess.check_output(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip(),
    }
    checks = CheckCases("Independent local checks")
    for path in python_checks:
        arguments = (
            ["--check-mutations"]
            if path.endswith("LDACControllerVolumeCheck.py")
            else []
        )
        checks.add(
            path,
            run,
            sys.executable,
            repo / path,
            *arguments,
            log=logs / (Path(path).stem + ".log"),
            environment=environment,
            workers=1,
        )
    for path in (
        "Packaging/check-virtual-output.sh",
        "Helpers/NativeBatterySelfTestCheck.sh",
    ):
        checks.add(
            path,
            run,
            "/bin/sh",
            repo / path,
            log=logs / (Path(path).stem + ".log"),
            environment=environment,
        )
    for source, check in (
        (
            "Helpers/NativeHUD/BannerLifetime.swift",
            "Helpers/NativeHUD/BannerLifetimeCheck.swift",
        ),
        (
            "Sources/LDACNativeSession.swift",
            "Helpers/LDAC/LDACSessionDiagnosticsCheck.swift",
        ),
    ):
        checks.add(check, standalone, source, check, directory, environment)
    for source in (
        "Helpers/LDAC/LDACLogFreeSignalingTests.m",
        "Helpers/LDAC/LDACLogFreeMediaTests.m",
    ):
        checks.add(source, native_transport, source, directory, environment)
    selection = ["--filter", options.filter]
    for pattern in options.exclude:
        selection.extend(["--exclude", pattern])
    selected = [
        name
        for name in checks.cases
        if fnmatch.fnmatchcase(name, options.filter)
        and not any(fnmatch.fnmatchcase(name, pattern) for pattern in options.exclude)
    ]
    if not selected:
        parser.error("No independent checks match " + options.filter)
    if options.list:
        checks.main(["--list", *selection])
        return
    if not options.fixtures_only:
        run_xctest(options, derived)
    if options.xctest_only:
        return
    logs.mkdir(parents=True, exist_ok=True)
    directory.mkdir(parents=True, exist_ok=True)
    checks.main(["--jobs", str(options.jobs), *selection])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
