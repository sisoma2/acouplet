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

## Install and run local changes

After finishing edits, run these commands from the repository root to test the
updated app in `/Applications`. The build uses the installed app's signing team
and an existing Apple Development certificate from that team. This preserves
the installed app's identity and settings, including LDAC driver authentication.

```sh
CODE_SIGN_IDENTITY='Apple Development' \
DEVELOPMENT_TEAM="$(codesign -dv --verbose=2 /Applications/Acouplet.app 2>&1 | sed -n 's/^TeamIdentifier=//p')" \
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

Once the build succeeds, quit any separate Debug copy, install the packaged
Release build, and launch the app from Applications:

```sh
osascript \
  -e 'if application id "dev.baglayan.Acouplet.debug" is running then' \
  -e 'tell application id "dev.baglayan.Acouplet.debug" to quit' \
  -e 'end if'
.build/local-update/Acouplet/Install.command --require-stopped
open /Applications/Acouplet.app
```

The installer quits the installed app, stops its background service, replaces
the app, and checks that the installed binaries match the new Release build.
It preserves whether the background service was running. Use the installer
for replacement so these steps finish before the new version starts.

Confirm that the running app is under `/Applications` and that its executable
matches the freshly compiled Release build:

```sh
pgrep -fl 'Acouplet.app/Contents/MacOS/Acouplet'
cmp .build/Build/Products/Release/Acouplet.app/Contents/MacOS/Acouplet \
  /Applications/Acouplet.app/Contents/MacOS/Acouplet
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Acouplet.app/Contents/Info.plist
```

`cmp` exits successfully without output when the executables match. There
should be one app process under `/Applications`, optionally with `--background-service`,
and no Debug copy. An additional `--ldac-owner` worker is expected during LDAC
playback. The build and install receipts are saved under `.build/local-update/`.

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

Driver revision 7 reports the pipeline estimate in device latency frames at the
negotiated sample rate; stream latency remains zero so Core Audio's device plus
stream sum counts the pipeline once. Input latency remains readable as zero during
Core Audio device registration, including before a playback lease is acquired.
The estimate includes the initial 250 ms PCM reserve (replaced by the actual sender
reserve at startup), one encoder frame,
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
latency offsets supply the migration fallback. Automatic activation is on for a
new profile for every recognized Sony model, subject to codec and volume-control
availability. Existing profiles with LDAC manually enabled also adopt automatic
activation once when upgrading. Connected headphones selected in Acouplet start
LDAC automatically at launch even when another Mac audio output is selected.
Direct startup waits for headphone controls and volume readback before playback.
During startup, LDAC takes precedence when macOS automatically selects the same
headphones as its ordinary Bluetooth output, including a late switch after handoff.
Other output choices and output changes after playback starts remain respected.
A failed automatic start can be attempted again on the next headphone connection.
Activation requires a current driver and respects another active music source. Manual Off persists
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

## Bluetooth airtime priority investigation

The existing HAL priority handshake requests Bluetooth audio configuration. Its
completion notification does not acknowledge an LDAC media-channel scheduling
change or measure radio airtime.

Inspection of the arm64e Bluetooth daemon on macOS 26.7.1 (25G241) found a separate
private path: `CBController modifyDevice:settings:completion:` with
`CBDeviceSettings.aclPriority`. The daemon labels value 80 as High and value 1 as
Default, checks controller support, and routes High to a controller priority
request. This targets the device's ACL link, which can carry several channels;
it is not a dedicated LDAC channel reservation.

On 2026-10-19, an access probe outside the development sandbox reached this API
and received `CBErrorDomain -71168`, with the reason
`Missing entitlement: com.apple.bluetooth.system`. The probe used a synthetic
device identifier and Default priority, so it did not raise priority on paired
headphones. An ordinary developer signature does not supply that Apple
entitlement. No production priority request was added through this path.

Live tests on the same build also checked `kCBL2CAPChannelPriority` on the owned
AVDTP media channel, using `CBClassicPeer sendMsg:args:` message 29 with a nested
`kCBMsgArgOptions` dictionary. A temporary wrapper around the existing media
helper replaced its channel-opening method only in the test process.
The installed app and production helpers were unchanged. The native session harness
retained channel ownership checks, AVDTP negotiation and shutdown, and used no HAL
audio-configuration request in any trial. Each trial transmitted about five seconds
of silent LDAC at 96 kHz / 660 kbps.

| Requested option | Owned media CID | Daemon registration priority |
| --- | --- | --- |
| Omitted | `690E` | 0 |
| 0 | `7C0E` | 0 |
| 1 | `8F0D` | 0 |
| 2 | `A30E` | 0 |
| 12 | `B60E` | 0 |
| 2, with incoming MTU 768 | `EF0E` | 0 |

These numbers are raw experimental values, not verified priority-level names.
Every trial completed transmission with `strictPass=1`, zero skipped frames,
confirmed transport shutdown and native Bluetooth audio restoration. In the last
trial, the daemon's connection-setup log read `inMTU:768` from the same options
dictionary while retaining `priority:0`; this confirms that options reached it.
The later registration log still reported an incoming MTU of 1024, so the setup
log alone does not establish the negotiated incoming MTU.

Disassembly explains the priority result: the Classic open handler at
`bluetoothd` arm64e address `0x10028f954` decodes only
`kCBL2CAPChannelInMTU` from the options. Its block at `0x100294350` passes zero
for priority into the common channel-creation function at `0x1004558cc`.
The other open handler that parses `kCBL2CAPChannelPriority` is not the Classic
path used here. This option therefore does not provide preferential LDAC airtime
through couplet's current transport on this build.

Normal installed LDAC playback was restored after the experiment.

The local `IOBluetoothDevice.highPriority` setter only stores an object field on
this build. Further qualification needs a permitted controller interface, evidence
that a request affects the owned media link, and controlled playback comparisons
under competing Bluetooth traffic. These short trials did not measure radio
airtime or receiver delivery. Socket drain timings alone cannot establish radio
scheduling.

## Sender timing and bounded packet submission

Adaptive quality starts at the connection bitrate and requires 15 seconds of
healthy transport before each quality increase. Repeated drain delays above the
larger of 12 ms and a packet's audio duration lower quality after 60 ms of observed
congestion. A 40 ms packet age or unsent audio queue lowers it immediately on the
next packet drain. Source starvation and scheduler gaps above 20 ms suppress these
decisions. Quality increases also require an empty unsent queue, low packet age
and timely pacing; draining a backlog cannot count faster than elapsed time.
After congestion, the healthy interval becomes 30 seconds and doubles after a
failed quality probe, up to 120 seconds. These are local transport observations,
not receiver delivery or signal strength measurements. Fixed quality modes retain
their explicit bitrate. The adaptive replay and media queue fixtures cover these
decisions and packet integrity; room-to-room range still needs hardware testing.

The default sender submits one RTP/LDAC packet, then waits for the local stream
socket to drain before submitting another. A `SOCK_STREAM` write does not provide
a message boundary to a reader. The sender retains this restriction and does not
queue multiple unframed packets into that stream.

Production uses only the serialized socket sender. The unsupported packet API,
its fallback, and developer mode/window controls have been removed. The bounded
pipeline prototype is preserved separately in
[`Experiments/LDACSender`](Experiments/LDACSender/README.md) as a patch and offline test
runner, excluded from app builds and normal checks. Historical traces can still
be analyzed: `SENDER_CONFIG` records requested and effective modes where present,
and the analyzer identifies the historical Classic fallback explicitly.

The archived packet sender calls `sendData:withCompletion:` once per immutable,
MTU-bounded packet and limits outstanding submissions to 1–16 packets. Its
completion bookkeeping handles delayed, reordered and stale callbacks. An API
reply is a local completion, not an HCI controller completion.

On macOS 26.7.1 (25G241), framework inspection showed that
`CBL2CAPChannel.sendData:withCompletion:` issues message 31 through the peer's
manager. The daemon's Classic dispatch table at `0x10028c844` routes messages
29 and 30 to open/close handlers, but message 31 goes to the unknown-message
branch at `0x10028c810`. The method's presence on the channel therefore does not
establish Classic support. `IOBluetoothL2CAPChannel.writeAsync:length:refcon:`
writes to the same output stream and schedules a local delegate callback; it
does not supply an alternative packet boundary or controller completion.

On 2026-10-19, a live 96 kHz / 990 kbps socket trial reproduced backpressure:
681 packets submitted in 4.915 seconds, 99,584 PCM frames skipped, median app
queue wait 321.921 ms, median submission call 0.010 ms and median observed local
drain 3.221 ms. Ordinary Bluetooth audio reconnected during cleanup. The packet
window-one trial failed on its first packet with error `-71142`, before becoming
active. A subsequent explicit window-four trial at the same rate and bitrate
also failed on packet zero with `NSOSStatusErrorDomain -71142`, after 1.410 ms;
playback never became active. Both trials confirmed native Bluetooth audio
restoration. There is no demonstrated live throughput improvement. The installed app was
restarted with its saved 96 kHz / 660 kbps setting. These trials used the native
session ownership checks and muted transmission, without a HAL priority request.

After adding the Classic guard, a one-second 96 kHz / 990 kbps startup trial
requested packet/window four and explicitly selected socket/window one. It
submitted and drained 199 packets, finished with `result=0 strictPass=1`, skipped
zero PCM frames and confirmed native audio restoration. The installed app then
resumed its saved 660 kbps playback. This short check verifies removal of the
unsupported request error, not sustained 990 kbps stability or pipeline support.

A later live trial requested 60 seconds at 96 kHz / 990 kbps with unity gain.
Playback became active through the same socket fallback, but persistent
degradation protection stopped it after 4.866 seconds: 99,328 skipped PCM frames
(1.035 seconds of audio), 20.7% loss in the protection window, and median app
queue wait 326.284 ms. There was no packet API error. This reproduces the original
throughput failure after the unsupported-request startup error was removed.
After this trial, the headphones reconnected and the installed app resumed its
saved 96 kHz / 660 kbps setting, with over 100 seconds and zero skipped PCM frames.

Offline trials impose a 7 ms completion delay and one 60 ms delayed callback.
At 48 and 96 kHz / 990 kbps, window one accumulates skipped PCM while window four
completes without skips. They verify immutable codec packets, unique RTP
sequences, callback reordering, window bounds, API failures and absence of writes
to the stream socket. This demonstrates the scheduling effect in the fixture,
not support for the private packet API on a real Classic channel.

Rebuilt apps read the optional trace duration at session startup. Use the app's
actual preference domain (`dev.baglayan.Acouplet.debug` for Debug builds):

```sh
defaults write dev.baglayan.Acouplet.debug LDACSenderTraceSeconds -int 15
```

Restart the rebuilt app so the owner reads the setting. Starting playback uses the
normal Bluetooth handoff and interrupts ordinary audio. The currently installed
release is unchanged by rebuilding these sources. Remove the setting to disable
tracing again:

```sh
defaults delete dev.baglayan.Acouplet.debug LDACSenderTraceSeconds
```

The retired `LDACSenderExperimentMode` and `LDACSenderExperimentWindow` defaults
are ignored. Production CLI invocations reject `--sender` and `--packet-window`.

Tracing is disabled by default. When enabled for 1–60 seconds, a fixed 65,536-record
buffer captures enqueue, submission call, successful or failed return, local
socket drain, and a monotonic/wall clock anchor. Records
contain packet identity and a fingerprint, not audio payload. They are written
after the sender releases its real-time policy. The owner supplies a separate
`packet-trace.log` in the session directory so session-log rotation does not
discard the trace. The helper creates this file exclusively with mode 0600 and
does not follow an existing symlink. Direct helper invocations can use
`--trace-seconds` and `--trace-file NEW_FILE`;
without a trace destination, records go to stdout after streaming.

Obtain a passive HCI capture with Apple's PacketLogger, available in
[Additional Tools for Xcode](https://developer.apple.com/bluetooth/), beginning
before the trial's ACL connection is established. On this Mac, the built-in
`BluetoothReporter --dumpPacketLog OUTPUT` required administrator authentication
but exported an empty file; it did not provide controller timing for the live
trials. The analyzer requires a usable `.pklg` capture and never substitutes API
replies or socket drain for missing controller events.

```sh
python3 Packaging/ldac-packet-timing.py analyze \
  "$HOME/Library/Caches/LDAC Sessions/SESSION_ID" --hci /path/to/trial.pklg \
  > /private/tmp/trial-timing.json
python3 Packaging/ldac-packet-timing.py compare \
  /private/tmp/socket-timing.json /private/tmp/packet-one-timing.json \
  /private/tmp/packet-four-timing.json
```

The analyzer reassembles outbound ACL fragments into L2CAP SDUs and matches the
exact RTP sequence, timestamp, length and fingerprint. Merged, split, modified or
duplicated SDUs cannot pass boundary validation. HCI Number Of Completed Packets
counts cover every channel on a connection handle; the analyzer tracks all
outbound ACL fragments and attributes batched completions in FIFO order only
after observing Connection Complete. Captures starting midconnection, missing
events, clock mismatches and incomplete traces retain unknown timing or unverified
boundaries. Completion observations are upper bounds from batched events, and
the controller may have transmitted or flushed a fragment; they do not prove
earbud decoding or audible delivery. See the
[Bluetooth HCI specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/host-controller-interface/host-controller-interface-functional-specification.html).

`Packaging/check-ldac-packet-timing.py`, `Helpers/LDAC/LDACPacketTraceCheck.py`
and `Helpers/LDAC/LDACMediaQueueCheck.py` run through `Packaging/check-all.py`.
They verify trace limits and identities, reject retired sender options before
device access, confirm the production binary excludes the packet API selector,
and check intact codec packets, contiguous RTP and no skipped PCM under a
simulated socket stall. High-quality queue trials also verify the dedicated
trace contains enqueue, submission, return, local drain and clock records.
The archived pipeline fixture runs separately:

```sh
python3 Experiments/LDACSender/check-pipeline.py
```

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
