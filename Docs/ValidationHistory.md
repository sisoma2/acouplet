[Documentation](README.md)

# Validation history

## Live capture recovery after injected silence

On 2026-10-22, a controlled live test with WF-1000XM5 earbuds on macOS 26.7.1
(25G241) used privately signed Release build 207 and the current revision 8 LDAC
driver. Spotify played through the real LDAC pipeline at 96 kHz / fixed 660 kbps.
The temporary capture helper accepted an explicit signal to invoke its overload
handler and substitute silent PCM. The injected silence cleared after a successful
real `AudioDeviceStop`/`AudioDeviceStart` of the capture aggregate; an eight-second
failsafe would have released silence if recovery failed.

The production watchdog requested exactly one restart after 2.001 seconds of
silence. Both Core Audio calls succeeded, completing 2.068 seconds after fault
injection. Subsequent `PCM_HEALTH` nonzero-frame counts increased from 1,380,979
to 1,573,491, while Spotify remained playing on the same track and advanced from
64.209 to 69.744 seconds. The app, owner and capture helper stayed running through
the trial, with no PCM failure or failsafe timeout. The user confirmed hearing the
brief dropout and automatic audible recovery without touching Spotify.

Local evidence is saved under `.build/live-capture-recovery/` in
`live-trial.json`, `live-trial.log`, the test build receipt and the temporary helper
source. The production source was restored before the trial. The test qualifies
the watchdog, real capture restart and audible LDAC recovery for the injected
fault; the original macOS scheduling overload was not reproduced.

Normal signed Release build 208 was installed afterward. Its app and capture
helper matched the Release binaries, the temporary injection hook was absent,
and the original signing certificate was preserved. The driver remained `current`;
Spotify resumed playing and the normal capture reported increasing nonzero-frame
counts through the LDAC output.

## Bluetooth headset discovery during calls

On 2026-10-21, a Zoom test with WH-1000XM5 headphones on macOS 26.7.1
detected microphone activity and restored ordinary Bluetooth, but left the Mac
speakers selected. A read-only probe using the production headset lookup
reproduced missing input and output results despite both devices being alive,
eligible and reporting the expected Bluetooth transport and channel counts.

The optional generic transport read inferred `Optional<UInt32>` and requested
five bytes for Core Audio's four-byte transport property. The size check rejected
every device. Specifying a concrete `UInt32` initial value without an optional
binding type annotation fixed the read; the production lookup then found both
real headset endpoints. A native check using the production call-routing class
then selected the real headset input and output and restored both previous
defaults afterward, without recording audio. All 33 focused call-routing and
Core Audio XCTest cases passed. Signed Release build 200 was installed with the
existing private certificate, its executable matched the Release build, and the
LDAC driver reported `current`. The user then confirmed that the automatic headset
handoff worked in Zoom.

## Normal app startup

On 2026-10-21, 34 focused Settings XCTest cases, 107 app installation/removal
fixtures and 93 packaging fixtures passed. The native legacy-service migration
check used disposable LaunchAgents to exercise normal and service-managed startup,
startup preference preservation, failure/retry handling and ownership validation.
Ruff lint and formatting checks passed.

Signed Release build 195 was installed over private-certificate build 193 on
macOS 26.7.1 (25G241), retaining the same private certificate and loaded LDAC driver
revision 8. The installed executable matched the Release build. The old
`dev.baglayan.Acouplet.agent` job and plist were absent, and the app ran from
`/Applications/Acouplet.app` without `--background-service`.

LDAC streamed at 96 kHz / 990 kbps. Normal Quit stopped the app and its owner
worker, and the app remained stopped during five seconds of observation. Opening
the installed app started a new LDAC session, and the user confirmed normal
audible playback after reopening. The driver reported `current`;
neither a Mac reboot nor a Core Audio restart was needed for this update.

## Private certificate authentication and revision 8

On 2026-10-21, a privately signed Release with driver revision 8 passed the
real-process driver authentication check: the pinned signer and Acouplet
identifier were accepted, while an unrelated identifier, ad-hoc signature and
different certificate pin were rejected. Eight focused driver-installer XCTest
cases, all 174 driver-installer fixtures, the LDAC build checks and native HAL
checks passed. The revision checks distinguish an installed revision 7 from an
updated revision 8 that still needs a restart to load.

The generated DMG also passed a read-only mounted signature check and matched
the Release executable after clearing image-copy metadata before compression.
The app's real signature validator accepted its bundled private driver after
temporary signing trust was removed from the build machine.

The hardware smoke test passed on macOS 26.7.1 (25G241) with private app build
193 and driver revision 8. The installed app and driver matched the private
Release binaries and certificate pin. Installation initially left revision 7
loaded and correctly reported `restartRequired`. After stopping Acouplet and
explicitly restarting the Core Audio service, revision 8 loaded without rebooting
the Mac and the app reported `current`. The installers themselves did not restart
Core Audio. The exact commands are saved in
[Reload the driver without restarting the Mac](LDACPlayback.md#reload-the-driver-without-restarting-the-mac).

Two live LDAC sessions negotiated 96 kHz / 990 kbps. The first stopped normally;
relaunching the installed app started the second. The observed sessions reported
no aborts, PCM failures or skipped frames, and the user confirmed normal audible
music playback after relaunch. This qualifies the private authentication and
startup/recovery smoke test; other sample rates, long-duration stability, RF
conditions and the full hardware matrix remain separate qualification work.

## Roadmap validation on macOS 26.7.1

The implementation passed 72 focused XCTest cases covering LDAC support, call
policies, settings and the HUD timeout regression, plus app/helper builds,
English/Turkish localization, bundle validation and native offline self-checks.
All 20 packaging/driver suites and the LDAC fixture suites passed, including
controller mutations, session closure,
owner lifecycle/exit, physical fallback routing and restoration, and all
rate/quality/buffer latency combinations. The hardware matrix recorder also accepts
permission-denied scenarios without media and rejects a pass with unrestored routes.

The full XCTest run reported 1,224 passes and 10 failures: four Intents crashes,
five preference-pane failures in tests requiring macOS 27, and one HUD subprocess
timeout test that passed when rerun separately. Those tests and their production
components were unchanged by the LDAC roadmap implementation. The full suite is
therefore not green on this macOS 26.7.1 machine. No hardware playback, video sync,
microphone echo or RF qualification is claimed by these checks.
