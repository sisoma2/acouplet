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

`SonyEarTipFitSession` owns the fit-test model, workflow transition, reply
ownership and phase timeouts. It returns the commands needed for the current
phase; the controller admits and sends them, then reports actual transmission.
Connection loss cancels the timeout and preserves an interrupted measurement
until explicit recovery. Timeout callbacks check both the current control
connection and the scheduled timeout identity, so a cancelled callback cannot
interrupt a replacement attempt. The controller retains transport failure
handling, diagnostics and the existing read-only feature properties.

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

## LDAC music controls

`LDACMusicBinding` classifies a snapshot of the controller identity, connection,
control session, raw transport, selected source, volume range and freshness.
Identity or session changes invalidate the binding; confirmed source changes
stop playback. Incomplete transitions and stale readbacks hold the binding
while the controller applies its existing recovery deadline.

`LDACVolumeSession` owns the pending volume, asynchronous write and write
identity. Its injected operations provide current binding snapshots, confirmed
headphone writes and native-output configuration. Every queued write rechecks
the playback session, write identity, raw transport and binding before it may
transmit. New requests coalesce while a write is awaiting confirmation. An old
cancelled write cannot clear a replacement write, and matching native volume
does not cause another output-configuration request.

`LDACController` retains media admission, connection preferences, binding-hold
deadlines, ordinary-audio restoration and the decisions to stop or recover
playback. It supplies these operations without transferring playback lifecycle
ownership to the volume session. Late native-owner configuration replies retain
their existing tolerance.

## Validation

Run the checks in [Testing](Testing.md). `SonySoundPressureSessionTests` covers
request transmission, stale generations, blocked replies, reset cancellation,
refresh intervals and manual resumption. `LDACDriverServiceTests` covers driver
state admission, repeated installer requests, error recovery and background
inspection races.

`SonyEarTipFitSessionTests` covers transmission ownership, stale timeouts,
connection changes, cancellation and notifications; the existing controller
and transition suites continue to cover the full protocol workflow.
`LDACMusicBindingTests` covers classification and precedence, and
`LDACVolumeSessionTests` covers coalescing, binding holds, cancellation,
replacement writes, source changes, confirmation and native-volume echoes.

The LDAC cleanup and volume fixtures compile `LDACDriverService.swift`,
`LDACMusicBinding.swift` and `LDACVolumeSession.swift` directly alongside their
fake platform interfaces. The volume mutation checks also verify the extracted
volume implementation by compiling a modified copy of the complete type. Their
remaining controller-method extraction continues to exercise playback
coordination. Run GUI checks only in
the isolated macOS VM described in the testing guide.
