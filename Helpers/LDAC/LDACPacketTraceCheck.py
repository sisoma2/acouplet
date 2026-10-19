import pathlib
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parents[2]
helper = root / 'Helpers/LDAC/DirectAVDTPLiveMediaProbe.m'
fixture = r'''
#include "LDACPacketTrace.h"

static void Require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "%s\n", message); exit(1); }
}

int main(void) {
    LDACPacketTrace trace;
    uint8_t bytes[13] = {0x80, 0x60, 0xff, 0xff, 0xff, 0xff, 0xfe, 0};
    Require(LDACPacketTraceInit(&trace, 0, 10, 20) && !trace.records, "Disabled tracing allocated storage");
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, sizeof(bytes), 10.1, 0);
    Require(!trace.count, "Disabled tracing recorded a packet");
    Require(LDACPacketTraceInit(&trace, 1, 10, 20), "Trace allocation failed");
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, sizeof(bytes), 11.1, 0);
    Require(!trace.count, "Trace exceeded time limit");
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, 12, 10.5, 0);
    Require(!trace.count, "Truncated packet was recorded");
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 42, bytes, sizeof(bytes), 10.5, 0);
    Require(trace.count == 1 && trace.records[0].sequence == 65535 && trace.records[0].rtp == 0xfffffe00 &&
        trace.records[0].fingerprint == LDACPacketFingerprint(bytes, sizeof(bytes)), "Packet identity changed");
    trace.count = LDACTraceCapacity;
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, sizeof(bytes), 10.5, 0);
    Require(trace.dropped == 1 && trace.count == LDACTraceCapacity, "Trace exceeded memory bound");
    trace.count = 1;
    FILE *output = tmpfile();
    Require(output != NULL, "Trace output allocation failed");
    LDACPacketTraceFinish(&trace, output);
    Require(!trace.records, "Trace storage was retained after finish");
    rewind(output);
    char line[1024];
    BOOL anchor = NO, packet = NO, footer = NO;
    while (fgets(line, sizeof(line), output)) {
        anchor |= strstr(line, "PACKET_TRACE_BEGIN monotonic=10.000000000 wall=20.000000000") != NULL;
        packet |= strstr(line, "event=submit packet=42 sequence=65535 rtp=4294966784") != NULL;
        footer |= strstr(line, "PACKET_TRACE_END records=1 dropped=1") != NULL;
    }
    Require(anchor && packet && footer, "Trace output lost identity, clock anchor or dropped records");
    fclose(output);
    puts("PASS tracing defaults off; packet identity, time/memory bounds, clock anchor and output verified");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='acouplet-packet-trace-') as directory:
    path = pathlib.Path(directory)
    check, binary = path / 'Trace.m', path / 'trace'
    check.write_text(fixture)
    command = ['xcrun', '--sdk', 'macosx', 'clang', '-O2', '-fobjc-arc', '-fblocks', '-D_DARWIN_C_SOURCE',
               '-DACOUPLET_LDAC_PROBE_ONLY=0', '-framework', 'Foundation', '-framework', 'CoreBluetooth',
               '-framework', 'IOBluetooth', '-I', str(helper.parent), '-I', str(root / 'Vendor/libldac/inc'),
               '-I', str(root / 'Vendor/libldac/src'), str(check), str(root / 'Vendor/libldac/src/ldacBT.c'),
               str(root / 'Vendor/libldac/src/ldaclib.c'), '-o', str(binary)]
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True, timeout=5)
    production = path / 'media'
    command[command.index(str(check))] = str(helper)
    command[-1] = str(production)
    subprocess.run(command, check=True)
    for arguments in [
        ['--sender', 'socket'], ['--sender', 'packet'], ['--packet-window', '1'], ['--packet-window', '4'],
        ['--trace-seconds', '61'], ['--trace-seconds', '-1'], ['--trace-seconds', '1.5'],
        ['--trace-seconds', '1', '--trace-seconds', '2'], ['--trace-file', '/tmp/unused-trace-file'],
        ['--trace-seconds', '0', '--trace-file', '/tmp/unused-trace-file'],
    ]:
        invalid = subprocess.run([str(production), '--media', '--pcm-fd', '3', '--address', '02-00-00-00-00-01', *arguments],
                                 capture_output=True, text=True, timeout=5)
        assert invalid.returncode == 2 and 'BEFORE' not in invalid.stdout, invalid.stdout + invalid.stderr
    assert b'sendData:withCompletion:' not in production.read_bytes()
    print('PASS production excludes packet API and rejects retired sender options and invalid trace settings before device access')
