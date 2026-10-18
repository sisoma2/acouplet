import argparse
import json
import os
import plistlib
import re
import runpy
import tempfile
from pathlib import Path

packaging = Path(__file__).resolve().parent
release = runpy.run_path(str(packaging / 'update-feed.py'))
distribution = runpy.run_path(str(packaging / 'check-distribution.py'))
run = release['run']


def prepare(archive, notes, output, history, initialize, account, team, repository):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Supply the expected ten-character Apple developer team ID.')
    if bool(history) == initialize:
        raise ValueError('Supply previous update history, or use --initialize for the first release.')
    if output.exists():
        raise ValueError('Use a new output directory; existing release files will not be replaced.')
    text = notes.read_text().strip()
    if not text:
        raise ValueError('Release notes are required.')
    run(['/usr/bin/xcrun', 'stapler', 'validate', archive], capture=True)
    run(['/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', archive], capture=True)
    with tempfile.TemporaryDirectory(prefix='acouplet-update-image-') as directory:
        mount = Path(directory) / 'image'
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, archive], capture=True)
        try:
            entries = {path.name for path in mount.iterdir()}
            if entries not in ({'Acouplet.app', 'Applications'}, {'Acouplet.app', 'Applications', '.DS_Store'}, {'Acouplet.app', 'Applications', '.DS_Store', '.background'}) or \
               (mount / 'Acouplet.app').is_symlink() or not (mount / 'Applications').is_symlink() or \
               os.readlink(mount / 'Applications') != '/Applications':
                raise ValueError('The update image must contain only the app, Applications shortcut and optional disk image artwork.')
            if '.DS_Store' in entries and ((mount / '.DS_Store').is_symlink() or not (mount / '.DS_Store').is_file()):
                raise ValueError('The disk image layout must be a regular file.')
            if '.background' in entries and ((mount / '.background').is_symlink() or not (mount / '.background').is_dir() or
                    {path.name for path in (mount / '.background').iterdir()} != {'background.tiff'} or
                    (mount / '.background/background.tiff').is_symlink() or not (mount / '.background/background.tiff').is_file()):
                raise ValueError('The disk image artwork must contain only regular layout and background files.')
            if '.DS_Store' in entries and '.background' not in entries:
                background = mount / 'Acouplet.app/Contents/Resources/DMGBackground.tiff'
                if background.is_symlink() or not background.is_file():
                    raise ValueError('The disk image background must be a regular file inside the signed app.')
            report = distribution['inspect_package'](mount, dmg=archive)
            if report['blockers']:
                raise ValueError('The update image failed release checks: ' + '; '.join(report['blockers']))
            if report['signing_team'] != team:
                raise ValueError('The update app does not belong to the expected developer team.')
            app = mount / 'Acouplet.app'
            run(['/usr/sbin/spctl', '--assess', '--type', 'execute', app], capture=True)
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info['CFBundleIdentifier'] != 'dev.baglayan.Acouplet':
                raise ValueError('The disk image contains a different application.')
            key = run([release['SPARKLE'] / 'generate_keys', '--account', account, '-p'], capture=True).strip()
            if key != info['SUPublicEDKey']:
                raise ValueError('The Keychain signing account does not match the app public key.')
            if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', info['CFBundleShortVersionString']) or not re.fullmatch(r'[1-9][0-9]*', info['CFBundleVersion']):
                raise ValueError('The app needs a numeric version and a positive integer build number.')
            release['github_download_prefix'](repository, info['CFBundleShortVersionString'])
            metadata = {'version': info['CFBundleShortVersionString'], 'build': int(info['CFBundleVersion']),
                        'initializeFeed': initialize, 'sdkVersion': info.get('DTSDKName', ''),
                        'architecture': run(['/usr/bin/lipo', '-archs', app / 'Contents/MacOS' / info['CFBundleExecutable']], capture=True).strip(),
                        'githubRepository': repository}
            output.mkdir(parents=True, mode=0o700)
            (output / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
            release['feed'](output, app=app, archive=archive, notes=text, history=history, account=account)
        finally:
            run(['/usr/bin/hdiutil', 'detach', mount], capture=True)
    print('Verified signed update files: ' + str(output / 'publish'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--dmg', required=True, type=Path)
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--history', type=Path)
    parser.add_argument('--initialize', action='store_true')
    parser.add_argument('--team', required=True)
    parser.add_argument('--github-repository', required=True)
    parser.add_argument('--account', default='dev.baglayan.Acouplet')
    args = parser.parse_args()
    prepare(args.dmg.resolve(), args.notes.resolve(), args.output.resolve(),
            args.history.resolve() if args.history else None, args.initialize, args.account, args.team, args.github_repository)
