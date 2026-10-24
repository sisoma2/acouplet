[Documentation](README.md)

# Validation history

## Independent upstream drafts and signed integration update

On 2026-10-25, the independent delivery scopes were extracted into nine draft
PRs, [#11 through #19](UpstreamPRs.md#independent-deliveries), each with one commit
based on upstream `0033a4b`. GUI isolation and fixture performance are separate
contributions. The isolated branches retain upstream's driver revision 9;
integration validation continues to preserve the installed revision 8 driver.

The media-exit contribution passed all eight process scenarios. Its full unit
run reported 1,267 passes and nine failing cases on macOS 26.7.1 (25G241). All nine
test identifiers and failure messages reproduced on unchanged upstream: four
App Intents crashes and five preference-pane cases requiring macOS 27. These are
baseline failures, not passing results or regressions attributed to the PR.

Focused isolated-branch XCTest runs passed 166 connection/coordinator/power-off
tests, 32 noise-control tests, 145 equalizer/protocol tests and 28 capability/LDAC
tests. The new paired-selection regression and all three new noise regressions
failed against unchanged upstream production code and passed with their fixes.
Capture recovery and startup fixtures passed; disabling recovery failed the
production streaming-loop check. Owner lifecycle and volume fixtures passed,
including four existing volume mutation checks.

Adaptive policy and encoder replays passed at all four sample rates. The pacing
fixture rejected its timed-run-loop negative control. Native signaling/media
checks passed without a competing Xcode build. The 90-second independent source
scenario sent 9,585 packets, recovered bitrate after congestion, skipped zero PCM
frames and retained exact PCM accounting. This extraction keeps upstream's
serialized sender; the encoded queue, buffer presets and packet tracing remain
separate work. Live sustained playback and reconnect qualification remain open.

Two GUI smoke tests passed in a disposable clone of the prepared macOS VM. The
clone was removed and its base retained. Offline VM/runner fixtures and the actual
host rejection guard passed. Cache, worker and runner fixtures passed, as did LDAC
build fixtures checking fresh signing and version metadata on a repeated build.
A real standalone helper check passed twice, reusing its compiler output on the
second run while executing the binary again. The complete GUI gallery was not
rerun. Evidence is saved locally under `.build/follow-up-prs/`.

Signed integration Release build **216** (version 0.32.0, source revision
`c9a111a`) was installed with the local installer and launched from
`/Applications/Acouplet.app`. Strict signature verification confirmed the existing
private certificate. The installed executable, transport, connection and battery
helpers matched the Release products. Only the installed main app and its expected
media watcher were running, with no Debug copy. The driver binary was unchanged
and reported `current`; no driver installation or Core Audio restart occurred.
The temporary signing keychain was removed and the original search list restored.
The installed app remains the combined integration build. Isolated upstream
branches were built and tested separately. Audible playback qualification remains
open for this update.

## Upstream integration and first feature PR

On 2026-10-24–25, `integration/upstream-sync` reconciled the fork with original
upstream commit `0033a4b253302c26158ce351b909d050f37f65fa` on macOS 26.7.1
(25G241). The integration uses upstream's callback-owned LDAC transport and
control transmission ordering while retaining the fork's battery, connection,
media lifetime, capture recovery and LDAC settings behavior.

The full unit suite passed 1,397 tests with zero failures and 27 skips. Compiler
string extraction, localization, Sparkle, battery helper and LDAC CLI bundle
checks passed. The 16 selected LDAC fixture suites passed, including all 62
session ownership cases. Native driver and battery checks passed without
installing a driver or accessing Bluetooth hardware. Packaging fixtures,
including all 107 local installer cases, passed in the integration audit.

The native signaling and media transport suite passed after reconciling the
fork's encoded queue with upstream's ownership checks. Its 90-second independent
source test observed bitrate recovery after congestion with exact PCM accounting
and no skipped frames. Deterministic replays covered every quality step at
44.1, 48, 88.2 and 96 kHz. Isolated drain jitter now subtracts its observed time
from recovery progress; it no longer erases the whole healthy interval.

The first isolated contribution is
[draft PR #10](https://github.com/baglayan/acouplet/pull/10), with three files and
no integration merge history. Its new native battery expiry regression fails
against upstream's helper and passes with the fix. All 58 publisher unit tests
and the native battery self-test script pass on that PR branch.

Signed Release build 215, from integration commit `ae528e3`, was installed with
the local installer and launched from `/Applications/Acouplet.app`. The app,
transport, connection and battery executables matched the Release products.
Strict signature verification passed and the private certificate fingerprint
matched the previous installation. Only the installed app and its expected media
watcher were running. The installed driver binary was unchanged and reported
`current`; no driver installation, Core Audio restart or Mac reboot was performed.
The temporary signing keychain was removed and the original search list restored.

Driver revision remains 8 at the user's request. Driver revision and installer
compatibility updates are deferred. Live LDAC playback with the combined transport
still requires separate hardware qualification. See the
[PR delivery plan](UpstreamPRs.md).

## Morning reconnect and battery expiry recovery

On 2026-10-22, WF-1000XM5 logs showed ordinary A2DP audio reconnecting during
the first LDAC handoff at 10:32. That attempt failed its five-second disconnect
check, and the next startup succeeded. The helper now retries once within the
same takeover when the native headset output is confirmed present. Restoration
keeps its existing ownership checks and single disconnect attempt.

Battery publication used 45-second sample leases while LDAC polled battery every
60 seconds. A later withdrawal recorded child exit 78 (clean lease expiry), final
native inventory restored, and supervisor exit 1, blocking subsequent publication.
An offline regression reproduced that exit combination when the child withdrew
its entries before the supervisor's next active inventory check. The supervisor
now enters cleanup on a validated component-withdrawal report and rechecks expiry
after waiting for child input. Failed cleanup still returns failure. LDAC battery
polling now runs every 30 seconds, without the full settings refresh.

Both native regression suites passed, including bounded takeover retries,
restoration boundaries, clean child expiry and unsuccessful child cleanup.
The 58 battery publisher XCTest cases and two focused streaming battery refresh
and command retry cases passed, as did Ruff lint and formatting checks. Evidence
is saved locally under `.build/reconnect-fix/`.

Privately signed Release build 210 was installed using the local installer.
The installed executable, battery helper and audio connection helper matched
the Release products, and signature verification confirmed the existing private
certificate. Only the installed app and its expected workers were running;
the revision 8 driver reported `current`. The same battery supervisor and child
stayed running beyond the old 45-second expiry window. Live LDAC at 96 kHz /
fixed 660 kbps showed increasing nonzero PCM frames with no PCM failures,
skipped frames, drain breaches or transport queue drops during the observed
first minute. The original takeover race was exercised offline, not forced on
the real headset. No Core Audio restart or Mac reboot was performed.

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
