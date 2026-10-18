import hashlib
import os
import plistlib
import subprocess
import tarfile
import tempfile
from pathlib import Path

packaging = Path(__file__).parent


def check_fetch(name, environment=None, cached=None, succeeds=True, downloads=False, valid_archive=False):
    with tempfile.TemporaryDirectory(prefix='acouplet-sparkle-check-') as directory:
        root = Path(directory)
        scripts = root / 'Packaging'
        scripts.mkdir()
        curl = root / 'curl'
        curl.write_text('#!/bin/zsh\nprint download > "${0:A:h}/network-call"\nif [[ -f "${0:A:h}/fixture.tar.xz" ]]; then\n    cp "${0:A:h}/fixture.tar.xz" "$7"\nelse\n    print invalid-archive > "$7"\nfi\n')
        curl.chmod(0o755)
        script = scripts / 'fetch-sparkle.sh'
        source = (packaging / 'fetch-sparkle.sh').read_text().replace('/usr/bin/curl', str(curl))
        if valid_archive:
            fixture = root / 'fixture'
            resources = fixture / 'Sparkle.framework/Resources'
            resources.mkdir(parents=True)
            (resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.10.0'}))
            (fixture / 'LICENSE').write_text('fixture license')
            archive = root / 'fixture.tar.xz'
            with tarfile.open(archive, 'w:xz') as file:
                for path in fixture.iterdir(): file.add(path, arcname=path.name)
            source = source.replace('c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c', hashlib.sha256(archive.read_bytes()).hexdigest())
        script.write_text(source)
        dependency = root / '.build/Sparkle-2.10.0'
        if cached is not None:
            resources = dependency / 'Sparkle.framework/Resources'
            resources.mkdir(parents=True)
            (resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': cached}))
        variables = {key: value for key, value in os.environ.items()
                     if key not in {'ACOUPLET_SPARKLE_ENABLED', 'ACOUPLET_PUBLIC_APIS_ONLY', 'CONFIGURATION'}}
        variables.update(environment or {})
        result = subprocess.run(['/bin/zsh', str(script)], env=variables, capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, (name, result.stdout, result.stderr)
        assert (root / 'network-call').exists() == downloads, name
        if downloads:
            assert dependency.exists() == valid_archive
            assert not list((root / '.build').glob('sparkle-download.*'))
        if valid_archive:
            assert (dependency / 'LICENSE').read_text() == 'fixture license'
            assert plistlib.loads((dependency / 'Sparkle.framework/Resources/Info.plist').read_bytes())['CFBundleShortVersionString'] == '2.10.0'
            assert all(path.stat().st_mode & 0o200 for path in [dependency, *dependency.rglob('*')])
        print(name + ': passed')


check_fetch('store-excludes-download', {'CONFIGURATION': 'AppStore'})
check_fetch('public-apis-exclude-download', {'ACOUPLET_PUBLIC_APIS_ONLY': 'YES'})
check_fetch('disabled-excludes-download', {'ACOUPLET_SPARKLE_ENABLED': 'NO'})
check_fetch('pinned-cache-reused', cached='2.10.0')
check_fetch('wrong-cache-version-rejected', cached='2.9.6', succeeds=False)
check_fetch('modified-archive-rejected', succeeds=False, downloads=True)
check_fetch('valid-archive-installed-writable-and-temporary-files-removed', downloads=True, valid_archive=True)
