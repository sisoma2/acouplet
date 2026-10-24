[Documentation](README.md)

# Feature contributions to upstream

Target contributions at [baglayan/acouplet](https://github.com/baglayan/acouplet).
The integration branch is `integration/upstream-sync`; its upstream baseline is
`0033a4b253302c26158ce351b909d050f37f65fa`.

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

| Order | Scope | Review boundary |
| --- | --- | --- |
| 2 | Pause media when Acouplet exits | Normal quit and independent crash watcher, with lifetime fixtures. |
| 3 | Recover silent system audio capture | Capture health detection, bounded restart and recovery fixtures. |
| 4 | Headphone connection and noise control recovery | Explicit disconnect, bounded Classic connection timeout and noise-state recovery; split further if the resulting diff mixes workflows. |
| 5 | LDAC call and microphone handoff | Headset selection, external microphone policy and restoration coverage. |
| 6 | LDAC device profiles and application routing | Settings, persistence, routing and validation; separate routing from profiles if independently reviewable. |
| 7 | LDAC latency and adaptive transport | Delay reporting, buffering, quality decisions and transport regressions; coordinate driver changes separately. |
| 8 | Packaging and release tooling | Independent tooling fixes with their own fixture coverage; private signing remains optional. |

Inspect current upstream behavior before extracting each delivery: some fork
changes may already be implemented there. Keep bug fixes separate from UI,
refactoring and release infrastructure whenever they can stand alone.

The integration driver revision remains **8** at the user's request. Revision and
installer compatibility changes are deferred. Integration validation must not
install the driver or restart Core Audio. Live LDAC playback with the combined
transport remains a separate hardware qualification step.
