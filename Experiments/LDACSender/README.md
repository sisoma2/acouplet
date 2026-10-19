# Bounded packet sender prototype

This archive preserves the unsupported packet API experiment for offline research.
It is excluded from app builds and the normal check suite. Production uses the
serialized socket sender and retains opt-in packet timing diagnostics.

Run the synthetic experiment from the repository root:

```sh
python3 Experiments/LDACSender/check-pipeline.py
```

The runner applies `packet-sender.patch` to a temporary copy of the production
media helper, includes the archived `LDACSenderExperiment.h`, and builds only
temporary executables. It does not modify production sources or access Bluetooth
devices. If production changes make the patch inapplicable, reconcile the patch
before rerunning the experiment.

The fixture compares windows of one and four immutable, MTU-bounded RTP/LDAC
packets at 48 and 96 kHz / 990 kbps. It checks delayed and reordered completions,
stale callback isolation, bounded submissions, API errors, and packet boundaries.
A four-packet window avoids the backlog imposed by synthetic callback delays;
this does not establish support or throughput on a real Classic channel.

On macOS 26.7.1 (25G241), the private channel packet API sends a message that the
daemon's Classic dispatch does not implement. Live window-one and window-four
trials failed on the first packet with `NSOSStatusErrorDomain -71142`. An explicit
Classic fallback avoided that error but retained the original serialized sender.
A subsequent 990 kbps trial still stopped after 4.866 seconds with 99,328 skipped
PCM frames. The fallback and private packet API are both removed from production;
there is no demonstrated live pipeline improvement.

The archived patch includes that historical fallback, so its command-line packet
mode also falls back to socket/window one on Classic. Only the fake packet channel
in the offline fixture exercises the pipeline. Further live work requires a
supported transport that preserves packet boundaries, followed by an HCI capture
and controlled comparisons. See [the investigation](../../NATIVE_MACOS.md#sender-timing-and-bounded-packet-submission)
for timing tools, live findings, and measurement limits.
