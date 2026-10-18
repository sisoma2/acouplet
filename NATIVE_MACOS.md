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

To build a local installer using an existing Apple Development certificate:

```sh
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

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
