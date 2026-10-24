# LDAC capture recovery

After an overload, the streaming capture helper restarts capture once when previously audible audio becomes silent for two seconds and another process is still playing through the captured output. Silence without overload, paused sources and unrelated outputs do not trigger a restart. Cooldowns bound later attempts. The PCM ring is preserved.

Run `python3 Helpers/LDAC/LDACCaptureRecoveryCheck.py` and `python3 Helpers/LDAC/LDACCaptureStartupCheck.py`. The recovery check uses synthetic clocks, source inventory and Core Audio calls, including the production streaming loop. It does not reproduce a real macOS overload or establish audible recovery. Application selection is outside this change.

Live qualification must observe a recovery event, increasing nonzero PCM frames and audible playback without pausing the player.
