import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

from build_cache import run_cached


with tempfile.TemporaryDirectory(prefix='acouplet-build-cache-') as directory:
    work = Path(directory)
    source = work / 'Sources'
    source.mkdir()
    header = source / 'Nested.h'
    header.write_text('first')
    output = work / 'helper'
    calls = work / 'calls'
    compiler = work / 'compiler.py'
    compiler.write_text('''import os, sys
from pathlib import Path
output, calls, header = Path(sys.argv[1]), Path(sys.argv[2].removeprefix('log:')), Path(sys.argv[3])
with calls.open('a') as log: log.write('compile\\n')
output.write_text(header.read_text() + '|'.join(sys.argv[4:]))
output.chmod(0o755)
if os.environ.get('FAIL_BUILD'): sys.exit(3)
''')
    command = [sys.executable, compiler, output, 'log:' + str(calls), header]
    cache = work / 'cache'

    def build(arguments=command, restore=False):
        run_cached(arguments, [source, compiler], [output], cache, restore)

    def count():
        return len(calls.read_text().splitlines())

    build()
    original_time = output.stat().st_mtime_ns
    build()
    assert count() == 1 and output.stat().st_mtime_ns == original_time
    timestamp = header.stat().st_mtime_ns
    header.write_text('other')
    os.utime(header, ns=(timestamp, timestamp))
    build()
    assert count() == 2 and output.read_text() == 'other'
    added = source / 'Additional.h'
    added.write_text('new include')
    build()
    added.unlink()
    build()
    assert count() == 4
    build([*command, '-O2'])
    assert count() == 5 and output.read_text() == 'other-O2'
    with patch.dict(os.environ, SWIFT_OPTIMIZATION_LEVEL='-O'):
        build()
        build()
    assert count() == 6
    developer = work / 'Xcode/Contents/Developer'
    tool = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
    tool.parent.mkdir(parents=True)
    tool.write_text('compiler version one')
    with patch.dict(os.environ, DEVELOPER_DIR=str(developer)):
        build()
        build()
        assert count() == 7
        tool.write_text('compiler version two')
        build()
        assert count() == 8
    build(restore=True)
    assert count() == 9
    output.write_text('signed executable')
    build(restore=True)
    assert count() == 9 and output.read_text() == 'other'
    output.unlink()
    build(restore=True)
    assert count() == 9 and output.stat().st_mode & 0o111
    (cache / '0').write_text('damaged cache')
    output.write_text('damaged output')
    build(restore=True)
    assert count() == 10 and output.read_text() == 'other'
    output.chmod(0o644)
    build()
    assert count() == 11 and output.stat().st_mode & 0o111
    with patch.dict(os.environ, FAIL_BUILD='1'):
        try:
            build([*command, 'failure'])
        except subprocess.CalledProcessError as error:
            assert error.returncode == 3
        else:
            raise AssertionError('Failed compilation was accepted')
    assert not (cache / 'record.json').exists()
    build()
    assert count() == 13
    (cache / 'record.json').write_text('{broken')
    build()
    assert count() == 14
    cli = [sys.executable, Path(__file__).with_name('build_cache.py'), '--cache', work / 'cli-cache',
           '--input', source, '--compiler', '--', *command, '-o', output]
    subprocess.run(list(map(str, cli)), check=True)
    subprocess.run(list(map(str, cli)), check=True)
    assert count() == 15
    with patch.dict(os.environ, ACOUPLET_BUILD_CACHE='NO'):
        build()
        build()
    assert count() == 17
print('Build reuse, content and toolchain invalidation, output restoration, executable modes and failed builds: passed')
