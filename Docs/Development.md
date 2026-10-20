[Documentation](README.md)

# Development

Use Xcode 27.0 with the macOS 27.0 SDK. The deployment target is macOS 15.4.
The native HUD is checked at launch and falls back when unavailable.
Select Xcode under Xcode > Settings > Locations > Command Line Tools before
running the commands below.

Run shell commands from the repository root.

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

## Install and run local changes

After finishing edits, run these commands from the repository root to test the
updated app in `/Applications`. The build uses the installed app's signing team
and an existing Apple Development certificate from that team. This preserves
the installed app's identity and settings, including LDAC driver authentication.

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

The installer quits the installed app, stops its background service, replaces
the app, and checks that the installed binaries match the new Release build.
It preserves whether the background service was running. Use the installer
for replacement so these steps finish before the new version starts.

When updating an app that supports LDAC update handoff, the installer requests
one Bluetooth disconnect and skips the intermediate ordinary-audio reconnection.
The replacement explicitly reconnects the previously active headset with its
session settings, then claims the handoff when starting LDAC. A separate recovery worker
restores ordinary Bluetooth audio if no replacement claims it within 60 seconds
after the old app exits. Sparkle uses the same handoff when relaunching immediately.
Normal Quit, shutdown and updates that leave the background service stopped keep
ordinary-audio restoration. The first installation of this change still uses the
previous app's shutdown behavior.

Confirm that the running app is under `/Applications` and that its executable
matches the freshly compiled Release build:

```sh
pgrep -fl 'Acouplet.app/Contents/MacOS/Acouplet'
cmp .build/Build/Products/Release/Acouplet.app/Contents/MacOS/Acouplet \
  /Applications/Acouplet.app/Contents/MacOS/Acouplet
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Acouplet.app/Contents/Info.plist
```

`cmp` exits successfully without output when the executables match. There
should be one app process under `/Applications`, optionally with `--background-service`,
and no Debug copy. An additional `--ldac-owner` worker is expected during LDAC
playback. The build and install receipts are saved under `.build/local-update/`.

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
