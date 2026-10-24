# LDAC capability observations

Capability observations are stored per normalized device address with firmware, connection mode, multipoint state and observation time. Positive observations expire after 30 days and negative observations after one day. A changed context or a potentially hidden endpoint allows discovery again. Unversioned Boolean observations are ignored.

An advertised LDAC endpoint with an incompatible requested rate remains a sample-rate failure. Advertised stereo rates disable unsupported settings without classifying the whole device as unsupported. Known models that hide LDAC while multipoint is active retain their existing restrictions.

Check LDAC support again clears only the selected device and uses the normal guarded playback setup, which can interrupt ordinary audio. Driver, capture permission, control and multipoint checks still apply.

Run `LDACSupportTests` and the LDAC owner lifecycle fixtures. Hardware discovery remains a manual check; the offline tests do not contact Bluetooth devices.
