[Documentation](README.md)

# Feature contributions to upstream

Target contributions at [baglayan/acouplet](https://github.com/baglayan/acouplet).
This plan was checked on 2026-10-25 against integration commit `e74029b` on
`integration/upstream-sync`. Upstream `main` still points to
`0033a4b253302c26158ce351b909d050f37f65fa`, the integration baseline.
The comparison contains 194 changed files, so the integration branch itself is
not a suitable feature PR.

Use the integration branch to reconcile and validate combined behavior. Create
each PR branch from the current upstream `main` and transfer only the relevant
changes and regression coverage. This keeps unrelated fork history out of each
review. If a feature depends on another PR, state that dependency and wait for its
merge before refreshing the dependent branch. Resolve upstream conflicts in the
integration branch first, then apply the relevant resolution to each PR branch.

## First delivery

[Draft PR #10: Fix native battery publication after sample expiry](https://github.com/baglayan/acouplet/pull/10)
uses branch `fix/native-battery-expiry` and commit `e017220`.

It stops the publication supervisor when its sample expires or the child withdraws
all battery components, preserves cleanup failure reporting, and records the
expiry reason in publisher diagnostics. The PR changes three files, with 54
insertions and eight deletions. It does not contain the integration merge.

Validation on the isolated PR branch:

- The new native regression fails against the original helper and passes with the fix.
- All 58 native battery publisher unit tests pass.
- `Helpers/NativeBatterySelfTestCheck.sh` passes, including native cleanup checks.

## Subsequent deliveries

The identifiers below are planning labels, not GitHub PR numbers. Suggested
branch names describe the isolated contribution. Dependencies describe the
intended extraction order; confirm them against the actual diff before opening.
Independent fixes can proceed while another PR is reviewed.

| ID | Suggested branch and PR scope | Land first |
| --- | --- | --- |
| F01 | `fix/pause-media-on-exit`: pause media on normal and unexpected app exit | Independent |
| F02 | `fix/ldac-capture-recovery`: recover silent capture after an overload | Independent |
| F03 | `fix/ldac-battery-refresh`: refresh battery before its publication lease expires | PR #10 |
| F04 | `fix/paired-headphone-reconnect`: explicit connect/disconnect and bounded connection recovery | Independent |
| F05 | `fix/noise-mode-confirmation`: recover noise controls and confirm mode changes | Independent |
| F06 | `feat/equalizer-user-slots`: save equalizer curves to User 1 and User 2 | Independent |
| F07 | `fix/ldac-capability-cache`: invalidate stale or incomplete capability observations | Independent |
| F08 | `feat/ldac-device-profiles`: persist per-headphone playback settings | F07 |
| F09 | `fix/ldac-session-recovery`: preserve session ownership through reconnects and setting changes | F04, F08 |
| F10 | `feat/ldac-call-handoff`: hand audio to the headset for calls and restore it afterward | F09 |
| F11 | `feat/ldac-application-routing`: capture selected applications | F02, F08 |
| F12 | `fix/ldac-adaptive-recovery`: improve adaptive quality recovery and sender pacing | Independent; hardware gate |
| F13 | `fix/normal-app-lifecycle`: replace the legacy background service with normal app startup | F01 |
| F14 | `feat/ldac-update-handoff`: transfer an LDAC session across an app update | F09, F13 |
| F15 | `feat/ldac-session-diagnostics`: add session reports and qualification tooling | Settle F09–F12 event formats |
| F16 | `perf/isolated-test-runners`: isolate GUI checks and improve fixture execution | Independent; split as below |
| F17 | `build/release-packaging`: deliver packaging and release improvements | F13–F14 for installer changes; F16 for CI |

### First wave: small fixes and headphone controls

**F01 — Pause media when Acouplet exits.** Start with `ae2abd6`, adapting the
startup and shutdown hooks to upstream's current lifecycle. Transfer
`MacMediaPlaybackLifetime.swift`, the worker CLI dispatch, app shutdown hooks,
project membership and `Helpers/MediaPlaybackLifetimeCheck.py`. Do not require
the normal-app migration in F13. Cover Quit, restart, cancelled termination,
duplicate launch, unexpected exit, SIGTERM, SIGKILL and parent death before worker
registration. Confirm one pause on normal shutdown and worker disposal. Manually
check a supported music player and browser video; automatic resume is out of scope.

**F02 — Recover silent capture after Core Audio overloads.** Start with `2e1fa3f`.
Extract the watchdog and bounded capture restart from `SystemAudioTapProbe.m`,
plus `Helpers/LDAC/LDACCaptureRecoveryCheck.py`. Adapt the fixture to upstream's
capture code rather than copying selective application routing as a prerequisite.
Cover overload followed by silence, silence without overload, paused sources,
cooldown, cancellation, restart failures and PCM accounting. Keep the change
independent of the sender and driver. Describe the existing injected-silence live
test accurately: it verified real capture restart, not reproduction of the original
macOS scheduling failure.

**F03 — Keep native battery publication fresh during LDAC.** Extract the battery
polling portion of `de71238` and the existing streaming-only battery refresh.
Keep the 30-second battery refresh below the 45-second native sample lease while
avoiding a full settings poll during playback. Include only the relevant
`SonyHeadphonesController.swift` changes and focused connection tests; the helper
expiry fix belongs to PR #10. Cover transition admission, command retries and
streaming/ordinary polling changes. Observe live publication beyond the former
expiry window. Do not include the unrelated takeover retry from the same commit.

**F04 — Make paired headphone connection and recovery explicit.** Use `d7530ca`
as the starting point for `SonyDeviceCoordinator`, `SonyHeadphonesController`
and the existing connection controls. Preserve selection of a disconnected paired
device, expose disconnect, suppress reconnect after explicit disconnect, and bound
Classic connection attempts. Cover stale timeout callbacks, failed attempts,
explicit reconnect, power-off and sleep/wake in the coordinator and connection
tests. Keep event-driven inventory optimization and LDAC-first startup separate.

**F05 — Recover noise controls and confirm changes.** Use `ed9aff2` and `e9acea1`
as references for targeted state refresh, pending-write confirmation and the
confirmed-change notification in `SonyHeadphonesController`, `SonyNoiseControl`
and `SonyNoiseModeHUD`. Cover changing states, stale replies, retries, duplicate
confirmations and rapid mode changes with `SonyNoiseControlTests`. Transfer only
the relevant UI hunks and strings. Keep audible feedback as a separate follow-up
if it needs an independent UX decision. Run menu selection and contrast checks
inside the isolated GUI VM.

**F06 — Save equalizer curves to device slots.** Start with `496e7aa`, including
later draft-initialization fixes only where required. Transfer slot capability
detection, select-and-confirm before writing the curve, editor controls and
matching strings. Cover unsupported slots, selection failure, coalesced edits,
reconnect and protocol generations in the equalizer, legacy-control, protocol and
preference-pane tests. Existing per-device drafts must not be overwritten by a
provisional flat curve. Avoid the broad Settings view extraction.

### Second wave: LDAC behavior

**F07 — Make LDAC capability observations expire and respect context.** Extract
`LDACSupport.swift`, capability events from `LDACNativeSession`, controller
admission and the selected-device recheck action. Cover age, firmware, connection
mode, multipoint state, address normalization and legacy records in
`LDACSupportTests`. A hidden endpoint must remain retryable; an unsupported sample
rate must not become a negative codec observation. Reuse upstream's WH-1000XM4
support and preserve its multipoint restrictions.

**F08 — Persist playback profiles per headphone.** Extract the profile model,
`SettingsStore` migration and only the associated settings controls. Cover global
setting fallback, address normalization, switching devices, explicit opt-outs,
last-successful settings and invalid persisted data in `SettingsStoreTests` and
the configuration tests. Add configuration fields alongside the PR that consumes
them: microphone policy in F10, application selection in F11 and latency fields
in the deferred driver work. Expose automatic activation per device without
silently importing the fork's default-on experimental LDAC policy. Changing that
default is a separate product decision and PR.

**F09 — Keep LDAC recovery bound to the current session.** Extract relevant
controller, native-output, owner and connection-helper changes, with
`LDACMusicBinding` and `LDACVolumeSession` where they make ownership testable.
Include expiry of stale startup/retry requests, switching between headphones,
rate/quality restart, confirmed volume writes and ordinary-output restoration.
The bounded initial takeover retry from `de71238` belongs here. Preserve upstream's
callback-owned transport and quit/RFCOMM ordering. Exercise cleanup, volume,
connection-ownership, native-output restoration, owner lifecycle and session-closure
fixtures, plus volume-session tests. Split automatic-start policy from recovery
if the extracted PR cannot demonstrate one coherent state transition. Live checks
must cover reconnect, manual Off, output changes and interrupted startup.

**F10 — Hand audio to calls and restore it afterward.** Use `406fbbd`, `04e6a81`
and `9c4c952` as references, extracting `LDACCallAudio`, controller hooks and the
associated profile controls. Cover microphone admission, headset input/output
selection, idle debounce, restoration and preservation of manual route changes
with `LDACCallAudioTests` and cleanup fixtures. Deliver automatic headset handoff
first; external-microphone and manual policies can follow separately if their
diffs are independently reviewable. Qualify built-in, USB and headset microphones
with real calls, including permission denial and unplugged devices.

**F11 — Route selected applications through LDAC.** Extract
`LDACApplicationRouting`, process-tap selection in `SystemAudioTapProbe.m`, native
session arguments and the profile UI. Cover empty/invalid selections, browser
helpers, application restart, selected-output ownership, excluded processes and
capture permission denial. Run capture startup/recovery fixtures and configuration
tests, then manually confirm included and excluded applications. Re-run F02's
recovery scenarios against selective capture. Keep latency and microphone policy
changes outside this PR.

**F12 — Improve adaptive quality recovery and sender pacing.** Extract only the
remaining delta in `LDACAdaptivePolicy.h` and `DirectAVDTPLiveMediaProbe.m` after
upstream's transport fixes. Retain the serialized socket sender and callback-derived
ownership. Cover bounded queues, packet integrity, source starvation, scheduler
stalls, isolated jitter, congestion demotion and healthy promotion with adaptive
policy, media queue, sender timing and log-free transport fixtures. Run the
90-second independently clocked source test without a competing Xcode build and
deterministic replays at all four sample rates. Live playback of the combined
transport remains unqualified; attach sustained fixed/adaptive playback and
reconnect evidence before marking this PR ready. Do not revive the archived packet
sender or claim socket drain proves headphone delivery.

### Third wave: app lifetime and delivery tooling

**F13 — Run as a normal menu-bar app.** Start with `7d5e34d`, adapting it to
upstream's unsplit Settings views. Include app entry and shutdown, Settings login
preference migration, legacy LaunchAgent retirement and the corresponding local
installer behavior together. Cover service-managed and normal startup, preserved
login opt-out, failed migration/retry and stopped/running updates with
`SettingsStoreTests`, `Packaging/check-service-migration.py` and
`Packaging/check-install.py`. Confirm a normal installed app process and its
expected workers. Keep cosmetic Settings refactoring outside this change.

**F14 — Transfer LDAC across an app update.** Start with `66fc5cf`. Extract
`LDACUpdateHandoff.swift`, owner/session hooks, the local installer request and
Sparkle relaunch integration. Cover a single Bluetooth disconnect, replacement
claim, session-setting preservation, stale tokens, replacement failure and the
60-second ordinary-audio fallback with handoff, owner/session and installer
fixtures. Normal Quit and an update leaving the app stopped must still restore
ordinary audio. Validate both the new handoff and first upgrade from an app that
does not support it. This contribution updates the app, not the HAL driver.

**F15 — Make session evidence usable.** Add session-log retention and bitrate
summaries, diagnostic reports and `Packaging/qualify-ldac.py` with their existing
fixture coverage. Preserve partial/unknown intervals in reports and record manual
hardware observations separately from automated results. Keep optional packet
tracing and `Packaging/ldac-packet-timing.py` in a second diagnostics PR if needed;
its tests must cover trace bounds, exclusive file creation, malformed/incomplete
captures and packet identity. Include only event fields implemented by landed PRs.
Historical experiments stay documentation or explicitly separate tooling.

**F16 — Improve test isolation and execution.** Open separate PRs for GUI VM
isolation and for shared fixture concurrency/build caching. Transfer the relevant
runner helpers, Xcode schemes and runner self-tests together. Verify selection,
empty-selection failure, shared worker limits, failed-child reporting and cache
invalidation; do not cache passing results. GUI automation must run in the
isolated macOS VM. Keep the Python/uv/Ruff adoption and repository-wide formatting
in their own tooling PR if upstream wants that workflow; feature regressions
must remain runnable with upstream's current tooling meanwhile.

**F17 — Improve packaging and release automation.** Extract independently
reviewable fixes for version/build provenance, installer behavior and signing
cleanup before proposing the complete GitHub Release workflow. Use the existing
package, install, update-feed, release-source and private-signing cleanup fixtures.
Carry the final fixes from `398e4a3`, `c206a5f`, `9876ffb` and `e9a2410`, not their
intermediate implementations. Propose private-certificate releases as an optional
distribution workflow after upstream agrees to it; preserve Apple-team signing.
Do not copy fork release destinations, feeds, credentials or version policy into
upstream. Driver authentication and installer compatibility remain deferred below.

## Deferred and separate contributions

- **Driver latency and compatibility:** receiver-delay parsing, pipeline latency,
  buffer presets and per-device calibration need their own app/helper/driver plan.
  Upstream currently uses driver revision **9**, while this integration deliberately
  remains at **8**. Do not transfer that revision downgrade or imply the two binaries
  are interchangeable. Agree on revisioning, old-driver behavior, authenticated
  properties and installer compatibility before extracting these changes. Include
  native property/parser checks and video-sync qualification when this work resumes.
- **Automatic LDAC defaults:** changing experimental LDAC and new profiles to
  default-on needs an explicit behavior proposal, supported-device qualification
  and preference-migration coverage. It is not incidental to F08 or F09.
- **Feature and view extraction:** contribute `SonySoundPressureSession`,
  `SonyEarTipFitSession` and driver-service extraction separately from Settings/menu
  view decomposition. Keep each extraction behavior-preserving and transfer its
  existing tests. Shared feature PRs should adapt to upstream's current layout.
- **Independent UI and discovery fixes:** Settings launch/reopen behavior, menu
  dismissal and selection, notification focus, preference-pane lifecycle and
  event-driven Bluetooth inventory should each be inspected for a remaining
  upstream bug and proposed with focused regressions. Shortcut-default changes
  are a separate preference decision. Keep `.vscode` exclusions optional.

Upstream already contains WH-1000XM4 support, custom Apple signing teams and the
quit/RFCOMM fix. Reconcile only remaining differences; do not reopen those
contributions under new names. Do not export fork-specific `AGENTS.md` preferences
or validation claims as upstream project policy.

## Extraction and acceptance checklist

1. Refresh upstream and check existing PRs before starting each extraction. Create
   the proposed branch from upstream `main` after any dependencies land. Treat the
   commit references above as source pointers, not safe whole-commit cherry-picks.
2. Transfer the smallest production change, focused regression, required project
   membership, strings and documentation together. Use the final integration
   implementation where an older source commit was corrected during integration.
   Avoid unrelated localization rewrites, formatting and runner dependencies.
3. For a bug fix, show the regression fails on the unmodified upstream behavior
   and passes after extraction. Run focused checks on the isolated branch;
   integration results do not establish that an extracted PR passes. Run existing
   relevant public-API and direct-build checks for affected build paths.
4. Follow [Testing](Testing.md) for the full unit/offline checks before marking
   ready. In this integration checkout, Python edits require
   `uv run --locked ruff check .`, `uv run --locked ruff format .`, then passing
   lint and format checks as documented in [Development](Development.md).
   Keep extracted regressions compatible with upstream's supported test runner;
   adopting uv is a separate contribution. GUI checks run only in the isolated VM.
5. For Swift or other app-code changes validated locally, follow
   [Install and run local changes](Development.md#install-and-run-local-changes):
   build a signed Release, preserve the installed signer, quit Debug, install with
   the local installer, launch `/Applications/Acouplet.app` and verify executable
   equality and the expected app/worker processes. Record manual device results
   with model, firmware, macOS build, routes and audio observations.
6. Keep integration driver revision **8** unchanged. App validation must not
   install a driver or restart Core Audio. Any later driver reload is a separate,
   coordinated manual action. Existing integration results are recorded in
   [Validation history](ValidationHistory.md); combined-transport live playback
   is still a separate qualification gate.
7. Open a draft with the concrete trigger, resulting behavior, exclusions,
   dependency links, isolated-branch test results and remaining hardware limits.
   Keep only a small review queue instead of opening the entire roadmap at once.

Start by extracting **F01 and F02**. While those are reviewed, prepare **F03**
against PR #10's eventual merged baseline, then **F04–F06**. Reassess the LDAC
wave after these smaller contributions land. This document plans follow-ups;
only PR #10 is currently open, and no other PRs have been created by this plan.
