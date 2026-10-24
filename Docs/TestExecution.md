# Incremental test execution

Run `python3 Packaging/check-all.py` for unit tests and offline fixtures. Use `--fixtures-only`, `--xctest-only`, `--filter PATTERN`, repeated `--exclude PATTERN`, `--only-testing AcoupletTests/ClassName`, `--jobs N` and `--list` for focused runs. `--clean` requests a clean XCTest build; ordinary runs reuse build products.

Independent fixtures share a bounded worker pool and retain separate logs under `.build/check-all/Logs`. Full unit runs use up to four workers; focused unit runs use one. Test cases have a 60-second execution limit. Empty selections and failed child checks fail the runner. GUI automation is outside this runner.

Native helper and standalone compiler outputs are reused only when source/header contents, command arguments, toolchain, SDK, build settings and output fingerprints match. Modified or missing artifacts rebuild or restore from verified compiler output. Signing and version metadata still run on each build. Set `ACOUPLET_BUILD_CACHE=NO` to disable reuse. Passing test results are never cached.

Run `python3 Packaging/check-build-cache.py`, `python3 Packaging/check-runner-check.py` and `python3 Packaging/check-all-check.py` for cache invalidation, worker budgeting and runner selection/failure coverage.
