import json
import plistlib
import re
import runpy
import subprocess
import sys
from pathlib import Path

private_tokens = [
    b'SystemBannerUI', b'SonyNativeHUD', b'sony_native_hud_', b'SwiftUI6_Glass', b'GlassV8explicit',
    b'IOPSCreatePowerSource', b'IOPSSetPowerSourceDetails', b'IOPSReleasePowerSource',
    b'IOPSCopyPowerSourcesByType', b'_pm_connect', b'_pm_disconnect', b'io_ps_',
    b'kCBAdvDataAppearance', b'classicPeer', b'MediaRemote', b'MRMediaRemote',
    b'SonyNativeBatteryPublisher', b'SonyNativeAppearanceRefresh',
    b'Sparkle.framework', b'SPUUpdater', b'SPUStandardUpdaterController', b'AppUpdater',
    b'org.sparkle-project', b'SUFeedURL', b'SUPublicEDKey',
    b'LDACSignaling', b'LDACMediaTransport', b'SonyAudioConnection', b'LDACLogObserver', b'--ldac-owner', b'ldacBT_', b'dev.baglayan.Acouplet.ldac-audio',
    b'AcoupletLDACOutput', b'dev.baglayan.Acouplet.LDACOutput', b'dev.baglayan.Acouplet.ldac-output',
]
mach_headers = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
                b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def check_bundle(artifact):
    app = artifact / 'Products/Applications/Acouplet.app' if artifact.suffix == '.xcarchive' else artifact
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(key.startswith('SU') for key in info):
        raise ValueError('Sparkle updater settings in App Store Info.plist')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file():
        raise ValueError('Missing main executable')
    for path in artifact.rglob('*'):
        if path.suffix in {'.prefPane', '.appex', '.xpc', '.driver'} or path.name in {'Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Sparkle.framework', 'Sparkle-LICENSE.txt', 'Autoupdate', 'Updater.app', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletAudio', 'Acouplet LDAC Output.pkg', 'Acouplet LDAC Removal.pkg', 'LDAC-LICENSE.txt', 'LDAC-NOTICE.txt', 'Install.command', 'Uninstall Service.command'} or path.name.startswith('libldac') or path.suffix == '.command':
            raise ValueError(f'Excluded integration or installer in artifact: {path}')
    binaries = []
    for path in artifact.rglob('*'):
        if not path.is_file():
            continue
        with path.open('rb') as file:
            header = file.read(4)
        if header not in mach_headers:
            continue
        binaries.append(path)
        data = path.read_bytes()
        imports = subprocess.check_output(['/usr/bin/otool', '-arch', 'all', '-L', str(path)])
        symbols = subprocess.check_output(['/usr/bin/nm', '-arch', 'all', '-m', str(path)], stderr=subprocess.STDOUT)
        for token in private_tokens:
            if any(token in value for value in [data, imports, symbols]):
                raise ValueError(f'Excluded private API or integration {token.decode()} in {path}')
        if b'/PrivateFrameworks/' in imports:
            raise ValueError(f'Private framework linked by {path}')
    if executable not in binaries:
        raise ValueError('Main executable is not a Mach-O binary')
    resources = app / 'Contents/Resources'
    for name in ['LICENSE', 'THIRD-PARTY-NOTICES.md', 'Resources/PrivacyInfo.xcprivacy']:
        source = Path(__file__).parent.parent / name
        if (resources / source.name).read_bytes() != source.read_bytes():
            raise ValueError(f'Missing or stale bundled resource: {source.name}')
    plistlib.loads((resources / 'PrivacyInfo.xcprivacy').read_bytes())
    miniature_assets = set(runpy.run_path(str(Path(__file__).with_name('prepare-no-sony-artwork.py')))['mini_icons'])
    allowed_assets = miniature_assets | {'AppIcon', 'AppIcon_Assets/system-dark'}
    allowed_assets |= {'AppIcon_Assets/Gradient-' + str(index) for index in [1, 3, 4]}
    allowed_assets |= {'AppIcon_Assets/Color-' + str(index) for index in range(1, 9)}
    allowed_assets |= {prefix + layer for prefix in ['AppIcon/', 'AppIcon_Assets/']
                       for layer in ['Shells', 'SoftParts']}
    if not list(resources.rglob('*.car')):
        raise ValueError('Missing compiled asset catalog')
    catalogs = list(artifact.rglob('*.car'))
    names = set()
    for catalog in catalogs:
        entries = json.loads(subprocess.check_output(['/usr/bin/assetutil', '-I', str(catalog)]))
        names.update(entry['Name'] for entry in entries if 'Name' in entry)
    unclassified = {name for name in names - allowed_assets
                    if re.fullmatch(r'ZZZZPackedAsset-\d+\.\d+\.\d+-gamut\d+', name) is None}
    if unclassified:
        raise ValueError('Unclassified compiled assets: ' + ', '.join(sorted(unclassified)))
    if not miniature_assets.issubset(names):
        raise ValueError('Missing custom miniature assets')
    for path in artifact.rglob('*'):
        if path.suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.gif'}:
            raise ValueError(f'Unclassified standalone raster artwork: {path}')
    print(f'Artifact audit passed: {len(binaries)} Mach-O files, private integrations and Sony photographs excluded')


if __name__ == '__main__':
    check_bundle(Path(sys.argv[1]).resolve())
