[Documentation](README.md)

# Hardware qualification

Run shell commands from the repository root.

## Hardware qualification matrix

Prepare a fresh opt-in matrix for each model, firmware and macOS build:

```sh
python3 Packaging/qualify-ldac.py prepare /private/tmp/ldac-hardware.json \
  --model WH-1000XM5 --firmware YOUR_FIRMWARE --minutes 10
```

The 48 scenarios cover all sixteen rate/quality combinations with both Music and
Video buffers, plus sleep/wake, headset power cycles, abrupt owner exit, competing
sources, built-in/USB/headset microphones, manual call handoff, explicit output
changes, manual Off, application restarts, browser helpers, excluded applications,
permission denial, WH-XM4 multipoint restrictions and video synchronization. Do not
run destructive scenario steps during a call or while other work needs audio.
The recorder does not operate Bluetooth or audio; a tester performs each scenario
explicitly and records audible quality, echo behavior and final output/input routes.

After a scenario, stop LDAC and record its session directory:

```sh
python3 Packaging/qualify-ldac.py record /private/tmp/ldac-hardware.json --hardware \
  --case music-48000-low --session '/path/to/LDAC Sessions/SESSION_UUID' \
  --result pass --recovery-seconds 0 --routes-restored yes \
  --notes 'Ten minutes of listening; no audible defects; original input/output restored.'
```

The recorder retains observed duration, underruns, transport stalls, skipped frames,
bitrate timeline, recovery time and route outcome. Sustained-playback passes require
a matching rate, quality and reserve, the full requested duration and no aborted
session. Capture the original and final routes in the notes, including intentional
manual changes; use `manual-choice-preserved` for that route outcome. A pass is a
manual listening observation, not an automatic sound-quality certification. Keep
WH-1000XM4 and newer models independent, and repeat on each supported macOS build.
The matrix and deterministic replay checks are included in the offline test runner;
no hardware scenarios execute automatically.
