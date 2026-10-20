[Documentation](README.md)

# Source boundaries

Acouplet keeps connection and playback coordination separate from feature state
and presentation. Extract a feature with its request ownership, timers and reply
handling so changes can be tested without opening a Bluetooth connection.

## Headphone controls

`SonyHeadphonesController` owns the control transport, command queue and connection
session. It checks whether a feature may send a command and notifies the feature
when that command is actually transmitted.

`SonySoundPressureSession` owns listening-level state, pending reads, request
generations, timeout handling, refresh intervals and automatic-refresh suspension.
The controller forwards its change notifications and exposes the existing
read-only feature properties. Connection transitions decide whether a reply may
publish a reading; stale replies still retire their pending request. Resetting a
read cancels its timeout and invalidates its generation. Timeout callbacks also
check that the control connection is still current.

Protocol payload parsing remains in `SonySoundPressure`. Transport admission and
connection-preference recovery remain in the controller.

## Settings and menu presentation

`SettingsView` owns tab selection and Settings lifecycle work, including automatic
listening-level refresh. `GeneralSettingsView`, `HeadphoneSettingsView` and
`DiagnosticsSettingsView` own their respective forms and dependencies. General
Settings owns the driver-removal confirmation state.

Shared controls live in `HeadphoneFeatureControls`, `HeadphoneTestControls`,
`MultipointControls` and `LDACSettingsView`. `HeadphoneConnectionView` contains the
connection controls and device picker. `DeviceArtwork` contains the device and
charging-case views.

`MenuBarView` retains panel sizing, menu dismissal and confirmation presentation.
`NoiseControlView` receives the selected controller and tint explicitly and
contains noise modes, listening presets and ambient controls. Its content keeps
the existing sibling layout and accessibility identifiers.

## LDAC driver operations

`LDACController` coordinates playback and checks that playback is stopped before
requesting driver operations. `LDACDriverService` owns driver inspection,
coalesced background inspection, installer launch state and installation errors.
It accepts injected inspection and launch functions for tests.

The controller forwards the service's published values through its existing
publishers. Background inspections apply results only if playback is still
stopped when the inspection finishes. A completed inspection then asks the
controller to reconsider the preferred codec.

## Validation

Run the checks in [Testing](Testing.md). `SonySoundPressureSessionTests` covers
request transmission, stale generations, blocked replies, reset cancellation,
refresh intervals and manual resumption. `LDACDriverServiceTests` covers driver
state admission, repeated installer requests, error recovery and background
inspection races.

The LDAC cleanup and volume fixtures compile `LDACDriverService.swift` directly
alongside their fake platform interfaces. Their remaining controller-method
extraction continues to exercise playback coordination. Run GUI checks only in
the isolated macOS VM described in the testing guide.
