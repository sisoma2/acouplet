from pathlib import Path
import subprocess
import tempfile

base = Path(__file__).resolve().parents[2]
source = (base / 'Helpers/LDAC/DirectAVDTPSustainedPlaybackProbe.m').read_text()
waiting = source[source.index('static BOOL AwaitConnection('):source.index('static BOOL PlaybackSequence(')]
callbacks = source[source.index('@interface DirectSignalingCallbacks'):source.index('@interface IOBluetoothDevice (ClassicPeerAccess)')]
fixture = r'''#import <Foundation/Foundation.h>
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
''' + callbacks + r'''
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
''' + waiting + r'''
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
'''
with tempfile.TemporaryDirectory(prefix='acouplet-signaling-startup-') as directory:
    path = Path(directory) / 'Startup.m'
    binary = path.with_suffix('')
    path.write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-framework', 'Foundation', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
for probe_only in ['0', '1']:
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-fsyntax-only',
                    '-mmacosx-version-min=15.4', '-DACOUPLET_LDAC_PROBE_ONLY=' + probe_only,
                    str(base / 'Helpers/LDAC/DirectAVDTPSustainedPlaybackProbe.m')], check=True)
