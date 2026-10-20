import json
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from check_stubs import StubExecutable

source = """#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['STUB_CHECK_ROOT'])
state = root / 'state'
state.write_text(str(int(state.read_text()) + 1 if state.exists() else 1))
print(json.dumps([Path(sys.argv[0]).name, sys.argv[1:], sys.stdin.read()]))
print('fixture diagnostic', file=sys.stderr)
sys.exit(int(os.environ['STUB_CHECK_EXIT']))
"""
stub = StubExecutable(source)


def check_invocation(root, name, regular):
    directory = root / name
    directory.mkdir()
    command = directory / ("App executable" if regular else "tool with spaces")
    if regular:
        os.link(stub.path, command)
    else:
        stub.link(command)
    assert command.stat().st_ino == stub.path.stat().st_ino
    arguments = [
        "argument with spaces",
        '"quoted"',
        "$literal",
        "Türkçe",
        "line\nbreak",
    ]
    for count, status in enumerate([0, 23], 1):
        result = subprocess.run(
            [command, *arguments],
            input="input\nwith lines\n",
            text=True,
            env={
                **os.environ,
                "STUB_CHECK_ROOT": str(directory),
                "STUB_CHECK_EXIT": str(status),
            },
            capture_output=True,
            check=False,
            timeout=10,
        )
        assert result.returncode == status
        assert json.loads(result.stdout) == [
            command.name,
            arguments,
            "input\nwith lines\n",
        ]
        assert result.stderr == "fixture diagnostic\n"
        assert (directory / "state").read_text() == str(count)
    copied = directory / "Copied executable"
    shutil.copy2(command, copied)
    copied.write_text("changed copy")
    assert stub.path.read_text().endswith(source.split("\n", 1)[1])


try:
    with tempfile.TemporaryDirectory(prefix="acouplet-stub-check-") as temporary:
        root = Path(temporary)
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [
                executor.submit(check_invocation, root, str(index), index % 2 == 0)
                for index in range(8)
            ]
            for future in futures:
                future.result()
finally:
    stub.close()
assert not stub.path.exists()
print(
    "Shared stub executables preserve command identity, arguments, stdin, stdout/stderr, exit status, copied-file isolation and concurrent fixture state: passed"
)
