import json
import signal
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import Mock, patch

import ui_test_vm as runner


for code, output, allowed in ((0, '1\n', True), (0, '0\n', False), (1, '1\n', False), (0, '', False), (0, 'yes\n', False)):
    with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, stdout=output)):
        try:
            runner.require_guest()
        except ValueError as error:
            assert not allowed and 'No GUI automation was started' in str(error)
        else:
            assert allowed

with patch.object(runner.shutil, 'which', return_value=None):
    try:
        runner.validate_vm('base')
    except ValueError as error:
        assert 'Tart is required' in str(error)
    else:
        raise AssertionError('Missing Tart was accepted')

for name, listing, allowed in (
    ('base', [{'Name': 'base', 'State': 'stopped'}], True),
    ('base', [{'Name': 'base', 'State': 'running'}], False),
    ('base', [{'Name': 'base', 'State': 'suspended'}], False),
    ('base', [], False),
    ('-base', [], False),
    ('registry/image:latest', [], False),
):
    with patch.object(runner.shutil, 'which', return_value='/mock/tart'), \
            patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps(listing))):
        try:
            assert runner.validate_vm(name) == '/mock/tart'
        except ValueError:
            assert not allowed
        else:
            assert allowed

with tempfile.TemporaryDirectory(prefix='acouplet-ui-vm-check-') as directory:
    repo = Path(directory)
    (repo / 'Sources').mkdir()
    (repo / 'Sources/Edited.swift').write_text('working tree edit')
    (repo / 'Sources/New.swift').write_text('untracked source')
    (repo / 'Sources/Link.swift').symlink_to('Edited.swift')
    (repo / '.env').write_text('excluded private input')
    (repo / '.build/Sparkle-2.10.0').mkdir(parents=True)
    (repo / '.build/Sparkle-2.10.0/LICENSE').write_text('dependency')
    with patch.object(runner.subprocess, 'check_output', return_value=b'Sources/Edited.swift\0Sources/New.swift\0Sources/Link.swift\0Sources/Deleted.swift\0'):
        runner.snapshot(repo, repo / 'snapshot.tar')
    with tarfile.open(repo / 'snapshot.tar') as archive:
        assert archive.extractfile('Sources/Edited.swift').read() == b'working tree edit'
        assert archive.extractfile('Sources/New.swift').read() == b'untracked source'
        assert archive.getmember('Sources/Link.swift').issym()
        assert archive.extractfile('.build/Sparkle-2.10.0/LICENSE').read() == b'dependency'
        assert '.env' not in archive.getnames() and 'Sources/Deleted.swift' not in archive.getnames()

    for scenario in ('success', 'test-failure', 'missing-results', 'boot-failure', 'clone-failure', 'stop-already-exited', 'cleanup-failure', 'interrupted'):
        calls = []
        process = Mock()
        process.poll.return_value = None

        def run(arguments, **options):
            calls.append(arguments)
            if arguments[1] == 'clone' and scenario == 'clone-failure':
                raise subprocess.CalledProcessError(1, arguments)
            if arguments[1] == 'delete' and scenario == 'cleanup-failure':
                raise subprocess.CalledProcessError(1, arguments)
            if arguments[1] == 'stop' and scenario == 'stop-already-exited':
                return subprocess.CompletedProcess(arguments, 1)
            if arguments[1] == 'exec' and '/bin/zsh' in arguments:
                if scenario == 'interrupted':
                    signal.raise_signal(signal.SIGTERM)
                vm_command = arguments
                assert '--ui-only' in vm_command
                assert vm_command[-2:] == ['--only-testing', 'AcoupletUITests/AppUITests/testExample']
                script = vm_command[vm_command.index('-lc') + 1]
                assert script.index('ui_test_vm.py --require-guest') < script.index('check-all.py')
                assert 'cp -R .build/check-all/Results' in script
                assert '--ui-vm' not in vm_command
                share = next(arg for arg in process.start_arguments if arg.startswith('--dir=results:'))
                results = Path(share.removeprefix('--dir=results:'))
                if scenario in ('success', 'stop-already-exited', 'cleanup-failure'):
                    result = results / 'XCTest/run-test/Acouplet.xcresult/Info.plist'
                    result.parent.mkdir(parents=True)
                    result.write_text('completed result')
                return subprocess.CompletedProcess(arguments, 65 if scenario == 'test-failure' else 0)
            return subprocess.CompletedProcess(arguments, 0)

        def start(arguments, **options):
            process.start_arguments = arguments
            assert '--no-graphics' in arguments and '--no-clipboard' in arguments
            assert '--no-audio' in arguments and '--no-usb-accessories' in arguments
            assert next(arg for arg in arguments if arg.startswith('--dir=source:')).endswith(':ro')
            assert options['env']['TART_NO_AUTO_PRUNE'] == '1'
            return process

        with patch.object(runner, 'validate_vm', return_value='/mock/tart'), \
                patch.object(runner, 'snapshot'), patch.object(runner.subprocess, 'run', side_effect=run), \
                patch.object(runner.subprocess, 'Popen', side_effect=start), \
                patch.object(runner, 'wait_for_guest', side_effect=RuntimeError('boot failed') if scenario == 'boot-failure' else None):
            try:
                runner.run_in_vm(repo, 'base', ['AcoupletUITests/AppUITests/testExample'], 2)
            except (RuntimeError, subprocess.CalledProcessError, KeyboardInterrupt):
                assert scenario not in ('success', 'stop-already-exited')
            else:
                assert scenario in ('success', 'stop-already-exited')
        name = calls[0][3]
        assert name.startswith('acouplet-ui-') and name != 'base'
        if scenario == 'clone-failure':
            assert len(calls) == 1
        else:
            assert calls[-2:] == [['/mock/tart', 'stop', name, '--timeout', '15'], ['/mock/tart', 'delete', name]]
            process.wait.assert_called_once_with(timeout=30)
        assert not any(command[0] == '/usr/bin/xcrun' for command in calls)

process = Mock()
process.poll.return_value = 1
with patch.object(runner.subprocess, 'run', side_effect=AssertionError('Exited VM was used')):
    try:
        runner.wait_for_guest('/mock/tart', 'clone', process)
    except RuntimeError as error:
        assert 'exited during startup' in str(error)
    else:
        raise AssertionError('Exited VM was accepted')

process.poll.return_value = None
with patch.object(runner.time, 'monotonic', side_effect=[0, 181]):
    try:
        runner.wait_for_guest('/mock/tart', 'clone', process)
    except RuntimeError as error:
        assert '180 seconds' in str(error)
    else:
        raise AssertionError('VM readiness had no deadline')

project = Path(__file__).resolve().parent.parent / 'Acouplet.xcodeproj'
for name, targets in (('Acouplet', ['AcoupletTests']), ('Acouplet UI Tests', ['AcoupletUITests']), ('Acouplet Public UI Tests', ['AcoupletUITests'])):
    scheme = ET.parse(project / 'xcshareddata/xcschemes' / (name + '.xcscheme'))
    assert [item.attrib['BlueprintName'] for item in scheme.findall('.//TestableReference/BuildableReference')] == targets
settings = subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project / 'project.pbxproj')])
objects = json.loads(settings)['objects']
target = next(item for item in objects.values() if item.get('isa') == 'PBXNativeTarget' and item.get('name') == 'AcoupletUITests')
guard = objects[target['buildPhases'][0]]
assert guard['alwaysOutOfDate'] == '1'
assert guard['shellScript'] == 'set -eu\n/usr/bin/python3 "$SRCROOT/Packaging/ui_test_vm.py" --require-guest\n'
print('GUI-test isolation, VM lifecycle, source snapshot, result collection and Xcode entry points: passed')
