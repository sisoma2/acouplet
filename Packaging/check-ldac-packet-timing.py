import importlib.util
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


source = Path(__file__).with_name('ldac-packet-timing.py')
spec = importlib.util.spec_from_file_location('packet_timing', source)
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


def record(at, kind, data):
    seconds = int(at)
    return struct.pack('>IIIB', 9 + len(data), seconds, round((at - seconds) * 1000000), kind) + data


def event(at, code, payload):
    return record(at, 1, bytes((code, len(payload))) + payload)


def connection(at, handle):
    return event(at, 3, b'\0' + struct.pack('<H', handle) + bytes(6) + b'\1\0')


def completed(at, entries):
    return event(at, 0x13, bytes((len(entries),)) + b''.join(struct.pack('<HH', *entry) for entry in entries))


def acl(at, handle, payload, boundary=2):
    return record(at, 2, struct.pack('<HH', handle | boundary << 12, len(payload)) + payload)


def sdu(payload, cid=0x41):
    return struct.pack('<HH', len(payload), cid) + payload


def packet(sequence, rtp):
    return b'\x80\x60' + struct.pack('>HI', sequence, rtp) + b'XM5\1' + bytes((2,)) + bytes(660)


def trace(packets, kind='socket', dropped=0):
    lines = [f'SENDER_CONFIG mode={kind} window=1 sampleRate=96000 bitrateKbps=990 adaptive=0 reserveMs=250.000',
             'FEED_COMPLETE result=0 strictPass=1 skippedFrames=0 sentPackets=2 elapsed=1',
             f'PACKET_TRACE_BEGIN monotonic=10 wall=1000 seconds=2 records={len(packets) * 4} dropped={dropped}']
    for index, data in enumerate(packets):
        sequence, rtp = struct.unpack('>HI', data[2:8])
        for name, at in [('enqueue', 10.001 + index * .01), ('submit', 10.002 + index * .01),
                         ('return', 10.003 + index * .01),
                         ('socket-drain' if kind == 'socket' else 'api-complete', 10.004 + index * .01)]:
            lines.append(f'PACKET_TRACE event={name} packet={index} sequence={sequence} rtp={rtp} length={len(data)} '
                         f'fingerprint={timing.fingerprint(data)} monotonic={at:.6f} status=0')
    lines.append(f'PACKET_TRACE_END records={len(packets) * 4} dropped={dropped}')
    return '\n'.join(lines) + '\n'


with tempfile.TemporaryDirectory(prefix='acouplet-packet-timing-') as directory:
    root = Path(directory)
    log, capture = root / 'session.log', root / 'capture.pklg'
    packets = [packet(65535, 0xfffffe00), packet(0, 0)]
    log.write_text(trace(packets))
    prefix = connection(999.9, 7) + connection(999.9, 8)
    first = sdu(packets[0])
    traffic = (acl(1000.005, 7, first[:200]) + acl(1000.006, 8, sdu(b'control', 3)) +
               acl(1000.007, 7, first[200:], 1) + acl(1000.015, 7, sdu(packets[1])) +
               completed(1000.020, [(8, 1), (7, 2)]) + completed(1000.030, [(7, 1)]))
    capture.write_bytes(prefix + traffic)
    report = timing.analyze(log, capture)
    assert report['boundary_status'] == 'verified' and report['hci_matched_packets'] == 2, report
    assert report['controller_attributed_packets'] == 2 and report['completion_events'] == 2, report
    first_row = report['packets'][0]
    assert first_row['hci_fragments'] == 2
    assert abs(first_row['app_queue_ms'] - 1) < .0001
    assert abs(first_row['local_completion_ms'] - 2) < .0001
    assert abs(first_row['host_to_hci_ms'] - 3) < .0001
    assert abs(first_row['controller_observation_ms'] - 13) < .0001
    assert first_row['controller_completed_observed_wall'] == 1000.020
    assert 'XM5' not in json.dumps(report) and 'payload' not in json.dumps(report['packets'])
    print('PASS exact RTP identity, sequence/timestamp wrap, fragmented L2CAP, interleaved handles, batched HCI completion attribution and distinct phase timings')

    capture.write_bytes(traffic)
    partial = timing.analyze(log, capture)
    assert partial['hci_matched_packets'] == 2 and partial['controller_attributed_packets'] == 0
    assert partial['milliseconds']['controller_observation_ms']['median'] is None
    capture.write_bytes(prefix + acl(1000.005, 7, sdu(packets[0])))
    missing = timing.analyze(log, capture)
    assert missing['boundary_status'] == 'unverified' and missing['controller_attributed_packets'] == 0
    print('PASS captures starting midconnection and missing completion events retain unknown controller timing')

    for bad in [packets[0] + packets[1], packets[0][:300], packets[0][:-1] + b'\1']:
        capture.write_bytes(prefix + acl(1000.005, 7, sdu(bad)))
        failed = timing.analyze(log, capture)
        assert failed['boundary_status'] == 'failed', failed
    capture.write_bytes(prefix + traffic + acl(1000.040, 7, sdu(packets[0])))
    assert timing.analyze(log, capture)['boundary_status'] == 'failed'
    print('PASS merged, split, changed and duplicated SDUs cannot pass packet-boundary validation')

    capture.write_bytes(prefix + traffic)
    log.write_text(trace(packets, dropped=1))
    assert not timing.analyze(log, capture)['trace_complete']
    assert timing.analyze(log, capture)['boundary_status'] == 'unverified'
    log.write_text(trace(packets).replace('PACKET_TRACE_END records=8 dropped=0\n', ''))
    assert not timing.analyze(log, capture)['trace_complete']
    log.write_text(trace(packets))
    local = timing.analyze(log)
    assert local['hci_matched_packets'] == 0 and local['boundary_status'] == 'unverified'
    capture.write_bytes(prefix + acl(999.999, 7, sdu(packets[0])))
    assert timing.analyze(log, capture)['issues']['clock_alignment_or_packet_identity'] == 1
    print('PASS bounded/dropped traces, missing trace footer, absent HCI and invalid clock alignment never claim complete evidence')

    capture.write_bytes(prefix + traffic + completed(1000.04, [(7, 9)]))
    assert timing.analyze(log, capture)['issues']['unattributed_controller_completions'] == 9
    for bad in [b'\0', struct.pack('>I', 8) + bytes(8), struct.pack('>I', 100), struct.pack('>I', 1048577)]:
        capture.write_bytes(bad)
        try:
            timing.analyze(log, capture)
            raise AssertionError('Malformed capture accepted')
        except ValueError:
            pass
    print('PASS controller count overruns and malformed/truncated/oversized PacketLogger records')

    capture.write_bytes(prefix + traffic)
    baseline_path, candidate_path = root / 'baseline.json', root / 'candidate.json'
    baseline_path.write_text(json.dumps(report))
    log.write_text(trace(packets, kind='packet'))
    candidate_path.write_text(json.dumps(timing.analyze(log, capture)))
    comparison = timing.compare([baseline_path, candidate_path])
    assert comparison['comparisons'][0]['same_audio_configuration']
    assert comparison['comparisons'][0]['median_change_ms']['host_to_hci_ms'] == 0
    for arguments in [['analyze', str(log), '--hci', str(capture)], ['compare', str(baseline_path), str(candidate_path)]]:
        result = subprocess.run([sys.executable, str(source), *arguments], capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and json.loads(result.stdout)
    print('PASS read-only analyze/compare CLI and comparable audio-configuration checks')
    split = root / 'rotated-session'
    split.mkdir()
    (split / 'session.log').write_text('FEED_COMPLETE result=0 strictPass=1 skippedFrames=0\n')
    (split / 'packet-trace.log').write_text(trace(packets, kind='packet'))
    assert timing.analyze(split, capture)['boundary_status'] == 'verified'
    print('PASS dedicated packet trace remains readable independently of rotated session logs')
    log.write_text(trace(packets).replace('mode=socket window=1', 'mode=socket window=1 requestedMode=packet requestedWindow=4'))
    fallback = timing.analyze(log, capture)
    assert fallback['sender_fallback'] and fallback['sender']['mode'] == 'socket' and fallback['sender']['window'] == '1'
    candidate_path.write_text(json.dumps(fallback))
    assert not timing.compare([baseline_path, candidate_path])['comparisons'][0]['requested_sender_applied']
    print('PASS requested packet windows that fall back to socket/window 1 are explicitly identified in analysis and comparisons')
