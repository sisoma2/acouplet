import os
import time
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from threading import Barrier, Lock
from unittest.mock import patch

from check_runner import CheckCases, default_jobs

barrier = Barrier(2, timeout=5)
lock = Lock()
completed = []


def concurrent(name):
    barrier.wait()
    with lock:
        completed.append(name)


checks = CheckCases("Fixture runner checks")
checks.add("selected-first", concurrent, "selected-first")
checks.add("selected-second", concurrent, "selected-second")
checks.add(
    "excluded", lambda: (_ for _ in ()).throw(AssertionError("Unselected check ran"))
)
with redirect_stdout(StringIO()):
    checks.main(["--jobs", "2", "--filter", "selected-*"])
assert sorted(completed) == ["selected-first", "selected-second"]

output = StringIO()
with redirect_stdout(output):
    checks.main(["--list"])
assert output.getvalue().splitlines() == [
    "selected-first",
    "selected-second",
    "excluded",
]
assert len(completed) == 2

excluded = CheckCases("Excluded checks never execute")
executed = []
for name in ("keep", "skip-first", "skip-second"):
    excluded.add(name, executed.append, name)
with redirect_stdout(StringIO()):
    excluded.main(["--exclude", "skip-f*", "--exclude", "*-second"])
assert executed == ["keep"]
output = StringIO()
with redirect_stdout(output):
    excluded.main(["--list", "--exclude", "skip-*"])
assert output.getvalue().splitlines() == executed
with redirect_stderr(StringIO()), redirect_stdout(StringIO()):
    try:
        excluded.main(["--filter", "skip-*", "--exclude", "skip-*"])
    except SystemExit as error:
        assert error.code == 2
    else:
        raise AssertionError("Empty selection after exclusions was accepted")
assert executed == ["keep"]

try:
    checks.add("excluded", lambda: None)
except ValueError:
    pass
else:
    raise AssertionError("Duplicate case would silently replace coverage")

failure = CheckCases("Failure propagation")
failure.add(
    "broken-case", lambda: (_ for _ in ()).throw(AssertionError("fixture failed"))
)
after_failure = []
failure.add("must-not-run", after_failure.append, "ran")
with redirect_stdout(StringIO()):
    try:
        failure.main(["--jobs", "1"])
    except RuntimeError as error:
        assert "broken-case" in str(error) and "fixture failed" in str(error)
    else:
        raise AssertionError("Fixture failure was swallowed")
assert not after_failure

serial = CheckCases("Serial fixture ordering")
order = []
for number in range(4):
    serial.add(str(number), order.append, number)
with patch.dict(os.environ, ACOUPLET_CHECK_JOBS="1"), redirect_stdout(StringIO()):
    serial.main([])
assert order == [0, 1, 2, 3]
weighted = CheckCases("Shared suite and case budget")
active = 0
peak = 0
finished = []


def occupy(name, workers):
    global active, peak
    with lock:
        active += workers
        peak = max(peak, active)
        assert active <= 2, "Nested checks exceeded the worker budget"
    time.sleep(0.01)
    with lock:
        active -= workers
        finished.append(name)


weighted.add_parallel("two-worker-suite", 2, occupy, "two-worker-suite", 2)
weighted.add("first-script", occupy, "first-script", 1)
weighted.add("second-script", occupy, "second-script", 1)
with redirect_stdout(StringIO()):
    weighted.main(["--jobs", "2"])
assert peak == 2 and active == 0
assert sorted(finished) == ["first-script", "second-script", "two-worker-suite"]

for processors, expected in ((10, 8), (2, 2), (None, 1)):
    with patch("check_runner.os.cpu_count", return_value=processors):
        assert default_jobs() == expected

parallel_suites = CheckCases("Concurrent suites within the default budget")
suite_barrier = Barrier(2, timeout=5)
suite_started = []


def occupy_suite(name):
    with lock:
        suite_started.append(name)
    suite_barrier.wait()


for name in ("first-suite", "second-suite"):
    parallel_suites.add_parallel(name, 4, occupy_suite, name)
with (
    patch.dict(os.environ),
    patch("check_runner.os.cpu_count", return_value=10),
    redirect_stdout(StringIO()),
):
    os.environ.pop("ACOUPLET_CHECK_JOBS", None)
    parallel_suites.main([])
assert sorted(suite_started) == ["first-suite", "second-suite"]

for arguments in (["--jobs", "0"], ["--jobs", "-1"], ["--filter", "no-match"]):
    with redirect_stderr(StringIO()):
        try:
            serial.main(arguments)
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError("Invalid runner options were accepted")

print(
    "Concurrent execution, complete case inventory, filtering, serial mode and failure propagation: passed"
)
