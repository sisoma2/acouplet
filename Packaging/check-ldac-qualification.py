from pathlib import Path
import importlib.util
import tempfile

source = Path(__file__).with_name('qualify-ldac.py')
spec = importlib.util.spec_from_file_location('qualification', source)
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)
matrix = qualification.prepare('WH-1000XM4', 'test', 10)
assert len(matrix['cases']) == 48
assert len({case['id'] for case in matrix['cases']}) == 48
assert {case['reserve_ms'] for case in matrix['cases'] if 'reserve_ms' in case} == {100, 250}
for rate in qualification.RATES:
    for quality in qualification.QUALITIES:
        assert sum(case.get('rate') == rate and case.get('quality') == quality for case in matrix['cases']) == 2
with tempfile.TemporaryDirectory(prefix='acouplet-qualification-') as directory:
    directory = Path(directory)
    (directory / 'session.log').write_text('0 LAUNCH media --sample-rate 48000 --quality low --pcm-reserve-ms 250\n0 media LIVE_BEGIN\n0 media LIVE_SENT rate=48000 channels=2 bitrateKbps=330\n1 media PCM_UNDERRUN\n600 media FEED_COMPLETE\n601 COMPLETE successful=true\n')
    statistics = qualification.session_statistics(directory)
    assert statistics['underruns'] == 1
    qualification.record(matrix, 'music-48000-low', statistics, 'pass', 0, 'yes', 'Manual fixture observation')
    assert matrix['cases'][4]['result'] == 'pass'
    for case, stats in [('music-44100-low', statistics), ('music-48000-mid', {**statistics, 'stream_seconds': 10}),
                        ('music-48000-high', {**statistics, 'aborted': True})]:
        try:
            qualification.record(matrix, case, stats, 'pass', 0, 'yes', 'Invalid evidence')
        except ValueError:
            pass
        else:
            raise AssertionError('Incompatible qualification evidence was accepted')
    denied = directory / 'denied'
    denied.mkdir()
    (denied / 'session.log').write_text('0 preflight CAPTURE_PERMISSION denied\n1 COMPLETE successful=false\n')
    denied_statistics = qualification.session_statistics(denied)
    assert denied_statistics['media_observed'] is False
    qualification.record(matrix, 'capture-denied', denied_statistics, 'pass', 0, 'manual-choice-preserved', 'Permission rejected before route takeover')
    try:
        qualification.record(matrix, 'music-48000-low', statistics, 'pass', 0, 'no', 'Route restoration failed')
    except ValueError:
        pass
    else:
        raise AssertionError('A pass with unrestored routes was accepted')
    for invalid in [float('nan'), -1, 0]:
        try:
            qualification.prepare('test', 'test', invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('Invalid duration was accepted')
print('PASS opt-in hardware matrix: all rate/quality combinations in both profiles, lifecycle scenarios and bounded evidence recording')
