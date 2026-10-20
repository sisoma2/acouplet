[Documentation](README.md)

# LDAC playback

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

Pending playback requests expire after 60 seconds, including time spent asleep.
Selecting different headphones cancels the previous request immediately and checks
the newly selected device's automatic profile after cleanup. Acouplet's Disconnect
and Power Off actions cancel immediately. Physical power-off, returning earbuds to
their case, and disconnecting through macOS use the reconnect grace period because
their connection loss cannot reliably be distinguished from a temporary dropout.
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
