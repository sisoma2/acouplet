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
and timeout cases. The installed scripts keep their normal wait times.

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

Driver revision 6 reports the pipeline estimate in device latency frames at the
negotiated sample rate; stream latency remains zero so Core Audio's device plus
stream sum counts the pipeline once. The estimate includes the initial 250 ms PCM
reserve (replaced by the actual sender reserve at startup), one encoder frame,
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
