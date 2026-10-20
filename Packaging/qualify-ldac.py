import argparse
import datetime
import importlib.util
import json
import math
import platform
import sys
from pathlib import Path

RATES = (44100, 48000, 88200, 96000)
QUALITIES = ("low", "mid", "high", "auto")
SCENARIOS = (
    (
        "sleep-wake",
        "Play for two minutes, sleep and wake the Mac, then verify recovery and restored routes.",
    ),
    (
        "headset-power-cycle",
        "Power the headphones off and on during playback; verify one controlled reconnection.",
    ),
    (
        "owner-exit",
        "Terminate only the LDAC owner during playback; verify ordinary audio and route restoration.",
    ),
    (
        "competing-source",
        "Start playback on a multipoint peer; verify LDAC stops and does not automatically take ownership back.",
    ),
    (
        "builtin-microphone",
        "Use the Mac microphone with the separate-microphone policy; check uninterrupted playback and echo.",
    ),
    (
        "usb-microphone",
        "Use a USB microphone with the separate-microphone policy; reconnect it and verify safe fallback.",
    ),
    (
        "headset-microphone",
        "Use the headset microphone in a call; verify ordinary call audio and controlled LDAC resume.",
    ),
    (
        "manual-handoff",
        "Use explicit call handoff and resume; verify microphone and output restoration.",
    ),
    (
        "manual-output-change",
        "Select another Mac output during playback; verify that the explicit choice is preserved.",
    ),
    (
        "manual-off",
        "Turn LDAC off, reconnect the headphones and restart the app; verify automatic activation stays suppressed.",
    ),
    (
        "selected-app-restart",
        "Route one app through LDAC, restart that app and verify that capture resumes.",
    ),
    (
        "browser-processes",
        "Route a browser, create and close audio tabs and verify helper processes follow the selection.",
    ),
    (
        "excluded-app-output",
        "Play a selected app and an excluded app together; verify the excluded app stays audible on its separate output.",
    ),
    (
        "capture-denied",
        "Deny system-audio permission; verify failure before audio route takeover.",
    ),
    (
        "xm4-multipoint",
        "On WH-1000XM4, verify the multipoint restriction and explicit confirmation; qualify newer models independently.",
    ),
    (
        "video-sync",
        "Compare a synchronized flash/click video at each rate in players honoring Core Audio latency; record offsets and receiver reports.",
    ),
)


def timestamp():
    return datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds")


def prepare(model, firmware, minutes):
    if not math.isfinite(minutes) or not 1 <= minutes <= 1440:
        raise ValueError("Duration must be between 1 and 1440 minutes.")
    cases = []
    for profile, reserve in [("music", 250), ("video", 100)]:
        for rate in RATES:
            for quality in QUALITIES:
                cases.append(
                    {
                        "id": f"{profile}-{rate}-{quality}",
                        "profile": profile,
                        "reserve_ms": reserve,
                        "rate": rate,
                        "quality": quality,
                        "minimum_seconds": minutes * 60,
                        "instructions": "Play continuously; record audible defects, stalls, skips and final restored routes.",
                        "result": "pending",
                    }
                )
    cases.extend(
        {"id": name, "instructions": instructions, "result": "pending"}
        for name, instructions in SCENARIOS
    )
    return {
        "schema": 1,
        "created": timestamp(),
        "macOS": platform.mac_ver()[0],
        "model": model,
        "firmware": firmware,
        "evidence": "Manual hardware observations plus session logs; offline checks do not qualify audible or RF behavior.",
        "cases": cases,
    }


def session_statistics(directory):
    source = Path(__file__).with_name("ldac-session-stats.py")
    spec = importlib.util.spec_from_file_location("ldac_session_stats", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    files = module.log_files(directory)
    if not files:
        raise ValueError(
            "No session.log files were found in the supplied session directory."
        )
    statistics = module.analyze("hardware", files)
    if statistics is None:
        return {"media_observed": False, "partial": True}
    keys = (
        "rate",
        "quality",
        "pcm_reserve_ms",
        "bitrate_kbps",
        "stream_seconds",
        "partial",
        "aborted",
        "underruns",
        "pcm_skips",
        "skipped_frames",
        "drain_breaches",
        "max_drain",
        "bitrate_timeline",
        "bitrate_unknown_seconds",
    )
    return {key: statistics.get(key) for key in keys}


def record(
    matrix, case_id, statistics, result, recovery_seconds, routes_restored, notes
):
    if not math.isfinite(recovery_seconds) or recovery_seconds < 0:
        raise ValueError("Recovery time must be a finite nonnegative number.")
    case = next((case for case in matrix["cases"] if case["id"] == case_id), None)
    if case is None:
        raise ValueError("Unknown hardware scenario: " + case_id)
    if result == "pass" and routes_restored == "no":
        raise ValueError(
            "A pass requires restored routes or a preserved manual route choice."
        )
    if result == "pass" and "rate" in case:
        if statistics.get("rate") != case["rate"]:
            raise ValueError("The observed sample rate does not match this scenario.")
        if (
            statistics.get("quality") != case["quality"]
            or statistics.get("pcm_reserve_ms") != case["reserve_ms"]
        ):
            raise ValueError(
                "The observed quality and reserve must match this scenario."
            )
        if case["quality"] != "auto":
            high = 909 if case["rate"] % 44100 == 0 else 990
            expected = high * {"low": 1, "mid": 2, "high": 3}[case["quality"]] // 3
            if statistics.get("bitrate_kbps") != expected:
                raise ValueError(
                    "The transmitted bitrate does not match the fixed quality."
                )
        if (
            statistics["stream_seconds"] < case["minimum_seconds"]
            or statistics["aborted"]
        ):
            raise ValueError(
                "A sustained-playback pass needs the full duration and no aborted session."
            )
    case.update(
        result=result,
        recorded=timestamp(),
        statistics=statistics,
        recovery_seconds=recovery_seconds,
        routes_restored=routes_restored,
        notes=notes[:4096],
    )


def main(arguments=None):
    parser = argparse.ArgumentParser(
        description="Prepare or record opt-in LDAC hardware qualification evidence. Does not control audio or Bluetooth."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare")
    create.add_argument("matrix", type=Path)
    create.add_argument("--model", required=True)
    create.add_argument("--firmware", required=True)
    create.add_argument("--minutes", type=float, default=10)
    add = commands.add_parser("record")
    add.add_argument("matrix", type=Path)
    add.add_argument("--hardware", action="store_true", required=True)
    add.add_argument("--case", required=True)
    add.add_argument("--session", type=Path, required=True)
    add.add_argument("--result", choices=("pass", "fail"), required=True)
    add.add_argument("--recovery-seconds", type=float, required=True)
    add.add_argument(
        "--routes-restored",
        choices=("yes", "no", "manual-choice-preserved"),
        required=True,
    )
    add.add_argument("--notes", required=True)
    options = parser.parse_args(arguments)
    if options.command == "prepare":
        if options.matrix.exists():
            raise ValueError(
                "The matrix already exists; choose a new path to preserve existing evidence."
            )
        matrix = prepare(options.model, options.firmware, options.minutes)
    else:
        matrix = json.loads(options.matrix.read_text())
        record(
            matrix,
            options.case,
            session_statistics(options.session),
            options.result,
            options.recovery_seconds,
            options.routes_restored,
            options.notes,
        )
    temporary = options.matrix.with_name(options.matrix.name + ".pending")
    temporary.write_text(json.dumps(matrix, indent=2, allow_nan=False) + "\n")
    temporary.replace(options.matrix)
    print(
        f"Recorded {sum(case['result'] != 'pending' for case in matrix['cases'])}/{len(matrix['cases'])} scenarios: {options.matrix}"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
