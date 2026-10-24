# Headphone connections

The device picker includes disconnected paired headphones and preserves the device selected for an explicit connection. Classic connection attempts expire after 45 seconds; an expired or replaced callback cannot revive the old session. Explicit Connect prefers Classic audio unless the prior transport or connection mode requires Bluetooth LE.

Disconnect closes the selected headphones and suppresses automatic reconnect until an explicit Connect or Bluetooth LE connection. Failures remain visible. Disconnect is unavailable during an LDAC session; LDAC disconnect coordination is a separate change.

Run the connection-controller and device-coordinator XCTest suites. Manually check picker selection, connect, disconnect, retry, power-off and sleep/wake with paired headphones.
