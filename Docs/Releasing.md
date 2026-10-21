[Documentation](README.md)

# Release builds with GitHub Actions

The [Release workflow](../.github/workflows/release.yml) generates a DMG with LDAC
support using your own code-signing certificate and publishes it in a GitHub
Release. It requires no Apple Developer membership and performs no Apple
notarization. The app, driver and helpers are signed with one private identity;
the DMG and embedded installer packages remain unsigned.

The app and driver recognize the exact certificate fingerprint. This preserves
an identity across builds without accepting other certificates or ad-hoc apps.
The app validates its bundled and installed drivers, and the install and removal
scripts check the same identity before replacing or deleting a driver.

The driver reports revision 8 for both Apple and private signing. A revision 7
driver must be updated, and the Mac must restart before loaded revision 8 can
be confirmed. The revision identifies driver behavior; verify the certificate
fingerprint separately to identify a private build.

## Choose the signing identity

Reuse the same Acouplet private release certificate and private key for local
and GitHub builds. The identity belongs to the app's release lineage, rather
than to a particular machine or runner. A new certificate has a different
fingerprint even if its name is identical, and requires the LDAC
[identity-change procedure](#updates-and-signing-identity-changes). Create a new
identity only for an initial setup or an intentional signing-key rotation.

The development Mac checked on 2026-10-21 has its existing identity in
`.build/private-hardware-test/identity/`. Its public certificate fingerprint is
`7466B0F0B564832D0ACA341A99C028B186F36E5B`, matching the pins in both the installed
app and LDAC driver. To reuse those files, select:

```sh
acouplet_identity_dir=.build/private-hardware-test/identity
```

This identity's export password is already saved in
`.build/private-hardware-test/identity/password`. It was verified to open the
matching `.p12`. The setup block below reads that file automatically when
present, so there is no password to invent or enter for this existing identity.
To set only its password secret without displaying the value:

```sh
(
  set -e
  set -o pipefail
  set +x
  printf '%s' "$(< .build/private-hardware-test/identity/password)" |
    gh secret set P12_PASSWORD --repo sisoma2/acouplet
)
```

Keep a secure backup of the password-protected `.p12` and its password outside
`.build/`, which is disposable. The `.p12` must include the private key; the
public `.pem` or a certificate extracted from the app cannot sign a build. If
the identity is available only in Keychain Access, export that certificate
together with its private key as a password-protected `.p12`. Changing the
export password preserves the signing identity.

### Create a new identity only when needed

Choose a strong password, then run these commands from the repository root in
zsh. Enter the password at the silent `read` prompt:

```sh
IFS= read -r -s 'P12_PASSWORD?New .p12 password: '
printf '\n'
export P12_PASSWORD
Packaging/create-private-signing-certificate.sh .build/private-signing
unset P12_PASSWORD
acouplet_identity_dir=.build/private-signing
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

Under **Settings > Actions > General**, the workflow supports allowing repository
owner actions plus selected external actions, with **Allow actions created by
GitHub** and **Require actions to be pinned to a full-length commit SHA** enabled.
It uses only `actions/checkout`, `actions/upload-artifact` and
`actions/download-artifact`, so Marketplace verified creators and additional
allowed-action patterns are unnecessary.

All action references are pinned to full commit SHAs verified in the
official repositories:

| Action | Release ref | Pinned commit |
| --- | --- | --- |
| `actions/checkout` | `v6` | `d23441a48e516b6c34aea4fa41551a30e30af803` |
| `actions/upload-artifact` | `v6` | `b7c566a772e6b6bfb58ed0dc250532a479d7789f` |
| `actions/download-artifact` | `v8.0.2` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |

When updating an action, verify the release's commit in its official repository,
replace every reference to that action with the full 40-character commit SHA,
and update this table. Keep the repository's SHA requirement enabled.

Each test job installs uv 0.13.4 using the official release's standalone installer,
verifying its pinned SHA-256 before execution. This needs no additional allowed
Actions. When updating uv, update both the release URL and installer checksum
in the workflow. Python follows `.python-version` (currently 3.15), dependencies
follow `uv.lock`, and tests run through `uv run --locked`. The packaging job also runs
Ruff lint and formatting checks, plus the update-preparation and LDAC
qualification checks with `/usr/bin/python3` to retain Python 3.9 compatibility
for packaging scripts that use the system interpreter.
The test checkout includes the tagged commit and its parent because the source
provenance fixtures exercise changes to both the Git index and `HEAD`.

The test and build jobs grant `GITHUB_TOKEN` only `contents: read` and disable
checkout credential persistence. A separate publishing job grants
`contents: write` to create the release for the pushed tag using the
[GitHub CLI](https://cli.github.com/manual/gh_release_create) and the automatic
`GITHUB_TOKEN`. It downloads the build artifact without checking out or running
repository code and has no signing secrets. No personal access token is needed.
The publishing job uses `ubuntu-26.04` explicitly to avoid automatic operating
system migrations through `ubuntu-latest`. The download action declares Node.js 24.

The build job clears extended attributes from the staged app and verifies its
signature before copying it into a writable APFS image made with
`diskutil image create blank`. The image reserves 256 MB beyond the staged payload
for filesystem metadata and free space. The job clears extended attributes and
verifies the copied app again before ejecting the writable image, then
compresses it to UDZO with `diskutil image create from`.
It checks the image checksum with `hdiutil verify`,
mounts it read-only with `diskutil image attach`, verifies the mounted app's
certificate and executable, and ejects it with `diskutil eject`.

Under **Settings > Secrets and variables > Actions**, add these repository
secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 of `Acouplet-private-signing.p12`. |
| `P12_PASSWORD` | Password chosen when generating that file. |

Add the repository variable `ACOUPLET_SIGNING_CERTIFICATE_SHA1` with the exact
fingerprint of that certificate, without colons. The workflow rejects a
certificate that does not match it. The fingerprint is public and belongs in a
variable; the `.p12` and its password belong in secrets.

### Create repository secrets with the GitHub CLI

Run these commands from the repository root in zsh. Check the CLI login first:

```sh
gh auth status --hostname github.com
```

If needed, sign in with `gh auth login --hostname github.com` using an account
that can manage this repository's Actions secrets and variables.

Set `acouplet_identity_dir` using one of the choices above. Then run this block.
It reads `password` from that directory when present; otherwise, enter the
existing `.p12` password at the silent prompt. It validates the
password and reads the fingerprint directly from the `.p12` before writing
anything to GitHub. It creates or replaces the two repository secrets and the
repository variable in `sisoma2/acouplet`:

```sh
(
  set -e
  set -o pipefail
  set +x
  acouplet_github_repo=sisoma2/acouplet
  if [[ -f "$acouplet_identity_dir/password" ]]; then
    P12_PASSWORD="$(< "$acouplet_identity_dir/password")"
  else
    IFS= read -r -s 'P12_PASSWORD?Existing .p12 password: '
    printf '\n'
  fi
  [[ -n "$P12_PASSWORD" ]]
  export P12_PASSWORD
  acouplet_certificate_sha1="$(
    /usr/bin/openssl pkcs12 -in "$acouplet_identity_dir/Acouplet-private-signing.p12" \
      -passin env:P12_PASSWORD -clcerts -nokeys |
      /usr/bin/openssl x509 -noout -fingerprint -sha1 |
      /usr/bin/sed 's/.*=//;s/://g'
  )"
  [[ "$acouplet_certificate_sha1" =~ ^[A-Fa-f0-9]{40}$ ]]
  printf 'Certificate SHA1: %s\n' "$acouplet_certificate_sha1"
  /usr/bin/base64 -i "$acouplet_identity_dir/Acouplet-private-signing.p12" |
    gh secret set BUILD_CERTIFICATE_BASE64 --repo "$acouplet_github_repo"
  printf '%s' "$P12_PASSWORD" |
    gh secret set P12_PASSWORD --repo "$acouplet_github_repo"
  gh variable set ACOUPLET_SIGNING_CERTIFICATE_SHA1 \
    --repo "$acouplet_github_repo" --body "$acouplet_certificate_sha1"
)
```

The subshell discards its password variable when it exits. Secret values go to
[`gh secret set`](https://cli.github.com/manual/gh_secret_set) through standard
input, which the CLI encrypts locally before upload. The public fingerprint goes
to [`gh variable set`](https://cli.github.com/manual/gh_variable_set). No secret
value is placed in a command argument or copied to the clipboard.

Verify the stored names and public fingerprint:

```sh
gh secret list --repo sisoma2/acouplet
gh variable get ACOUPLET_SIGNING_CERTIFICATE_SHA1 --repo sisoma2/acouplet
```

The secret list shows names and update times; it does not reveal secret values.
There is no need to create a `GITHUB_TOKEN`, provisioning-profile secret or
keychain-password secret for this workflow. GitHub supplies the token and the
build job generates its temporary keychain password.

The workflow uses GitHub's
[Xcode 27 runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/).
The test and build jobs run on separate disposable runners. The test jobs have no
signing secrets. After tests pass, the build job creates a password-protected
temporary keychain and trusts the certificate for code signing. Import uses
noninteractive sudo and has a three-minute step timeout. Immediately after the
DMG's final signature verification, cleanup deletes the exported `.p12` identity,
resets the certificate's administrative code-signing trust to `unspecified`,
then deletes the temporary keychain even if the trust reset fails. Each
Security command has a 20-second timeout, with a two-minute limit on the whole
cleanup step. Cleanup runs as root so its timeout handler can kill a stalled
Security process. Either Security command failing fails the cleanup step after
removing private credential files. A failed trust reset retains only the public
`.pem` so cleanup can retry; successful cleanup removes it.
The reset uses `security add-trusted-cert -d -r unspecified -p codeSign` to replace
the temporary `trustRoot` grant. It avoids the
[hosted-runner hang in `remove-trusted-cert`](https://github.com/actions/runner-images/issues/12116),
which also reproduced on the Xcode 27 runner even before keychain deletion.
An `unspecified` entry grants no explicit trust; its public settings record remains
on the disposable runner until GitHub destroys that VM. This cleanup is for
disposable CI runners, not for removing certificates from a development Mac.
Cleanup uses `if: always()` so it also runs when an earlier step fails or the run
is cancelled. It finishes within its time limits even when cancellation keeps
that step running. Users
installing the app do not need your private key or a system-wide trust entry for
your certificate.

If an older run hangs in **Remove private signing credentials**, its unbounded
`security remove-trusted-cert -d` call can prevent subsequent credential deletion
and artifact uploads. Normal cancellation can leave an `always()` step running.
Try `gh run cancel RUN_ID --repo sisoma2/acouplet --force`. If GitHub reports the
run completed while its job still shows in progress, the API cannot cancel it
again; check that the run is marked cancelled and no release was published before
recreating an unpublished tag. Job logs may remain unavailable until the runner
exits. The step name alone does not establish whether sudo, trust removal or
keychain deletion was blocked.

## Generate and download a Release

Commit and push the workflow and intended source changes before creating the
release tag. The workflow runs automatically when a new tag with the form
`vMAJOR.MINOR` or `vMAJOR.MINOR.PATCH` is pushed, such as `v0.31` or `v0.31.0`.
It removes the leading `v` to obtain the app version. Branch pushes, tag updates
and tag deletions do not start release builds. There are no manual version or
build-number inputs.

Create and push a tag at the commit you want to release:

```sh
git tag -a v0.31.0 -m 'Acouplet 0.31.0'
git push origin v0.31.0
```

The tagged commit must contain this workflow. Each tag has its own concurrency
group, so pushing another release tag does not cancel a pending release for a
different version. To retry a failed run, use **Re-run jobs** in GitHub Actions.

Rerunning a job uses its original commit. If a fix changes the source or workflow,
create a new version tag at the fixed commit, or reuse an unpublished version by
deleting and recreating its tag at that commit. Confirm that the old run has
finished and no GitHub Release exists for the tag before reusing it. A force-push
that only moves an existing tag does not trigger this workflow. Keep published
release tags unchanged.

The workflow generates the build number as `195 + github.run_number`. The
offset preserves continuity with the existing build 195: workflow run 1 uses
build 196, run 2 uses build 197, and so on. GitHub's
[workflow run number](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#github-context)
increases with each new run and remains unchanged on retries. The build job
passes its generated number to the publishing job so the package, artifact name
and release notes agree. No build-number input or repository variable is needed.
Use a new version for each published release. If builds from another source
overtake this numbering range, increase the offset before publishing further
releases.

The publishing job uses the pushed tag `vVERSION` and publishes
`Acouplet VERSION` as the latest release. It requires the tag to exist and resolve
to the exact commit built by the run. A missing or moved tag fails publication.
Existing releases are not overwritten; rerunning an already published version
fails at release creation.

The workflow starts four concurrent **Tests** jobs: `xctest` runs the unit suite
and bundle checks, `packaging` runs packaging fixtures, `native` runs helper
fixtures except controller-volume, and `controller-volume` runs that baseline
and mutation suite. The split keeps the slow controller compiler fixtures from
holding the other suites' shared worker budget. The default local runner still
runs the full suite.

The `xctest` and `packaging` jobs each fetch Sparkle into their own runner's
checkout. XCTest needs the framework, and the packaging update-feed fixtures
execute Sparkle's `generate_appcast` tool. The native fixture jobs do not need
this dependency.

Each job uploads `Acouplet-test-results-SUITE-RUN_ID`, including its summary,
individual check logs and, for `xctest`, the XCTest `.xcresult` bundle, even when
tests fail. Rerunning a job replaces only that suite's artifact. A failing suite
does not cancel the other test jobs, so their diagnostic results remain available.
**Build Release** waits for every test job to pass; **Publish GitHub Release**
waits for the build. Test logs remain in separate Actions artifacts; the build
job does not download them or include them in the release evidence.

The build job builds a Release with `Packaging/package.sh --local` and exercises
the driver's real certificate checks with signed test processes. It verifies that the expected
signer is accepted and that an unrelated app identifier, an ad-hoc signature and a
certificate outside the configured pin are rejected. It then creates and
verifies a compressed DMG without Finder automation. It clears extended
attributes from the app inside a writable image before compression, then verifies
the final mounted app's certificate and executable. This prevents Finder metadata
introduced during image creation from invalidating the strict signature check.

A successful build uploads the `Acouplet-VERSION-BUILD` Actions artifact with
the DMG, checksum and `Acouplet-VERSION-evidence.tar.gz`. The evidence archive
contains the build receipt, build log and debugging symbols. It is retained
only in the Actions artifact for debugging and is not attached to the GitHub
Release.

The publishing job downloads the build artifact, rechecks the DMG checksum and
creates a GitHub Release with these downloadable assets:

- `Acouplet-VERSION.dmg`, containing Acouplet and a shortcut to Applications.
- `SHA256SUMS.txt`, a checksum using the DMG's downloadable filename.

Open the repository's **Releases** page and download the DMG and `SHA256SUMS.txt`
into the same directory, then verify the DMG there:

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
Sparkle update feed. Publishing a GitHub Release does not publish a Sparkle
update feed. Release assets remain available beyond the Actions artifact
retention periods. The build artifact, including the evidence archive, is
retained for 30 days; test results and release diagnostics remain separate
Actions artifacts and are retained for 14 days.

## Local builds and validation

Settings and About show the release version and build number side by side on one line.
GitHub builds take the version from the pushed tag without its leading `v`.
Local packages default to the latest version tag reachable from `HEAD`, so a
build after `v0.31.0` displays `Version 0.31.0` while its build number increases
independently. `ACOUPLET_MARKETING_VERSION` can explicitly select a version,
including when building a source checkout without tags. Without that override,
packaging requires a reachable tag and rejects invalid version formats.

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
