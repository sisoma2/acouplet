[Documentation](README.md)

# Release builds with GitHub Actions

The [Release workflow](../.github/workflows/release.yml) generates a DMG with LDAC
support using your own code-signing certificate. It requires no Apple Developer
membership and performs no Apple notarization. The app, driver and helpers are
signed with one private identity; the DMG and embedded installer packages remain
unsigned.

The app and driver recognize the exact certificate fingerprint. This preserves
an identity across builds without accepting other certificates or ad-hoc apps.
The app validates its bundled and installed drivers, and the install and removal
scripts check the same identity before replacing or deleting a driver.

The driver reports revision 8 for both Apple and private signing. A revision 7
driver must be updated, and the Mac must restart before loaded revision 8 can
be confirmed. The revision identifies driver behavior; verify the certificate
fingerprint separately to identify a private build.

## Create a signing identity once

Choose a strong password, then run these commands from the repository root in
zsh. Enter the password at the silent `read` prompt:

```sh
read -r -s P12_PASSWORD
export P12_PASSWORD
Packaging/create-private-signing-certificate.sh .build/private-signing
unset P12_PASSWORD
```

The script creates:

| File | Purpose |
| --- | --- |
| `.build/private-signing/Acouplet-private-signing.p12` | Password-protected private key and certificate. Keep a secure backup. |
| `.build/private-signing/Acouplet-private-signing.pem` | Public certificate. |

It prints the public certificate's 40-character SHA-1 fingerprint. This is the
certificate identifier used by macOS code-signing requirements, not a file
checksum. The certificate lasts ten years. Reuse the same identity for future
releases; do not regenerate it for each workflow run. The script refuses to
overwrite existing files, and `.build/` is ignored by Git.

## Configure GitHub Actions

Under **Settings > Secrets and variables > Actions**, add these repository
secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 of `Acouplet-private-signing.p12`. |
| `P12_PASSWORD` | Password chosen when generating that file. |

Copy the encoded identity to the clipboard with:

```sh
base64 -i .build/private-signing/Acouplet-private-signing.p12 | pbcopy
```

Add the repository variable `ACOUPLET_SIGNING_CERTIFICATE_SHA1` with the exact
fingerprint printed by the script, without colons. The workflow rejects a
certificate that does not match it.

The workflow uses GitHub's
[Xcode 27 runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/).
It tests the source before importing the private identity, then creates a
password-protected temporary keychain and trusts the certificate for code signing
on that disposable runner. Cleanup removes the trust entry, keychain and
credential files. Users installing the app do not need your private key or a
system-wide trust entry for your certificate.

## Generate and download a Release

Commit and push the workflow and intended source changes. The workflow must be
present on the repository's default branch for **Run workflow** to appear.
Open **Actions > Release > Run workflow**, select the branch to build, and enter:

| Input | Value |
| --- | --- |
| `version` | Marketing version with two or three numeric components, such as `0.31.0`. |
| `build_number` | Positive integer greater than every previously distributed build number. |

Build numbers are explicit because a fresh runner cannot read the local build
counter or an installed app. Use a new number for each new build.

To build a tag with the GitHub CLI, provide it with `--ref`:

```sh
gh workflow run release.yml --ref YOUR_TAG -f version=0.31.0 -f build_number=123
```

The workflow runs the unit and offline fixture suite, builds a Release with
`Packaging/package.sh --local`, and exercises the driver's real certificate
checks with signed test processes. It verifies that the expected signer is
accepted and that an unrelated app identifier, an ad-hoc signature and a
certificate outside the configured pin are rejected. It then creates and
verifies a compressed DMG without Finder automation. It clears extended
attributes from the app inside a writable image before compression, then verifies
the final mounted app's certificate and executable. This prevents Finder metadata
introduced during image creation from invalidating the strict signature check.

A successful run uploads the `Acouplet-VERSION-BUILD` artifact containing:

- `Acouplet-VERSION.dmg`, containing Acouplet and a shortcut to Applications.
- `SHA256SUMS.txt`, a checksum using the DMG's downloadable filename.
- `Acouplet-VERSION-evidence.tar.gz`, the build receipt, test and build logs,
  and debugging symbols.

Download and extract the artifact, then verify the DMG from that directory:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Quit Acouplet before replacing an existing copy. Open the DMG and drag Acouplet
to Applications. On first launch, existing installations retire the old background
service and preserve its startup preference as **Launch at login**. The app runs
normally in the menu bar. Because the app and its LDAC
packages are not notarized, macOS may block them. If you trust the build, use
**System Settings > Privacy & Security > Open Anyway** after trying to open the
app or package. Enable LDAC from the app, authorize the driver installation,
and restart the Mac to load it.

## Updates and signing identity changes

Keep signing with the same certificate. Existing private drivers accept app
updates signed with that certificate, subject to the usual driver revision
check. If a driver update is needed, install it through the app and restart.

An existing Apple-signed driver or a driver signed with another private
certificate is deliberately rejected. Before switching signing identities, stop
LDAC and use the old app's LDAC removal action, then restart to unload the old
driver. Replace the app, install the new driver's package from the new app, and
restart again. Do not delete an old signing key until users can remove its driver.
Bluetooth or audio-capture permission may need approval again after a signing
identity change. Permission continuity for private certificates depends on macOS;
verify it on the versions you distribute to.

These builds use the development distribution, which disables the production
Sparkle update feed. The workflow does not create a GitHub Release or publish an
update feed. Release artifacts are retained for 30 days; separate diagnostics
are retained for 14 days. Archive release files elsewhere before they expire.

## Local builds and validation

Import the `.p12` into a local keychain and explicitly trust its public
certificate for code signing on the build machine. Set its fingerprint as both
the signing identity and pin, leaving the Apple team and installer identity empty:

```sh
CODE_SIGN_IDENTITY=YOUR_CERTIFICATE_SHA1 \
ACOUPLET_SIGNING_CERTIFICATE_SHA1=YOUR_CERTIFICATE_SHA1 \
DEVELOPMENT_TEAM= ACOUPLET_INSTALLER_SIGNING_IDENTITY= \
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

The certificate pin is accepted only for development distributions. All nested
code must match that certificate. Only private-certificate builds add the
`com.apple.security.cs.disable-library-validation` entitlement to the app so it
can load its bundled frameworks without an Apple team identifier; the app's
own LDAC signature checks remain enforced.

With the identity available, test actual driver authentication without installing
a driver or changing audio routing:

```sh
CODE_SIGN_IDENTITY=YOUR_CERTIFICATE_SHA1 \
ACOUPLET_SIGNING_CERTIFICATE_SHA1=YOUR_CERTIFICATE_SHA1 \
Packaging/check-private-signing.sh
```

For the hardware smoke test, install the matching private app and driver using
the identity-change procedure above, then restart. In **LDAC setup and
compatibility**, bundled, installed and loaded driver revisions must all show
**8**. The revision alone does not establish which certificate signed the driver.
Verify the app and installed driver against the release's fingerprint:

```sh
certificate=YOUR_CERTIFICATE_SHA1
codesign --verify --deep --strict --all-architectures \
  --test-requirement="=identifier \"dev.baglayan.Acouplet\" and certificate leaf = H\"$certificate\"" \
  /Applications/Acouplet.app
codesign --verify --deep --strict --all-architectures \
  --test-requirement="=identifier \"dev.baglayan.Acouplet.LDACOutput\" and certificate leaf = H\"$certificate\"" \
  /Library/Audio/Plug-Ins/HAL/AcoupletLDACOutput.driver
```

Enable LDAC, play music and confirm that it is audible through the headphones.
Use `Packaging/ldac-session-stats.py` to inspect the new session's rate, bitrate
and failures. Stop and restart LDAC once to check that driver authentication and
audio routing recover. Record results separately from the offline checks.

For normal work on a Mac with an existing Apple-signed installation, continue to
follow [Install and run local changes](Development.md#install-and-run-local-changes)
to preserve that installation's team. Apple Development and Developer ID signing
remain supported, and `Packaging/direct.sh --notarize` retains its production
Developer ID requirements.
