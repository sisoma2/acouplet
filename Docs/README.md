# Acouplet documentation

Acouplet is a native macOS menu bar app for Sony Bluetooth headphones, earbuds
and speakers. It provides device controls and experimental LDAC playback.
For installation and everyday use, start with the [project README](../README.md).

## Development guides

| Guide | Contents |
| --- | --- |
| [Development](Development.md) | Python tooling and Ruff, Xcode requirements, builds, signed local installation, artwork and build options. |
| [Release automation](Releasing.md) | Private certificate setup, LDAC-enabled DMGs published to GitHub Releases and Actions diagnostics without Apple membership. |
| [Source boundaries](Architecture.md) | Feature state, Settings and menu views, normal app startup, legacy service migration and LDAC driver operations. |
| [Testing](Testing.md) | Unit tests, offline fixtures, isolated GUI tests, build reuse and logs. |
| [Headphone controls](HeadphoneControls.md) | Noise-mode recovery, confirmation and audible feedback. |
| [LDAC playback](LDACPlayback.md) | Driver reload without a Mac restart, capability discovery, latency, device profiles, call policies, application routing and health reports. |
| [LDAC sender timing and diagnostics](LDACTransport.md) | Adaptive quality, serialized transport, packet traces, HCI analysis and archived pipeline findings. |
| [Bluetooth airtime priority](BluetoothPriority.md) | Private API investigations, live trial results and measurement limits. |
| [Hardware qualification](HardwareQualification.md) | Preparing and recording manual playback, call and recovery scenarios. |
| [Validation history](ValidationHistory.md) | Recorded macOS 26.7.1 test results and remaining qualification limits. |
| [Upstream PR deliveries](UpstreamPRs.md) | Follow-up scopes, extraction order, dependencies, validation and deferred driver work. |

Run shell commands in these guides from the repository root. After editing Swift
or other app code, follow [Install and run local changes](Development.md#install-and-run-local-changes)
to build, install and verify a signed Release update.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`Sources/`](../Sources/) | Swift application, device controls, settings, audio routing and LDAC lifecycle. |
| [`Helpers/`](../Helpers/) | Native Bluetooth, audio, battery and HUD helpers; LDAC encoding, transport and virtual output driver. |
| [`Resources/`](../Resources/) | Artwork, assets and localized resources. |
| [`Configuration/`](../Configuration/) | Application build configuration and entitlements. |
| [`Acouplet.xcodeproj/`](../Acouplet.xcodeproj/) | Xcode project and shared schemes. |
| [`Tests/`](../Tests/) and [`UITests/`](../UITests/) | Unit tests and GUI automation. |
| [`Packaging/`](../Packaging/) | Build, install, release, diagnostic and fixture runners. |
| [`PreferencePane/`](../PreferencePane/) and [`Controls/`](../Controls/) | Preference-pane and Controls extension sources. |
| [`Experiments/LDACSender/`](../Experiments/LDACSender/README.md) | Archived packet-sender prototype and its separate offline runner. |
| [`Vendor/libldac/`](../Vendor/libldac/) | Vendored LDAC codec sources. |

Keep new project documentation in this folder and add it to the guide index.
Keep historical investigation results distinct from current behavior and record
which macOS build and hardware were tested. See [third-party notices](../THIRD-PARTY-NOTICES.md)
for bundled dependencies and artwork licensing.
