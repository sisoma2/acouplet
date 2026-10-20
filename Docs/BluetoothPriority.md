[Documentation](README.md)

# Bluetooth airtime priority investigation

## Bluetooth airtime priority investigation

The existing HAL priority handshake requests Bluetooth audio configuration. Its
completion notification does not acknowledge an LDAC media-channel scheduling
change or measure radio airtime.

Inspection of the arm64e Bluetooth daemon on macOS 26.7.1 (25G241) found a separate
private path: `CBController modifyDevice:settings:completion:` with
`CBDeviceSettings.aclPriority`. The daemon labels value 80 as High and value 1 as
Default, checks controller support, and routes High to a controller priority
request. This targets the device's ACL link, which can carry several channels;
it is not a dedicated LDAC channel reservation.

On 2026-10-19, an access probe outside the development sandbox reached this API
and received `CBErrorDomain -71168`, with the reason
`Missing entitlement: com.apple.bluetooth.system`. The probe used a synthetic
device identifier and Default priority, so it did not raise priority on paired
headphones. An ordinary developer signature does not supply that Apple
entitlement. No production priority request was added through this path.

Live tests on the same build also checked `kCBL2CAPChannelPriority` on the owned
AVDTP media channel, using `CBClassicPeer sendMsg:args:` message 29 with a nested
`kCBMsgArgOptions` dictionary. A temporary wrapper around the existing media
helper replaced its channel-opening method only in the test process.
The installed app and production helpers were unchanged. The native session harness
retained channel ownership checks, AVDTP negotiation and shutdown, and used no HAL
audio-configuration request in any trial. Each trial transmitted about five seconds
of silent LDAC at 96 kHz / 660 kbps.

| Requested option | Owned media CID | Daemon registration priority |
| --- | --- | --- |
| Omitted | `690E` | 0 |
| 0 | `7C0E` | 0 |
| 1 | `8F0D` | 0 |
| 2 | `A30E` | 0 |
| 12 | `B60E` | 0 |
| 2, with incoming MTU 768 | `EF0E` | 0 |

These numbers are raw experimental values, not verified priority-level names.
Every trial completed transmission with `strictPass=1`, zero skipped frames,
confirmed transport shutdown and native Bluetooth audio restoration. In the last
trial, the daemon's connection-setup log read `inMTU:768` from the same options
dictionary while retaining `priority:0`; this confirms that options reached it.
The later registration log still reported an incoming MTU of 1024, so the setup
log alone does not establish the negotiated incoming MTU.

Disassembly explains the priority result: the Classic open handler at
`bluetoothd` arm64e address `0x10028f954` decodes only
`kCBL2CAPChannelInMTU` from the options. Its block at `0x100294350` passes zero
for priority into the common channel-creation function at `0x1004558cc`.
The other open handler that parses `kCBL2CAPChannelPriority` is not the Classic
path used here. This option therefore does not provide preferential LDAC airtime
through couplet's current transport on this build.

Normal installed LDAC playback was restored after the experiment.

The local `IOBluetoothDevice.highPriority` setter only stores an object field on
this build. Further qualification needs a permitted controller interface, evidence
that a request affects the owned media link, and controlled playback comparisons
under competing Bluetooth traffic. These short trials did not measure radio
airtime or receiver delivery. Socket drain timings alone cannot establish radio
scheduling.
