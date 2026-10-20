[Documentation](README.md)

# Headphone controls

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
