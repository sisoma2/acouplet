import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

packaging = Path(__file__).parent
root = packaging.parent
spec = importlib.util.spec_from_file_location('artwork', packaging / 'prepare-no-sony-artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)


def hashes(folder):
    return {p.relative_to(folder).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in folder.rglob('*') if p.is_file()}


def rejects(source, destination):
    before = hashes(destination)
    try:
        artwork.prepare(source, destination)
    except ValueError:
        pass
    else:
        raise AssertionError('Embedded photographs must fail filtering')
    assert hashes(destination) == before


resources = root / 'Resources'
before = hashes(resources)
with tempfile.TemporaryDirectory(prefix='acouplet-artwork-check-') as directory:
    temporary = Path(directory)
    shutil.copytree(resources, temporary / 'Resources')
    source = temporary / 'Resources/Assets.xcassets'
    destination = temporary / 'Filtered.xcassets'
    assert artwork.prepare(source, destination) == 145
    assert {p.stem for p in destination.glob('*.imageset')} == set(artwork.mini_icons)
    assert not list(destination.rglob('*.png'))
    assert all((destination / name).read_bytes() == (source / name).read_bytes() for name in hashes(destination))
    stale = destination / 'StalePhoto.imageset'
    stale.mkdir()
    (stale / 'photo.png').write_bytes(b'photograph')
    new = source / 'UnclassifiedPhoto.imageset'
    new.mkdir()
    (new / 'photo.png').write_bytes(b'photograph')
    artwork.prepare(source, destination)
    assert not stale.exists() and not (destination / new.name).exists()
    vector = source / 'EarbudLeft.imageset/EarbudLeft.svg'
    original = vector.read_text()
    vector.write_text(original.replace('</svg>', '<image href="data:image/png;base64,AA=="/></svg>'))
    rejects(source, destination)
    vector.write_text(original)
    icon_vector = next((temporary / 'Resources/AppIcon.icon/Assets').glob('*.svg'))
    original = icon_vector.read_text()
    icon_vector.write_text(original.replace('</svg>', '<image href="photo.png"/></svg>'))
    rejects(source, destination)
    icon_vector.write_text(original)
    contents = vector.with_name('Contents.json')
    original = contents.read_text()
    contents.write_text(original.replace('EarbudLeft.svg', '../photo.png'))
    rejects(source, destination)
    contents.write_text(original)
    rejects(source, source)
    photographs = temporary / 'Private Photos.xcassets'
    photo = photographs / 'XM5Hero.imageset'
    photo.mkdir(parents=True)
    (photo / 'photo.png').write_bytes(b'product photograph')
    (photo / 'private.txt').write_text('not an asset')
    metadata = {'images': [{'filename': 'photo.png', 'idiom': 'universal'}], 'info': {'version': 1, 'author': 'xcode'}}
    (photo / 'Contents.json').write_text(json.dumps(metadata))
    override = photographs / 'EarbudLeft.imageset'
    override.mkdir()
    (override / 'EarbudLeft.svg').write_text('stale external miniature')
    photo_before = hashes(photographs)
    artwork.prepare(source, destination, photographs)
    assert (destination / photo.name / 'photo.png').read_bytes() == b'product photograph'
    assert not (destination / photo.name / 'private.txt').exists()
    assert (destination / 'EarbudLeft.imageset/EarbudLeft.svg').read_bytes() == vector.read_bytes()
    assert hashes(photographs) == photo_before
    prepared = hashes(destination)
    for filename in ['../private.txt', '/tmp/photo.png', 'photo.svg', 'missing.png']:
        metadata['images'][0]['filename'] = filename
        (photo / 'Contents.json').write_text(json.dumps(metadata))
        try:
            artwork.prepare(source, destination, photographs)
        except (ValueError, FileNotFoundError):
            pass
        else:
            raise AssertionError('Invalid external photograph must fail preparation')
        assert hashes(destination) == prepared
    metadata['images'][0]['filename'] = 'photo.png'
    (photo / 'Contents.json').write_text(json.dumps(metadata))
    (photo / 'photo.png').unlink()
    (photo / 'photo.png').symlink_to(photo / 'private.txt')
    try:
        artwork.prepare(source, destination, photographs)
    except ValueError:
        pass
    else:
        raise AssertionError('Linked photograph must fail preparation')
    assert hashes(destination) == prepared
    (photo / 'photo.png').unlink()
    (photo / 'photo.png').write_bytes(b'product photograph')
    project = plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-',
                                                     str(root / 'Acouplet.xcodeproj/project.pbxproj')]))
    phase = next(value for value in project['objects'].values() if value.get('name') == 'Prepare Artwork')
    derived = temporary / 'Derived Files'
    derived.mkdir()
    environment = dict(os.environ, SRCROOT=str(root), DERIVED_FILE_DIR=str(derived),
                       ACOUPLET_SONY_ARTWORK_DIR=str(photographs), ACOUPLET_NO_SONY_ARTWORK='NO')
    subprocess.run(['/bin/sh', '-c', phase['shellScript']], env=environment, check=True)
    staged = derived / 'PreparedAssets.xcassets'
    assert (staged / photo.name / 'photo.png').exists()
    environment.update(ACOUPLET_NO_SONY_ARTWORK='YES', ACOUPLET_SONY_ARTWORK_DIR='/nonexistent/private/photos')
    subprocess.run(['/bin/sh', '-c', phase['shellScript']], env=environment, check=True)
    assert {p.stem for p in staged.glob('*.imageset')} == set(artwork.mini_icons)
    environment.update(ACOUPLET_NO_SONY_ARTWORK='NO', ACOUPLET_SONY_ARTWORK_DIR='')
    assert subprocess.run(['/bin/sh', '-c', phase['shellScript']], check=False, env=environment, capture_output=True).returncode != 0
    protocol = (root / 'Sources/SonyProtocol.swift').read_text()
    model = protocol.split('enum SonyDeviceModel:', 1)[1].split('\nstruct SonyProtocolInfo:', 1)[0]
    color = protocol.split('struct SonyDeviceColor:', 1)[1].split('\nstruct SonyDeviceInformation:', 1)[0]
    check = temporary / 'main.swift'
    check.write_text('import Foundation\nenum SonyDeviceModel:' + model + '\nstruct SonyDeviceColor:' + color + '''
    #if !ACOUPLET_NO_SONY_ARTWORK
    assert(SonyDeviceModel.whXM5.artwork == "XM5Hero" && SonyDeviceModel.wfXM5.artwork == "WFXM5Hero")
    #endif
for model in SonyDeviceModel.allCases {
    #if ACOUPLET_NO_SONY_ARTWORK
    assert(model.artwork == nil)
    #endif
    for name in [model.symbol, model.leftSymbol, model.rightSymbol, model.caseSymbol, model.filledCaseSymbol].compactMap({ $0 }) {
        assert(FileManager.default.fileExists(atPath: CommandLine.arguments[1] + "/" + name + ".imageset/" + name + ".svg"))
    }
}
''')
    for flags in ([], ['-D', 'ACOUPLET_NO_SONY_ARTWORK']):
        binary = temporary / 'check-model'
        subprocess.run(['/usr/bin/xcrun', 'swiftc', *flags, str(check), '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(destination)], check=True)
assert hashes(resources) == before
print('Artwork filtering, external photographs, build-mode isolation, both model compile modes and source preservation passed')
