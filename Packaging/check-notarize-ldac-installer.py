import json
import runpy
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

helper = runpy.run_path(str(Path(__file__).with_name('notarize-ldac-installer.py')))
calls = []
notary_status = 'Accepted'
reject_removal = False
checks = {'embedded_installer': True, 'developer_id_installer': True, 'same_signing_team': True, 'secure_timestamp': True}
removal_checks = checks.copy()


def run(arguments, **kwargs):
    calls.append(arguments)
    if arguments[1:3] == ['notarytool', 'log']:
        Path(arguments[-1]).write_text('{}')
    return subprocess.CompletedProcess(arguments, 0)


def output(arguments):
    calls.append(arguments)
    status = 'Invalid' if reject_removal and Path(arguments[3]).name == 'Acouplet LDAC Removal.pkg' else notary_status
    return json.dumps({'id': 'fixture-submission', 'status': status}).encode()


with tempfile.TemporaryDirectory(prefix='acouplet-installer-notary-check-') as directory:
    root = Path(directory)
    app = root / 'Acouplet.app'
    installer = app / 'Contents/Resources/Acouplet LDAC Output.pkg'
    installer.parent.mkdir(parents=True)
    installer.write_text('fixture signed installer')
    uninstaller = installer.with_name('Acouplet LDAC Removal.pkg')
    uninstaller.write_text('fixture signed uninstaller')
    evidence = root / 'evidence'
    with patch.dict(helper['distribution'], command=lambda args: (0, b'', b'TeamIdentifier=ABCDE12345\n'), inspect_installer=lambda path, team, removal=False: (removal_checks if removal else checks).copy()), \
         patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=output):
        for values in (checks, removal_checks):
            values['secure_timestamp'] = False
            try:
                helper['notarize'](app, 'fixture', evidence)
                raise AssertionError('Missing timestamp was accepted')
            except ValueError:
                pass
            assert calls == [] and not evidence.exists()
            values['secure_timestamp'] = True
        notary_status = 'Invalid'
        try:
            helper['notarize'](app, 'fixture', evidence)
            raise AssertionError('Rejected notarization was accepted')
        except RuntimeError:
            pass
        assert [call[1:3] for call in calls] == [['notarytool', 'submit'], ['notarytool', 'log']]
        assert json.loads((evidence / 'installer-notary-result.json').read_text())['status'] == 'Invalid'
        for keychain in (None, Path('/fixture/temporary.keychain-db')):
            calls.clear()
            notary_status = 'Accepted'
            helper['notarize'](app, 'fixture', evidence, keychain)
            assert [call[1:3] for call in calls] == [['notarytool', 'submit'], ['notarytool', 'log'], ['stapler', 'staple'], ['stapler', 'validate'], ['--assess', '--type']] * 2
            for call in [*calls[:2], *calls[5:7]]:
                assert call[call.index('--keychain-profile') + 1] == 'fixture'
                assert ('--keychain' in call) == bool(keychain)
                if keychain: assert call[call.index('--keychain') + 1] == str(keychain)
            assert calls[4] == ['/usr/sbin/spctl', '--assess', '--type', 'install', str(installer)]
            assert calls[-1] == ['/usr/sbin/spctl', '--assess', '--type', 'install', str(uninstaller)]
            assert json.loads((evidence / 'uninstaller-notary-result.json').read_text())['status'] == 'Accepted'
        calls.clear()
        reject_removal = True
        try:
            helper['notarize'](app, 'fixture', evidence)
            raise AssertionError('Rejected removal notarization was accepted')
        except RuntimeError:
            pass
        assert [call[1:3] for call in calls[5:]] == [['notarytool', 'submit'], ['notarytool', 'log']]
        assert json.loads((evidence / 'uninstaller-notary-result.json').read_text())['status'] == 'Invalid'
        assert list(app.parent.glob('*.pkg')) == []
print('Embedded installer rejects invalid signing before upload and rejected notarization before stapling; accepted installs validate and pass Gatekeeper: passed')
