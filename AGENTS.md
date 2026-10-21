# Repository preferences

Do not add comments to code in this repository. Use clear names and straightforward code instead.

After finishing edits that modify Python files, run `uv run --locked ruff check .` and `uv run --locked ruff format .`. Fix all lint errors and confirm `uv run --locked ruff check .` and `uv run --locked ruff format --check .` pass before building and installing any required update. Skip Ruff lint and formatting checks when no Python files change.

After finishing edits that modify Swift or other app code, build a signed Release update, quit any running Debug copy, install the update into /Applications using the local installer, and launch /Applications/Acouplet.app to test it. Follow [Install and run local changes](Docs/Development.md#install-and-run-local-changes). Confirm that only the installed new build is running and that its executable matches the build. Preserve the installed app's signing team so LDAC and existing permissions continue working. Skip this Release build, installation and launch workflow when no Swift or other app code changes.

## Documentation

Project documentation lives in [Docs](Docs/README.md). Start with that index for development, testing, LDAC behavior and research. Add or update documentation there when project behavior or workflows change.

## Project memory

On 2026-10-21, the private-certificate Release passed live LDAC playback with driver revision 8 on macOS 26.7.1 (25G241) without rebooting the Mac. After installing the matching app and driver, quit Acouplet normally and wait for its owner worker to exit, then run `osascript -e 'do shell script "/usr/bin/killall -TERM coreaudiod" with administrator privileges'`. Wait for Core Audio to return, reopen `/Applications/Acouplet.app`, and verify `--ldac-driver-state` reports `current` and bundled/installed/loaded revisions match. This interrupts all audio and requires administrator authorization; coordinate it with the user. The test streamed at 96 kHz / 990 kbps, recovered after app relaunch, and the user confirmed normal audible playback. See [the saved commands](Docs/LDACPlayback.md#reload-the-driver-without-restarting-the-mac). Keep this as a manual procedure; installers do not restart Core Audio automatically.
