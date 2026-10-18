from check_runner import CheckCases
from contextlib import redirect_stdout, redirect_stderr
from io import StringIO
from threading import Barrier, Lock
from unittest.mock import patch
import os
import time


barrier = Barrier(2, timeout=5)
lock = Lock()
completed = []


def concurrent(name):
    barrier.wait()
    with lock:
        completed.append(name)


checks = CheckCases('Fixture runner checks')
checks.add('selected-first', concurrent, 'selected-first')
checks.add('selected-second', concurrent, 'selected-second')
checks.add('excluded', lambda: (_ for _ in ()).throw(AssertionError('Unselected check ran')))
with redirect_stdout(StringIO()):
    checks.main(['--jobs', '2', '--filter', 'selected-*'])
assert sorted(completed) == ['selected-first', 'selected-second']

output = StringIO()
with redirect_stdout(output):
    checks.main(['--list'])
assert output.getvalue().splitlines() == ['selected-first', 'selected-second', 'excluded']
assert len(completed) == 2

try:
    checks.add('excluded', lambda: None)
except ValueError:
    pass
else:
    raise AssertionError('Duplicate case would silently replace coverage')

failure = CheckCases('Failure propagation')
failure.add('broken-case', lambda: (_ for _ in ()).throw(AssertionError('fixture failed')))
after_failure = []
failure.add('must-not-run', after_failure.append, 'ran')
with redirect_stdout(StringIO()):
    try:
        failure.main(['--jobs', '1'])
    except RuntimeError as error:
        assert 'broken-case' in str(error) and 'fixture failed' in str(error)
    else:
        raise AssertionError('Fixture failure was swallowed')
assert not after_failure

serial = CheckCases('Serial fixture ordering')
order = []
for number in range(4):
    serial.add(str(number), order.append, number)
with patch.dict(os.environ, ACOUPLET_CHECK_JOBS='1'), redirect_stdout(StringIO()):
    serial.main([])
assert order == [0, 1, 2, 3]
weighted = CheckCases('Shared suite and case budget')
active = 0
peak = 0
finished = []


def occupy(name, workers):
    global active, peak
    with lock:
        active += workers
        peak = max(peak, active)
        assert active <= 2, 'Nested checks exceeded the worker budget'
    time.sleep(0.01)
    with lock:
        active -= workers
        finished.append(name)


weighted.add_parallel('two-worker-suite', 2, occupy, 'two-worker-suite', 2)
weighted.add('first-script', occupy, 'first-script', 1)
weighted.add('second-script', occupy, 'second-script', 1)
with redirect_stdout(StringIO()):
    weighted.main(['--jobs', '2'])
assert peak == 2 and active == 0
assert sorted(finished) == ['first-script', 'second-script', 'two-worker-suite']
for arguments in (['--jobs', '0'], ['--jobs', '-1'], ['--filter', 'no-match']):
    with redirect_stderr(StringIO()):
        try:
            serial.main(arguments)
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError('Invalid runner options were accepted')

print('Concurrent execution, complete case inventory, filtering, serial mode and failure propagation: passed')
