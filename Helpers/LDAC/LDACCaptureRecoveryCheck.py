import subprocess
import tempfile
from pathlib import Path

source = Path(__file__).with_name("SystemAudioTapProbe.m").read_text()
state = source[
    source.index("typedef struct {") : source.index("static void Interrupt(")
]
recovery = source[
    source.index("typedef struct {\n    uint64_t overloads;") : source.index(
        "static BOOL CaptureSourceIsRunning("
    )
]
status = source[
    source.index(
        "static BOOL Status(OSStatus status, const char *operation) {"
    ) : source.index("static BOOL ReadFormat(")
]
listener = source[
    source.index("static OSStatus CaptureOverloaded(") : source.index(
        "static BOOL StreamAudio("
    )
]
inventory = source[
    source.index(
        "static BOOL CaptureSourceIsRunning(AudioDeviceID device, NSArray<NSString *> *selected) {"
    ) : source.index("static int CheckApplicationRouting(")
]
ring = source[
    source.index("static BOOL RingWrite(") : source.index("static int CheckStreamRing(")
]
converter = source[
    source.index("static OSStatus ConverterInput(") : source.index(
        "static BOOL CreateConverter("
    )
]
stream = source[
    source.index("static BOOL StreamAudio(") : source.index(
        "static OSStatus ReadAudio("
    )
]
callback = source[
    source.index("static OSStatus ReadAudio(") : source.index(
        "#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY\nstatic BOOL SaveCapture("
    )
]
fixture = (
    r"""#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include <math.h>
#include <errno.h>
#include <poll.h>
#define ACOUPLET_AUDIO_HELPER_STREAM_ONLY 1
static volatile sig_atomic_t interrupted;
static _Atomic(const char *) permissionDeniedOperation;
static unsigned stops, starts;
static OSStatus stopResult, startResult;
static BOOL cancelOnStop;
static BOOL streamingScenario, stalled, releaseStall;
static double clockNow, restartedAt;
static OSStatus MockStop(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 23 && io == (AudioDeviceIOProcID)1);
    stops++;
    if (cancelOnStop) interrupted = SIGTERM;
    return stopResult;
}
static OSStatus MockStart(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 23 && io == (AudioDeviceIOProcID)1 && stops == starts + 1);
    starts++;
    if (streamingScenario && !startResult) {
        restartedAt = clockNow;
        if (releaseStall) stalled = NO;
    }
    return startResult;
}
#define AudioDeviceStop MockStop
#define AudioDeviceStart MockStart
"""
    + state
    + status
    + recovery
    + listener
    + r"""
static BOOL inventoryFailure, malformed, running = YES, selectedFailure, ownProcess;
static AudioDeviceID outputDevice = 23;
static OSStatus MockSize(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    assert(object == kAudioObjectSystemObject && address->mSelector == kAudioHardwarePropertyProcessObjectList);
    *size = malformed ? 1 : sizeof(AudioObjectID);
    return inventoryFailure ? kAudioHardwareBadObjectError : noErr;
}
static OSStatus MockData(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    if (address->mSelector == kAudioHardwarePropertyProcessObjectList) {
        assert(object == kAudioObjectSystemObject);
        *(AudioObjectID *)data = 42;
    } else {
        assert(object == 42);
        switch (address->mSelector) {
            case kAudioProcessPropertyIsRunningOutput: *(UInt32 *)data = running; break;
            case kAudioProcessPropertyPID: *(pid_t *)data = ownProcess ? getpid() : getpid() + 1; break;
            case kAudioProcessPropertyDevices:
                assert(address->mScope == kAudioObjectPropertyScopeOutput);
                *(AudioDeviceID *)data = outputDevice;
                *size = sizeof(AudioDeviceID);
                break;
            default: abort();
        }
    }
    return noErr;
}
static NSArray<NSNumber *> *SelectedAudioProcesses(NSArray<NSString *> *selected) {
    return selectedFailure ? nil : ([selected containsObject:@"included"] ? @[@42] : @[]);
}
#define AudioObjectGetPropertyDataSize MockSize
#define AudioObjectGetPropertyData MockData
"""
    + inventory
    + ring
    + converter
    + callback
    + r"""
static Capture *streamCapture;
static BOOL injectOverload, injected, pauseSource;
static uint64_t writtenFrames, nonzeroAfterRestart;
static double lastAudibleWrite;
static double MonotonicTime(void) { return clockNow; }
static ssize_t StreamWrite(int fd, const void *bytes, size_t size) {
    assert(fd == 61 && size % 8 == 0);
    const float *samples = bytes;
    for (size_t frame = 0; frame < size / 8; frame++) {
        if (samples[frame * 2] != 0 || samples[frame * 2 + 1] != 0) {
            lastAudibleWrite = clockNow;
            if (starts) nonzeroAfterRestart++;
        }
    }
    writtenFrames += size / 8;
    return size;
}
@interface StreamClock : NSObject
+ (void)sleepForTimeInterval:(NSTimeInterval)interval;
@end
@implementation StreamClock
+ (void)sleepForTimeInterval:(NSTimeInterval)interval {
    assert(interval == 0.001 && streamCapture);
    clockNow += 512.0 / streamCapture->format.mSampleRate;
    if (!injected && clockNow >= 0.2) {
        injected = YES;
        stalled = YES;
        if (pauseSource) running = NO;
        if (injectOverload) {
            AudioObjectPropertyAddress address = {.mSelector = kAudioDeviceProcessorOverload};
            assert(CaptureOverloaded(23, 1, &address, streamCapture) == noErr);
        }
    }
    float samples[1024];
    for (UInt32 index = 0; index < 1024; index++) samples[index] = stalled ? 0 : (index % 2 ? -0.25 : 0.25);
    AudioBufferList input = {1, {{2, sizeof(samples), samples}}};
    assert(ReadAudio(23, NULL, &input, NULL, NULL, NULL, streamCapture) == noErr);
}
@end
#define NSThread StreamClock
#define write StreamWrite
"""
    + stream
    + r"""
#undef write
#undef NSThread
static void RunStream(BOOL overload, BOOL paused, BOOL recovers, AudioDeviceID route,
                       NSArray<NSString *> *selected, unsigned expectedStarts) {
    stops = starts = 0;
    stopResult = startResult = noErr;
    interrupted = 0;
    cancelOnStop = inventoryFailure = malformed = selectedFailure = ownProcess = NO;
    running = YES;
    outputDevice = route;
    streamingScenario = YES;
    clockNow = restartedAt = lastAudibleWrite = 0;
    injectOverload = overload;
    pauseSource = paused;
    releaseStall = recovers;
    injected = stalled = NO;
    writtenFrames = nonzeroAfterRestart = 0;
    Capture capture = {.capacity = 2048, .streaming = YES};
    capture.format = (AudioStreamBasicDescription){96000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    capture.pcm = calloc(capture.capacity * 2, sizeof(float));
    assert(capture.pcm);
    streamCapture = &capture;
    assert(StreamAudio(&capture, 61, 8, getppid(), 23, (AudioDeviceIOProcID)1, 23, selected));
    assert(!atomic_load(&capture.failed) && starts == expectedStarts && stops == expectedStarts);
    assert(writtenFrames == capture.frames && capture.frames > 700000 && capture.nonzeroFrames > 0);
    if (expectedStarts) assert(restartedAt >= 2.19 && restartedAt < 2.22);
    if (expectedStarts && recovers) assert(nonzeroAfterRestart > 500000 && lastAudibleWrite > 7.9);
    else assert(!nonzeroAfterRestart && lastAudibleWrite < 0.21);
    printf("STREAM_RECOVERY_CASE overload=%d paused=%d recovers=%d route=%u selected=%d restarts=%u recoveredFrames=%llu passed\n",
        overload, paused, recovers, route, selected != nil, starts, (unsigned long long)nonzeroAfterRestart);
    free(capture.pcm);
    streamCapture = NULL;
    streamingScenario = NO;
}
static void RunStreamingChecks(void) {
    RunStream(YES, NO, YES, 23, nil, 1);
    RunStream(NO, NO, YES, 23, nil, 0);
    RunStream(YES, YES, YES, 23, nil, 0);
    RunStream(YES, NO, YES, 24, nil, 0);
    RunStream(YES, NO, YES, 23, @[@"excluded"], 0);
    RunStream(YES, NO, YES, 23, @[@"included"], 1);
    RunStream(YES, NO, NO, 23, nil, 1);
}
"""
    + r"""
static void Reset(void) {
    stops = starts = 0;
    stopResult = startResult = noErr;
    interrupted = 0;
    cancelOnStop = NO;
}
int main(void) {
    CaptureRecovery recovery = {0};
    assert(!CaptureRecoveryDue(&recovery, 1, 0, 100));
    assert(!CaptureRecoveryDue(&recovery, 10, 0, 100));
    assert(!CaptureRecoveryDue(&recovery, 11, 1, 200));
    assert(!CaptureRecoveryDue(&recovery, 12.99, 1, 200));
    assert(CaptureRecoveryDue(&recovery, 13, 1, 200));
    Capture capture = {0};
    atomic_store(&capture.produced, 800);
    atomic_store(&capture.consumed, 600);
    assert(RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 13));
    assert(stops == 1 && starts == 1 && recovery.recoveryAttempts == 1);
    assert(atomic_load(&capture.produced) == 800 && atomic_load(&capture.consumed) == 600);
    assert(!CaptureRecoveryDue(&recovery, 14, 1, 200));
    assert(!CaptureRecoveryDue(&recovery, 15, 2, 200));
    assert(!CaptureRecoveryDue(&recovery, 23, 2, 200));
    assert(CaptureRecoveryDue(&recovery, 24, 3, 200));
    assert(!CaptureRecoveryDue(&recovery, 25, 3, 300));
    assert(!CaptureRecoveryDue(&recovery, 26, 3, 400));
    assert(!CaptureRecoveryDue(&recovery, 29, 3, 400));
    recovery = (CaptureRecovery){0};
    assert(!CaptureRecoveryDue(&recovery, 1, 1, 0));
    assert(!CaptureRecoveryDue(&recovery, 5, 1, 0));
    assert(!CaptureRecoveryDue(&recovery, 6, 1, 100));
    assert(!CaptureRecoveryDue(&recovery, 10, 1, 100));
    assert(CaptureRecoveryDue(&recovery, 11, 2, 100));
    double expiry = recovery.pendingUntil;
    assert(CaptureRecoveryDue(&recovery, 12, 3, 100) && recovery.pendingUntil == expiry);
    assert(!CaptureRecoveryDue(&recovery, expiry, 3, 100));
    Reset(); interrupted = SIGTERM;
    assert(!RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 20) && !stops && !starts);
    Reset(); atomic_store(&capture.failed, 4);
    assert(!RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 20) && !stops && !starts);
    atomic_store(&capture.failed, 0);
    Reset(); cancelOnStop = YES;
    assert(!RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 20) && stops == 1 && !starts);
    Reset(); stopResult = kAudioHardwareBadObjectError;
    assert(!RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 20) && stops == 1 && !starts);
    assert(atomic_load(&capture.failed) == 8);
    Reset(); atomic_store(&capture.failed, 0); startResult = kAudioHardwareBadObjectError;
    assert(!RestartCapture(&capture, &recovery, 23, (AudioDeviceIOProcID)1, 20) && starts == 1);
    assert(atomic_load(&capture.failed) == 8);
    AudioObjectPropertyAddress changes[] = {{.mSelector = kAudioDevicePropertyDeviceIsRunning},
        {.mSelector = kAudioDeviceProcessorOverload}, {.mSelector = kAudioDeviceProcessorOverload}};
    assert(CaptureOverloaded(23, 1, changes, &capture) == noErr && atomic_load(&capture.overloads) == 0);
    assert(CaptureOverloaded(23, 3, changes, &capture) == noErr && atomic_load(&capture.overloads) == 1);
    assert(CaptureSourceIsRunning(23, nil));
    assert(!CaptureSourceIsRunning(kAudioObjectUnknown, nil));
    assert(CaptureSourceIsRunning(23, @[@"included"]));
    assert(!CaptureSourceIsRunning(23, @[@"excluded"]));
    selectedFailure = YES; assert(!CaptureSourceIsRunning(23, @[@"included"])); selectedFailure = NO;
    running = NO; assert(!CaptureSourceIsRunning(23, nil)); running = YES;
    ownProcess = YES; assert(!CaptureSourceIsRunning(23, nil)); ownProcess = NO;
    outputDevice = 24; assert(!CaptureSourceIsRunning(23, nil)); outputDevice = 23;
    inventoryFailure = YES; assert(!CaptureSourceIsRunning(23, nil)); inventoryFailure = NO;
    malformed = YES; assert(!CaptureSourceIsRunning(23, nil));
    RunStreamingChecks();
    puts("Capture recovery passed: overload-gated silence, positive audio, startup, expiry, cooldown, cancellation, restart failures, ring preservation, source routing and inventory failures.");
}
"""
)
with tempfile.TemporaryDirectory(prefix="acouplet-capture-recovery-") as directory:
    directory = Path(directory)
    path = directory / "Check.m"
    binary = directory / "check"
    path.write_text(fixture)
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-isysroot",
            subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
            "-fobjc-arc",
            "-framework",
            "Foundation",
            "-framework",
            "CoreAudio",
            "-framework",
            "AudioToolbox",
            str(path),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True)
