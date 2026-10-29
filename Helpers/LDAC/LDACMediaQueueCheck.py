import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
helper = root / "Helpers/LDAC/DirectAVDTPLiveMediaProbe.m"
fixture = r"""
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
static int idleControlFD = -1;
static unsigned idleTransitions, resumeTransitions;
static _Atomic unsigned idlePackets;
static unsigned packetsAtIdle;
static double resumeDelay;
static unsigned idleBufferGrowths;
static int IdlePrintf(const char *format, ...);
#define printf IdlePrintf
#define main ProductionMain
#include "__HELPER__"
#undef main
#undef printf

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

static int IdlePrintf(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    char message[4096];
    int length = vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    fputs(message, stdout);
    if (idleControlFD >= 0 && !strncmp(message, "IDLE_READY ", 11)) {
        idleTransitions++;
        usleep(20000);
        packetsAtIdle = atomic_load(&idlePackets);
        Require(write(idleControlFD, "idle-suspended\n", 15) == 15, "Idle confirmation failed");
    } else if (idleControlFD >= 0 && !strncmp(message, "IDLE_AUDIO_READY ", 16)) {
        Require(atomic_load(&idlePackets) == packetsAtIdle, "Media packets were sent while idle");
        int control = idleControlFD;
        unsigned packetCount = packetsAtIdle;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(resumeDelay * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                Require(atomic_load(&idlePackets) == packetCount, "Media was sent before resume acknowledgment");
                Require(write(control, "idle-resumed\n", 13) == 13, "Resume confirmation failed");
            });
    } else if (idleControlFD >= 0 && !strncmp(message, "IDLE_RESUMED ", 13)) {
        resumeTransitions++;
    } else if (!strncmp(message, "IDLE_BUFFER_GROWN ", 18)) {
        idleBufferGrowths++;
    }
    return length;
}

@interface SocketChannel : NSObject
@property int socketFD;
@property UInt16 outgoingMTU;
@property UInt16 cid;
@end
@implementation SocketChannel
@end

static void Check(uint32_t rate, NSString *quality, NSUInteger idle) {
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
        idleControlFD = idle ? controlWriter : -1;
        idleTransitions = resumeTransitions = 0;
        idleBufferGrowths = 0;
        resumeDelay = idle == 3 ? 1.1 : 0;
        atomic_store(&idlePackets, 0);
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
                atomic_fetch_add(&idlePackets, 1);
            }
        });
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            float block[256] = {0};
            uint64_t started = mach_absolute_time();
            for (NSUInteger frame = 0; frame < rate * (idle == 3 ? 2.5 : 1.2); frame += 128) {
                if ((idle == 1 || idle == 3) && frame >= rate * 0.8) {
                    for (NSUInteger index = 0; index < 256; index++) block[index] = 0.25;
                }
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
        Require(received > (idle ? 10 : 30), "Too few packets were verified");
        if (idle) {
            Require(idleTransitions == 1 && resumeTransitions == (idle == 1 || idle == 3), "Unexpected idle transition count");
            Require((atomic_load(&idlePackets) > packetsAtIdle) == (idle == 1 || idle == 3), "Media resume did not follow returning audio");
            if (idle == 3) Require(idleBufferGrowths > 0, "Delayed resume did not exercise buffer growth");
        }
        idleControlFD = -1;
        Require(dup2(originalInput, STDIN_FILENO) >= 0, "Could not restore control input");
        close(originalInput);
        close(sockets[0]); close(sockets[1]); close(pcm[1]); close(control[1]);
        printf("PASS queued media rate=%u quality=%s packets=%lu: 60ms delayed receiver, unique RTP sequences, contiguous timestamps, intact codec packets, no skipped PCM, orderly stop\n",
            rate, quality.UTF8String, received);
    }
}

static void CheckIdleBuffer(void) {
    for (NSNumber *rate in @[@44100, @48000, @88200, @96000]) {
        DirectMediaProbe *probe = [DirectMediaProbe new];
        probe.pcmFD = -1;
        LDACProfile profile;
        Require(SelectProfile(rate.unsignedIntValue, @"low", &profile), "Invalid idle buffer profile");
        probe.profile = profile;
        probe.pcmRing = calloc(1, profile.capacityBytes);
        Require(probe.pcmRing != NULL, "Could not allocate idle buffer");
        probe.pcmReserveBytes = profile.prefillBytes;
        probe.pcmHead = profile.capacityBytes - PCMBlockBytes;
        NSUInteger silentBytes = (profile.prefillBytes / PCMBlockBytes + 6) * PCMBlockBytes;
        probe.pcmBytes = silentBytes + PCMBlockBytes;
        float firstAudio = 1e-30f;
        NSUInteger firstPosition = (probe.pcmHead + silentBytes) % profile.capacityBytes;
        memcpy(probe.pcmRing + firstPosition, &firstAudio, sizeof(firstAudio));
        NSUInteger expectedDiscard = PCMSkipBytes(silentBytes, profile.prefillBytes, UINT64_MAX);
        [probe discardIdleSilence];
        Require(probe.idleHasAudio && !probe.pcmSkippedBytes, "Quiet audio was lost or counted as transport loss");
        Require(probe.pcmDiscardedBytes == expectedDiscard, "Idle pre-roll was not retained");
        Require(probe.pcmBytes == silentBytes + PCMBlockBytes - expectedDiscard, "Idle buffer accounting changed");
        float retained;
        memcpy(&retained, probe.pcmRing + firstPosition, sizeof(retained));
        Require(retained == firstAudio, "First audio sample was overwritten at the ring boundary");
        NSMutableData *expected = [NSMutableData dataWithLength:probe.pcmBytes];
        for (NSUInteger byte = 0; byte < probe.pcmBytes; byte++)
            ((uint8_t *)expected.mutableBytes)[byte] = probe.pcmRing[(probe.pcmHead + byte) % probe.pcmCapacityBytes];
        Require([probe resizePCMBuffer:profile.capacityBytes * 2], "Could not grow wrapped PCM");
        Require(probe.pcmHead == 0 && !memcmp(probe.pcmRing, expected.bytes, expected.length), "Ring growth changed retained audio");
        Require([probe resizePCMBuffer:profile.capacityBytes], "Could not shrink PCM after idle");
        Require(!memcmp(probe.pcmRing, expected.bytes, expected.length), "Ring shrink changed retained audio");
        Require([probe resizePCMBuffer:profile.capacityBytes * 2], "Could not prepare idle backlog");
        memset(probe.pcmRing, 0, probe.pcmCapacityBytes);
        probe.pcmHead = probe.pcmCapacityBytes - PCMBlockBytes;
        probe.pcmBytes = probe.pcmCapacityBytes;
        [probe discardIdleSilence];
        Require(probe.pcmCapacityBytes == profile.capacityBytes && probe.pcmBytes <= profile.prefillBytes + PCMBlockBytes,
            "Idle silence did not release the expanded buffer");
    }
}

int main(int argc, const char *argv[]) {
    if (argc > 1) {
        CheckIdleBuffer();
        Check(48000, @"low", YES);
        Check(96000, @"auto", YES);
        Check(48000, @"mid", 2);
        Check(48000, @"high", 3);
        Check(96000, @"high", 3);
        Check(44100, @"high", 3);
        Check(88200, @"high", 3);
        return 0;
    }
    for (NSUInteger rate = 48000; rate <= 96000; rate += 48000)
        for (NSString *quality in @[@"low", @"mid", @"high", @"auto"]) Check((uint32_t)rate, quality, NO);
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
    idle_source = original.replace(
        "MonotonicTime() - lastAudioAt >= 30", "MonotonicTime() - lastAudioAt >= 0.4"
    )
    assert idle_source != original
    prior.write_text(idle_source)
    subprocess.run(command, check=True)
    result = subprocess.run(
        [str(binary), "idle"],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr
    print(
        "PASS idle playback at 48 and 96 kHz: drained suspension, no idle media, "
        "buffered resume, contiguous RTP, orderly stop"
    )
    prior.write_text(
        idle_source.replace(
            "!available && self.idlePhase && !self.pcmComplete",
            "!available && NO && !self.pcmComplete",
        )
    )
    subprocess.run(command, check=True)
    result = subprocess.run(
        [str(binary), "idle"],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert (
        result.returncode != 0 and "PCM_FAILED reason=ring-overflow" in result.stdout
    ), result.stdout[-6000:] + result.stderr
    print(
        "PASS negative control: delayed resume reproduces the original PCM ring overflow"
    )
