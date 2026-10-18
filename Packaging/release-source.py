import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

source_roots = ('Sources', 'Helpers', 'Vendor', 'Resources', 'Configuration', 'Packaging', 'Controls', 'Acouplet.xcodeproj')


def git(repo, *arguments):
    return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *arguments],
                                   env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}, stderr=subprocess.PIPE)


def metadata(path):
    value = path.lstat()
    return [value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns]


def file_record(path):
    if not path.exists() and not path.is_symlink():
        return None
    before = metadata(path)
    if not stat.S_ISREG(before[2]):
        raise ValueError('Release inputs must be regular files: ' + path.name)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if metadata(path) != before:
        raise ValueError('A release input changed while being read: ' + path.name)
    return {'sha256': digest, 'metadata': before}


def ignored_artifact(name):
    path = Path(name)
    return path.name == '.DS_Store' or path.suffix == '.xcuserstate' or any(part in ('__pycache__', 'xcuserdata') for part in path.parts)


def snapshot(repo, development, artwork):
    try:
        revision = git(repo, 'rev-parse', '--verify', 'HEAD').decode().strip()
    except subprocess.CalledProcessError:
        if not development:
            raise ValueError('Production packaging requires committed Git source.')
        revision = 'unversioned'
    if revision != 'unversioned':
        tree = git(repo, 'rev-parse', 'HEAD^{tree}').decode().strip()
        status = git(repo, 'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none')
        index = os.fsdecode(git(repo, 'ls-files', '--stage', '-z'))
        unchecked = [os.fsdecode(name) for name in git(repo, 'ls-files', '-v', '-z').split(b'\0') if name and (name[:1].islower() or name.startswith(b'S '))]
        names = {os.fsdecode(name) for name in git(repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0') if name}
        ignored = [os.fsdecode(name) for name in git(repo, 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--', *source_roots).split(b'\0') if name]
        ignored = [name for name in ignored if name != 'Configuration/Direct.xcconfig' and not ignored_artifact(name)]
        if not development and (status or ignored or unchecked):
            raise ValueError('Production packaging requires a clean index and worktree, with no untracked release inputs.')
        names.update(ignored)
    else:
        tree, status, index = 'unversioned', b'unversioned', None
        ignored, unchecked = [], []
        names = {str(path.relative_to(repo)) for root in source_roots for path in (repo / root).rglob('*') if path.is_file() or path.is_symlink()}
    names.add('Configuration/Direct.xcconfig')
    files = {name: file_record(repo / name) for name in sorted(names) if not ignored_artifact(name)}
    if artwork:
        catalog = Path(artwork)
        if catalog.is_symlink() or not catalog.is_dir():
            raise ValueError('The Sony artwork input must be a directory, not a symlink.')
        for path in sorted(catalog.rglob('*')):
            if path.is_symlink() or path.is_file():
                files['SonyArtwork/' + str(path.relative_to(catalog))] = file_record(path)
    if revision != 'unversioned' and (git(repo, 'rev-parse', '--verify', 'HEAD').decode().strip() != revision or
                                      git(repo, 'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none') != status or
                                      os.fsdecode(git(repo, 'ls-files', '--stage', '-z')) != index):
        raise ValueError('Git source changed while the release inputs were being recorded.')
    return {'revision': revision, 'tree': tree, 'status': os.fsdecode(status), 'index': index,
            'ignored': ignored, 'unchecked': unchecked, 'files': files}


def receipt(record, changed):
    initial = record['source']
    inputs = {name: {'sha256': item['sha256'], 'mode': stat.S_IMODE(item['metadata'][2])} if item else None
              for name, item in initial['files'].items()}
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    state = 'unversioned' if initial['revision'] == 'unversioned' else 'dirty' if initial['status'] or initial['ignored'] or initial['unchecked'] else 'clean'
    if record['development']:
        state = 'development (' + ('changed during build' if changed else state) + ')'
    else:
        state = 'production clean'
    return '\n'.join(('Revision: ' + initial['revision'], 'Source tree: ' + initial['tree'],
                      'Source input SHA256: ' + digest, 'Worktree: ' + state))


def main():
    action, root, record_path, *options = sys.argv[1:]
    repo, path = Path(root).resolve(), Path(record_path)
    if action == 'capture':
        if options not in ([], ['--development']):
            raise ValueError('Usage: release-source.py capture REPO RECORD [--development]')
        development = bool(options)
        artwork = os.environ.get('ACOUPLET_SONY_ARTWORK_DIR', '')
        if os.environ.get('ACOUPLET_NO_SONY_ARTWORK', 'NO' if artwork else 'YES') != 'NO':
            artwork = ''
        if artwork:
            artwork = str(Path(artwork).absolute())
        record = {'development': development, 'artwork': artwork, 'source': snapshot(repo, development, artwork)}
        path.write_text(json.dumps(record, sort_keys=True))
    elif action == 'verify' and not options:
        record = json.loads(path.read_text())
        current = snapshot(repo, record['development'], record['artwork'])
        changed = current != record['source']
        if changed and not record['development']:
            raise ValueError('Release source changed during packaging. The previous distribution was kept.')
        print(receipt(record, changed))
    else:
        raise ValueError('Usage: release-source.py verify REPO RECORD')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
