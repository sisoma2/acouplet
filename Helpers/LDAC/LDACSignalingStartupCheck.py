import subprocess
import tempfile
from pathlib import Path

base = Path(__file__).resolve().parents[2]
source = (base / "Helpers/LDAC/DirectAVDTPSustainedPlaybackProbe.m").read_text()
waiting = source[
    source.index("static BOOL AwaitConnection(") : source.index(
        "static BOOL PlaybackSequence("
    )
]
callbacks = source[
    source.index("@interface DirectSignalingCallbacks") : source.index(
        "@interface IOBluetoothDevice (ClassicPeerAccess)"
    )
]
fixture = (
    r"""#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#import <IOKit/IOReturn.h>
#define CBManagerStatePoweredOn 5
@class CBClassicManager;
@interface CBL2CAPChannel : NSObject
@end
@implementation CBL2CAPChannel
@end
@interface CBClassicPeer : NSObject
@property CBClassicManager *manager;
@property(copy) void (^connectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^disconnectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
@end
@implementation CBClassicPeer
@end
@interface CBClassicManager : NSObject
@property NSInteger state;
@property(copy) void (^connectionStatusHandler)(CBClassicPeer *, NSInteger);
@end
@implementation CBClassicManager
@end
@interface IOBluetoothCoreBluetoothCoordinator : NSObject
@property dispatch_queue_t coordinatorQueue;
+ (instancetype)sharedInstance;
@end
@implementation IOBluetoothCoreBluetoothCoordinator
+ (instancetype)sharedInstance {
    static IOBluetoothCoreBluetoothCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator = [self new]; coordinator.coordinatorQueue = dispatch_queue_create("fixture.coordinator", DISPATCH_QUEUE_SERIAL); });
    return coordinator;
}
@end
"""
    + callbacks
    + r"""
@interface DirectPlaybackProbe : NSObject
@property BOOL stopRequested, stdinEnded, failed, connectionDone;
@property IOReturn connectionStatus;
@property NSString *connectionAddress;
@end
@implementation DirectPlaybackProbe
@end
@interface FixtureDevice : NSObject
@property BOOL connected;
@property CBClassicPeer *classicPeer;
@property NSString *addressString;
- (IOReturn)openConnection:(DirectPlaybackProbe *)probe;
@end
#define IOBluetoothDevice FixtureDevice
static FixtureDevice *device;
static DirectPlaybackProbe *registration;
static double elapsed, connectAt, commandAt, stopAt, callbackAt, powerAt;
static unsigned calls, opens;
static NSString *command;
static BOOL endInput;
static IOReturn issueStatus, callbackStatus;
static void Tick(void) {
    if (elapsed >= connectAt) device.connected = YES;
    if (elapsed >= powerAt) device.classicPeer.manager.state = CBManagerStatePoweredOn;
    if (registration && elapsed >= callbackAt) {
        registration.connectionDone = YES;
        registration.connectionStatus = callbackStatus;
    }
}
@implementation FixtureDevice
- (IOReturn)openConnection:(DirectPlaybackProbe *)probe {
    assert([probe.connectionAddress isEqualToString:self.addressString]);
    ++opens;
    if (!issueStatus) registration = probe;
    Tick();
    return issueStatus;
}
@end
static double MonotonicTime(void) { return elapsed; }
static void RunLoopFor(double seconds) { elapsed += seconds; Tick(); }
static BOOL SonyClassicIsConnected(FixtureDevice *value) { return value.connected; }
static NSString *ReadLine(DirectPlaybackProbe *probe, double deadline, BOOL requireLink, NSTimeInterval interval) {
    assert(!requireLink && interval == 0.001 && deadline > elapsed);
    ++calls;
    elapsed = deadline;
    Tick();
    if (elapsed >= stopAt) { probe.stopRequested = YES; return @"stop"; }
    if (elapsed < commandAt) return nil;
    if ([command isEqualToString:@"stop"] || endInput) probe.stopRequested = YES;
    if (endInput) probe.stdinEnded = YES;
    NSString *next = command;
    command = nil;
    return next;
}
"""
    + waiting
    + r"""
static DirectPlaybackProbe *Reset(void) {
    elapsed = 0;
    calls = opens = 0;
    connectAt = callbackAt = INFINITY;
    powerAt = 0;
    commandAt = 0;
    stopAt = INFINITY;
    command = nil;
    registration = nil;
    endInput = NO;
    issueStatus = callbackStatus = 0;
    device = [FixtureDevice new];
    device.addressString = @"02-00-00-00-00-01";
    device.classicPeer = [CBClassicPeer new];
    device.classicPeer.manager = [CBClassicManager new];
    device.classicPeer.manager.state = CBManagerStatePoweredOn;
    return [DirectPlaybackProbe new];
}
static void CheckCallbacks(void) {
    CBClassicPeer *target = [CBClassicPeer new];
    CBClassicPeer *other = [CBClassicPeer new];
    CBClassicManager *manager = [CBClassicManager new];
    target.manager = manager;
    __block NSUInteger originalCalls = 0, opens = 0, closes = 0;
    void (^originalOpen)(CBL2CAPChannel *, NSInteger) = ^(CBL2CAPChannel *value, NSInteger status) {};
    void (^originalClose)(CBL2CAPChannel *, NSInteger) = ^(CBL2CAPChannel *value, NSInteger status) {};
    target.connectL2CAPCallback = originalOpen;
    target.disconnectL2CAPCallback = originalClose;
    void (^original)(CBClassicPeer *, NSInteger) = ^(CBClassicPeer *peer, NSInteger status) {
        ++originalCalls;
        peer.connectL2CAPCallback = originalOpen;
        peer.disconnectL2CAPCallback = originalClose;
    };
    manager.connectionStatusHandler = original;
    DirectSignalingCallbacks *owner = [[DirectSignalingCallbacks alloc] initWithPeer:target
        opened:^(CBL2CAPChannel *value, NSInteger status) { ++opens; }
        closed:^(CBL2CAPChannel *value, NSInteger status) { ++closes; }];
    assert(owner);
    dispatch_sync(owner.queue, ^{
        manager.connectionStatusHandler(other, 0);
        assert(other.connectL2CAPCallback == originalOpen);
        for (unsigned index = 0; index < 2; ++index) {
            manager.connectionStatusHandler(target, 0);
            target.connectL2CAPCallback(nil, 0);
            target.disconnectL2CAPCallback(nil, 0);
        }
    });
    assert(originalCalls == 3 && opens == 2 && closes == 2);
    [owner invalidate];
    [owner invalidate];
    assert(manager.connectionStatusHandler == original && target.connectL2CAPCallback == originalOpen && target.disconnectL2CAPCallback == originalClose);
    owner = [[DirectSignalingCallbacks alloc] initWithPeer:target opened:originalOpen closed:originalClose];
    void (^replacement)(CBClassicPeer *, NSInteger) = ^(CBClassicPeer *peer, NSInteger status) {};
    void (^replacementOpen)(CBL2CAPChannel *, NSInteger) = ^(CBL2CAPChannel *value, NSInteger status) {};
    dispatch_sync(owner.queue, ^{ manager.connectionStatusHandler = replacement; target.connectL2CAPCallback = replacementOpen; });
    [owner invalidate];
    assert(manager.connectionStatusHandler == replacement && target.connectL2CAPCallback == replacementOpen);
    target.manager = nil;
    assert(![[DirectSignalingCallbacks alloc] initWithPeer:target opened:originalOpen closed:originalClose]);
    puts("PASS signaling callback ownership: repeated coordinator resets, unrelated peer, restoration, replacement preservation, missing manager");
}
int main(void) {
    @autoreleasepool {
        CheckCallbacks();
        DirectPlaybackProbe *probe = Reset();
        command = @"acl-connected"; commandAt = 0.004; connectAt = callbackAt = 0.006;
        assert(AwaitConnection(probe, device, 1) && opens == 1 && elapsed < 0.007);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.004; connectAt = 0.002; callbackAt = 0.006;
        assert(AwaitConnection(probe, device, 1) && opens == 1 && elapsed >= callbackAt);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.001; callbackAt = 0.002; connectAt = 0.004;
        assert(AwaitConnection(probe, device, 1) && opens == 1 && elapsed >= connectAt);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.001; callbackAt = connectAt = 0.006; stopAt = 0.003;
        assert(!AwaitConnection(probe, device, 1) && probe.stopRequested && probe.connectionDone && opens == 1 && !probe.failed);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.001; stopAt = 0.003;
        assert(!AwaitConnection(probe, device, 1) && probe.failed && opens == 1 && elapsed >= 5);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.001; issueStatus = 1;
        assert(!AwaitConnection(probe, device, 1) && probe.failed && opens == 1 && elapsed < 0.002);
        probe = Reset();
        command = @"acl-connected"; commandAt = 0.001; callbackAt = 0.002; callbackStatus = 1;
        assert(!AwaitConnection(probe, device, 1) && probe.failed && opens == 1 && elapsed < 0.003);
        probe = Reset();
        connectAt = 0.001;
        assert(!AwaitConnection(probe, device, 0.004) && opens == 0);
        probe = Reset();
        device.connected = YES;
        assert(!AwaitConnection(probe, device, 1) && calls == 0 && opens == 0);
        probe = Reset();
        command = @"stop"; connectAt = 0.001;
        assert(!AwaitConnection(probe, device, 1) && probe.stopRequested && opens == 0);
        probe = Reset();
        endInput = YES;
        assert(!AwaitConnection(probe, device, 1) && probe.stdinEnded && opens == 0);
        probe = Reset();
        command = @"unexpected";
        assert(!AwaitConnection(probe, device, 1) && probe.failed && opens == 0);
        probe = Reset();
        device.classicPeer.manager.state = 0; powerAt = INFINITY;
        assert(!AwaitConnection(probe, device, 0.004) && opens == 0);
        probe = Reset();
        device.classicPeer.manager.state = 0; powerAt = 0.003;
        command = @"acl-connected"; commandAt = 0.004; callbackAt = connectAt = 0.006;
        assert(AwaitConnection(probe, device, 1) && opens == 1);
        puts("PASS signaling registration: ACL/peer/callback ordering, registration required, rejected/failed/pending registration, bounded cancellation, existing ACL, stop/EOF/invalid input, power readiness");
    }
}
"""
)
with tempfile.TemporaryDirectory(prefix="acouplet-signaling-startup-") as directory:
    path = Path(directory) / "Startup.m"
    binary = path.with_suffix("")
    path.write_text(fixture)
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-fobjc-arc",
            "-fblocks",
            "-Werror",
            "-framework",
            "Foundation",
            str(path),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True)
    peer_source = Path(directory) / "PeerCommands.m"
    peer_binary = peer_source.with_suffix("")
    peer_source.write_text(
        r"""#import <Foundation/Foundation.h>
#include <assert.h>
@interface DirectPlaybackProbe : NSObject
@property BOOL configured, configurationSent, streamOpened, delayReporting, peerStopped;
@property BOOL closed, failed, lastRejected, stdinEnded, stopRequested, protocolCleanup;
@property uint32_t sampleRate;
@property uint16_t realCID, mediaCID;
@property uint8_t selectedSink;
@property NSMutableData *pending;
@end
@implementation DirectPlaybackProbe
@end
static NSMutableArray<NSData *> *incoming, *outgoing;
static NSArray<NSData *> *nextReplies;
static double elapsed;
static double MonotonicTime(void) { return elapsed; }
static uint8_t RateBit(uint32_t rate) { assert(rate == 96000); return 4; }
static BOOL SendSignal(DirectPlaybackProbe *probe, NSData *packet) {
    [outgoing addObject:packet];
    if (!(((const uint8_t *)packet.bytes)[0] & 15)) {
        for (NSData *reply in nextReplies) {
            [incoming addObject:reply];
            [probe.pending appendData:reply];
        }
        nextReplies = nil;
    }
    return YES;
}
static NSData *FramedReply(DirectPlaybackProbe *probe, double deadline) {
    if (!incoming.count) { elapsed = deadline; return nil; }
    NSData *packet = incoming.firstObject;
    [incoming removeObjectAtIndex:0];
    [probe.pending replaceBytesInRange:NSMakeRange(0, packet.length) withBytes:NULL length:0];
    return packet;
}
static NSData *Packet(NSArray<NSNumber *> *bytes) {
    NSMutableData *packet = [NSMutableData data];
    for (NSNumber *value in bytes) { uint8_t byte = value.unsignedCharValue; [packet appendBytes:&byte length:1]; }
    return packet;
}
"""
        + source[
            source.index("static NSData *ServiceBytes(") : source.index(
                "static BOOL WaitControlWithIdle("
            )
        ]
        + r"""
int main(void) {
    @autoreleasepool {
        DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
        probe.sampleRate = 96000;
        probe.delayReporting = YES;
        probe.pending = [NSMutableData data];
        incoming = [NSMutableArray array];
        outgoing = [NSMutableArray array];
        uint8_t transaction = 5;
        nextReplies = @[Packet(@[@0x52, @3]), Packet(@[@0x60, @13, @4, @7, @0xD0]), Packet(@[@0x70, @6, @4])];
        assert(EmptyAcceptance(Query(probe, &transaction, 3, [NSData data])));
        probe.configured = YES;
        nextReplies = @[Packet(@[@0x62, @6])];
        assert(EmptyAcceptance(Query(probe, &transaction, 6, Packet(@[@12]))));
        assert([outgoing[1] isEqualToData:Packet(@[@0x62, @13])]);
        assert([outgoing[2] isEqualToData:Packet(@[@0x73, @6, @0x31])]);
        assert([outgoing[3] isEqualToData:Packet(@[@0x60, @6, @12])]);
        assert(!probe.failed && !probe.peerStopped && !probe.lastRejected);
        probe.streamOpened = YES;
        nextReplies = @[Packet(@[@0x72, @7])];
        assert(EmptyAcceptance(Query(probe, &transaction, 7, Packet(@[@12]))));
        probe.selectedSink = 3;
        BOOL suspended = NO;
        nextReplies = @[Packet(@[@0x82, @9])];
        assert(IdleControl(probe, @"media-idle", &transaction, &suspended) && suspended);
        assert([outgoing.lastObject isEqualToData:Packet(@[@0x80, @9, @12])]);
        assert(!IdleControl(probe, @"media-idle", &transaction, &suspended));
        nextReplies = @[Packet(@[@0x92, @7])];
        assert(IdleControl(probe, @"media-resume", &transaction, &suspended) && !suspended);
        assert([outgoing.lastObject isEqualToData:Packet(@[@0x90, @7, @12])]);
        assert(!IdleControl(probe, @"media-resume", &transaction, &suspended));
        for (NSNumber *configured in @[@NO, @YES]) {
            probe.configured = configured.boolValue;
            assert([PeerReply(probe, Packet(@[@0x70, @6, @4])) isEqualToData:Packet(@[@0x73, @6, @0x31])]);
            assert([PeerReply(probe, Packet(@[@0x70, @6, @8])) isEqualToData:Packet(@[@0x73, @6, @0x12])]);
            assert([PeerReply(probe, Packet(@[@0x70, @6])) isEqualToData:Packet(@[@0x73, @6, @0x11])]);
            assert([PeerReply(probe, Packet(@[@0x70, @6, @4, @0])) isEqualToData:Packet(@[@0x73, @6, @0x11])]);
        }
        probe.configured = YES;
        nextReplies = @[Packet(@[@0x80, @6, @4]), Packet(@[@0xA3, @6, @0x31])];
        assert(!Query(probe, &transaction, 6, Packet(@[@12])) && probe.lastRejected);
        assert(!probe.failed && !probe.peerStopped);
        puts("PASS captured WH-1000XM5 startup: delay report and competing Open rejected without aborting local Open/Start; malformed endpoints and local rejection preserved");
    }
}
"""
    )
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-fobjc-arc",
            "-Werror",
            "-framework",
            "Foundation",
            str(peer_source),
            "-o",
            str(peer_binary),
        ],
        check=True,
    )
    subprocess.run([str(peer_binary)], check=True)
for probe_only in ["0", "1"]:
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-fobjc-arc",
            "-fblocks",
            "-Werror",
            "-fsyntax-only",
            "-mmacosx-version-min=15.4",
            "-DACOUPLET_LDAC_PROBE_ONLY=" + probe_only,
            str(base / "Helpers/LDAC/DirectAVDTPSustainedPlaybackProbe.m"),
        ],
        check=True,
    )

writer = source[
    source.index("static BOOL SendSignal(") : source.index(
        "static NSData *ServiceBytes("
    )
]
writer_fixture = (
    r"""#import <Foundation/Foundation.h>
#include <assert.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
@interface FixtureChannel : NSObject
@property UInt16 outgoingMTU;
@property int socketFD;
@end
@implementation FixtureChannel
@end
@interface FixtureOutput : NSObject
@property int descriptor;
@property BOOL shortWrite;
@property NSError *streamError;
- (NSInteger)write:(const uint8_t *)bytes maxLength:(NSUInteger)length;
@end
@implementation FixtureOutput
- (NSInteger)write:(const uint8_t *)bytes maxLength:(NSUInteger)length {
    return write(self.descriptor, bytes, self.shortWrite ? length - 1 : length);
}
@end
@interface DirectPlaybackProbe : NSObject
@property BOOL closed, failed;
@property FixtureChannel *channel;
@property FixtureOutput *output;
- (void)pollInput;
@end
@implementation DirectPlaybackProbe
- (void)pollInput {}
@end
static DirectPlaybackProbe *cancelOnTick;
static void RunLoopFor(double seconds) {
    if (cancelOnTick) { cancelOnTick.closed = YES; cancelOnTick = nil; }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}
static double MonotonicTime(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000.0; }
"""
    + writer.replace("MonotonicTime() + 2", "MonotonicTime() + 0.2")
    + r"""
static DirectPlaybackProbe *Reset(int descriptors[2]) {
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
    DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
    probe.channel = [FixtureChannel new];
    probe.channel.outgoingMTU = 895;
    probe.channel.socketFD = descriptors[0];
    probe.output = [FixtureOutput new];
    probe.output.descriptor = descriptors[0];
    return probe;
}
int main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        static const uint8_t reply[] = {0x62, 0x0D}, request[] = {0x60, 0x06, 0x0C};
        NSData *ack = [NSData dataWithBytes:reply length:sizeof(reply)];
        NSData *open = [NSData dataWithBytes:request length:sizeof(request)];
        int descriptors[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
        assert(write(descriptors[0], reply, 2) == 2 && write(descriptors[0], request, 3) == 3);
        uint8_t merged[8];
        assert(read(descriptors[1], merged, sizeof(merged)) == 5);
        close(descriptors[0]); close(descriptors[1]);
        for (unsigned attempt = 0; attempt < 20; ++attempt) {
            DirectPlaybackProbe *probe = Reset(descriptors);
            int reader = descriptors[1];
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                uint8_t buffer[8];
                usleep(10000);
                ssize_t count = read(reader, buffer, sizeof(buffer));
                assert(count == 2 && memcmp(buffer, reply, 2) == 0);
                usleep(10000);
                count = read(reader, buffer, sizeof(buffer));
                assert(count == 3 && memcmp(buffer, request, 3) == 0);
            });
            assert(SendSignal(probe, ack) && SendSignal(probe, open));
            assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
            close(descriptors[0]); close(descriptors[1]);
        }
        DirectPlaybackProbe *probe = Reset(descriptors);
        double start = MonotonicTime();
        assert(!SendSignal(probe, ack) && probe.failed && MonotonicTime() - start < 0.3);
        close(descriptors[0]); close(descriptors[1]);
        probe = Reset(descriptors);
        cancelOnTick = probe;
        assert(!SendSignal(probe, ack) && probe.closed);
        close(descriptors[0]); close(descriptors[1]);
        probe = Reset(descriptors);
        probe.channel.socketFD = -1;
        assert(!SendSignal(probe, ack) && probe.failed);
        close(descriptors[0]); close(descriptors[1]);
        probe = Reset(descriptors);
        probe.output.shortWrite = YES;
        assert(!SendSignal(probe, ack) && probe.failed);
        close(descriptors[0]); close(descriptors[1]);
        probe = Reset(descriptors);
        close(descriptors[1]);
        assert(!SendSignal(probe, ack) && probe.failed);
        close(descriptors[0]);
        probe = Reset(descriptors);
        probe.channel.outgoingMTU = 2;
        assert(!SendSignal(probe, open));
        close(descriptors[0]); close(descriptors[1]);
        puts("PASS signaling writes: 20 delayed socket readers keep delay replies and OPEN requests separate; merged byte-stream negative control; stalled/closed/invalid/short writes, MTU and cancellation fail safely");
    }
}
"""
)
with tempfile.TemporaryDirectory(prefix="acouplet-signaling-writes-") as directory:
    path = Path(directory) / "Writer.m"
    binary = path.with_suffix("")
    path.write_text(writer_fixture)
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-fobjc-arc",
            "-fblocks",
            "-Werror",
            "-framework",
            "Foundation",
            str(path),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True, timeout=10)
