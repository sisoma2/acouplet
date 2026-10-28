[Documentation](README.md)

# Headphone controls

## Ending a Bluetooth connection

When macOS reports that a headset disconnected, Acouplet closes its control
connection and cancels pending commands and automatic retries. It waits for a
new Bluetooth connection or an explicit **Connect** before opening controls
again. This also releases a separate Bluetooth LE control connection when the
headset's ordinary Bluetooth connection ends.

LDAC also confirms a headset departure through its connection watcher and session
completion. That confirmation clears any earlier control-channel error and retry countdown, even
when the ordinary Bluetooth notification was ignored during LDAC recovery.
The header shows **Not Connected** with **Connect**. LDAC may keep its pending
request while waiting for the headset to return, without retrying the controls.
Inventory polling also clears an earlier control error when it confirms that
the headset is disconnected.

The LDAC worker reports confirmed headset or Bluetooth-radio disconnection as
soon as it receives the connection-close evidence, before finishing audio and
driver cleanup. The panel immediately switches to **Not Connected** and hides
LDAC instead of showing **Reconnecting…** throughout cleanup. Temporary control
or transport failures still use recovery while the headset remains connected.

The disconnected menu shows the selected headset's name and artwork with its
connection status and **Connect** button. Device controls, including LDAC,
transport counters and report export, stay hidden until the headset returns.
App settings, About and Quit remain available.

Temporary disconnects managed by LDAC, connection-mode changes and multipoint
changes keep their existing recovery flow. A missing inventory entry by itself
does not end an open control connection, so a transient discovery gap or losing
one earbud does not disconnect the remaining bud.

## Delayed noise-control acknowledgments

Noise-control capability, availability and status reads retry once after a
three-second acknowledgment timeout during startup and normal use, including
LDAC playback. The retry sends the identical frame and sequence, keeps the
control session open and leaves queued commands waiting for a real acknowledgment.
It does not restart response deadlines or reapply a status reply already consumed.
If the retry also goes unacknowledged, or the original eight-second noise-status
deadline expires, the existing control recovery still runs. Setting commands do
not gain a retry.

The 2026-10-25 keyboard reconnection at fixed 96 kHz / 990 kbps was followed by
sender congestion and an unacknowledged `62 17` noise-availability read. Previously
that read retried during startup only; its three-second timeout during playback
reset the controls and stopped LDAC. The bounded retry addresses that shutdown
trigger, not the underlying Bluetooth throughput loss. Recovery under keyboard
traffic still needs live qualification.

## Noise mode recovery and feedback

Noise-control transitions recheck the headset after 250 ms, then up to five more
times at one-second intervals within the original eight-second status deadline.
If the headset never settles, the next poll resynchronizes the control connection,
including during LDAC playback. Unconfirmed writes request fresh status immediately.
Only validated terminal replies re-enable writes; expired-session replies are ignored.
Mode confirmations compare active settings, allowing the headset to normalize
inactive NC/ambient fields without leaving a successful Off or ANC command pending.

Confirmed local mode changes play a brief distinct two-note tone through the selected
headset's output. Initial sync, headset-button changes and ambient-level adjustments
do not play an extra tone. Standard LDAC uses its virtual output; per-application
LDAC routing currently omits feedback because it excludes Acouplet's own audio.
These are app-generated tones, rather than Sony's built-in voice prompts.
