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

By default, the full unit suite uses up to four separate test processes,
bounded by `--jobs`. Use `--test-workers 1` for a serial unit run, or choose another process limit
explicitly. Focused `--only-testing` runs use one test process by default.
Unit tests have a 60-second execution allowance so an unexpected system call
cannot leave the entire run waiting indefinitely. GUI galleries retain their
normal execution allowance. LDAC recovery fixtures inject the local Bluetooth
address instead of querying the real host controller.

The native HUD, LDAC helper compilers and standalone Swift checks also reuse
unchanged build outputs. Reuse checks source and header contents, compiler
arguments, toolchain, SDK and build settings. Missing or changed outputs are
rebuilt or restored from verified compiler artifacts. LDAC bundles still receive
the current version metadata and fresh signatures on every build. Artwork
preparation preserves an unchanged catalog so Xcode can reuse asset compilation.
Test executables still run every time; passing test results are never cached.
Set `ACOUPLET_BUILD_CACHE=NO` to bypass this reuse for troubleshooting or timing.

Run just the fixtures, select matching scripts, or focus XCTest on a class:

```sh
python3 Packaging/check-all.py --fixtures-only
python3 Packaging/check-all.py --fixtures-only --filter '*LDAC*'
python3 Packaging/check-all.py --xctest-only --only-testing AcoupletTests/LDACCallAudioTests
python3 Packaging/check-all.py --ui-only --ui-vm acouplet-ui-base
python3 Packaging/check-all.py --include-ui --ui-vm acouplet-ui-base
python3 Packaging/check-all.py --list
```

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

Native HUD presentation and the launch service check run separately.
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
and timeout cases. The installed scripts keep their normal wait times. Packaging
fixtures share each unchanged stub executable across cases, avoiding repeated
macOS launch costs for newly written executable files. Command names, exit codes,
logs and filesystem state remain specific to each fixture. Python stubs use the
same interpreter as the test runner. No passing check results are cached. On
macOS 26.7.1, all 104 installer cases completed in 68.1 seconds with four workers,
compared with the previous 217.3-second run using four workers.
