[Documentation](README.md)

# Validation history

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
