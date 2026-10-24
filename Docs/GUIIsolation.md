# Isolated GUI tests

Run GUI tests in a disposable clone of a stopped local Tart macOS VM with Xcode, Python 3, an unlocked desktop, the Tart guest agent and GUI automation permissions. Default app tests include only unit tests; both GUI schemes require a macOS guest before building the GUI target.

Fetch Sparkle, then run `python3 Packaging/check-ui.py --ui-vm acouplet-ui-base`. Use repeated `--only-testing AcoupletUITests/testName` options for focused checks. Inside an isolated guest, omit `--ui-vm`.

The runner snapshots tracked and unignored source files and the cached Sparkle dependency, copies them to the guest disk and retains XCTest results under `.build/ui-test-vm/run-*/results`. Each run stops and removes only its disposable clone. The base VM is retained, source sharing is read-only and clipboard, audio and USB sharing are disabled.

Run `python3 Packaging/check-ui-test-vm.py` and `python3 Packaging/check-ui-runner.py` for offline admission, lifecycle, source snapshot, cleanup and result-validation checks. These fixtures do not launch GUI automation.
