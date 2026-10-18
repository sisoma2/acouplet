import os
import shutil
import subprocess
import tempfile
from pathlib import Path

packaging = Path(__file__).resolve().parent
environment = {key: value for key, value in os.environ.items()
               if key not in ('ACOUPLET_NO_SONY_ARTWORK', 'ACOUPLET_SONY_ARTWORK_DIR')}


with tempfile.TemporaryDirectory(prefix='acouplet-release-source-check-') as directory:
    root = Path(directory)
    repo = root / 'repo'
    subprocess.run(['/usr/bin/git', 'clone', '--shared', '--quiet', str(packaging.parent), str(repo)], check=True)
    record = root / 'source.json'

    def git(*arguments):
        return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *arguments],
                                       env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}, stderr=subprocess.PIPE).decode().strip()

    revision = git('rev-parse', 'HEAD')

    def run(action, succeeds=True, development=False, extra=None):
        result = subprocess.run(['/usr/bin/python3', str(packaging / 'release-source.py'), action, str(repo), str(record),
                                 *(['--development'] if development else [])],
                                check=False, env={**environment, **(extra or {})}, text=True, capture_output=True)
        assert (result.returncode == 0) == succeeds, (action, result.stdout, result.stderr)
        return result.stdout

    def clean():
        git('reset', '--hard', revision)
        git('clean', '-fdx')
        (repo / '.git/info/exclude').write_text('')

    run('capture')
    receipt = run('verify')
    assert 'Revision: ' + revision in receipt and 'Worktree: production clean' in receipt
    first_digest = next(line for line in receipt.splitlines() if line.startswith('Source input SHA256:'))
    assert str(root) not in receipt
    subprocess.run(['/usr/bin/git', '-C', str(repo), 'status', '--porcelain'], check=True, capture_output=True)
    run('verify')
    print('unchanged source and ordinary Git index refreshes: passed')

    source = repo / 'README.md'
    original = source.read_bytes()
    source.write_bytes(original + b'\nchanged\n')
    run('capture', succeeds=False)
    git('add', 'README.md')
    run('capture', succeeds=False)
    clean()
    (repo / 'Sources/Untracked.swift').write_text('untracked')
    run('capture', succeeds=False)
    clean()
    (repo / '.git/info/exclude').write_text('Sources/Untracked.swift\n')
    (repo / 'Sources/Untracked.swift').write_text('ignored compiler input')
    run('capture', succeeds=False)
    clean()
    print('dirty, staged, untracked, and ignored source rejection: passed')

    for flag in ('assume-unchanged', 'skip-worktree'):
        git('update-index', '--' + flag, 'README.md')
        source.write_bytes(original + b'\nhidden change\n')
        assert git('status', '--porcelain') == ''
        run('capture', succeeds=False)
        git('update-index', '--no-' + flag, 'README.md')
        clean()
    print('tracked changes hidden by index flags are rejected: passed')

    run('capture')
    previous = source.stat()
    source.write_bytes(original + b'\nchanged\n')
    source.write_bytes(original)
    os.utime(source, ns=(previous.st_atime_ns, previous.st_mtime_ns))
    assert git('status', '--porcelain') == ''
    run('verify', succeeds=False)
    run('capture')
    assert first_digest in run('verify')
    print('edit-and-revert detected; content receipt remains deterministic: passed')

    run('capture')
    git('read-tree', 'HEAD^')
    run('verify', succeeds=False)
    clean()
    run('capture')
    git('checkout', '--quiet', 'HEAD^')
    run('verify', succeeds=False)
    clean()
    print('index and HEAD drift: passed')

    config = repo / 'Configuration/Direct.xcconfig'
    original_config = config.read_bytes()
    artwork = root / 'private-artwork'
    artwork.mkdir()
    image = artwork / 'photo.bin'
    image.write_bytes(b'private artwork')
    extra = {'ACOUPLET_SONY_ARTWORK_DIR': str(artwork)}
    run('capture', extra=extra)
    receipt = run('verify', extra=extra)
    assert str(root) not in receipt and 'do-not-publish' not in receipt and 'private artwork' not in receipt
    config.write_text('PRIVATE_SETTING = changed\n')
    run('verify', succeeds=False, extra=extra)
    config.write_bytes(original_config)
    run('capture', extra=extra)
    image.write_bytes(b'changed artwork')
    run('verify', succeeds=False, extra=extra)
    run('capture', extra=extra)
    (artwork / 'added.bin').write_bytes(b'new input')
    run('verify', succeeds=False, extra=extra)
    run('capture', extra={**extra, 'ACOUPLET_NO_SONY_ARTWORK': 'YES'})
    image.write_bytes(b'unused artwork')
    run('verify', extra=extra)
    print('private config and used external artwork are pinned without receipt disclosure: passed')

    config.unlink()
    config.symlink_to(image)
    run('capture', succeeds=False)
    config.unlink()
    image.unlink()
    image.symlink_to(source)
    run('capture', succeeds=False, extra=extra)
    clean()
    print('external input symlinks rejected: passed')

    source.write_bytes(original + b'\ndevelopment\n')
    run('capture', development=True)
    assert 'Worktree: development (dirty)' in run('verify')
    source.write_bytes(original + b'\nchanged during development\n')
    receipt = run('verify')
    assert 'Worktree: development (changed during build)' in receipt
    assert 'production clean' not in receipt and 'Revision: ' + revision in receipt
    clean()
    run('capture', development=True)
    assert 'Worktree: development (clean)' in run('verify')
    shutil.rmtree(repo / '.git')
    run('capture', development=True)
    receipt = run('verify')
    assert 'Revision: unversioned' in receipt and 'production clean' not in receipt
    run('capture', succeeds=False)
    print('dirty, clean, changed and unversioned development builds remain development: passed')
