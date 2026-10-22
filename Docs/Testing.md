[Documentation](README.md)

# Testing

Run shell commands from the repository root.

## Python lint and formatting

Set up the [Python tooling environment](Development.md#python-tooling), then run:

```sh
uv sync --locked
uv run --locked ruff check .
uv run --locked ruff format --check .
```

After editing Python files, run the lint check and
`uv run --locked ruff format .`, fix all lint errors, and confirm both checks
above pass before building and installing any required update. Skip Ruff lint
and formatting checks when no Python files change.

The native test runner does not invoke Ruff. To run its checks with the project's
Python interpreter, use `uv run --locked python Packaging/check-all.py` and the
same selection flags documented below. Direct `python3` commands remain supported
for environments without uv, including the isolated GUI-test VM.

The Release workflow runs four concurrent jobs on separate Xcode runners:
XCTest and bundle checks, packaging fixtures, native fixtures, and controller-volume
baseline and mutation fixtures. Each job retains the runner's CPU-based worker
budget. The packaging job also runs Ruff and the update-preparation and LDAC
qualification checks with the system Python to catch Python 3.9 compatibility
issues. All four jobs must pass before the Release build starts. Each job installs
pinned uv and syncs the locked Python 3.15 environment.

## Tests

`Helpers/MediaPlaybackLifetimeCheck.py` compiles the production playback lifetime
code with a recording pause command. Separate processes cover Quit, restart,
cancelled termination, duplicate launch, unexpected exit, SIGTERM and SIGKILL,
including parent death before the worker registers its watcher. The fixture checks
that playback is untouched while the app runs, normal shutdown pauses once,
and workers exit after handling the parent. Live music and browser playback still
need manual confirmation with a player that supports macOS media controls.

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
overloading the machine. The default budget is up to eight workers, bounded by
the logical CPU count. Each child suite uses up to four workers, allowing two
large suites to overlap on an eight-worker run. Use `--jobs 4` for the previous
budget, or `--jobs 8` to select eight explicitly. `ACOUPLET_CHECK_JOBS` sets the
default for both the full runner and individual suites. Each completed check
reports its elapsed time. Swift fixture compilers reuse the module cache.

By default, the full unit suite uses up to four separate test processes,
bounded by `--jobs`. Use `--test-workers 1` for a serial unit run, or choose another process limit
explicitly. Focused `--only-testing` runs use one test process by default.
Unit tests have a 60-second execution allowance so an unexpected system call
cannot leave the entire run waiting indefinitely. GUI galleries retain their
normal execution allowance. LDAC recovery fixtures inject the local Bluetooth
address instead of querying the real host controller.

The inventory-notification callback test sends an Objective-C device fixture
through the real callback selectors from a background queue. Its address getter
uses stored data, so the test exercises the main-actor hop without creating an
`IOBluetoothDevice` or contacting the system Bluetooth service.

The native HUD, LDAC helper compilers and standalone Swift checks also reuse
unchanged build outputs. Reuse checks source and header contents, compiler
arguments, toolchain, SDK and build settings. Missing or changed outputs are
rebuilt or restored from verified compiler artifacts. LDAC bundles still receive
the current version metadata and fresh signatures on every build. Artwork
preparation preserves an unchanged catalog so Xcode can reuse asset compilation.
Test executables still run every time; passing test results are never cached.
The controller-volume baseline and mutation fixtures also reuse compiled
executables when their generated Swift, production dependencies, compiler,
SDK and build settings match. Each case runs a separate copy with a fresh
temporary home. Concurrent runs lock compilation for the same fixture.
Set `ACOUPLET_BUILD_CACHE=NO` to bypass this reuse for troubleshooting or timing.

On the development Mac with 10 logical CPUs, the 42 offline suites took
319.6 seconds with four workers and 213.6 seconds with eight workers while
populating the controller fixture cache. A repeat of all 15 controller-volume
cases reused their compiled binaries and took 52.4 seconds, compared with
86.6 seconds when compiling them. These are local measurements; concurrent
work can make individual suites slower even when total elapsed time improves.

Run just the fixtures, select matching scripts, or focus XCTest on a class:

```sh
python3 Packaging/check-all.py --fixtures-only
python3 Packaging/check-all.py --fixtures-only --filter '*LDAC*'
python3 Packaging/check-all.py --fixtures-only --filter 'Helpers/*' --exclude '*LDACControllerVolumeCheck.py'
python3 Packaging/check-all.py --xctest-only --only-testing AcoupletTests/LDACCallAudioTests
python3 Packaging/check-all.py --ui-only --ui-vm acouplet-ui-base
python3 Packaging/check-all.py --include-ui --ui-vm acouplet-ui-base
python3 Packaging/check-all.py --list
```

`--exclude` removes independent checks matching a filename wildcard and can be
repeated. It applies to both execution and `--list`; an empty selection fails.
It does not select XCTest cases; use `--only-testing` for those.

`--ui-only` runs the GUI suite, including the screenshot galleries. GUI automation
requires an isolated macOS VM. On macOS 26.7.1, disabling XCTest automation has
crashed Code, Chrome and Finder inside Apple's `XCTAutomationSupport` framework.
The runner refuses to start GUI automation on a physical host. The `Acouplet`
Xcode scheme runs only unit tests; `Acouplet UI Tests` and `Acouplet Public UI Tests`
build the GUI target only inside a guest. Run `test-without-building` only inside
the guest as well.

Prepare a stopped local [Tart](https://tart.run/quick-start/) base VM with Xcode 27
or later, Python 3, the Tart guest agent, an unlocked desktop, and permission to
run UI automation and capture screenshots. For example, start from the published
[Xcode 27 image](https://github.com/cirruslabs/macos-image-templates/releases/tag/27):

```sh
brew install openai/tools/tart
TART_NO_AUTO_PRUNE=1 tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:27 acouplet-ui-base
tart set acouplet-ui-base --cpu 4 --memory 8192
tart run acouplet-ui-base
```

Finish desktop setup and grant test permissions inside the guest, then stop it
with `tart stop acouplet-ui-base`. Keep personal apps and accounts out of the
base VM. `--ui-vm acouplet-ui-base` clones it for each run, copies current tracked
and untracked source files that Git does not ignore plus the cached Sparkle
dependency, runs tests on the guest disk, and saves logs and XCTest results under
`.build/ui-test-vm/run-*/results/`. Each run stops and deletes its own clone;
the base VM is kept. Source is shared read-only, clipboard, audio and USB sharing
are disabled, and automatic Tart cache pruning is disabled. GUI runs inside an
already isolated guest can omit `--ui-vm`.

`--include-ui` runs unit tests, GUI tests and the offline fixtures; combine it with `--xctest-only`
to omit fixtures. Local phases reuse build products; disposable VM runs build
from the copied source. Both modes accept `--only-testing` for focused reruns.
GUI tests run serially because they share the
desktop, after unit tests finish. Each phase must execute passing tests; an empty
or failing phase fails the command. The default command runs unit tests and
offline fixtures.

GUI waits first check the current state, avoiding XCTest's initial polling delay
when the element already exists, has disappeared or has the expected value.
Changing states are checked every 50 milliseconds within the original timeout,
using the run loop so UI automation can continue processing events.
Family galleries open Settings with its keyboard shortcut and avoid activating
an app that the test host already activated during launch. They still capture
every model, finish, appearance, noise mode, equalizer and Settings page.
Automatic XCTest screen captures are disabled to avoid recording every UI action;
explicitly requested gallery screenshots and contrast evidence are always kept,
including on success.
GUI fixtures place titled windows on the primary display, keeping captures and
controls reachable when the desktop has multiple displays with different scales.
Tests force visible native scrollbars and page through their tracks to reveal
offscreen Settings controls. Captures crop the containing display using its own
scale, including menu bar items and HUDs on secondary displays.
Noise-control contrast checks crop each button from the panel screenshot already
captured for that state, preserving all mode, appearance, selection and readability checks
without requesting separate screenshots for each button.

Native HUD presentation runs separately. To exercise legacy startup migration
with disposable LaunchAgents, without opening the app or using Bluetooth, run:

```sh
python3 Packaging/check-service-migration.py
```

This checks normal and service-managed startup, login preference preservation,
failure/retry handling and removal of the old job. It does not modify the installed
Acouplet service or login item.

Bluetooth, audio and connection recovery still need testing with real hardware.

`Helpers/LDAC/LDACCaptureRecoveryCheck.py` exercises the production overload
watchdog, capture restart and active-source inventory with synthetic clocks and
Core Audio calls. It covers silence without overloads, initial silence, returning
audio, window expiry, notification bursts, cooldowns, cancellation, stop/start
errors, PCM ring preservation and selected-application/output admission. The
fixture does not overload the host audio service or control a real player.

Run that check directly with:

```sh
uv run --locked python Helpers/LDAC/LDACCaptureRecoveryCheck.py
```

It also runs the production audio callback, PCM ring and complete streaming loop
with synthetic stereo samples and a simulated clock. Seven stream scenarios cover
overload followed by silence and recovery, silence without an overload, a paused
source, an unrelated output, included and excluded applications, and silence that
persists after the restart. The test asserts the two-second recovery threshold,
one stop/start, delivered audio after a successful simulated restart, preserved
frame counts and the absence of repeated restarts if silence persists. Core Audio
stop/start calls and source inventory are simulated, so this confirms the helper's
control flow rather than recovery from a real macOS overload. Live qualification
requires a recovery attempt followed by increasing `PCM_HEALTH` nonzero-frame
counts and audible playback without pausing the source player. The
[2026-10-22 headset test](ValidationHistory.md#live-capture-recovery-after-injected-silence)
verified these with a temporary signed helper injecting silent PCM and an overload
event into the real playback pipeline. Its real capture restart and audible
recovery passed; the original macOS scheduling failure was not reproduced.

Packaging, app installation, LDAC driver installation, and direct-release
fixtures run up to eight isolated cases concurrently when invoked directly,
bounded by the logical CPU count. Through `check-all.py`, each suite uses up to
four of the shared workers. They support `--filter`,
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
and timeout cases. The installed scripts keep their normal wait times. Packaging
fixtures share each unchanged stub executable across cases, avoiding repeated
macOS launch costs for newly written executable files. Command names, exit codes,
logs and filesystem state remain specific to each fixture. Python stubs use the
same interpreter as the test runner. No passing check results are cached. On
macOS 26.7.1, all 104 installer cases completed in 68.1 seconds with four workers,
compared with the previous 217.3-second run using four workers.
