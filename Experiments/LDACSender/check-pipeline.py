import pathlib
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parents[2]
helper = root / 'Helpers/LDAC/DirectAVDTPLiveMediaProbe.m'
fixture = r'''
#define main ProductionMain
#include "__HELPER__"
#undef main

static void Require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "%s\n", message); exit(1); }
}

@interface PacketChannel : NSObject
@property int socketFD;
@property UInt16 outgoingMTU;
@property UInt16 cid;
@property LDACProfile profile;
@property NSUInteger count, active, peak;
@property BOOL reject;
@property(strong) NSLock *lock;
@property(strong) dispatch_group_t callbacks;
@end
@implementation PacketChannel
- (void)sendData:(NSData *)data withCompletion:(void (^)(NSError *))completion {
    [self.lock lock];
    const uint8_t *bytes = data.bytes;
    Require(data.length <= self.outgoingMTU && data.length >= 13, "Packet exceeded MTU");
    Require(bytes[0] == 0x80 && bytes[1] == 0x60, "Missing RTP header");
    Require(((uint16_t)bytes[2] << 8 | bytes[3]) == (uint16_t)self.count, "Packet order changed");
    Require(FrameHeadersMatch(bytes + 13, data.length - 13, bytes[12], self.profile, NULL), "Merged or split codec packet");
    uint64_t hash = LDACPacketFingerprint(bytes, data.length);
    NSUInteger index = self.count++;
    self.active++;
    self.peak = MAX(self.peak, self.active);
    dispatch_group_enter(self.callbacks);
    [self.lock unlock];
    double delay = index == 12 ? .060 : .007;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            Require(hash == LDACPacketFingerprint(data.bytes, data.length), "Packet bytes changed while pending");
            [self.lock lock];
            self.active--;
            [self.lock unlock];
            completion(self.reject ? [NSError errorWithDomain:@"Fixture" code:42 userInfo:nil] : nil);
            dispatch_group_leave(self.callbacks);
        });
}
@end

static void CheckWindow(uint32_t rate, NSUInteger window, BOOL reject) {
    @autoreleasepool {
        int sockets[2], pcm[2], control[2];
        Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "Socket pair failed");
        Require(pipe(pcm) == 0 && pipe(control) == 0, "Pipes failed");
        Require(fcntl(pcm[0], F_SETFL, O_NONBLOCK) == 0, "PCM flags failed");
        int originalInput = dup(STDIN_FILENO);
        Require(dup2(control[0], STDIN_FILENO) >= 0, "Control input failed");
        close(control[0]);
        DirectMediaProbe *probe = [DirectMediaProbe new];
        LDACProfile profile;
        Require(SelectProfile(rate, @"high", &profile), "Profile failed");
        probe.profile = profile;
        probe.packetSender = YES;
        probe.packetWindow = window;
        probe.traceSeconds = 3;
        if (window > 1) {
            probe.traceOutput = tmpfile();
            Require(probe.traceOutput != NULL, "Trace file allocation failed");
        }
        probe.pcmFD = pcm[0];
        probe.pcmRing = calloc(1, profile.capacityBytes);
        probe.pcmBytes = profile.prefillBytes;
        probe.pcmReady = YES;
        probe.pcmActive = YES;
        probe.controlPending = [NSMutableData data];
        probe.encoderMTU = 895;
        probe.encoder = ldacBT_get_handle();
        Require(probe.encoder && ldacBT_init_handle_encode(probe.encoder, 895, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, rate) == 0, "Encoder failed");
        PacketChannel *channel = [PacketChannel new];
        channel.socketFD = sockets[0]; channel.outgoingMTU = 895; channel.cid = 1;
        channel.profile = profile; channel.lock = [NSLock new]; channel.reject = reject;
        channel.callbacks = dispatch_group_create();
        probe.channel = (CBL2CAPChannel *)channel;
        dispatch_group_t group = dispatch_group_create();
        int pcmWriter = pcm[1], controlWriter = control[1];
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            float block[256] = {0};
            uint64_t started = mach_absolute_time();
            NSUInteger durationFrames = reject ? rate / 100 : rate * 3;
            for (NSUInteger frame = 0; frame < durationFrames; frame += 128) {
                Require(write(pcmWriter, block, sizeof(block)) == sizeof(block), "PCM write failed");
                mach_wait_until(started + MachTicks((double)(frame + 128) / rate));
            }
            Require(write(controlWriter, "stop\n", 5) == 5, "Stop failed");
        });
        BOOL succeeded = FeedLive(probe, (CBL2CAPChannel *)channel, 0, 0);
        if (probe.traceOutput) {
            Require(ftell(probe.traceOutput) > 0, "Dedicated trace file was empty");
            rewind(probe.traceOutput);
            char line[1024];
            BOOL anchor = NO, footer = NO;
            while (fgets(line, sizeof(line), probe.traceOutput)) {
                anchor |= strstr(line, "PACKET_TRACE_BEGIN") != NULL;
                footer |= strstr(line, "PACKET_TRACE_END") != NULL;
            }
            Require(anchor && footer, "Dedicated trace file was incomplete");
        }
        Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, "Writer stuck");
        Require(dispatch_group_wait(channel.callbacks, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, "Callbacks stuck");
        Require(channel.peak <= window && channel.count > 0 && channel.active == 0, "Window bound or callback lifetime failed");
        if (reject) Require(!succeeded && probe.failed, "API error was ignored");
        else if (window == 1) Require(probe.pcmSkippedBytes > 0, "Slow serialized negative control did not build backlog");
        else Require(succeeded && !probe.failed && !probe.pcmSkippedBytes && channel.peak > 1,
            "Pipeline failed to hide completion latency without losing PCM");
        char byte;
        Require(recv(sockets[1], &byte, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "Packet API also wrote the stream socket");
        Require(dup2(originalInput, STDIN_FILENO) >= 0, "Restore input failed");
        close(originalInput); close(sockets[0]); close(sockets[1]); close(pcm[1]); close(control[1]);
        printf("PASS packet sender rate=%u window=%lu reject=%d packets=%lu peak=%lu skippedFrames=%llu: immutable MTU-bounded packets, ordered RTP, delayed/out-of-order replies, no socket writes\n",
            rate, window, reject, channel.count, channel.peak, probe.pcmSkippedBytes / 8);
    }
}

static void CheckBounds(void) {
    LiveQueue queue;
    Require(LiveQueueInit(&queue, 8192), "Queue allocation failed");
    for (int index = 0; index < 6; index++) {
        LiveQueuePacket *slot = LiveQueueSlot(&queue);
        slot->length = 673; slot->samples = 512;
        LiveQueueCommit(&queue);
    }
    Require(LiveQueueNextToSend(&queue, 8192) != NULL, "Default sender not writable");
    LiveQueueMarkSent(&queue);
    Require(!LiveQueueNextToSend(&queue, 8192), "Default sender lost serialization");
    for (int index = 1; index < 4; index++) {
        Require(LiveQueueNextPacketToSubmit(&queue, 4) != NULL, "Window did not fill");
        LiveQueueMarkSent(&queue);
    }
    Require(!LiveQueueNextPacketToSubmit(&queue, 4), "Window exceeded bound");
    Require(!LiveQueueNextPacketToSubmit(&queue, 0) && !LiveQueueNextPacketToSubmit(&queue, 17), "Invalid window accepted");
    LiveQueueFree(&queue);
    LDACPacketCompletions *completions = [LDACPacketCompletions new];
    Require([completions registerPacket:0] && ![completions registerPacket:16], "Occupied callback slot reused");
    [completions completePacket:0 at:1 status:0];
    LDACPacketCompletion value;
    Require([completions takePacket:0 completion:&value] && value.at == 1, "Callback transfer failed");
    Require([completions registerPacket:16], "Callback slot not reusable");
    [completions completePacket:0 at:2 status:42];
    Require(![completions takePacket:16 completion:&value], "Late callback corrupted reused slot");
    LDACPacketTrace trace;
    Require(LDACPacketTraceInit(&trace, 1, 10, 20), "Trace allocation failed");
    uint8_t bytes[13] = {0x80, 0x60};
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, sizeof(bytes), 11.1, 0);
    Require(!trace.count, "Trace exceeded time limit");
    trace.count = LDACTraceCapacity;
    LDACPacketTraceAppend(&trace, LDACTraceSubmit, 0, bytes, sizeof(bytes), 10.5, 0);
    Require(trace.dropped == 1 && trace.count == LDACTraceCapacity, "Trace exceeded memory bound");
    free(trace.records);
    puts("PASS queue and diagnostic bounds, default serialization, stale callback isolation");
}

int main(void) {
    CheckBounds();
    for (uint32_t rate = 48000; rate <= 96000; rate += 48000) {
        CheckWindow(rate, 1, NO);
        CheckWindow(rate, 4, NO);
    }
    CheckWindow(96000, 4, YES);
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='acouplet-pipeline-check-') as directory:
    path = pathlib.Path(directory)
    check, binary = path / 'Pipeline.m', path / 'pipeline'
    prototype = path / 'Prototype.m'
    subprocess.run(['patch', '--silent', '--output', str(prototype), str(helper),
                    str(pathlib.Path(__file__).with_name('packet-sender.patch'))], check=True)
    check.write_text(fixture.replace('__HELPER__', str(prototype)))
    command = ['xcrun', '--sdk', 'macosx', 'clang', '-O2', '-fobjc-arc', '-fblocks', '-D_DARWIN_C_SOURCE',
               '-DACOUPLET_LDAC_PROBE_ONLY=0', '-framework', 'Foundation', '-framework', 'CoreBluetooth',
               '-framework', 'IOBluetooth', '-I', str(helper.parent), '-I', str(pathlib.Path(__file__).parent), '-I', str(root / 'Vendor/libldac/inc'), '-I', str(root / 'Vendor/libldac/src'),
               str(check), str(root / 'Vendor/libldac/src/ldacBT.c'), str(root / 'Vendor/libldac/src/ldaclib.c'), '-o', str(binary)]
    subprocess.run(command, check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=35)
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr
    print('\n'.join(line for line in result.stdout.splitlines() if line.startswith('PASS ')))
    production = path / 'media'
    command[command.index(str(check))] = str(prototype)
    command[-1] = str(production)
    subprocess.run(command, check=True)
    for arguments in [
        ['--sender', 'socket', '--packet-window', '2'], ['--sender', 'unknown'],
        ['--sender', 'packet', '--packet-window', '0'], ['--sender', 'packet', '--packet-window', '17'],
        ['--trace-seconds', '61'], ['--trace-seconds', '-1'], ['--trace-seconds', '1', '--trace-seconds', '2'],
        ['--trace-file', '/tmp/unused-trace-file'],
    ]:
        invalid = subprocess.run([str(production), '--media', '--pcm-fd', '3', '--address', '02-00-00-00-00-01', *arguments],
                                 capture_output=True, text=True, timeout=5)
        assert invalid.returncode == 2 and 'BEFORE' not in invalid.stdout, invalid.stdout + invalid.stderr
    print('PASS experiment CLI rejects invalid modes, windows, trace duration and duplicate options before device access')
