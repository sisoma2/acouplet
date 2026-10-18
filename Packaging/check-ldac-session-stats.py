from pathlib import Path
import importlib.util
import json
import tempfile

root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('ldac_session_stats', root / 'ldac-session-stats.py')
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)

fixtures = {
    'promotion': [
        '0 media LIVE_BEGIN',
        '0 media LIVE_SENT rate=48000 channels=2 bitrateKbps=330',
        '10 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=660 frameBytes=220',
        '20 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=990 frameBytes=330',
        '30 media FEED_COMPLETE',
    ],
    'demotion': [
        '0 media LIVE_BEGIN',
        '0 media LIVE_SENT rate=44100 channels=2 bitrateKbps=909',
        '10 media LIVE_FORMAT rate=44100 channels=2 bitrateKbps=606 frameBytes=220',
        '20 media LIVE_FORMAT rate=44100 channels=2 bitrateKbps=303 frameBytes=110',
        '30 media FEED_COMPLETE',
    ],
    'malformed': [
        '0 media LIVE_BEGIN',
        '0 media LIVE_SENT rate=48000 channels=2 bitrateKbps=330',
        '1 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=nan frameBytes=330',
        '2 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=990 frameBytes=110',
        '3 media LIVE_FORMAT rate=48000 channels=1 bitrateKbps=990 frameBytes=330',
        '4 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=990',
        '5 media LIVE_FORMAT rate=32000 channels=2 bitrateKbps=990 frameBytes=330',
        '6 media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=inf frameBytes=330',
        'nan media LIVE_FORMAT rate=48000 channels=2 bitrateKbps=990 frameBytes=330',
        '10 media FEED_COMPLETE',
    ],
    'partial': [
        '10 media LIVE_PROGRESS sentPackets=100',
        '15 media LIVE_FORMAT rate=96000 channels=2 bitrateKbps=990 frameBytes=330',
        '25 media LIVE_PROGRESS sentPackets=200',
    ],
    'reset': [
        '0 media LIVE_BEGIN',
        '5 media PCM_ENCODER_RESET skippedFrames=128 rate=48000 bitrateKbps=330 eqmid=2',
        '10 media FEED_COMPLETE',
    ],
}

with tempfile.TemporaryDirectory(prefix='acouplet-session-stats-') as directory:
    directory = Path(directory)
    results = {}
    for name, lines in fixtures.items():
        session = directory / name
        session.mkdir()
        (session / 'session.log').write_text('\n'.join(lines) + '\n')
        results[name] = stats.analyze(name, stats.log_files(session))
    promotion = results['promotion']
    assert promotion['bitrate_kbps'] == 990
    assert promotion['bitrate_seconds'] == {'330': 10, '660': 10, '990': 10}
    assert promotion['bitrate_time_weighted_kbps'] == 660
    assert promotion['bitrate_min_kbps'] == 330 and promotion['bitrate_max_kbps'] == 990
    assert not promotion['partial']
    assert results['demotion']['bitrate_seconds'] == {'909': 10, '606': 10, '303': 10}
    assert results['demotion']['bitrate_kbps'] == 303
    assert results['malformed']['bitrate_kbps'] == 330
    assert results['malformed']['bitrate_seconds'] == {'330': 10}
    assert results['partial']['partial']
    assert results['partial']['bitrate_unknown_seconds'] == 5
    assert results['partial']['bitrate_seconds'] == {'990': 10}
    assert results['partial']['bitrate_timeline'][0]['offset_seconds'] == 5
    assert results['reset']['bitrate_unknown_seconds'] == 5
    assert results['reset']['bitrate_seconds'] == {'330': 5}
    rotated = directory / 'rotated'
    rotated.mkdir()
    (rotated / 'session.log.2').write_text('\n'.join(fixtures['promotion'][:2]) + '\n')
    (rotated / 'session.log.1').write_text(fixtures['promotion'][2] + '\n')
    (rotated / 'session.log').write_text('\n'.join(fixtures['promotion'][3:]) + '\n')
    replay = stats.analyze('rotated', stats.log_files(rotated))
    assert replay['bitrate_timeline'] == promotion['bitrate_timeline']
    assert not replay['partial']
    (rotated / 'session.log.2').unlink()
    replay = stats.analyze('rotated', stats.log_files(rotated))
    assert replay['partial'] and replay['bitrate_seconds'] == {'660': 10, '990': 10}
    json.dumps(results, allow_nan=False)
    report = stats.render(list(results.values()), dict(sessions=5, aborts=0, stream_hours=1, aborts_per_hour=0, cascades=0, cascades_per_hour=0))
    assert 'rate/last kbps' in report and '990 kb/s for 10s' in report

print('PASS adaptive bitrate promotions, demotions, malformed events, resets, rotations and partial timelines')
