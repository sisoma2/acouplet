[Documentation](README.md)

# Validation history

## Roadmap validation on macOS 26.7.1

The implementation passed 72 focused XCTest cases covering LDAC support, call
policies, settings and the HUD timeout regression, plus app/helper builds,
English/Turkish localization, bundle validation and native offline self-checks.
All 20 packaging/driver suites and the LDAC fixture suites passed, including
controller mutations, session closure,
owner lifecycle/exit, physical fallback routing and restoration, and all
rate/quality/buffer latency combinations. The hardware matrix recorder also accepts
permission-denied scenarios without media and rejects a pass with unrestored routes.

The full XCTest run reported 1,224 passes and 10 failures: four Intents crashes,
five preference-pane failures in tests requiring macOS 27, and one HUD subprocess
timeout test that passed when rerun separately. Those tests and their production
components were unchanged by the LDAC roadmap implementation. The full suite is
therefore not green on this macOS 26.7.1 machine. No hardware playback, video sync,
microphone echo or RF qualification is claimed by these checks.
