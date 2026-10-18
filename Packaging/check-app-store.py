import json
import os
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

packaging = Path(__file__).parent
checker = runpy.run_path(str(packaging / 'check-store-bundle.py'))
mini_icons = runpy.run_path(str(packaging / 'prepare-no-sony-artwork.py'))['mini_icons']


def check(name, alteration=None, rejects=False, archive=False):
    with tempfile.TemporaryDirectory(prefix='acouplet-store-check-') as directory:
        artifact = Path(directory) / ('Test.xcarchive' if archive else 'Acouplet.app')
        app = artifact / 'Products/Applications/Acouplet.app' if archive else artifact
        executable = app / 'Contents/MacOS/Acouplet'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'\xcf\xfa\xed\xfe\0')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': executable.name}))
        resources = app / 'Contents/Resources'
        resources.mkdir()
        (resources / 'Assets.car').write_bytes(b'assets')
        for notice in ['LICENSE', 'THIRD-PARTY-NOTICES.md']:
            shutil.copy2(packaging.parent / notice, resources / notice)
        shutil.copy2(packaging.parent / 'Resources/PrivacyInfo.xcprivacy', resources / 'PrivacyInfo.xcprivacy')
        names = [*mini_icons, 'AppIcon', 'AppIcon/SoftParts', 'AppIcon_Assets/Color-1', 'ZZZZPackedAsset-1.0.1-gamut0']
        imports = b'/System/Library/Frameworks/Foundation.framework/Foundation'
        symbols = b'public_symbols'
        if alteration:
            result = alteration(artifact, app, names)
            if isinstance(result, tuple):
                imports, symbols = result
        def command(args, **kwargs):
            if Path(args[0]).name == 'assetutil':
                data = Path(args[-1]).read_bytes()
                return data if data.startswith(b'[') else json.dumps([{'Name': name} for name in names]).encode()
            return imports if Path(args[0]).name == 'otool' else symbols
        failed = False
        with patch('subprocess.check_output', side_effect=command):
            try:
                checker['check_bundle'](artifact)
            except (ValueError, FileNotFoundError):
                failed = True
        assert failed == rejects, name
        print(name + ': passed')


def binary(artifact, app, names, relative, token):
    path = artifact / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\xcf\xfa\xed\xfe\0' + token)


check('public-bundle')
check('public-archive', archive=True)
for token in checker['private_tokens']:
    check('private-main-' + token.decode(), lambda artifact, app, names, token=token:
          (app / 'Contents/MacOS/Acouplet').write_bytes(b'\xcf\xfa\xed\xfe\0' + token), rejects=True)
check('private-nested-dylib', lambda artifact, app, names:
      binary(artifact, app, names, 'Contents/Frameworks/Nested.dylib', b'SystemBannerUI'), rejects=True)
check('private-archive-dsym', lambda artifact, app, names:
      binary(artifact, app, names, 'dSYMs/Helper.dSYM/Contents/Resources/DWARF/Helper', b'io_ps_'), rejects=True, archive=True)
check('private-link', lambda artifact, app, names: (b'/System/Library/PrivateFrameworks/Example', b''), rejects=True)
check('private-symbol', lambda artifact, app, names: (b'', b'IOPSCreatePowerSource'), rejects=True)
check('photographic-asset', lambda artifact, app, names: names.append('XM5Hero'), rejects=True)
check('unknown-asset', lambda artifact, app, names: names.append('FuturePhotograph'), rejects=True)
check('missing-miniature', lambda artifact, app, names: names.remove('Earbuds'), rejects=True)
check('raster-resource', lambda artifact, app, names: (app / 'Contents/Resources/photo.png').write_bytes(b'image'), rejects=True)
check('stale-notices', lambda artifact, app, names: (app / 'Contents/Resources/THIRD-PARTY-NOTICES.md').write_text('old'), rejects=True)
check('missing-privacy-manifest', lambda artifact, app, names: (app / 'Contents/Resources/PrivacyInfo.xcprivacy').unlink(), rejects=True)
check('stale-privacy-manifest', lambda artifact, app, names: (app / 'Contents/Resources/PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({})), rejects=True)
for name in ['Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Sparkle.framework', 'Sparkle-LICENSE.txt', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletAudio', 'AcoupletLDACOutput.driver', 'Acouplet LDAC Output.pkg', 'Acouplet LDAC Removal.pkg', 'LDAC-LICENSE.txt', 'LDAC-NOTICE.txt', 'libldacBT_enc.dylib', 'Install.command', 'Uninstall Service.command', 'Uninstall LDAC Output.command']:
    check('excluded-file-' + name, lambda artifact, app, names, name=name: (app / name).touch(), rejects=True)
check('non-mach-main', lambda artifact, app, names: (app / 'Contents/MacOS/Acouplet').write_bytes(b'placeholder'), rejects=True)
check('updater-link', lambda artifact, app, names: (b'@rpath/Sparkle.framework/Versions/B/Sparkle', b''), rejects=True)
check('updater-symbol', lambda artifact, app, names: (b'', b'OBJC_CLASS_$_SPUUpdater'), rejects=True)
check('updater-info', lambda artifact, app, names: (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Acouplet', 'SUFeedURL': 'https://baglayan.dev/updates/appcast.xml'})), rejects=True)


def nested_asset(artifact, app, names):
    path = artifact / 'Nested/Photos.car'
    path.parent.mkdir(parents=True)
    path.write_text('[{"Name":"XM5Hero"}]')


def nested_raster(artifact, app, names):
    path = artifact / 'Nested/photo.png'
    path.parent.mkdir(parents=True)
    path.write_bytes(b'image')


check('nested-photographic-asset', nested_asset, rejects=True, archive=True)
check('nested-raster-resource', nested_raster, rejects=True, archive=True)


def check_command(name, signing, mode='success', unsigned=False, succeeds=True):
    with tempfile.TemporaryDirectory(prefix='acouplet-store-command-check-') as directory:
        root = Path(directory).resolve()
        scripts = root / 'Packaging'
        scripts.mkdir()
        stub = root / 'stub'
        stub.write_text('''#!/usr/bin/python3
from pathlib import Path
import json, os, sys
root = Path(os.environ['ACOUPLET_STORE_CHECK_ROOT'])
args = sys.argv[1:]
if args == ['-p']:
    (root / 'selected-developer-dir').touch()
    print('/Applications/Selected Xcode.app/Contents/Developer')
    sys.exit(0)
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
if args[0] == 'xcodebuild':
    assert os.environ['DEVELOPER_DIR'] == os.environ['ACOUPLET_STORE_CHECK_DEVELOPER_DIR']
    assert '-allowProvisioningUpdates' not in args
    assert args[-1] == 'archive'
    archive = Path(args[args.index('-archivePath') + 1])
    assert root / '.build/app-store' in archive.parents
    archive.mkdir()
    (archive / 'checked-artifact').write_text('new')
elif args[0].endswith('check-store-bundle.py'):
    assert Path(args[1]).suffix == '.xcarchive'
    if os.environ['ACOUPLET_STORE_CHECK_MODE'] == 'audit-failure': sys.exit(1)
else:
    assert args[:3] == ['--verify', '--deep', '--strict']
'''.replace('#!/usr/bin/python3', '#!' + sys.executable))
        stub.chmod(0o755)
        source = (packaging / 'app-store.sh').read_text()
        for tool in ['xcrun', 'python3', 'codesign', 'xcode-select']:
            source = source.replace('/usr/bin/' + tool, str(stub))
        script = scripts / 'app-store.sh'
        script.write_text(source)
        previous = root / 'dist/Acouplet App Store.xcarchive'
        previous.mkdir(parents=True)
        (previous / 'old-artifact').write_text('old')
        environment = {key: value for key, value in os.environ.items()
                       if key not in {'CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE_SPECIFIER', 'DEVELOPMENT_TEAM', 'DEVELOPER_DIR'}}
        environment.update(signing, ACOUPLET_STORE_CHECK_ROOT=str(root), ACOUPLET_STORE_CHECK_MODE=mode,
                           ACOUPLET_STORE_CHECK_DEVELOPER_DIR=signing.get('DEVELOPER_DIR', '/Applications/Selected Xcode.app/Contents/Developer'))
        result = subprocess.run(['/bin/zsh', str(script), *(['--unsigned'] if unsigned else [])],
                                check=False, env=environment, text=True, capture_output=True)
        assert (result.returncode == 0) == succeeds, (name, result.stdout, result.stderr)
        assert (root / 'selected-developer-dir').exists() == ('DEVELOPER_DIR' not in signing)
        log = root / 'commands.jsonl'
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        if commands:
            build = commands[0]
            settings = dict(arg.split('=', 1) for arg in build if '=' in arg)
            assert settings['ACOUPLET_PUBLIC_APIS_ONLY'] == settings['ACOUPLET_NO_SONY_ARTWORK'] == 'YES'
            assert build[build.index('-configuration') + 1] == 'AppStore'
            assert settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] == 'NO'
            if unsigned:
                assert settings['CODE_SIGNING_ALLOWED'] == 'NO'
                assert not any('--verify' in command for command in commands)
            else:
                assert 'PROVISIONING_PROFILE_SPECIFIER' not in settings
                assert settings['ACOUPLET_APP_STORE_PROFILE'] == signing['PROVISIONING_PROFILE_SPECIFIER']
                assert commands[-1][:3] == ['--verify', '--deep', '--strict']
        if succeeds:
            assert (previous / 'checked-artifact').read_text() == 'new'
            assert not (previous / 'old-artifact').exists()
        else:
            assert (previous / 'old-artifact').read_text() == 'old'
        print(name + ': passed')


check_command('unsigned-command', {}, unsigned=True)
check_command('explicit-developer-directory', {'DEVELOPER_DIR': '/Applications/Chosen Xcode.app/Contents/Developer'}, unsigned=True)
check_command('audit-failure-keeps-previous', {}, mode='audit-failure', unsigned=True, succeeds=False)
check_command('existing-distribution-signing', {'CODE_SIGN_IDENTITY': 'Apple Distribution: Example (ABCDE12345)',
              'PROVISIONING_PROFILE_SPECIFIER': 'Existing Profile', 'DEVELOPMENT_TEAM': 'ABCDE12345'})
check_command('missing-signing-stops-before-build', {}, succeeds=False)
check_command('development-identity-rejected', {'CODE_SIGN_IDENTITY': 'Apple Development',
              'PROVISIONING_PROFILE_SPECIFIER': 'Existing Profile'}, succeeds=False)
