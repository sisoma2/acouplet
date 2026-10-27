import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "Helpers/LDAC/DirectAVDTPLiveMediaProbe.m").read_text()
start = source.index("static uint32_t MachTicks(")
end = source.index("static kern_return_t ApplySenderRealtime(", start)
timing = source[start:end]
streaming = source[
    source.index("static BOOL FeedLive(") : source.index("LiveQueueFree(&sendQueue)")
]
assert "RunLoopFor(" not in streaming
assert streaming.count("WaitForSenderService(") == 5
fixture = (
    r"""
#import <Foundation/Foundation.h>
#include <assert.h>
#include <mach/mach_time.h>

static uint64_t now, sourceWork, lastDeadline;
static unsigned int interruptions, waits, pumps;

static uint64_t TestTime(void) { return now; }
static kern_return_t TestTimebase(mach_timebase_info_t timebase) {
    timebase->numer = 125;
    timebase->denom = 3;
    return KERN_SUCCESS;
}
static SInt32 TestRunLoop(CFRunLoopMode mode, CFTimeInterval seconds, Boolean once) {
    if (!CFEqual(mode, kCFRunLoopDefaultMode) || seconds != 0 || !once) {
        fputs("Sender used a coalesced timer\n", stderr);
        exit(1);
    }
    now += sourceWork;
    pumps++;
    return kCFRunLoopRunHandledSource;
}
static kern_return_t TestWait(uint64_t deadline) {
    assert(deadline > now);
    if (waits) assert(deadline == lastDeadline);
    lastDeadline = deadline;
    waits++;
    if (interruptions) {
        interruptions--;
        now += 1;
        return KERN_ABORTED;
    }
    now = deadline;
    return KERN_SUCCESS;
}
#define mach_absolute_time TestTime
#define mach_timebase_info TestTimebase
#define CFRunLoopRunInMode TestRunLoop
#define mach_wait_until TestWait
"""
    + timing
    + r"""
#undef mach_absolute_time
#undef mach_timebase_info
#undef CFRunLoopRunInMode
#undef mach_wait_until

int main(void) {
    now = 100000;
    WaitForSenderService(0);
    WaitForSenderService(-1);
    assert(now == 100000 && !waits && !pumps);
    WaitForSenderService(0.001);
    assert(now == 124000 && waits == 1 && pumps == 1);
    waits = 0;
    interruptions = 3;
    sourceWork = 100;
    uint64_t started = now;
    WaitForSenderService(0.001);
    assert(now == started + 24000 && waits == 4 && pumps == 2 && !interruptions);
    waits = 0;
    sourceWork = 48000;
    started = now;
    WaitForSenderService(0.001);
    assert(now == started + sourceWork && !waits && pumps == 3);
    sourceWork = 0;
    for (int sampleRate = 48000; sampleRate <= 96000; sampleRate += 48000) {
        now = 0;
        for (int packet = 0; packet < 1875; packet++) {
            uint64_t due = (uint64_t)llround((double)(packet + 1) * 256 * (sampleRate / 48000) / sampleRate * 24000000);
            while (now < due) {
                waits = 0;
                WaitForSenderService(fmin(0.001, (double)(due - now) / 24000000));
            }
            assert(now - due <= 1);
        }
        assert(now == 240000000);
    }
    puts("PASS sender wake deadlines: nonblocking callback pump, no calendar timer, interrupted waits retain their deadline, overdue sources do not add a second wait, and 48/96 kHz Quality pacing does not accumulate drift");
}
"""
)

with tempfile.TemporaryDirectory(prefix="acouplet-sender-timing-") as directory:
    path = pathlib.Path(directory)
    check = path / "Timing.m"
    binary = path / "timing"
    check.write_text(fixture)
    subprocess.run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-fobjc-arc",
            "-framework",
            "Foundation",
            str(check),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True, timeout=10)
    old_timer = fixture.replace(
        "CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);",
        "CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);",
    )
    assert old_timer != fixture
    check.write_text(old_timer)
    subprocess.run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-fobjc-arc",
            "-framework",
            "Foundation",
            str(check),
            "-o",
            str(binary),
        ],
        check=True,
    )
    result = subprocess.run(
        [str(binary)], check=False, capture_output=True, text=True, timeout=10
    )
    assert result.returncode == 1 and "Sender used a coalesced timer" in result.stderr
    print("PASS negative control: restoring a timed run-loop wait is rejected")
