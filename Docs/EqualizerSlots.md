# Equalizer user slots

The equalizer editor can save a curve to User 1 or User 2 when the headphones advertise those destinations. The controller selects and confirms the destination before writing its curve. Edits waiting for the same destination coalesce, and timeouts or connection changes discard the pending curve.

Run the equalizer, legacy-controls and protocol XCTest suites. Manually verify both supported user slots, switching presets and reconnecting. Unsupported devices do not offer slot writes.
