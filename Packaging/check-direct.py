import json
import os
import plistlib
import runpy
import shutil
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from check_runner import CheckCases

packaging = Path(__file__).parent
checker = runpy.run_path(str(packaging / 'check-distribution.py'))
inspect_package = checker['inspect_package']
calls = []
failure = None

project = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-',
                                             str(packaging.parent / 'Acouplet.xcodeproj/project.pbxproj')]))['objects']
helper = next(target for target in project.values() if target.get('isa') == 'PBXNativeTarget' and target['name'] == 'Acouplet Battery Publisher')
for config in project[helper['buildConfigurationList']]['buildConfigurations']:
    settings = project[config]['buildSettings']
    if project[config]['name'] in ('Debug', 'Release'):
        assert settings['ENABLE_APP_SANDBOX'] == 'NO' and settings['ENABLE_HARDENED_RUNTIME'] == 'YES'
        assert settings['CODE_SIGN_ENTITLEMENTS'] == 'Helpers/BatteryHelper.entitlements'
assert plistlib.loads((packaging.parent / 'Helpers/BatteryHelper.entitlements').read_bytes()) == {}


def command(args, **kwargs):
    calls.append(args)
    target = Path(args[-1])
    status, stdout, stderr = 0, b'', b''
    if args[1:3] == ['stapler', 'validate']:
        if failure == ('staple', target.name): status, stderr = 1, b'does not have a ticket stapled to it'
    elif args[0] == '/usr/sbin/pkgutil':
        if args[1] == '--check-signature':
            team = 'OTHER67890' if failure == ('team', target.name) else 'ABCDE12345'
            stdout = ('    1. Developer ID Installer: Example (' + team + ')\n').encode()
            if failure != ('timestamp', target.name): stdout += b'Signed with a trusted timestamp on: Oct 1 2026\n'
            if failure == ('signature', target.name): status = 1
            if failure == ('developer-id', target.name): stdout = b'Apple Development\n'
        else:
            assert args[1] == '--expand-full'
            target.mkdir()
            app = Path(args[2]).parents[2]
            if Path(args[2]).name == 'Acouplet LDAC Removal.pkg':
                (target / 'Scripts').mkdir()
                script = target / 'Scripts/postinstall'
                script.write_text((packaging / 'LDACOutputUninstaller/postinstall').read_text().replace('@ACOUPLET_LDAC_SIGNING_TEAM_ID@', 'OTHER67890' if failure == ('scripts-team', 'Acouplet LDAC Removal.pkg') else 'ABCDE12345'))
                script.chmod(0o755)
                (target / 'PackageInfo').write_text('<pkg-info identifier="dev.baglayan.Acouplet.LDACOutput.Removal" version="0.22"><scripts><postinstall file="./postinstall"/></scripts></pkg-info>')
                if failure == ('payload', 'Acouplet LDAC Removal.pkg'):
                    (target / 'Payload').mkdir()
                    (target / 'Payload/unexpected').touch()
                if failure == ('scripts', 'Acouplet LDAC Removal.pkg'): script.write_text('different script')
                if failure == ('scripts-extra', 'Acouplet LDAC Removal.pkg'): (target / 'Scripts/unexpected').touch()
                if failure == ('scripts-mode', 'Acouplet LDAC Removal.pkg'): script.chmod(0o644)
                if failure == ('identity', 'Acouplet LDAC Removal.pkg'):
                    info = target / 'PackageInfo'
                    info.write_text(info.read_text().replace('LDACOutput.Removal', 'LDACOutput'))
                return subprocess.CompletedProcess(args, status, stdout, stderr)
            driver = target / 'Payload/AcoupletLDACOutput.driver'
            shutil.copytree(app / 'Contents/Helpers/AcoupletLDACOutput.driver', driver)
            (target / 'Scripts').mkdir()
            for name in ('preinstall', 'postinstall'):
                script = target / 'Scripts' / name
                script.write_text((packaging / 'LDACOutputInstaller' / name).read_text().replace('@ACOUPLET_LDAC_SIGNING_TEAM_ID@', 'OTHER67890' if failure == ('scripts-team', 'Acouplet LDAC Output.pkg') else 'ABCDE12345'))
                script.chmod(0o755)
            (target / 'PackageInfo').write_text('<pkg-info identifier="dev.baglayan.Acouplet.LDACOutput" version="0.22" install-location="/Library/Audio/Plug-Ins/HAL"><bundle path="./AcoupletLDACOutput.driver" id="dev.baglayan.Acouplet.LDACOutput" CFBundleVersion="22"/><scripts><preinstall file="./preinstall"/><postinstall file="./postinstall"/></scripts></pkg-info>')
            if failure == ('payload', 'Acouplet LDAC Output.pkg'): (driver / 'Contents/MacOS/AcoupletVirtualOutput').write_text('different driver')
            if failure == ('scripts', 'Acouplet LDAC Output.pkg'): (target / 'Scripts/preinstall').write_text('different script')
            if failure == ('scripts-extra', 'Acouplet LDAC Output.pkg'): (target / 'Scripts/unexpected').touch()
            if failure == ('scripts-mode', 'Acouplet LDAC Output.pkg'): (target / 'Scripts/postinstall').chmod(0o644)
            if failure == ('mode', 'Acouplet LDAC Output.pkg'): (driver / 'Contents/MacOS/AcoupletVirtualOutput').chmod(0o600)
    elif '--display' in args:
        if '--entitlements' in args:
            entitlements = {}
            if target.name == 'Acouplet.app':
                entitlements = {'com.apple.security.device.bluetooth': True, 'com.apple.security.network.client': True}
            if failure == ('debugger', target.name): entitlements['com.apple.security.get-task-allow'] = True
            if failure == ('sandbox', target.name): entitlements['com.apple.security.app-sandbox'] = True
            if failure == ('inherit', target.name): entitlements['com.apple.security.inherit'] = True
            if failure == ('extra-entitlement', target.name): entitlements['com.apple.security.device.bluetooth'] = True
            stdout = plistlib.dumps(entitlements)
        else:
            team = 'OTHER67890' if failure == ('team', target.name) else 'ABCDE12345'
            flags = '0x0(none)' if failure == ('runtime', target.name) else '0x10000(runtime)'
            stderr = ('CodeDirectory v=20500 flags=' + flags + '\nTeamIdentifier=' + team + '\n').encode()
            if failure != ('timestamp', target.name): stderr += b'Timestamp=Oct 1 2026\n'
    elif failure == ('signature', target.name) or failure == ('developer-id', target.name) and any(arg.startswith('--test-requirement=') for arg in args): status = 1
    return subprocess.CompletedProcess(args, status, stdout, stderr)


def sparkle_fixture(app):
    info = {'CFBundleExecutable': 'Acouplet', 'SUFeedURL': 'https://baglayan.dev/updates/appcast.xml',
            'SUPublicEDKey': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
            'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
            'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableInstallerLauncherService': False,
            'SUEnableDownloaderService': False, 'SUEnableSystemProfiling': False,
            'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': False, 'CFBundleShortVersionString': '0.22', 'CFBundleVersion': '22', 'AcoupletDistribution': 'production'}
    (app / 'Contents').mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    for target in checker['sparkle']['code_targets'](app):
        if target.name == 'Autoupdate': target.touch()
        else: target.mkdir(parents=True, exist_ok=True)
    resources = app / 'Contents/Frameworks/Sparkle.framework/Resources'
    resources.mkdir()
    (resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.10.0'}))
    resources = app / 'Contents/Resources'
    resources.mkdir(exist_ok=True)
    (resources / 'Sparkle-LICENSE.txt').write_text('Copyright (c) 2006-2013 Andy Matuschak.')
    (resources / 'Acouplet LDAC Output.pkg').write_text('signed installer')
    (resources / 'Acouplet LDAC Removal.pkg').write_text('signed uninstaller')
    driver = app / 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput'
    driver.parent.mkdir(parents=True, exist_ok=True)
    driver.write_text('driver')
    driver.chmod(0o755)
    (driver.parents[1] / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.baglayan.Acouplet.LDACOutput', 'CFBundleVersion': '22'}))


def check_distribution():
    global failure
    failure = None
    calls.clear()
    commands = SimpleNamespace(run=command, check_output=lambda *args: b'@rpath/Sparkle.framework/Versions/B/Sparkle',
                               TimeoutExpired=subprocess.TimeoutExpired, CalledProcessError=subprocess.CalledProcessError)
    with tempfile.TemporaryDirectory(prefix='acouplet-direct-check-') as directory:
        root = Path(directory)
        dmg = root / 'release.dmg'
        dmg.touch()
        sparkle_fixture(root / 'Acouplet.app')
        with patch.dict(inspect_package.__globals__, subprocess=commands), patch.dict(checker['sparkle']['check_bundle'].__globals__, subprocess=commands):
            report = inspect_package(root, True, dmg)
            assert not report['blockers'] and not report['stapled_tickets_verified']
            assert not any(args[1:3] == ['stapler', 'validate'] for args in calls)
            calls.clear()
            report = inspect_package(root, False, dmg)
            assert not report['blockers'] and report['stapled_tickets_verified']
            assert [args[-1] for args in calls if args[1:3] == ['stapler', 'validate']] == [str(root / 'Acouplet.app/Contents/Resources/Acouplet LDAC Output.pkg'), str(root / 'Acouplet.app/Contents/Resources/Acouplet LDAC Removal.pkg'), str(dmg)]
            for name in ('Acouplet.app', 'Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'Sparkle.framework', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver', 'release.dmg'):
                for check in ('signature', 'developer-id', 'timestamp', 'team'):
                    failure = (check, name)
                    assert inspect_package(root, True, dmg)['blockers'], failure
            for name in ('Acouplet.app', 'Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'Sparkle.framework', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver'):
                for check in ('runtime', 'debugger'):
                    failure = (check, name)
                    assert inspect_package(root, True, dmg)['blockers'], failure
            for name in ('Acouplet.app', 'Acouplet Battery Publisher'):
                failure = ('sandbox', name)
                assert inspect_package(root, True, dmg)['blockers'], failure
            for check in ('inherit', 'extra-entitlement'):
                failure = (check, 'Acouplet Battery Publisher')
                assert inspect_package(root, True, dmg)['blockers'], failure
            for check in ('signature', 'developer-id', 'timestamp', 'team', 'payload', 'scripts', 'scripts-team', 'scripts-extra', 'scripts-mode', 'mode', 'staple'):
                failure = (check, 'Acouplet LDAC Output.pkg')
                assert inspect_package(root, check != 'staple', dmg)['blockers'], failure
            for check in ('signature', 'developer-id', 'timestamp', 'team', 'payload', 'scripts', 'scripts-team', 'scripts-extra', 'scripts-mode', 'identity', 'staple'):
                failure = (check, 'Acouplet LDAC Removal.pkg')
                assert inspect_package(root, check != 'staple', dmg)['blockers'], failure
            failure = ('staple', dmg.name)
            assert inspect_package(root, False, dmg)['blockers']
            failure = None
            info_path = root / 'Acouplet.app/Contents/Info.plist'
            original_info = plistlib.loads(info_path.read_bytes())
            for key, value in [('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False), ('SUEnableInstallerLauncherService', True),
                               ('SUSignedFeedFailureExpirationInterval', 1728000), ('SUPublicEDKey', ''),
                               ('SUPublicEDKey', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
                               ('SUFeedURL', 'http://baglayan.dev/updates/appcast.xml'), ('AcoupletDistribution', 'development'), ('AcoupletDistribution', '')]:
                info_path.write_bytes(plistlib.dumps({**original_info, key: value}))
                assert inspect_package(root, True, dmg)['blockers'], key
            info_path.write_bytes(plistlib.dumps(original_info))


stub_source = r'''#!/usr/bin/python3
from pathlib import Path
import json, os, re, shutil, subprocess, sys
root = Path(os.environ['ACOUPLET_DIRECT_CHECK_ROOT'])
mode = os.environ['ACOUPLET_DIRECT_CHECK_MODE']
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log: log.write(json.dumps([name, *args]) + '\n')
if name == 'package.sh':
    identity = os.environ['CODE_SIGN_IDENTITY']
    assert args == ['--direct'] and (identity.startswith('Developer ID Application: ') or re.fullmatch(r'[0-9A-Fa-f]{40}', identity))
    if mode == 'build-failure': sys.exit(65)
elif name == 'ditto': shutil.copytree(args[0], args[1])
elif name == 'build-ldac-output-installer.sh':
    assert Path(args[0]).name == 'AcoupletLDACOutput.driver' and args[2] == '0.22'
    Path(args[1]).write_text('fresh final signed installer')
    Path(args[1]).with_name('Acouplet LDAC Removal.pkg').write_text('fresh final signed uninstaller')
elif name == 'swift':
    assert len(args) == 4 and Path(args[0]).name == 'DMGBackground.swift'
    icon, background = Path(args[1]), Path(args[2])
    assert icon.name == 'AppIcon.icns' and icon.is_file()
    assert background == icon.with_name('DMGBackground.tiff')
    assert args[3] == os.environ['ACOUPLET_DMG_APPEARANCE']
    if mode == 'background-failure': sys.exit(1)
    background.write_text('Fixture background: ' + args[3])
elif name == 'create-dmg.sh':
    assert len(args) == 2
    stage = Path(args[0])
    assert sorted(path.name for path in stage.iterdir()) == ['Acouplet.app', 'Applications']
    assert (stage / 'Applications').is_symlink()
    assert os.readlink(stage / 'Applications') == '/Applications'
    assert (stage / 'Acouplet.app/Contents/Resources/DMGBackground.tiff').read_text() == (stage / 'Acouplet.app/Contents/_CodeSignature/CodeResources').read_text()
    if mode == 'image-failure': sys.exit(1)
    Path(args[1]).write_text('signed image')
elif name == 'codesign':
    if Path(args[-1]).name == 'Acouplet.app':
        background = Path(args[-1]) / 'Contents/Resources/DMGBackground.tiff'
        assert background.read_text() == 'Fixture background: ' + os.environ['ACOUPLET_DMG_APPEARANCE']
        signature = Path(args[-1]) / 'Contents/_CodeSignature/CodeResources'
        signature.parent.mkdir(exist_ok=True)
        signature.write_text(background.read_text())
    assert '--sign' in args and '--timestamp' in args and '--deep' not in args
    if mode == 'sign-failure': sys.exit(1)
elif name == 'hdiutil':
    assert args[0] == 'verify' and Path(args[1]).is_file()
elif name == 'xcrun':
    assert args[:2] == ['notarytool', 'submit'] or args[:2] == ['notarytool', 'log'] or args[:2] == ['stapler', 'staple']
    if args[:2] == ['notarytool', 'submit']:
        assert args[args.index('--keychain-profile') + 1] == 'existing-profile'
        print(json.dumps({'id': 'submission-id', 'status': 'Invalid' if mode == 'notary-invalid' else 'Accepted'}))
    elif args[:2] == ['notarytool', 'log']: Path(args[-1]).write_text('{}')
    elif mode == 'staple-failure': sys.exit(1)
elif name == 'spctl':
    if mode == 'gatekeeper-failure': sys.exit(1)
elif name == 'python3':
    if Path(args[0]).name == 'check-all.py':
        assert len(args) == 1
        if mode == 'tests-failure': sys.exit('Fixture test failure')
    elif Path(args[0]).name == 'release-source.py':
        action = args[1]
        if action == 'capture':
            if mode == 'source-dirty': sys.exit('Production packaging requires clean source.')
            Path(args[3]).write_text('source snapshot')
        else:
            assert Path(args[3]).read_text() == 'source snapshot'
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            if mode == 'source-drift' or (mode == 'source-drift-before-notary' and any(command[0] == 'create-dmg.sh' for command in commands)) or (mode == 'source-drift-after-notary' and any(command[0] == 'spctl' for command in commands)):
                sys.exit('Release source changed during packaging.')
            print('Revision: ' + 'a' * 40 + '\nWorktree: production clean')
    elif Path(args[0]).name == 'check-distribution.py':
        if mode == 'check-failure': sys.exit(1)
        print('{}')
    elif Path(args[0]).name == 'notarize-ldac-installer.py':
        assert Path(args[1], 'Contents/Resources/Acouplet LDAC Output.pkg').read_text() == 'fresh final signed installer'
        assert Path(args[1], 'Contents/Resources/Acouplet LDAC Removal.pkg').read_text() == 'fresh final signed uninstaller'
        if mode == 'installer-notary-failure': sys.exit(1)
    else: sys.exit(subprocess.call(['/usr/bin/python3', *args]))
else: raise AssertionError(name)
'''


def check_release(mode='success', notarize=False, signing=None, succeeds=True, appearance='pearl'):
    with tempfile.TemporaryDirectory(prefix='acouplet-direct-release-check-') as directory:
        root = Path(directory)
        scripts, stubs = root / 'Packaging', root / 'stubs'
        scripts.mkdir()
        stubs.mkdir()
        source = (packaging / 'direct.sh').read_text()
        for name in ('package.sh', 'build-ldac-output-installer.sh', 'create-dmg.sh', 'codesign', 'ditto', 'hdiutil', 'xcrun', 'spctl', 'python3', 'swift'):
            stub = (scripts if name in ('package.sh', 'build-ldac-output-installer.sh', 'create-dmg.sh') else stubs) / name
            stub.write_text(stub_source)
            stub.chmod(0o755)
            source = source.replace(('/usr/sbin/' if name == 'spctl' else '/usr/bin/') + name, str(stub))
        source = source.replace('/bin/sh "$repo_root/Packaging/build-ldac-output-installer.sh"', '"$repo_root/Packaging/build-ldac-output-installer.sh"')
        script = scripts / 'direct.sh'
        script.write_text(source)
        prepared = root / '.build/package/Acouplet'
        app = prepared / 'Acouplet.app'
        for relative in ('Contents/MacOS/Acouplet', 'Contents/Helpers/Acouplet Battery Publisher', 'Contents/Frameworks/SonyNativeHUD.dylib', 'Contents/Helpers/SonyNativeHUDCheck', 'Contents/Resources/Assets.car', 'Contents/Helpers/LDACSignaling', 'Contents/Helpers/LDACMediaTransport', 'Contents/Helpers/SonyAudioConnection', 'Contents/Helpers/LDACLogObserver', 'Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio', 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput', 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist'):
            target = app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('original')
        sparkle_fixture(app)
        (app / 'Contents/Resources/AppIcon.icns').write_text('Fixture icon.')
        for relative in ('Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater', 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer'):
            target = app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('original')
        (root / 'Configuration').mkdir()
        shutil.copy2(packaging.parent / 'Configuration/Direct.entitlements', root / 'Configuration/Direct.entitlements')
        (prepared / 'Build Receipt.txt').write_text('original receipt')
        (prepared / 'Install.command').write_text('must not ship')
        local_previous = root / '.build/local-update/Acouplet/Local Build Receipt.txt'
        local_previous.parent.mkdir(parents=True)
        local_previous.write_text('previous development receipt')
        for name in ('Acouplet.app.dSYM', 'Acouplet Battery Publisher.dSYM'):
            (root / '.build/Build/Products/Release' / name).mkdir(parents=True)
        for name in ('Sparkle.framework.dSYM', 'Autoupdate.dSYM', 'Updater.app.dSYM', 'Installer.xpc.dSYM'):
            (root / '.build/Sparkle-2.10.0/Symbols' / name).mkdir(parents=True)
        dist = root / 'dist'
        dist.mkdir()
        previous = dist / 'Acouplet-0.22.dmg'
        previous.write_text('previous release')
        environment = {key: value for key, value in os.environ.items() if key not in ('CODE_SIGN_IDENTITY', 'NOTARY_KEYCHAIN_PROFILE')}
        environment.update(ACOUPLET_DIRECT_CHECK_ROOT=str(root), ACOUPLET_DIRECT_CHECK_MODE=mode, ACOUPLET_INSTALLER_SIGNING_IDENTITY='Developer ID Installer: Example (ABCDE12345)', ACOUPLET_DMG_APPEARANCE=appearance)
        environment.update({'CODE_SIGN_IDENTITY': 'Developer ID Application: Example (ABCDE12345)', 'NOTARY_KEYCHAIN_PROFILE': 'existing-profile'} if signing is None else signing)
        result = subprocess.run(['/bin/zsh', str(script), *(['--notarize'] if notarize else [])], env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, (mode, result.stdout, result.stderr)
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()] if (root / 'commands.jsonl').exists() else []
        assert local_previous.read_text() == 'previous development receipt'
        if succeeds:
            assert Path(commands[0][1]).name == 'release-source.py' and commands[0][2] == 'capture'
            tests_index = next(index for index, args in enumerate(commands) if args[0] == 'python3' and Path(args[1]).name == 'check-all.py')
            package_index = next(index for index, args in enumerate(commands) if args[0] == 'package.sh')
            assert 0 < tests_index < package_index
            assert commands[tests_index + 1][2] == 'verify'
            signed = [Path(args[-1]).name for args in commands if args[0] == 'codesign']
            installer_index = next(index for index, args in enumerate(commands) if args[0] == 'build-ldac-output-installer.sh')
            background_index = next(index for index, args in enumerate(commands) if args[0] == 'swift')
            outer_index = next(index for index, args in enumerate(commands) if args[0] == 'codesign' and Path(args[-1]).name == 'Acouplet.app')
            assert installer_index < outer_index and background_index < outer_index
            if notarize:
                notary_index = next(index for index, args in enumerate(commands) if args[0] == 'python3' and Path(args[1]).name == 'notarize-ldac-installer.py')
                assert installer_index < notary_index < outer_index
            assert signed == ['SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Acouplet Battery Publisher', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'Sparkle.framework', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver', 'Acouplet.app', 'Acouplet-0.22.dmg'], signed
            assert previous.read_text() == ('signed image' if notarize else 'previous release')
            assert any(args[:3] == ['xcrun', 'notarytool', 'submit'] for args in commands) == notarize
            assert (prepared / 'Build Receipt.txt').read_text() == 'original receipt'
            assert (app / 'Contents/Frameworks/SonyNativeHUD.dylib').read_text() == 'original'
            assert (app / 'Contents/Helpers/SonyNativeHUDCheck').read_text() == 'original'
            assert not (app / 'Contents/Resources/DMGBackground.tiff').exists()
        else:
            assert previous.read_text() == 'previous release'
            if signing is not None: assert not commands, commands
            if mode == 'background-failure':
                assert commands[-1][0] == 'swift'
                assert not any(args[0] == 'codesign' and Path(args[-1]).name == 'Acouplet.app' for args in commands)
            if mode.startswith('source-'):
                assert Path(commands[-1][1]).name == 'release-source.py'
                if mode == 'source-dirty': assert not any(args[0] == 'package.sh' for args in commands)
                if mode != 'source-drift-after-notary': assert not any(args[:3] == ['xcrun', 'notarytool', 'submit'] for args in commands)
            if mode == 'tests-failure':
                assert Path(commands[-1][1]).name == 'check-all.py'
                assert not any(args[0] in ('package.sh', 'codesign', 'xcrun') for args in commands)


checks = CheckCases('Direct release fixtures')
checks.add('distribution-policy', check_distribution)
checks.add('release', check_release)
checks.add('dark', check_release, appearance='dark')
checks.add('notarized', check_release, notarize=True)
checks.add('fingerprint', check_release, signing={'CODE_SIGN_IDENTITY': 'A' * 40})
checks.add('missing-identity', check_release, signing={}, succeeds=False)
checks.add('development-identity', check_release, signing={'CODE_SIGN_IDENTITY': 'Apple Development'}, succeeds=False)
checks.add('missing-notary-profile', check_release, signing={'CODE_SIGN_IDENTITY': 'Developer ID Application: Example (ABCDE12345)'}, notarize=True, succeeds=False)
for mode in ('tests-failure', 'build-failure', 'sign-failure', 'background-failure', 'image-failure', 'check-failure', 'notary-invalid', 'staple-failure', 'gatekeeper-failure', 'installer-notary-failure', 'source-dirty', 'source-drift', 'source-drift-before-notary', 'source-drift-after-notary'):
    checks.add(mode, check_release, mode, notarize=True, succeeds=False)


if __name__ == '__main__':
    checks.main()
