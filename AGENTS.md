# Repository preferences

Do not add comments to code in this repository. Use clear names and straightforward code instead.

After finishing edits that modify Python files, run `uv run --locked ruff check .` and `uv run --locked ruff format .`. Fix all lint errors and confirm `uv run --locked ruff check .` and `uv run --locked ruff format --check .` pass before building and installing any required update. Skip Ruff lint and formatting checks when no Python files change.

After finishing edits that modify Swift or other app code, build a signed Release update, quit any running Debug copy, install the update into /Applications using the local installer, and launch /Applications/Acouplet.app to test it. Follow [Install and run local changes](Docs/Development.md#install-and-run-local-changes). Confirm that only the installed new build is running and that its executable matches the build. Preserve the installed app's signing team so LDAC and existing permissions continue working. Skip this Release build, installation and launch workflow when no Swift or other app code changes.

## Documentation

Project documentation lives in [Docs](Docs/README.md). Start with that index for development, testing, LDAC behavior and research. Add or update documentation there when project behavior or workflows change.
