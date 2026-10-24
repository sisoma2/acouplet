# LDAC adaptive recovery

Adaptive quality initially requires 15 seconds of healthy transport before each increase. Sustained drain delays demote quality after 60 ms of observed congestion; severe packet delay demotes immediately. After congestion, the healthy interval becomes 30 seconds and doubles after failed probes up to 120 seconds. Isolated jitter subtracts its observed time instead of erasing all promotion progress. Source starvation and scheduler stalls still reset progress and do not count as receiver congestion.

The policy counts no more healthy audio time than elapsed time, even while draining a backlog. Fixed quality remains fixed. This extraction retains upstream's serialized sender and does not add the integration branch's encoded queue, packet tracing, buffering presets or driver changes.

Run `python3 Helpers/LDAC/LDACAdaptivePolicyCheck.py` and the native signaling/media checks in `python3 Packaging/check-all.py`. Deterministic replays exercise all four rates and the 90-second independent source scenario checks bitrate recovery and exact PCM accounting. Avoid competing builds during timing-sensitive checks.

Live sustained fixed/adaptive playback and reconnect qualification remain required before the draft PR is marked ready. Local socket drain does not prove headphone delivery.
