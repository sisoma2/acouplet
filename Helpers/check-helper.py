import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
identifier, marker = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()


def sample(**updates):
    part = {"level": 40, "isCharging": False, "observedAt": time.time()}
    value = {
        "identifier": identifier,
        "name": "WF-1000XM5",
        "address": "02:00:00:00:00:19",
        "controlSession": 1,
        "left": part,
        "right": part.copy(),
    }
    value.update(updates)
    return json.dumps(value) + "\n"


def child(mode="--model"):
    return subprocess.Popen(
        [binary, mode, identifier, marker],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def submitted(process, line):
    process.stdin.write(line)
    process.stdin.flush()
    assert select.select([process.stdout], [], [], 3)[0], (
        "helper did not acknowledge model input"
    )
    reply = json.loads(process.stdout.readline())
    assert reply == {
        "event": "refresh-completed",
        "pid": process.pid,
        "sample": json.loads(line),
        "update": 1,
    }, reply


assert subprocess.run([binary, "--self-test"], check=True).returncode == 0
for publishes in (False, True):
    process = child()
    if publishes:
        submitted(process, sample())
    process.stdin.close()
    assert process.wait(timeout=3) == 0
    output, error = process.stdout.read(), process.stderr.read()
    assert output == "" and error == "", (output, error)
print("graceful EOF before/after model input: passed")

for invalid in (
    "[]\n",
    sample(identifier=str(uuid.uuid4())),
    sample(right={"level": 0, "isCharging": False, "observedAt": time.time()}),
    sample(left={"level": 40, "isCharging": False, "observedAt": time.time() - 21}),
    sample(right={"level": 40, "isCharging": False, "observedAt": time.time() + 6}),
    sample(**{"Power Source ID": 123}),
):
    process = child()
    output, error = process.communicate(invalid, timeout=3)
    assert process.returncode == 2 and output == "" and error == "", (output, error)
process = child()
line = sample()
submitted(process, line)
output, error = process.communicate(line, timeout=3)
assert process.returncode == 2 and output == "" and error == "", (output, error)
print(
    "invalid identity, unavailable part, freshness, source ID and replay stop without model acceptance: passed"
)

case = {
    "identifier": identifier,
    "name": "WF-1000XM5",
    "address": "02:00:00:00:00:19",
    "controlSession": 1,
    "caseBattery": {"level": 0, "isCharging": False, "observedAt": time.time()},
}
process = child("--case-model")
line = json.dumps(case) + "\n"
submitted(process, line)
output, error = process.communicate(line, timeout=3)
assert process.returncode == 2 and output == "" and error == "", (output, error)
for mode, invalid in (
    ("--model", line),
    ("--case-model", sample()),
    (
        "--case-model",
        json.dumps(dict(case, caseBattery=dict(case["caseBattery"], level=101))) + "\n",
    ),
):
    process = child(mode)
    output, error = process.communicate(invalid, timeout=3)
    assert process.returncode == 2 and output == "" and error == "", (output, error)
print(
    "Case accepts zero, rejects replay/out-of-range input and remains separate from the pair: passed"
)

parent_source = """import json, os, subprocess, sys, time
child = subprocess.Popen(sys.argv[1:5], stdin=subprocess.PIPE, stdout=open(sys.argv[5], 'w'), stderr=subprocess.STDOUT)
print(child.pid, flush=True)
if sys.argv[6] == 'publish':
    child.stdin.write(sys.argv[7].encode()); child.stdin.flush()
time.sleep(30)
"""


def running(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


with tempfile.TemporaryDirectory(prefix="acouplet-battery-eof-") as directory:
    for publishes in (False, True):
        log = Path(directory) / ("published.log" if publishes else "empty.log")
        parent = subprocess.Popen(
            [
                sys.executable,
                "-c",
                parent_source,
                binary,
                "--model",
                identifier,
                marker,
                str(log),
                "publish" if publishes else "empty",
                sample(),
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        child_pid = None
        try:
            assert select.select([parent.stdout], [], [], 3)[0], (
                "parent did not spawn child"
            )
            child_pid = int(parent.stdout.readline())
            if publishes:
                deadline = time.monotonic() + 3
                while (
                    time.monotonic() < deadline
                    and "refresh-completed" not in log.read_text()
                ):
                    time.sleep(0.02)
                assert "refresh-completed" in log.read_text()
            parent.kill()
            assert parent.wait(timeout=3) == -signal.SIGKILL
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and running(child_pid):
                time.sleep(0.02)
            assert not running(child_pid), "model helper survived parent EOF"
            reports = [json.loads(line) for line in log.read_text().splitlines()]
            assert len(reports) == int(publishes) and all(
                report["event"] == "refresh-completed" for report in reports
            ), reports
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait(timeout=3)
            if child_pid is not None and running(child_pid):
                os.kill(child_pid, signal.SIGKILL)
print(
    "verified parent SIGKILL before/after model input terminates child through stdin EOF: passed"
)
print("model-only checks complete; no IOPS calls")
