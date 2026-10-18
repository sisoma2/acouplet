import json
import plistlib
import runpy
import tempfile
from pathlib import Path
from unittest.mock import patch

prepare = runpy.run_path(str(Path(__file__).with_name('prepare-updates.py')))
operation = prepare['prepare']
state = operation.__globals__

with tempfile.TemporaryDirectory(prefix='acouplet-prepare-updates-check-') as directory:
    root = Path(directory)
    archive, notes, output = root / 'Release.dmg', root / 'notes.md', root / 'release'
    archive.write_bytes(b'Fixture only.')
    notes.write_text('Release notes.\n')
    calls = []
    signing_key = 'fixture-public-key'
    fail_notary = False
    signing_team = 'ABCDEFGHIJ'
    bundle_id = 'dev.baglayan.Acouplet'
    layout_case = ''
    layout_mode = 'legacy'

    def run(arguments, input=None, capture=False):
        words = list(map(str, arguments))
        calls.append(words)
        if fail_notary and 'stapler' in words:
            raise RuntimeError('Fixture missing notarization.')
        if 'attach' in words:
            app = Path(words[words.index('-mountpoint') + 1]) / 'Acouplet.app'
            (app / 'Contents').mkdir(parents=True)
            (app.parent / 'Applications').symlink_to('/Applications')
            background = app.parent / '.background'
            if layout_mode == 'legacy':
                background.mkdir()
                (background / 'background.tiff').write_bytes(b'Fixture background.')
            if layout_mode == 'embedded':
                embedded = app / 'Contents/Resources/DMGBackground.tiff'
                embedded.parent.mkdir()
                embedded.write_bytes(b'Fixture background.')
            if layout_mode != 'plain': (app.parent / '.DS_Store').write_bytes(b'Fixture layout.')
            if layout_case == 'extra-app': (app.parent / 'Other.app').mkdir()
            if layout_case == 'extra-hidden': (app.parent / '.unexpected').touch()
            if layout_case == 'extra-background': (background / 'unexpected').touch()
            if layout_case == 'background-link':
                (background / 'background.tiff').unlink()
                background.rmdir()
                background.symlink_to(root, target_is_directory=True)
            if layout_case == 'image-link':
                (background / 'background.tiff').unlink()
                (background / 'background.tiff').symlink_to(notes)
            if layout_case in ('layout-link', 'embedded-layout-link'):
                (app.parent / '.DS_Store').unlink()
                (app.parent / '.DS_Store').symlink_to(notes)
            if layout_case == 'embedded-layout-directory':
                (app.parent / '.DS_Store').unlink()
                (app.parent / '.DS_Store').mkdir()
            if layout_case in ('embedded-image-link', 'embedded-image-missing', 'embedded-image-directory'):
                embedded.unlink()
                if layout_case == 'embedded-image-link': embedded.symlink_to(notes)
                if layout_case == 'embedded-image-directory': embedded.mkdir()
            if layout_case == 'applications-target':
                (app.parent / 'Applications').unlink()
                (app.parent / 'Applications').symlink_to(root)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '53', 'CFBundleShortVersionString': '0.27',
                'SUPublicEDKey': 'fixture-public-key', 'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Fixture', 'DTSDKName': 'macosx27.2'}))
        if 'generate_keys' == Path(words[0]).name:
            assert words[-3:] == ['--account', 'dev.baglayan.Acouplet', '-p']
            return signing_key
        return 'arm64' if '-archs' in words else ''

    def feed(folder, **kwargs):
        assert folder == output and kwargs['archive'] == archive
        assert kwargs['account'] == 'dev.baglayan.Acouplet'
        assert kwargs['notes'] == 'Release notes.'
        metadata = json.loads((folder / 'release.json').read_text())
        assert metadata['build'] == 53 and metadata['version'] == '0.27'
        assert metadata['initializeFeed'] is True and metadata['githubRepository'] == 'fixture/repo'

    def rejects():
        try:
            operation(archive, notes, output, None, True, 'dev.baglayan.Acouplet', 'ABCDEFGHIJ', 'fixture/repo')
        except (ValueError, RuntimeError):
            return
        raise AssertionError('Invalid release was accepted.')

    with patch.dict(state, run=run), patch.dict(state['distribution'], inspect_package=lambda *args, **kwargs: {'blockers': [], 'signing_team': signing_team}), patch.dict(state['release'], feed=feed):
        fail_notary = True
        rejects()
        assert not output.exists() and not any('generate_keys' == Path(call[0]).name for call in calls)
        fail_notary, signing_key = False, 'wrong-key'
        rejects()
        assert not output.exists() and calls[-1][1] == 'detach'
        signing_key = 'fixture-public-key'
        for case in ['team', 'identity', 'extra-app', 'extra-hidden', 'extra-background', 'background-link', 'image-link', 'layout-link', 'applications-target',
                     'embedded-layout-link', 'embedded-layout-directory', 'embedded-image-link', 'embedded-image-missing', 'embedded-image-directory']:
            signing_team = 'WRONGTEAM1' if case == 'team' else 'ABCDEFGHIJ'
            bundle_id = 'wrong.product' if case == 'identity' else 'dev.baglayan.Acouplet'
            layout_case = case
            layout_mode = 'embedded' if case.startswith('embedded-') else 'legacy'
            before = len([call for call in calls if Path(call[0]).name == 'generate_keys'])
            rejects()
            assert len([call for call in calls if Path(call[0]).name == 'generate_keys']) == before
            assert not output.exists()
        signing_team, bundle_id, layout_case = 'ABCDEFGHIJ', 'dev.baglayan.Acouplet', ''
        for layout_mode in ('plain', 'legacy', 'embedded'):
            output = root / ('release-' + layout_mode)
            operation(archive, notes, output, None, True, 'dev.baglayan.Acouplet', 'ABCDEFGHIJ', 'fixture/repo')
            assert calls[-1][1] == 'detach'
            rejects()
        assert not any('-x' in call or '--ed-key-file' in call for call in calls)
print('Local update preparation: notarization gate, product/team/layout identity, signing-key continuity, existing-output rejection and disk-image cleanup passed.')
