import json
import plistlib
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


def placeholders(value):
    return Counter(re.findall(r'%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]', value))


def read_catalog(path):
    catalog = json.loads(path.read_text())
    assert catalog['sourceLanguage'] == 'en'
    for key, entry in catalog['strings'].items():
        english = entry['localizations']['en']['stringUnit']['value']
        turkish = entry['localizations']['tr']['stringUnit']['value']
        assert turkish, 'Empty Turkish translation: ' + key
        assert placeholders(english) == placeholders(turkish), 'Changed placeholders: ' + key
        assert entry['localizations']['tr']['stringUnit']['state'] == 'translated', key
    return catalog


def check_catalog(root):
    catalog = read_catalog(root / 'Resources/Localizable.xcstrings')
    for path in [*(root / 'Sources').glob('*.swift'), root / 'Helpers/NativeHUD/SonyNativeHUD.swift']:
        source = path.read_text()
        for literal in re.findall(r'(?:String\(localized:|(?:Text|Button|Label|Toggle|Picker|LabeledContent|Section|TextField|GroupBox|\.help|\.accessibilityLabel|\.alert)\()\s*("(?:\\[nrt"\\]|[^"\\])*")', source):
            key = json.loads(literal)
            assert key in catalog['strings'], str(path) + ': missing key ' + key
    return catalog


def check_table(resources, catalog, table, exact=False):
    for language in ['en', 'tr']:
        path = resources / (language + '.lproj') / (table + '.strings')
        actual = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
        if exact:
            assert actual.keys() == catalog['strings'].keys(), str(path) + ': unexpected localized keys'
        for key, entry in catalog['strings'].items():
            expected = entry['localizations'][language]['stringUnit']['value']
            assert actual.get(key) == expected, language + ': missing or incorrect bundled translation: ' + key


def check_bundle(app, catalog, permission_catalog, audio_catalog):
    check_table(app / 'Contents/Resources', catalog, 'Localizable')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    helper = app / 'Contents/Helpers/Acouplet Audio.app'
    main_permissions = {'strings': dict(permission_catalog['strings'])}
    if helper.exists():
        main_permissions['strings'].update(audio_catalog['strings'])
        helper_info = plistlib.loads((helper / 'Contents/Info.plist').read_bytes())
        assert helper_info['NSAudioCaptureUsageDescription'] == audio_catalog['strings']['NSAudioCaptureUsageDescription']['localizations']['en']['stringUnit']['value']
        check_table(helper / 'Contents/Resources', audio_catalog, 'InfoPlist', exact=True)
    expected_keys = set(main_permissions['strings'])
    assert {key for key in info if key.endswith('UsageDescription')} == expected_keys, 'Unexpected main permission descriptions'
    for key, entry in main_permissions['strings'].items():
        assert info[key] == entry['localizations']['en']['stringUnit']['value'], 'Incorrect English permission fallback: ' + key
    check_table(app / 'Contents/Resources', main_permissions, 'InfoPlist', exact=True)


def check_extraction(directory, catalog):
    file_list = directory / 'Acouplet.SwiftFileList'
    assert file_list.is_file(), 'Pass the app build Objects-normal/<arch> directory containing Acouplet.SwiftFileList'
    expected = {Path(line.strip('"')).resolve() for line in file_list.read_text().splitlines() if line}
    assert expected, 'Empty app Swift source list'
    paths = list(directory.rglob('*.stringsdata'))
    assert paths, 'No native string extraction files in ' + str(directory)
    keys = set()
    sources = set()
    for path in paths:
        data = json.loads(path.read_text())
        source = Path(data['source']).resolve()
        if source not in expected:
            continue
        assert path.stat().st_mtime_ns >= source.stat().st_mtime_ns, 'Stale native string extraction: ' + str(path)
        sources.add(source)
        for entry in data['tables'].get('Localizable', []):
            keys.add(entry['key'])
    assert sources == expected, 'Missing native string extraction for: ' + ', '.join(sorted(str(path) for path in expected - sources))
    assert keys, 'Native extraction contained no localized strings'
    missing = keys - catalog['strings'].keys()
    assert not missing, 'Missing native extracted keys:\n' + '\n'.join(sorted(missing))
    print('Native compiler extraction coverage: passed (' + str(len(keys)) + ' keys across ' + str(len(sources)) + ' compiled sources)')


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    catalog = check_catalog(root)
    permission_catalog = read_catalog(root / 'Resources/InfoPlist.xcstrings')
    audio_catalog = read_catalog(root / 'Helpers/LDAC/Resources/InfoPlist.xcstrings')
    assert set(permission_catalog['strings']) == {'NSBluetoothAlwaysUsageDescription'}
    assert set(audio_catalog['strings']) == {'NSAudioCaptureUsageDescription'}
    if len(sys.argv) > 1:
        assert len(sys.argv) == 3, 'Bundle verification requires the app and its native compiler extraction directory'
        check_bundle(Path(sys.argv[1]), catalog, permission_catalog, audio_catalog)
        check_extraction(Path(sys.argv[2]), catalog)
    else:
        print('Native compiler interpolation coverage not checked; pass the built app and its Objects-normal/<arch> directory')
    print('English fallback, Turkish coverage and format placeholders: passed (' + str(len(catalog['strings'])) + ' keys)')
