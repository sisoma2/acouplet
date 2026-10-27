[Documentation](README.md)

# LDAC playback

LDAC driver installation and commands require an authenticated app. Apple-signed
builds use their signing team; private-certificate development builds pin the
exact certificate across the app, driver and installer scripts. Ad-hoc builds
remain unsupported. See [Release automation](Releasing.md) for private signing,
driver installation and migration between signing identities.

Driver revision 8 adds private certificate authentication. Both signing modes
report revision 8; verify the app and installed driver's certificate fingerprint
when qualifying a private release. Revision 7 must be replaced, and a loaded
revision 7 remains restart-required after revision 8 is installed.

## Idle playback and headset battery use

After 30 seconds of digitally silent captured audio, the media sender stops
encoding at an encoder boundary, drains queued packets, and requests AVDTP
Suspend. The signaling connection, negotiated codec, media channel and Mac audio
capture remain available. No media packets are transmitted while suspended.
Any nonzero captured sample, including quiet audio or a system sound routed to
LDAC, requests AVDTP Start. A short silent pre-roll and the first returning audio
remain buffered until Start is confirmed, then the encoder and pacing resume.
Muting the output gain does not make a playing source count as idle.

The normal capture ring bounds the audio retained during a resume. Protocol
rejection, a transition timeout or buffer overflow uses the existing failure and
ordinary-audio recovery path. Quit, microphone handoff and disconnection keep
their normal shutdown ownership checks, including when playback is suspended.
The lifecycle log records `IDLE_SUSPENDED` and `IDLE_PLAYBACK_RESUMED`.

Full settings polling outside LDAC uses a two-minute fallback. Battery requests
use component observation timestamps, so fresh headset notifications avoid extra
reads while retaining the existing 45-second expiry for native battery samples.
See [Native battery publication](Architecture.md#native-battery-publication).
The idle behavior reduces unnecessary transmission; actual headset battery
savings and audible resume latency require hardware measurement.

## Reload the driver without restarting the Mac

After installing a replacement LDAC driver, restarting the Core Audio service
can load it without rebooting macOS. This worked on 2026-10-21 with macOS 26.7.1
(25G241), private app build 193 and driver revision 8. See the
[hardware test result](ValidationHistory.md#private-certificate-authentication-and-revision-8).
The installers do not restart Core Audio automatically.

This briefly interrupts all Mac audio and requires administrator authorization.
Finish any audio call or recording before continuing. Install the matching app
and driver first; reloading Core Audio does not install or change their signatures.

Quit Acouplet normally:

```sh
osascript -e 'tell application id "dev.baglayan.Acouplet" to quit'
```

Wait for the app and its LDAC owner worker to exit. This command should return no
matching processes before continuing:

```sh
pgrep -fl '^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)'
```

Restart only the Core Audio service with the same command used during the test.
macOS prompts for administrator authorization and relaunches the service:

```sh
osascript -e 'do shell script "/usr/bin/killall -TERM coreaudiod" with administrator privileges'
```

Allow a few seconds for the service to return. Confirm that it has a running
process, then reopen the installed app and inspect the driver state:

```sh
pgrep -x coreaudiod
open /Applications/Acouplet.app
/Applications/Acouplet.app/Contents/MacOS/Acouplet --ldac-driver-state
```

The state should be `current`. In **LDAC setup and compatibility**, confirm that
the bundled, installed and loaded revisions all match the expected new revision
(8 in the verified test). Enable LDAC if needed, play music and confirm it is
audible. To inspect stream evidence, run from the repository root:

```sh
python3 Packaging/ldac-session-stats.py
```

The test streamed at 96 kHz / 990 kbps and recovered after a normal app stop and
relaunch. If the loaded revision stays old or the state remains `restartRequired`,
use the normal Mac restart procedure.

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
If ordinary Bluetooth audio reconnects during the initial disconnect, the handoff
retries that disconnect once within the same startup, after confirming the native
headset output is present. Each attempt waits at most five seconds. Ordinary-audio
restoration retains its existing connection ownership checks and does not use this
takeover retry.
During startup, LDAC takes precedence when macOS automatically selects the same
headphones as its ordinary Bluetooth output, including a late switch after handoff.
Other output choices and output changes after playback starts remain respected.
A failed automatic start can be attempted again on the next headphone connection.
Activation requires a current driver and respects another active music source. Manual Off persists
its suppression across reconnects; another multipoint source taking ownership
also suppresses automatic activation until the user explicitly enables LDAC.

Pending playback requests expire after 60 seconds, including time spent asleep.
Selecting different headphones cancels the previous request immediately and checks
the newly selected device's automatic profile after cleanup. Acouplet's Disconnect
and Power Off actions cancel immediately. Physical power-off, returning earbuds to
their case, and disconnecting through macOS use the reconnect grace period because
their connection loss cannot reliably be distinguished from a temporary dropout.
When active LDAC playback loses its connection, stops unexpectedly, or the user
disconnects or powers off the headphones in Acouplet, the app requests Pause from
the current macOS media player before cleanup restores audio routes. Reconnecting
or falling back to ordinary Bluetooth audio after a transport failure, including
at fixed 990 kbps quality, does not resume music automatically. Players must support
macOS media controls to respond. Deliberately turning LDAC off, changing playback
settings and microphone handoffs keep their existing playback behavior.
Microphone handoff can wait for a longer call while the same headphones remain
connected; losing that connection starts the same 60-second deadline. Expiry clears
only the pending request, leaving the device's automatic profile and Manual Off
preference intact for future connections. Cancellation reasons appear in the LDAC
lifecycle log.

A configuration becomes the last successful configuration after 30 seconds of
active playback. After two failed attempts, Settings offers an explicit restore
button. A fixed quality choice is never replaced automatically. Music and Video
presets select 48 kHz adaptive quality with 250 ms and 100 ms reserves respectively.
Custom preserves explicit settings and permits a 50–500 ms reserve. Video and
Custom remain experimental: offline checks validate frame scaling and protocol
readiness, not audible resilience. Neither a smaller sender reserve nor a manual
offset removes receiver buffering.

The default microphone policy restores normal headset call audio for microphone
activity, automatically selecting the same headset for both microphone input and
audio output when its Bluetooth devices return. The output is selected after the
microphone so activating the call profile does not leave audio on another output.
Routing retries when the headset devices disappear or change during reconnection.
After the call, the previous devices are restored before LDAC resumes; manual input
and output changes made during the call are preserved while the headset devices
remain available. Separate microphone mode selects a chosen built-in or USB input
and keeps LDAC only when that input is appropriate; headset microphone use still
requires handoff. Manual mode exposes explicit pause/resume controls while preserving headset
handoff if a headset input is used. The menu identifies the process and microphone
currently in use.
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

The capture helper also records `PCM_HEALTH` once per second, including callback,
delivered-frame, nonzero-frame, overload and recovery-attempt counts and elapsed
silence. These are signal statistics; no audio is saved. Core Audio overload
notifications on the capture aggregate and source output arm a five-second
recovery window after the stream has produced nonzero audio. If capture then
remains entirely silent for two seconds while another audio process is still
running on that same output, the helper attempts one stop/start of its own capture
IOProc. Application selection still limits which source processes qualify.
The PCM ring, LDAC encoder, Bluetooth connection, output volume and source player
remain in place. A ten-second cooldown and a new overload are required for another
attempt. Silence alone, initial silence and inactive sources do not arm recovery;
an overload coinciding with an intentional silent passage can still cause one
capture restart. Restart errors use the existing capture shutdown path.

`PCM_OVERLOAD_RECOVERY` identifies attempts; later `PCM_HEALTH` nonzero-frame
increments show that capture contains audio again. This addresses suspected silent
capture after an overload, rather than proving the cause of every audible dropout.
The 2026-10-22 interruption coincided with a Core Audio overload and recovered after
the user paused Spotify. Deterministic fixtures cover recovery decisions and failed
restarts. A [controlled live test](ValidationHistory.md#live-capture-recovery-after-injected-silence)
with WF-1000XM5 earbuds at 96 kHz / 660 kbps confirmed one real capture restart and
automatic audible recovery after injected silence. Recovery from the original
macOS overload still needs qualification when that failure recurs.

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
