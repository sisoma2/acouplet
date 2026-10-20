import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
helper = root / "Helpers/LDAC/DirectAVDTPLiveMediaProbe.m"
fixture = r"""
#define main ProductionMain
#include "__HELPER__"
#undef main

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

@interface SocketChannel : NSObject
@property int socketFD;
@property UInt16 outgoingMTU;
@property UInt16 cid;
@end
@implementation SocketChannel
@end

static void Check(uint32_t rate, NSString *quality) {
    @autoreleasepool {
        int sockets[2], pcm[2], control[2];
        Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "Could not create socket pair");
        Require(pipe(pcm) == 0 && pipe(control) == 0, "Could not create PCM/control pipes");
        Require(fcntl(pcm[0], F_SETFL, O_NONBLOCK) == 0, "Could not make PCM nonblocking");
        int originalInput = dup(STDIN_FILENO);
        Require(originalInput >= 0 && dup2(control[0], STDIN_FILENO) >= 0, "Could not set fixture control input");
        close(control[0]);
        DirectMediaProbe *probe = [DirectMediaProbe new];
        LDACProfile profile;
        Require(SelectProfile(rate, quality, &profile), "Invalid fixture profile");
        probe.profile = profile;
        if ([quality isEqualToString:@"high"]) {
            probe.traceSeconds = 3;
            probe.traceOutput = tmpfile();
            Require(probe.traceOutput != NULL, "Could not allocate packet trace");
        }
        probe.pcmFD = pcm[0];
        probe.pcmRing = calloc(1, profile.capacityBytes);
        Require(probe.pcmRing != NULL, "Could not allocate PCM ring");
        probe.pcmBytes = profile.prefillBytes;
        probe.pcmReady = YES;
        probe.pcmActive = YES;
        probe.controlPending = [NSMutableData data];
        probe.encoderMTU = 895;
        probe.encoder = ldacBT_get_handle();
        Require(probe.encoder && ldacBT_init_handle_encode(probe.encoder, 895, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, rate) == 0, "Could not initialize codec");
        SocketChannel *channel = [SocketChannel new];
        channel.socketFD = sockets[0];
        channel.outgoingMTU = 895;
        channel.cid = 1;
        probe.channel = (CBL2CAPChannel *)channel;
        dispatch_group_t group = dispatch_group_create();
        int receiver = sockets[1], pcmWriter = pcm[1], controlWriter = control[1];
        __block NSUInteger received = 0;
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            uint64_t expectedTimestamp = 0;
            while (YES) {
                struct pollfd input = {receiver, POLLIN, 0};
                Require(poll(&input, 1, 2000) == 1, "Timed out waiting for encoded packet");
                if (received == 12) usleep(60000);
                uint8_t bytes[895];
                ssize_t length = read(receiver, bytes, sizeof(bytes));
                if (!length) break;
                Require(length >= 13, "Truncated RTP packet");
                Require(bytes[0] == 0x80 && bytes[1] == 0x60, "RTP header was merged or corrupted");
                uint16_t sequence = (uint16_t)bytes[2] << 8 | bytes[3];
                Require(sequence == (uint16_t)received, "Queued RTP sequence was duplicated or skipped");
                uint32_t timestamp = (uint32_t)bytes[4] << 24 | (uint32_t)bytes[5] << 16 |
                    (uint32_t)bytes[6] << 8 | bytes[7];
                Require(timestamp == (uint32_t)expectedTimestamp, "Queued RTP timestamp was duplicated or skipped");
                Require(FrameHeadersMatch(bytes + 13, length - 13, bytes[12], profile, NULL), "Encoded frames were split or merged");
                expectedTimestamp += bytes[12] * profile.frameSamples;
                received++;
            }
        });
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            float block[256] = {0};
            uint64_t started = mach_absolute_time();
            for (NSUInteger frame = 0; frame < rate * 1.2; frame += 128) {
                Require(write(pcmWriter, block, sizeof(block)) == sizeof(block), "PCM write failed");
                mach_wait_until(started + MachTicks((double)(frame + 128) / rate));
            }
            Require(write(controlWriter, "stop\n", 5) == 5, "Stop command failed");
        });
        BOOL succeeded = FeedLive(probe, (CBL2CAPChannel *)channel, 0, 0);
        if (probe.traceOutput) {
            rewind(probe.traceOutput);
            char line[1024];
            BOOL anchor = NO, footer = NO, enqueue = NO, submit = NO, returned = NO, drain = NO;
            while (fgets(line, sizeof(line), probe.traceOutput)) {
                anchor |= strstr(line, "PACKET_TRACE_BEGIN") != NULL;
                footer |= strstr(line, "PACKET_TRACE_END") != NULL;
                enqueue |= strstr(line, "event=enqueue") != NULL;
                submit |= strstr(line, "event=submit") != NULL;
                returned |= strstr(line, "event=return") != NULL;
                drain |= strstr(line, "event=socket-drain") != NULL;
            }
            Require(anchor && footer && enqueue && submit && returned && drain, "Packet timing trace was incomplete");
        }
        shutdown(sockets[0], SHUT_WR);
        Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0, "Fixture workers did not finish");
        Require(succeeded && !probe.failed && !probe.pcmSkippedBytes, "Sender did not recover the simulated link stall without skipping PCM");
        Require(received > 30, "Too few packets were verified");
        Require(dup2(originalInput, STDIN_FILENO) >= 0, "Could not restore control input");
        close(originalInput);
        close(sockets[0]); close(sockets[1]); close(pcm[1]); close(control[1]);
        printf("PASS queued media rate=%u quality=%s packets=%lu: 60ms delayed receiver, unique RTP sequences, contiguous timestamps, intact codec packets, no skipped PCM, orderly stop\n",
            rate, quality.UTF8String, received);
    }
}

int main(void) {
    for (NSUInteger rate = 48000; rate <= 96000; rate += 48000)
        for (NSString *quality in @[@"low", @"mid", @"high", @"auto"]) Check((uint32_t)rate, quality);
    return 0;
}
"""

with tempfile.TemporaryDirectory(prefix="acouplet-media-queue-") as directory:
    path = pathlib.Path(directory)
    check = path / "Queue.m"
    binary = path / "queue"
    command = [
        "xcrun",
        "--sdk",
        "macosx",
        "clang",
        "-O2",
        "-fobjc-arc",
        "-fblocks",
        "-D_DARWIN_C_SOURCE",
        "-DACOUPLET_LDAC_PROBE_ONLY=0",
        "-framework",
        "Foundation",
        "-framework",
        "CoreBluetooth",
        "-framework",
        "IOBluetooth",
        "-I",
        str(root / "Vendor/libldac/inc"),
        "-I",
        str(root / "Vendor/libldac/src"),
        "-I",
        str(helper.parent),
        str(check),
        str(root / "Vendor/libldac/src/ldacBT.c"),
        str(root / "Vendor/libldac/src/ldaclib.c"),
        "-o",
        str(binary),
    ]
    check.write_text(fixture.replace("__HELPER__", str(helper)))
    subprocess.run(command, check=True)
    result = subprocess.run(
        [str(binary)], check=False, capture_output=True, text=True, timeout=20
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr
    print(
        "\n".join(
            line for line in result.stdout.splitlines() if line.startswith("PASS ")
        )
    )
    original = helper.read_text()
    regression = original.replace(
        "flushing ? NULL : pcm, sendQueue.tail, timestamp,",
        "flushing ? NULL : pcm, sentPackets, timestamp,",
    )
    assert regression != original
    prior = path / "Prior.m"
    prior.write_text(regression)
    check.write_text(fixture.replace("__HELPER__", str(prior)))
    subprocess.run(command, check=True)
    result = subprocess.run(
        [str(binary)], check=False, capture_output=True, text=True, timeout=10
    )
    assert (
        result.returncode == 1
        and "Queued RTP sequence was duplicated or skipped" in result.stderr
    ), result.stdout[-4000:] + result.stderr
    print(
        "PASS negative control: original transmitted-count RTP sequence duplicates are reproduced"
    )
