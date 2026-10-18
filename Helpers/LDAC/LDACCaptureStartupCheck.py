import subprocess
import tempfile
from pathlib import Path

source = Path(__file__).with_name("SystemAudioTapProbe.m").read_text()
read_format = source[source.index("static BOOL ReadFormat("):source.index("static BOOL RingWrite(")]
status = source[source.index("static BOOL Status("):source.index("static BOOL ReadFormat(")]
fixture = r'''#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
static volatile sig_atomic_t interrupted;
static _Atomic(const char *) permissionDeniedOperation;
static double now;
static unsigned calls, unavailable;
static OSStatus result;
static BOOL wrongSize, interruptOnWait;
static double MonotonicTime(void) { return now; }
static OSStatus CaptureFormatProperty(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(object == 23 && address->mSelector == kAudioDevicePropertyStreamFormat);
    assert(address->mScope == kAudioObjectPropertyScopeInput && *size == sizeof(AudioStreamBasicDescription));
    ++calls;
    if (calls <= unavailable) { *size = 0; return kAudioHardwareUnknownPropertyError; }
    if (result) return result;
    *(AudioStreamBasicDescription *)data = (AudioStreamBasicDescription){.mSampleRate = 96000, .mChannelsPerFrame = 2};
    if (wrongSize) *size = 0;
    return noErr;
}
@interface CaptureClock : NSObject
+ (void)sleepForTimeInterval:(NSTimeInterval)interval;
@end
@implementation CaptureClock
+ (void)sleepForTimeInterval:(NSTimeInterval)interval {
    assert(interval > 0 && calls < 10);
    now += interval;
    if (interruptOnWait) interrupted = SIGTERM;
}
@end
#define NSThread CaptureClock
#define AudioObjectGetPropertyData CaptureFormatProperty
''' + status + read_format + r'''
static BOOL Read(double deadline) {
    AudioStreamBasicDescription format = {0};
    BOOL ok = ReadFormat(23, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, deadline, &format);
    if (ok) assert(format.mSampleRate == 96000 && format.mChannelsPerFrame == 2);
    return ok;
}
static void Reset(void) {
    calls = unavailable = 0;
    now = 1;
    result = noErr;
    interrupted = 0;
    wrongSize = interruptOnWait = NO;
    atomic_store(&permissionDeniedOperation, NULL);
}
int main(void) {
    Reset(); assert(Read(2) && calls == 1);
    Reset(); unavailable = 2; assert(Read(2) && calls == 3);
    Reset(); unavailable = 100; assert(!Read(1.025) && calls == 3 && now < 1.04);
    Reset(); unavailable = 100; assert(!Read(0) && calls == 1);
    Reset(); unavailable = 100; assert(!Read(0.5) && calls == 1);
    Reset(); unavailable = 100; interruptOnWait = YES; assert(!Read(2) && calls == 1 && interrupted == SIGTERM);
    Reset(); result = kAudioDevicePermissionsError; assert(!Read(2) && calls == 1 && atomic_load(&permissionDeniedOperation));
    Reset(); result = kAudioHardwareBadObjectError; assert(!Read(2) && calls == 1 && !atomic_load(&permissionDeniedOperation));
    Reset(); wrongSize = YES; assert(!Read(2) && calls == 1);
    puts("Capture startup: 9 checks passed; delayed stream, deadline, cancellation, permission and invalid format.");
}
'''
with tempfile.TemporaryDirectory(prefix="acouplet-capture-startup-") as directory:
    directory = Path(directory)
    path = directory / "Check.m"
    binary = directory / "check"
    path.write_text(fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreAudio", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
