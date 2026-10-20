[Documentation](README.md)

# LDAC sender timing and diagnostics

Run shell commands from the repository root.

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
[`Experiments/LDACSender`](../Experiments/LDACSender/README.md) as a patch and offline test
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
