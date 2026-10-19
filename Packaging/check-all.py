import argparse
import fnmatch
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

from check_runner import CheckCases

repo = Path(__file__).resolve().parent.parent
python_checks = (
    'Packaging/check-localizations-check.py',
    'Packaging/check-no-sony-artwork.py',
    'Packaging/check-sparkle.py',
    'Packaging/check-update-feed.py',
    'Packaging/check-prepare-updates.py',
    'Packaging/check-release-source.py',
    'Packaging/check-ldac-packing.py',
    'Packaging/check-ldac-build.py',
    'Packaging/check-ldac-session-stats.py',
    'Packaging/check-ldac-packet-timing.py',
    'Packaging/check-ldac-qualification.py',
    'Packaging/check-ldac-output-installer.py',
    'Packaging/check-notarize-ldac-installer.py',
    'Packaging/check-runner-check.py',
    'Packaging/check-stubs-check.py',
    'Packaging/check-package.py',
    'Packaging/check-install.py',
    'Packaging/check-direct.py',
    'Packaging/check-app-store.py',
    'Packaging/check-preference-panes.py',
    'Helpers/SonyBLEWriteCheck.py',
    'Helpers/LDAC/LDACControllerCleanupCheck.py',
    'Helpers/LDAC/LDACControllerVolumeCheck.py',
    'Helpers/LDAC/LDACNativeOutputRestoreCheck.py',
    'Helpers/LDAC/LDACSessionClosureCheck.py',
    'Helpers/LDAC/LDACCaptureStartupCheck.py',
    'Helpers/LDAC/LDACSignalingStartupCheck.py',
    'Helpers/LDAC/LDACSenderTimingCheck.py',
    'Helpers/LDAC/LDACMediaQueueCheck.py',
    'Helpers/LDAC/LDACPacketTraceCheck.py',
    'Helpers/LDAC/LDACConnectionOwnershipCheck.py',
    'Helpers/LDAC/LDACOwnerLifecycleCheck.py',
    'Helpers/LDAC/LDACOwnerExitCheck.py',
    'Packaging/check-all-check.py',
)


def run(*arguments, log=None, environment=None, workers=None):
    command = list(map(str, arguments))
    settings = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', **(environment or {})}
    if workers is not None:
        settings['ACOUPLET_CHECK_JOBS'] = str(workers)
    if log is None:
        print('\nChecking: ' + ' '.join(command), flush=True)
        subprocess.run(command, cwd=repo, check=True, env=settings)
    else:
        with log.open('w') as output:
            try:
                subprocess.run(command, cwd=repo, check=True, env=settings, stdout=output, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError as error:
                raise RuntimeError('Check failed; log: ' + str(log) + '\n' + '\n'.join(log.read_text(errors='replace').splitlines()[-30:])) from error


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Run native tests and independent local checks with incremental builds.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--fixtures-only', action='store_true', help='Run independent checks without building the app or running XCTest.')
    mode.add_argument('--xctest-only', action='store_true', help='Run XCTest and bundle checks without fixture suites.')
    parser.add_argument('--jobs', type=int, default=os.environ.get('ACOUPLET_CHECK_JOBS', min(4, os.cpu_count() or 1)), help='Concurrent check suites and fixture cases (default: up to 4).')
    parser.add_argument('--filter', default='*', help='Select independent checks by filename wildcard.')
    parser.add_argument('--only-testing', action='append', default=[], help='XCTest selector, such as AcoupletTests/LDACCallAudioTests; repeat to select more.')
    parser.add_argument('--clean', action='store_true', help='Clean Xcode build products before testing.')
    parser.add_argument('--list', action='store_true', help='List independent check names without running them.')
    options = parser.parse_args(arguments)
    if options.jobs < 1:
        parser.error('--jobs must be positive')
    if options.fixtures_only and (options.only_testing or options.clean):
        parser.error('--only-testing and --clean require XCTest')
    if options.xctest_only and options.filter != '*':
        parser.error('--filter selects independent checks; use --only-testing for XCTest')
    independent = [*python_checks, 'Packaging/check-virtual-output.sh', 'Helpers/NativeBatterySelfTestCheck.sh',
                   'Helpers/NativeHUD/BannerLifetimeCheck.swift', 'Helpers/LDAC/LDACSessionDiagnosticsCheck.swift']
    if not any(fnmatch.fnmatchcase(path, options.filter) for path in independent):
        parser.error('No independent checks match ' + options.filter)
    if options.list:
        listing = CheckCases('Independent local checks')
        for path in independent:
            listing.add(path, lambda: None)
        listing.main(['--list', '--filter', options.filter])
        return
    derived = repo / '.build/check-all'
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], cwd=repo, text=True).strip()
    environment = {'CLANG_MODULE_CACHE_PATH': str(derived / 'ModuleCache'), 'SDKROOT': sdk, 'ACOUPLET_CHECK_JOBS': str(options.jobs)}
    if not options.fixtures_only:
        run_xctest(options, derived, environment)
    if options.xctest_only:
        print('\nXCTest checks passed.', flush=True)
        return
    logs = derived / 'Logs'
    logs.mkdir(parents=True, exist_ok=True)
    log_directory = Path(tempfile.mkdtemp(prefix='run-', dir=logs))
    print('Check logs: ' + str(log_directory), flush=True)
    checks = CheckCases('Independent local checks')
    case_suites = {'Packaging/check-package.py', 'Packaging/check-install.py', 'Packaging/check-direct.py',
                   'Packaging/check-ldac-output-installer.py', 'Helpers/LDAC/LDACControllerVolumeCheck.py'}
    for path in python_checks:
        arguments = ['--check-mutations'] if path == 'Helpers/LDAC/LDACControllerVolumeCheck.py' else []
        workers = min(4, options.jobs) if path in case_suites else 1
        checks.add_parallel(path, workers, run, sys.executable, repo / path, *arguments, log=log_directory / (Path(path).stem + '.log'), environment=environment, workers=workers)
    for path in ('Packaging/check-virtual-output.sh', 'Helpers/NativeBatterySelfTestCheck.sh'):
        checks.add(path, run, '/bin/sh', repo / path, log=log_directory / (Path(path).stem + '.log'), environment=environment, workers=1)
    with tempfile.TemporaryDirectory(prefix='acouplet-standalone-checks-') as directory:
        for source, check in (
            ('Helpers/NativeHUD/BannerLifetime.swift', 'Helpers/NativeHUD/BannerLifetimeCheck.swift'),
            ('Sources/LDACNativeSession.swift', 'Helpers/LDAC/LDACSessionDiagnosticsCheck.swift'),
        ):
            checks.add(check, standalone, source, check, Path(directory), log_directory, environment)
        checks.main(['--jobs', str(options.jobs), '--filter', options.filter])
    print('\nAll selected local checks passed.', flush=True)


def run_xctest(options, derived, environment):
    sparkle = repo / '.build/Sparkle-2.10.0'
    required = ('Sparkle.framework/Resources/Info.plist', 'bin/generate_appcast', 'bin/sign_update', 'LICENSE')
    if any(not (sparkle / name).is_file() for name in required):
        raise ValueError('Fetch the test dependency first: Packaging/fetch-sparkle.sh')
    if plistlib.loads((sparkle / required[0]).read_bytes())['CFBundleShortVersionString'] != '2.10.0':
        raise ValueError('The cached Sparkle version must be 2.10.0.')
    if not options.clean:
        refresh_extraction(derived)
    results = derived / 'Results'
    results.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix='run-', dir=results)) / 'Acouplet.xcresult'
    run('/usr/bin/xcrun', 'xcodebuild', '-project', repo / 'Acouplet.xcodeproj', '-scheme', 'Acouplet',
        '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', derived,
        '-resultBundlePath', result,
        '-parallel-testing-enabled', 'NO', *['-only-testing:' + selector for selector in (options.only_testing or ['AcoupletTests'])],
        'ACOUPLET_PUBLIC_APIS_ONLY=NO', 'ACOUPLET_NO_SONY_ARTWORK=YES', 'ACOUPLET_SONY_ARTWORK_DIR=',
        'ACOUPLET_DISTRIBUTION=development', 'ENABLE_DEBUG_DYLIB=NO', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=', *(['clean'] if options.clean else []), 'test', environment=environment)
    summary = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], cwd=repo))
    if summary['passedTests'] <= 0 or summary['failedTests'] != 0:
        raise ValueError('XCTest must execute passing tests with no failures. Results: ' + str(result))
    app = derived / 'Build/Products/Debug/Acouplet.app'
    extraction = list((derived / 'Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal').glob('*/Acouplet.SwiftFileList'))
    if not extraction:
        raise ValueError('The test build did not produce the app compiler extraction files.')
    for file_list in extraction:
        run(sys.executable, repo / 'Packaging/check-localizations.py', app, file_list.parent, environment=environment)
    run(sys.executable, repo / 'Packaging/check-sparkle-bundle.py', app, environment=environment)
    run(sys.executable, repo / 'Helpers/check-helper.py', app / 'Contents/Helpers/Acouplet Battery Publisher', environment=environment)
    run(sys.executable, repo / 'Packaging/check-ldac-cli.py', app, environment=environment)


def standalone(source, check, directory, logs, environment):
    binary = directory / Path(check).stem
    run('/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', repo / source, repo / check, '-o', binary,
        log=logs / (binary.name + '-build.log'), environment=environment, workers=1)
    run(binary, log=logs / (binary.name + '.log'), environment=environment, workers=1)


def refresh_extraction(derived):
    refreshed = 0
    for file_list in (derived / 'Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal').glob('*/Acouplet.SwiftFileList'):
        for line in file_list.read_text().splitlines():
            source = Path(line.strip('"'))
            extraction = file_list.parent / (source.stem + '.stringsdata')
            if source.is_file() and (not extraction.is_file() or extraction.stat().st_mtime_ns < source.stat().st_mtime_ns):
                extraction.unlink(missing_ok=True)
                (file_list.parent / (source.stem + '.o')).unlink(missing_ok=True)
                refreshed += 1
    if refreshed:
        print(f'Refreshing {refreshed} outdated compiler string extractions.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
