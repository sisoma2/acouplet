from pathlib import Path
from unittest.mock import patch
from contextlib import redirect_stdout
from io import StringIO
import json, os, plistlib, runpy, subprocess, tempfile

runner = runpy.run_path(str(Path(__file__).with_name('check-all.py')))
main = runner['main']

with tempfile.TemporaryDirectory(prefix='acouplet-check-all-check-') as directory:
    repo = Path(directory)
    commands = []
    summaries = []

    def run(arguments, **options):
        assert options['cwd'] == repo and options['check'] is True
        commands.append(arguments)
        return subprocess.CompletedProcess(arguments, 0)

    def summary(arguments, **options):
        if arguments == ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']:
            return '/mock/SDK\n'
        assert arguments[:6] == ['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path']
        assert options['cwd'] == repo
        result = Path(arguments[-1])
        assert result.name == 'Acouplet.xcresult' and result.parent.parent == repo / '.build/check-all/Results'
        assert result.parent.is_dir()
        assert result not in summaries
        summaries.append(result)
        return json.dumps({'passedTests': 1, 'failedTests': 0}).encode()

    with patch.dict(main.__globals__, repo=repo), patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=summary):
        try:
            main()
        except ValueError as error:
            assert 'fetch-sparkle.sh' in str(error)
        else:
            raise AssertionError('Missing test dependency was accepted')
        assert not commands
        sparkle = repo / '.build/Sparkle-2.10.0'
        for name in ('Sparkle.framework/Resources/Info.plist', 'bin/generate_appcast', 'bin/sign_update', 'LICENSE'):
            path = sparkle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.10.0'}) if path.suffix == '.plist' else b'fixture')
        try:
            main()
        except ValueError as error:
            assert 'compiler extraction' in str(error)
        else:
            raise AssertionError('Missing compiler extraction was accepted')
        assert len(commands) == 1
        extraction = repo / '.build/check-all/Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal/arm64/Acouplet.SwiftFileList'
        extraction.parent.mkdir(parents=True)
        extraction.touch()
        commands.clear()
        main()
    xcode = commands[0]
    assert xcode[:2] == ['/usr/bin/xcrun', 'xcodebuild'] and xcode[-1] == 'test' and 'clean' not in xcode
    assert '-only-testing:AcoupletTests' in xcode and '-parallel-testing-enabled' in xcode
    assert 'ACOUPLET_PUBLIC_APIS_ONLY=NO' in xcode and 'CODE_SIGN_IDENTITY=-' in xcode
    assert 'ENABLE_DEBUG_DYLIB=NO' in xcode
    assert 'ACOUPLET_DISTRIBUTION=development' in xcode and 'ACOUPLET_NO_SONY_ARTWORK=YES' in xcode
    assert xcode[xcode.index('-resultBundlePath') + 1] == str(summaries[-1])
    scripts = [Path(command[1]).name for command in commands if len(command) > 1 and command[1].endswith('.py')]
    for path in runner['python_checks']:
        assert Path(path).name in scripts, path
    assert 'check-helper.py' in scripts and 'check-ldac-cli.py' in scripts and 'check-sparkle-bundle.py' in scripts
    volume_check = next(command for command in commands if len(command) > 1 and Path(command[1]).name == 'LDACControllerVolumeCheck.py')
    assert volume_check[2:] == ['--check-mutations']
    bundle_check = next(command for command in commands if len(command) == 4 and Path(command[1]).name == 'check-localizations.py')
    assert bundle_check[-1] == str(extraction.parent)
    assert any(Path(command[0]).name == 'BannerLifetimeCheck' for command in commands)
    assert any(Path(command[0]).name == 'LDACSessionDiagnosticsCheck' for command in commands)
    assert not any(Path(word).name in ('check-service.sh', 'NativeHUDCheck', 'install', 'direct.sh', 'package.sh', 'fetch-sparkle.sh') for command in commands for word in command)
    assert not any('AcoupletUITests' in word for command in commands for word in command)
    commands.clear()
    with patch.dict(main.__globals__, repo=repo), patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=summary):
        main(['--xctest-only', '--clean', '--only-testing', 'AcoupletTests/LDACCallAudioTests', '--only-testing', 'AcoupletTests/LDACRecoveryTests'])
    assert commands[0][-2:] == ['clean', 'test']
    assert '-only-testing:AcoupletTests/LDACCallAudioTests' in commands[0]
    assert '-only-testing:AcoupletTests/LDACRecoveryTests' in commands[0]
    assert '-only-testing:AcoupletTests' not in commands[0]
    assert not any(str(repo / path) in command for path in runner['python_checks'] for command in commands)
    for result_summary in ({'passedTests': 0, 'failedTests': 0},
                           {'passedTests': 0, 'failedTests': 0, 'skippedTests': 4},
                           {'passedTests': 1, 'failedTests': 1}):
        commands.clear()
        with patch.dict(main.__globals__, repo=repo), patch('subprocess.run', side_effect=run), \
             patch('subprocess.check_output', return_value=json.dumps(result_summary).encode()):
            try:
                main()
            except ValueError as error:
                assert 'execute passing tests with no failures' in str(error)
            else:
                raise AssertionError('Empty, skipped, or failing XCTest summary was accepted')
        assert len(commands) == 1
    commands.clear()

    def fail(arguments, **options):
        commands.append(arguments)
        raise subprocess.CalledProcessError(17, arguments)

    with patch.dict(main.__globals__, repo=repo), patch('subprocess.run', side_effect=fail):
        try:
            main()
        except subprocess.CalledProcessError as error:
            assert error.returncode == 17
        else:
            raise AssertionError('Failed XCTest run was accepted')
    assert len(commands) == 1

    commands.clear()
    with patch.dict(main.__globals__, repo=repo / 'fixtures-only'), patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=summary):
        fixture_repo = main.__globals__['repo']
        def fixture_run(arguments, **options):
            assert options['cwd'] == fixture_repo
            assert options['env']['ACOUPLET_CHECK_JOBS'] == '1'
            assert options['env']['SDKROOT'] == '/mock/SDK'
            commands.append(arguments)
            return subprocess.CompletedProcess(arguments, 0)
        with patch('subprocess.run', side_effect=fixture_run):
            main(['--fixtures-only', '--filter', '*check-runner-check.py', '--jobs', '2'])
    assert len(commands) == 1 and Path(commands[0][1]).name == 'check-runner-check.py'
    commands.clear()
    with patch.dict(main.__globals__, repo=repo / 'fixture-group'), patch('subprocess.check_output', side_effect=summary):
        def group_run(arguments, **options):
            assert options['env']['ACOUPLET_CHECK_JOBS'] == '2'
            commands.append(arguments)
            return subprocess.CompletedProcess(arguments, 0)
        with patch('subprocess.run', side_effect=group_run):
            main(['--fixtures-only', '--filter', '*check-package.py', '--jobs', '2'])
    assert len(commands) == 1 and Path(commands[0][1]).name == 'check-package.py'
    output = StringIO()
    with patch('subprocess.run', side_effect=AssertionError('Listing executed a check')), patch('subprocess.check_output', side_effect=AssertionError('Listing queried Xcode')), redirect_stdout(output):
        main(['--list', '--filter', '*check-direct.py'])
    assert output.getvalue().splitlines() == ['Packaging/check-direct.py']

    cached = repo / 'cached'
    objects = cached / 'Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal/arm64'
    objects.mkdir(parents=True)
    sources = []
    for name in ('Fresh', 'Stale', 'Missing Extraction'):
        source = repo / (name + '.swift')
        source.write_text('source')
        os.utime(source, ns=(1650000000000000000, 1650000000000000000))
        sources.append(source)
        (objects / (name + '.o')).write_text('object')
        if name != 'Missing Extraction':
            extraction = objects / (name + '.stringsdata')
            extraction.write_text('extracted')
            timestamp = 1650000000000000000 + (1 if name == 'Fresh' else -1)
            os.utime(extraction, ns=(timestamp, timestamp))
    (objects / 'Acouplet.SwiftFileList').write_text('\n'.join('"' + str(source) + '"' for source in sources))
    runner['refresh_extraction'](cached)
    assert (objects / 'Fresh.o').is_file() and (objects / 'Fresh.stringsdata').is_file()
    assert not (objects / 'Stale.o').exists() and not (objects / 'Stale.stringsdata').exists()
    assert not (objects / 'Missing Extraction.o').exists()
    assert all(source.read_text() == 'source' for source in sources)
print('Local check inventory, prerequisites, native XCTest settings, compiler coverage and failure propagation: passed')
