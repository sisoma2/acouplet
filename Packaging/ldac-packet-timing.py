import argparse
import collections
import json
import math
import re
import statistics
import struct
from pathlib import Path

FIELDS = re.compile(r"(\w+)=([^\s]+)")
MAX_RECORD_BYTES = 1024 * 1024


def fingerprint(data):
    value = 14695981039346656037
    for byte in data:
        value = ((value ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016X}"


def session_lines(path):
    path = Path(path)
    if path.is_dir():
        rotated = sorted(
            (p for p in path.glob("session.log.*") if p.suffix[1:].isdigit()),
            key=lambda p: int(p.suffix[1:]),
            reverse=True,
        )
        paths = rotated + [path / "session.log"]
        if (path / "packet-trace.log").is_file():
            paths.append(path / "packet-trace.log")
    else:
        paths = [path]
    for source in paths:
        with source.open() as stream:
            yield from stream


def read_trace(path):
    packets, config, anchor, end, health = {}, {}, None, None, {}
    for line in session_lines(path):
        fields = dict(FIELDS.findall(line))
        if re.search(r"\bSENDER_CONFIG ", line):
            config = fields
        elif re.search(r"\bFEED_COMPLETE ", line):
            health = {
                key: fields[key]
                for key in (
                    "result",
                    "strictPass",
                    "skippedFrames",
                    "sentPackets",
                    "elapsed",
                )
                if key in fields
            }
        elif re.search(r"\bPACKET_TRACE_BEGIN ", line):
            if anchor is not None:
                raise ValueError("Use one session with one packet trace per report")
            anchor = {
                key: float(fields[key]) for key in ("monotonic", "wall", "seconds")
            }
            anchor["dropped"] = int(fields["dropped"])
        elif re.search(r"\bPACKET_TRACE_END ", line):
            end = int(fields["records"])
        elif re.search(r"\bPACKET_TRACE ", line):
            number = int(fields["packet"])
            packet = packets.setdefault(number, {"packet": number, "events": []})
            identity = (
                int(fields["sequence"]),
                int(fields["rtp"]),
                int(fields["length"]),
                fields["fingerprint"].upper(),
            )
            if "identity" in packet and packet["identity"] != identity:
                raise ValueError("Packet identity changed inside the trace")
            packet["identity"] = identity
            at = float(fields["monotonic"])
            if not math.isfinite(at):
                raise ValueError("Nonfinite trace timestamp")
            packet["events"].append(
                {"event": fields["event"], "at": at, "status": int(fields["status"])}
            )
    if anchor is None or not packets:
        raise ValueError(
            "No packet trace found; enable LDACSenderTraceSeconds before the next session"
        )
    if not all(math.isfinite(value) for value in anchor.values()):
        raise ValueError("Invalid trace clock anchor")
    complete = (
        end == sum(len(packet["events"]) for packet in packets.values())
        and not anchor["dropped"]
    )
    return packets, config, anchor, complete, health


def pklg_records(path):
    with Path(path).open("rb") as stream:
        while True:
            header = stream.read(4)
            if not header:
                return
            if len(header) != 4:
                raise ValueError("Truncated PacketLogger record header")
            (length,) = struct.unpack(">I", header)
            if not 9 <= length <= MAX_RECORD_BYTES:
                raise ValueError("Invalid PacketLogger record length")
            record = stream.read(length)
            if len(record) != length:
                raise ValueError("Truncated PacketLogger record")
            seconds, micros, kind = struct.unpack(">IIB", record[:9])
            if micros >= 1000000:
                raise ValueError("Invalid PacketLogger timestamp")
            yield seconds + micros / 1000000, kind, record[9:]


def hci_packets(path, expected):
    pending = collections.defaultdict(collections.deque)
    synchronized, assembly, matched = {}, {}, collections.defaultdict(list)
    issues = collections.Counter()
    completed_events = 0
    expected_by_header = collections.defaultdict(list)
    for identity in expected:
        expected_by_header[identity[:2]].append(identity)

    def finish_sdu(state):
        data = bytes(state["data"])
        if len(data) != state["length"]:
            issues["invalid_l2cap_length"] += 1
            return
        if len(data) < 13 or data[:2] != b"\x80\x60" or data[8:12] != b"XM5\x01":
            return
        sequence, rtp = struct.unpack(">HI", data[2:8])
        identity = (sequence, rtp, len(data), fingerprint(data))
        candidates = expected_by_header.get((sequence, rtp), [])
        if identity in expected:
            matched[identity].append(
                {
                    "handle": state["handle"],
                    "cid": state["cid"],
                    "fragments": state["fragments"],
                }
            )
        elif candidates:
            issues["media_boundary_or_payload_mismatch"] += 1

    for at, kind, data in pklg_records(path):
        if kind == 1:
            if len(data) < 2 or data[1] != len(data) - 2:
                issues["invalid_event_length"] += 1
                continue
            if data[0] == 3 and len(data) >= 5 and data[2] == 0:
                handle = struct.unpack("<H", data[3:5])[0] & 0xFFF
                if pending[handle]:
                    issues["handle_reused_with_pending_packets"] += 1
                pending[handle].clear()
                assembly.pop(handle, None)
                synchronized[handle] = True
            elif data[0] == 5 and len(data) == 6 and data[2] == 0:
                handle = struct.unpack("<H", data[3:5])[0] & 0xFFF
                pending[handle].clear()
                assembly.pop(handle, None)
                synchronized[handle] = False
            elif data[0] == 0x13:
                if len(data) < 3 or len(data) != 3 + 4 * data[2]:
                    issues["invalid_completed_packets_event"] += 1
                    continue
                completed_events += 1
                for offset in range(3, len(data), 4):
                    handle, count = struct.unpack("<HH", data[offset : offset + 4])
                    handle &= 0xFFF
                    if count > len(pending[handle]):
                        issues["unattributed_controller_completions"] += count - len(
                            pending[handle]
                        )
                        synchronized[handle] = False
                        for fragment in pending[handle]:
                            fragment["trusted"] = False
                        pending[handle].clear()
                        continue
                    for _ in range(count):
                        fragment = pending[handle].popleft()
                        if synchronized.get(handle, False) and fragment["trusted"]:
                            fragment["completed_at"] = at
            continue
        if kind != 2:
            continue
        if len(data) < 4:
            issues["invalid_acl_header"] += 1
            continue
        flags, length = struct.unpack("<HH", data[:4])
        handle, boundary, broadcast = flags & 0xFFF, (flags >> 12) & 3, flags >> 14
        if len(data) != 4 + length or broadcast:
            issues["invalid_acl_length_or_broadcast"] += 1
            synchronized[handle] = False
            continue
        fragment = {
            "at": at,
            "completed_at": None,
            "trusted": synchronized.get(handle, False),
        }
        pending[handle].append(fragment)
        if len(pending[handle]) > 16384:
            raise ValueError(
                "Too many uncompleted HCI fragments; capture may lack completion events"
            )
        payload = data[4:]
        if boundary in (0, 2, 3):
            if handle in assembly:
                issues["incomplete_l2cap_sdu"] += 1
            if len(payload) < 4:
                issues["invalid_l2cap_header"] += 1
                assembly.pop(handle, None)
                continue
            sdu_length, cid = struct.unpack("<HH", payload[:4])
            assembly[handle] = {
                "handle": handle,
                "cid": cid,
                "length": sdu_length,
                "data": bytearray(payload[4:]),
                "fragments": [fragment],
            }
        elif boundary == 1:
            if handle not in assembly:
                issues["orphan_acl_continuation"] += 1
                continue
            assembly[handle]["data"].extend(payload)
            assembly[handle]["fragments"].append(fragment)
        state = assembly.get(handle)
        if state is not None and len(state["data"]) >= state["length"]:
            finish_sdu(state)
            del assembly[handle]
    issues["incomplete_l2cap_sdu"] += len(assembly)
    return matched, dict(+issues), completed_events


def distribution(values):
    values = sorted(value for value in values if value is not None)
    if not values:
        return {"count": 0, "median": None, "p95": None, "max": None}
    return {
        "count": len(values),
        "median": statistics.median(values),
        "p95": values[max(0, math.ceil(len(values) * 0.95) - 1)],
        "max": values[-1],
    }


def analyze(session, hci=None):
    packets, config, anchor, complete, health = read_trace(session)
    submitted = {}
    rows = []
    issues = collections.Counter()
    clock_offset = anchor["wall"] - anchor["monotonic"]
    for number, packet in sorted(packets.items()):
        events = packet["events"]
        enqueued = next(
            (event["at"] for event in events if event["event"] == "enqueue"), None
        )
        returned = next(
            (
                event
                for event in events
                if event["event"] == "return" and event["status"] == 0
            ),
            None,
        )
        if returned is None:
            continue
        submit = next(
            (
                event["at"]
                for event in reversed(events)
                if event["event"] == "submit" and event["at"] <= returned["at"]
            ),
            None,
        )
        if enqueued is None or submit is None:
            issues["incomplete_app_packet"] += 1
            continue
        local = next(
            (
                event
                for event in events
                if event["event"] in ("socket-drain", "api-complete")
            ),
            None,
        )
        row = {
            "packet": number,
            "sequence": packet["identity"][0],
            "rtp": packet["identity"][1],
            "length": packet["identity"][2],
            "fingerprint": packet["identity"][3],
            "submit_wall": submit + clock_offset,
            "return_wall": returned["at"] + clock_offset,
            "local_completion_wall": local["at"] + clock_offset
            if local and local["status"] == 0
            else None,
            "local_completion_kind": local["event"] if local else None,
            "app_queue_ms": 1000 * (submit - enqueued),
            "submission_call_ms": 1000 * (returned["at"] - submit),
            "local_completion_ms": 1000 * (local["at"] - submit)
            if local and local["status"] == 0
            else None,
            "host_to_hci_ms": None,
            "controller_observation_ms": None,
            "end_to_controller_ms": None,
        }
        if local and local["status"]:
            issues["api_completion_error"] += 1
        rows.append(row)
        submitted[number] = packet["identity"]
    matches, capture_issues, completion_events = (
        hci_packets(hci, set(submitted.values())) if hci else ({}, {}, 0)
    )
    matched_count = controller_count = 0
    matched_links = set()
    for row in rows:
        candidates = matches.get(submitted[row["packet"]], [])
        if len(candidates) != 1:
            if candidates:
                issues["ambiguous_hci_packet"] += 1
            continue
        match = candidates[0]
        fragments = match["fragments"]
        first, last = fragments[0]["at"], fragments[-1]["at"]
        if first < row["submit_wall"] - 0.002:
            issues["clock_alignment_or_packet_identity"] += 1
            continue
        matched_count += 1
        matched_links.add((match["handle"], match["cid"]))
        row.update(
            hci_first_wall=first,
            hci_last_wall=last,
            hci_fragments=len(fragments),
            host_to_hci_ms=1000 * (first - row["submit_wall"]),
        )
        if all(
            fragment["completed_at"] is not None and fragment["trusted"]
            for fragment in fragments
        ):
            completed = max(fragment["completed_at"] for fragment in fragments)
            if completed < last:
                issues["controller_clock_order"] += 1
                continue
            row.update(
                controller_completed_observed_wall=completed,
                controller_observation_ms=1000 * (completed - last),
                end_to_controller_ms=1000 * (completed - row["submit_wall"]),
            )
            controller_count += 1
    issues.update(capture_issues)
    boundary_failures = (
        issues["media_boundary_or_payload_mismatch"] or issues["ambiguous_hci_packet"]
    )
    verified = (
        bool(rows)
        and matched_count == len(rows)
        and len(matched_links) == 1
        and not issues
        and complete
    )
    fallback = config.get("requestedMode", config.get("mode")) != config.get(
        "mode"
    ) or config.get("requestedWindow", config.get("window")) != config.get("window")
    return {
        "schema": 1,
        "sender": config,
        "sender_fallback": fallback,
        "health": health,
        "trace_complete": complete,
        "submitted_packets": len(rows),
        "hci_matched_packets": matched_count,
        "controller_attributed_packets": controller_count,
        "completion_events": completion_events,
        "boundary_status": "failed"
        if boundary_failures
        else ("verified" if verified else "unverified"),
        "issues": dict(+issues),
        "milliseconds": {
            key: distribution(row[key] for row in rows)
            for key in (
                "app_queue_ms",
                "submission_call_ms",
                "local_completion_ms",
                "host_to_hci_ms",
                "controller_observation_ms",
                "end_to_controller_ms",
            )
        },
        "limitations": [
            "API replies and socket drain are local observations, not controller completions.",
            "HCI completion counts are FIFO-attributed by connection handle, cover transmitted or flushed fragments, and may be batched.",
            "Controller attribution requires observing Connection Complete before traffic on that handle.",
            "HCI completion does not establish earbud decoding or audible playback.",
            "PacketLogger and app wall clocks must share an unchanged system clock.",
        ],
        "packets": rows,
    }


def compare(paths):
    reports = [json.loads(Path(path).read_text()) for path in paths]
    baseline = reports[0]
    comparisons = []
    for report in reports[1:]:
        comparable = all(
            key in baseline["sender"]
            and baseline["sender"][key] == report["sender"].get(key)
            for key in ("sampleRate", "bitrateKbps", "adaptive", "reserveMs")
        )
        comparisons.append(
            {
                "sender": report["sender"],
                "health": report.get("health", {}),
                "requested_sender_applied": not report.get("sender_fallback", False),
                "same_audio_configuration": comparable,
                "boundary_status": report["boundary_status"],
                "controller_attributed_packets": report[
                    "controller_attributed_packets"
                ],
                "median_change_ms": {
                    key: (
                        report["milliseconds"][key]["median"] - value["median"]
                        if report["milliseconds"][key]["median"] is not None
                        and value["median"] is not None
                        else None
                    )
                    for key, value in baseline["milliseconds"].items()
                },
            }
        )
    return {
        "baseline": baseline["sender"],
        "baseline_health": baseline.get("health", {}),
        "comparisons": comparisons,
        "interpretation": "Compare effective packet windows 1 and 4 at the same rate, quality and workload. A fallback to socket/window 1 is not a packet-pipeline trial. Local completion timing across socket and packet APIs has different meanings. Live audio quality and queue/skipped-frame evidence are still required.",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Correlate LDAC submission/local completion with a passive PacketLogger HCI capture."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    analysis = commands.add_parser("analyze")
    analysis.add_argument("session", type=Path)
    analysis.add_argument("--hci", type=Path)
    comparison = commands.add_parser("compare")
    comparison.add_argument("reports", nargs="+", type=Path)
    options = parser.parse_args()
    try:
        if options.command == "analyze":
            result = analyze(options.session, options.hci)
        else:
            if len(options.reports) < 2:
                raise ValueError(
                    "Compare requires a baseline and at least one candidate report"
                )
            result = compare(options.reports)
        print(json.dumps(result, indent=2, allow_nan=False))
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(2, f"{error}\n")


if __name__ == "__main__":
    main()
