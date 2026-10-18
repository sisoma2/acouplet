# Development

Use Xcode 27.0 with the macOS 27.0 SDK. The deployment target is macOS 15.4.
The native HUD is checked at launch and falls back when unavailable.
Select Xcode under Xcode > Settings > Locations > Command Line Tools before
running the commands below.

## Build

Fetch the build dependency, then open `Acouplet.xcodeproj`:

```sh
Packaging/fetch-sparkle.sh
open Acouplet.xcodeproj
```

Select your development team under Signing & Capabilities and run the Acouplet
scheme. Debug uses a separate bundle identifier from the installed app.

To build a local installer with ad-hoc signing, without an Apple development
team or certificate:

```sh
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

To use an existing Apple Development certificate instead:

```sh
CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=YOURTEAMID \
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

Certificate signing provides permission continuity between builds and is required
for LDAC driver authentication. Release and App Store builds use your signing
settings; the project does not pin an upstream Team ID.

Quit the installed app, then open `Install.command` in
`.build/local-update/Acouplet/`. See that package's README for removal instructions.
Do not rebuild while installation is running.

## Artwork and build options

The default build uses the repository's vector artwork. Product photographs
are optional and are not included in the repository. To use an external catalog:

```sh
DEVELOPER_DIR="$(xcode-select -p)" \
ACOUPLET_SONY_ARTWORK_DIR=/path/to/SonyPhotos.xcassets Packaging/package.sh --local
```

For builds in Xcode, set `ACOUPLET_NO_SONY_ARTWORK=NO` and
`ACOUPLET_SONY_ARTWORK_DIR` to that catalog. It is combined with the vectors in
DerivedData; the source tree is unchanged.

`ACOUPLET_PUBLIC_APIS_ONLY=YES` excludes private system integrations and LDAC.

## Tests

```sh
Packaging/fetch-sparkle.sh
python3 Packaging/check-all.py
```

This runs XCTest, offline native helper and driver checks, localization checks,
and packaging fixtures, reporting failures with their check logs. `Packaging/direct.sh`
runs the same checks before packaging a production release.

Xcode build products are reused between runs. Add `--clean` when a fresh build
is needed. Independent scripts run concurrently in separate processes, with
individual logs under `.build/check-all/Logs/`. Use `--jobs 1` for serial checks.
Suites and their child cases share the worker budget to avoid nested pools
overloading the machine. Swift fixture compilers reuse the module cache.

Run just the fixtures, select matching scripts, or focus XCTest on a class:

```sh
python3 Packaging/check-all.py --fixtures-only
python3 Packaging/check-all.py --fixtures-only --filter '*LDAC*'
python3 Packaging/check-all.py --xctest-only --only-testing AcoupletTests/LDACCallAudioTests
python3 Packaging/check-all.py --list
```

UI tests, native HUD presentation and the launch service check run separately.
Bluetooth, audio and connection recovery still need testing with real hardware.

Packaging, app installation, LDAC driver installation, and direct-release
fixtures run up to four isolated cases concurrently. They support `--filter`,
`--list`, and `--jobs` for focused reruns without rebuilding the app:

```sh
python3 Packaging/check-package.py
python3 Packaging/check-package.py --filter 'local-*'
python3 Packaging/check-package.py --jobs 4
python3 Packaging/check-install.py --filter 'install/native-*'
python3 Packaging/check-ldac-output-installer.py --filter 'postinstall/*'
python3 Packaging/check-direct.py --filter '*notary*'
python3 Helpers/LDAC/LDACControllerVolumeCheck.py --check-mutations --filter 'mutation/*volume*'
```

Installer fixtures shorten simulated polling budgets while keeping delayed-exit
and timeout cases. The installed scripts keep their normal wait times. Packaging
fixtures share each unchanged stub executable across cases, avoiding repeated
macOS launch costs for newly written executable files. Command names, exit codes,
logs and filesystem state remain specific to each fixture. Python stubs use the
same interpreter as the test runner. No passing check results are cached. On
macOS 26.7.1, all 104 installer cases completed in 68.1 seconds with four workers,
compared with the previous 217.3-second run using four workers.

## LDAC capability and presentation timing

The LDAC settings menu offers **Check LDAC support again**. It clears only the
selected device's observation and starts the normal guarded playback setup,
which can interrupt ordinary playback. Known model exclusions, microphone,
multipoint, output ownership, driver and capture-permission checks still apply.
Capability records include the observation time, firmware, connection mode and
multipoint state. Negative observations expire after one day, positive ones after
30 days; changed context or a potentially hidden endpoint permits discovery again.
Legacy Boolean observations are ignored because their age and context are unknown.
An advertised LDAC endpoint with an unsupported requested sample rate remains a
sample-rate failure, rather than a negative codec observation.

Driver revision 6 reports the pipeline estimate in device latency frames at the
negotiated sample rate; stream latency remains zero so Core Audio's device plus
stream sum counts the pipeline once. The estimate includes the initial 250 ms PCM
reserve (replaced by the actual sender reserve at startup), one encoder frame,
and the encoder's packet assembly duration. The transport queue capacity is a
congestion limit, not another fixed delay, and is not added to the reserve.
Negotiated AVDTP receiver delay reports from 0 to 2 seconds replace the previous
receiver contribution rather than accumulating it. Malformed, unnegotiated and
out-of-range reports are rejected. The owner writes the bounded estimate using an
authenticated, lease-protected property; changes notify Core Audio, and release,
expiry and owner exit clear the session estimate.

The experimental settings also save a **Latency offset** per device, from -500 to
+500 ms, applied on the next start. Positive values increase the reported delay;
negative values reduce it, with the total clamped to zero. The new driver must be
installed and loaded using the existing update/restart flow. This is an estimate,
not a measured audiovisual offset. Hardware qualification should compare video
synchronization at 44.1, 48, 88.2 and 96 kHz in each quality mode, both with and
without receiver reports, in players that honor Core Audio latency. Record the
player, device firmware, observed offset and calibration; other players may ignore
these properties.

`Packaging/ldac-session-stats.py` reports the last observed bitrate, a transition
timeline, seconds at each observed bitrate, observed range and an average over
known intervals in JSON. The text report includes the timeline and unknown time.
Missing startup, missing completion or unobserved bitrate intervals mark a session
as partial. No bitrate is inferred for time before the first available observation.
`Packaging/check-ldac-session-stats.py` replays synthetic promotions, demotions,
malformed events, encoder resets, rotations and partial logs. These checks and the
native property/parser checks run through `Packaging/check-all.py`.

## LDAC device profiles and call policies

General > Experimental Features > LDAC device profile stores the rate, quality,
latency calibration, buffer reserve, microphone policy and application selection
for each Bluetooth device. Existing global rate/quality settings and per-device
latency offsets supply the migration fallback. Automatic activation is off for a
new profile. Enabling it still requires the headphones to be the selected Mac
output, verified local source ownership and a current driver. Manual Off persists
its suppression across reconnects; another multipoint source taking ownership
also suppresses automatic activation until the user explicitly enables LDAC.

A configuration becomes the last successful configuration after 30 seconds of
active playback. After two failed attempts, Settings offers an explicit restore
button. A fixed quality choice is never replaced automatically. Music and Video
presets select 48 kHz adaptive quality with 250 ms and 100 ms reserves respectively.
Custom preserves explicit settings and permits a 50–500 ms reserve. Video and
Custom remain experimental: offline checks validate frame scaling and protocol
readiness, not audible resilience. Neither a smaller sender reserve nor a manual
offset removes receiver buffering.

The default microphone policy restores normal headset call audio for microphone
activity. Separate microphone mode selects a chosen built-in or USB input and keeps
LDAC only when that input is appropriate; headset microphone use still requires
handoff. Manual mode exposes explicit pause/resume controls while preserving headset
handoff if a headset input is used. The menu identifies the process and microphone
currently in use. Input changes made by the user are preserved during restoration.
Qualify microphone availability, app restarts and echo cancellation in actual call
applications before relying on separate-microphone mode. LDAC provides no microphone
return channel.

## Application routing and diagnostics

Application selection requires a separate wired, USB, display or built-in output.
During handoff the owner selects that output for ordinary applications. A private,
muted-when-tapped process inclusion tap captures only selected applications there;
the selected mix is converted to the negotiated LDAC rate. Excluded applications
remain audible on the separate output. Selected applications must use System Default
output; application-specific hardware choices are not overridden. An enabled empty
selection is invalid and never becomes a global tap.

The capture helper resolves audio process objects from selected bundle IDs, helper
bundle prefixes and process ancestry. It updates the inclusion list every 500 ms,
including application and browser helper restarts; macOS 26+ also supplies native
bundle restoration. Three consecutive failed inventory reads stop capture rather
than broadening it. The helper never includes its own audio process. Shutdown
quiesces the routing updater before destroying the tap, which unmutes selected
applications. Route recovery includes the owned separate output so both normal
Stop and owner death preserve later manual route choices. Hardware scenarios must
verify browsers, permission denial, process churn and excluded-app audibility.

The transport health panel reports PCM underruns, skipped frames, local transport
stalls, queue duration/peak and bitrate or encoder transitions. Owner messages are
bounded and health publication is throttled to at most once per second during
playback, with a final snapshot at completion. Socket drain and queue observations
are local observations; they do not measure receiver delivery or radio packet loss.
Export LDAC report writes a user-selected JSON file containing versions, the model,
firmware, driver revisions, configuration scalars and structured health. It excludes
recorded audio, raw signaling, process IDs, selected application IDs and device UIDs;
free-form recovery reasons redact addresses, UUIDs, process IDs and user paths.

Setup and compatibility combines bundled/installed/loaded driver revisions, restart
state, capture access, controller readiness, Sound Quality, advertised stereo rates,
model-specific multipoint restrictions and runtime ownership checks. Reading this
view is passive. Explicit support rediscovery uses the existing guarded playback
sequence and can interrupt ordinary audio. Bluetooth log access must be established
before selecting the handoff output; unique signaling/media ownership evidence is
still required before transmission. Unknown future OS versions fail preflight.

Standard-account playback remains a research milestone. Removing log access or
running an always-root playback owner is not implemented as a workaround. A future
replacement must demonstrate callback-derived ACL identity and unique channel
ownership across stale handles, reconnects, competing sources and abrupt exits;
until that evidence exists the current administrator/log guards stay in place.

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
