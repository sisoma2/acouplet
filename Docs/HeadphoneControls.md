[Documentation](README.md)

# Headphone controls

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
