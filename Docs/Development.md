[Documentation](README.md)

# Development

Use Xcode 27.0 with the macOS 27.0 SDK. The deployment target is macOS 15.4.
The native HUD is checked at launch and falls back when unavailable.
Select Xcode under Xcode > Settings > Locations > Command Line Tools before
running the commands below.

Run shell commands from the repository root.

## VS Code

The shared [workspace settings](../.vscode/settings.json) exclude `.build/` from
the Explorer, searches and recursive file watching. Other files in `.vscode/`
remain ignored. Packaging artifacts in `.build/` include `Applications` links
to `/Applications`, so browsing through them can open installed application
files, including VS Code's own extension manifests. Keep those generated files
closed during normal development.
Exclusions do not disable validation for files that are already open or stop
extensions that scan files independently.

After changing these settings, close tabs opened through `.build/` and run
`Developer: Reload Window` from the Command Palette. JSON problems in installed
extension manifests are not Acouplet source errors; do not edit those manifests
to resolve them.

## Python tooling

Install [uv](https://docs.astral.sh/uv/getting-started/installation/), then
create the project environment with the locked development dependencies:

```sh
uv sync --locked
```

The project uses Python 3.15 for development, selected by `.python-version`.
uv can download that interpreter when it is unavailable locally. The scripts
remain compatible with Python 3.9 or later and use only the standard library
and repository modules. Ruff is a development dependency pinned in
`pyproject.toml` and `uv.lock`; there is no separate requirements file or Python
package to build. Keep `.venv/` and `.ruff_cache/` out of version control.

Run tools through the project environment:

```sh
uv run --locked ruff check .
uv run --locked ruff format --check .
uv run --locked python Packaging/check-all.py
```

After editing Python files, run `uv run --locked ruff check .` and
`uv run --locked ruff format .`, fix all lint errors, and confirm the lint and
format checks above pass before building and installing any required update.
Skip Ruff lint and formatting checks when no Python files change. Ruff targets
Python 3.9 and excludes build outputs and vendored code. Configure editor
integrations to use `.venv/bin/ruff` so they use the same version as the command
line.

Xcode phases, packaging scripts and the isolated GUI-test VM continue to use
their existing Python interpreters. They do not require uv or Ruff. Python
checks launched by `Packaging/check-all.py` use that runner's interpreter,
so invoking it through uv exercises the development environment. See
[Testing](Testing.md) for focused checks and VM requirements.

## Build

For automated Release DMGs without Apple credentials, see
[Release automation](Releasing.md).

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

Apple certificate signing provides permission continuity between builds. LDAC
also supports a private certificate pinned by fingerprint in development
distributions; see [Release automation](Releasing.md) for setup and migration.
Ad-hoc signing cannot authenticate LDAC driver commands. Release and App Store
builds use your signing settings; the project does not pin an upstream Team ID.

Quit the installed app, then open `Install.command` in
`.build/local-update/Acouplet/`. See that package's README for removal instructions.
Do not rebuild while installation is running.

## Install and run local changes

After editing Swift or other app code, run these commands from the repository
root to test the updated app in `/Applications`. Skip this Release build,
installation and launch workflow when no Swift or other app code changes.
For an Apple-signed installation, the build uses the installed app's signing team
and an existing Apple Development certificate from that team. For a private-signed
installation, use the same certificate and pin as described in
[Local builds and validation](Releasing.md#local-builds-and-validation). Both paths
must preserve the installed app's signer for LDAC authentication and permission
continuity.

```sh
CODE_SIGN_IDENTITY='Apple Development' \
DEVELOPMENT_TEAM="$(codesign -dv --verbose=2 /Applications/Acouplet.app 2>&1 | sed -n 's/^TeamIdentifier=//p')" \
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

Once the build succeeds, quit any separate Debug copy, install the packaged
Release build, and launch the app from Applications:

```sh
osascript \
  -e 'if application id "dev.baglayan.Acouplet.debug" is running then' \
  -e 'tell application id "dev.baglayan.Acouplet.debug" to quit' \
  -e 'end if'
.build/local-update/Acouplet/Install.command --require-stopped
open /Applications/Acouplet.app
```

The installer quits the installed app, removes its legacy background service if
present, replaces the app, and checks that the installed binaries match the new
Release build. It reopens a previously running app normally and keeps a stopped
app stopped. Existing startup preferences migrate to **Launch at login** in
Acouplet Settings. Use the installer for replacement so these steps finish before
the new version starts.

When updating an app that supports LDAC update handoff, the installer requests
one Bluetooth disconnect and skips the intermediate ordinary-audio reconnection.
The replacement explicitly reconnects the previously active headset with its
session settings, then claims the handoff when starting LDAC. A separate recovery worker
restores ordinary Bluetooth audio if no replacement claims it within 60 seconds
after the old app exits. Sparkle uses the same handoff when relaunching immediately.
Normal Quit, shutdown and updates that leave the app stopped keep
ordinary-audio restoration. The first installation of this change still uses the
previous app's shutdown behavior.

The direct app requests Pause from the current macOS media player before quitting
or restarting, including update relaunches. A separate `--media-playback-watch`
worker watches the app process and requests Pause if it crashes, receives a
termination signal or is force-quit. Normal shutdown disarms the worker after
requesting Pause, so it does not pause playback again after the replacement starts.
Acouplet does not resume playback automatically. Players and browser videos must
support macOS media controls to respond; the public API build omits this integration.

Confirm that the running app is under `/Applications` and that its executable
matches the freshly compiled Release build:

```sh
pgrep -fl 'Acouplet.app/Contents/MacOS/Acouplet'
cmp .build/Build/Products/Release/Acouplet.app/Contents/MacOS/Acouplet \
  /Applications/Acouplet.app/Contents/MacOS/Acouplet
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Acouplet.app/Contents/Info.plist
```

`cmp` exits successfully without output when the executables match. There
should be one app process under `/Applications` with no `--background-service`
argument and no Debug copy. A `--media-playback-watch` worker is expected while
the direct app is running, and an additional `--ldac-owner` worker is expected
during LDAC playback. The build and install receipts are saved under `.build/local-update/`.

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
