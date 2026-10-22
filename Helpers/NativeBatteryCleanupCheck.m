#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/IOCFUnserialize.h>
#import <IOBluetooth/IOBluetooth.h>

static BOOL checkBluetoothPresent;
static BOOL checkBluetoothConnected;
static BOOL checkBluetoothClassicConnected;

@interface CheckBluetoothClassicPeer : NSObject
- (NSInteger)state;
@end

@implementation CheckBluetoothClassicPeer
- (NSInteger)state { return checkBluetoothClassicConnected ? 2 : 0; }
@end

@interface CheckBluetoothDevice : NSObject
+ (instancetype)deviceWithAddressString:(NSString *)address;
- (BOOL)isPaired;
- (BOOL)isConnected;
- (id)classicPeer;
@end

@implementation CheckBluetoothDevice
+ (instancetype)deviceWithAddressString:(NSString *)address { return checkBluetoothPresent ? self.new : nil; }
- (BOOL)isPaired { return YES; }
- (BOOL)isConnected { return checkBluetoothConnected; }
- (id)classicPeer { return CheckBluetoothClassicPeer.new; }
@end

static double checkTime;
static BOOL checkPairMode;
static NSMutableArray *checkPairHistory;
static NSMutableArray *checkPairEnvelopeHistory;
static NSUInteger checkPairEnvelopeWrites;

@interface CheckDate : NSObject
+ (NSDate *)date;
+ (NSDate *)dateWithTimeIntervalSinceNow:(NSTimeInterval)interval;
@end

@implementation CheckDate
+ (NSDate *)date { return checkTime ? [NSDate dateWithTimeIntervalSince1970:checkTime] : NSDate.date; }
+ (NSDate *)dateWithTimeIntervalSinceNow:(NSTimeInterval)interval { return [NSDate dateWithTimeIntervalSinceNow:interval]; }
@end

static CFTypeRef checkCopyPowerSourcesByType(int type);
static CFArrayRef checkCopyPowerSourcesList(CFTypeRef info);
static CFDictionaryRef checkGetPowerSourceDescription(CFTypeRef info, CFTypeRef source);

#define IOPSCopyPowerSourcesByType checkCopyPowerSourcesByType
#define IOPSCopyPowerSourcesList checkCopyPowerSourcesList
#define IOPSGetPowerSourceDescription checkGetPowerSourceDescription
#define IOBluetoothDevice CheckBluetoothDevice
#define NSDate CheckDate
#define ACOUPLET_BATTERY_CLEANUP_CHECK
#include "SonyNativeBatteryBridge.m"
#undef NSDate

static NSMutableArray *checkRecords;
static NSMutableArray *checkRemoved;
static BOOL checkUnavailable;
static BOOL checkRetainAfterRemoval;
static BOOL checkStall;
static BOOL checkDisconnectAfterUpdate;
static int checkFailures;
static int checkNextSource;
static NSString *checkReleasePath;
static NSString *checkSupervisorDirectory;

static CFTypeRef checkCopyPowerSourcesByType(int type) {
    assert(type == 4);
    if (checkUnavailable) return NULL;
    NSMutableArray *records = checkRecords.mutableCopy;
    NSFileManager *files = NSFileManager.defaultManager;
    if (checkSupervisorDirectory && [files fileExistsAtPath:[checkSupervisorDirectory stringByAppendingPathComponent:@"prepared"]]
        && ![files fileExistsAtPath:[checkSupervisorDirectory stringByAppendingPathComponent:@"withdrawing"]]) {
        NSDictionary *baseline = records.firstObject;
        for (NSUInteger index = 0; index < 3; index++) {
            NSMutableDictionary *record = [single(baseline, [@"cleanup-check/" stringByAppendingString:@[@"a", @"b", @"c"][index]]) mutableCopy];
            record[@"Power Source ID"] = @(102 + index);
            [records addObject:record];
        }
        if ([files fileExistsAtPath:[checkSupervisorDirectory stringByAppendingPathComponent:@"submitted"]])
            assert([NSData.data writeToFile:[checkSupervisorDirectory stringByAppendingPathComponent:@"acknowledged"] atomically:YES]);
    }
    return CFBridgingRetain(records);
}

static CFArrayRef checkCopyPowerSourcesList(CFTypeRef info) { return CFRetain(info); }
static CFDictionaryRef checkGetPowerSourceDescription(CFTypeRef info, CFTypeRef source) { return source; }

static kern_return_t checkRemoveSource(mach_port_t connection, int source) {
    assert(connection == 0);
    [checkRemoved addObject:@(source)];
    if (checkStall) while (YES) pause();
    if (checkFailures) { checkFailures--; return kIOReturnError; }
    if (!checkRetainAfterRemoval) {
        NSIndexSet *matching = [checkRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
            return [record[@"Power Source ID"] isEqual:@(source)];
        }];
        [checkRecords removeObjectsAtIndexes:matching];
        if (checkPairMode && source == 101) {
            NSIndexSet *parents = [checkRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
                return [record[ownerKey] isEqual:@"cleanup-check/parent"];
            }];
            [checkRecords removeObjectsAtIndexes:parents];
        }
        if (checkReleasePath) assert([NSData.data writeToFile:checkReleasePath atomically:YES]);
    }
    return KERN_SUCCESS;
}

static kern_return_t checkCreateSource(mach_port_t connection, int *source, int *result) {
    assert(connection == 0);
    *source = ++checkNextSource;
    *result = kIOReturnSuccess;
    return KERN_SUCCESS;
}

static kern_return_t checkUpdateSource(mach_port_t connection, int source, vm_offset_t data, mach_msg_type_number_t length, int *result) {
    assert(connection == 0 && length > 0);
    NSMutableDictionary *record = [CFBridgingRelease(IOCFUnserialize((const char *)data, NULL, 0, NULL)) mutableCopy];
    record[@"Power Source ID"] = @(source);
    NSUInteger index = [checkRecords indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        return [candidate[@"Power Source ID"] isEqual:@(source)];
    }];
    if (index == NSNotFound) [checkRecords addObject:record];
    else checkRecords[index] = record;
    *result = kIOReturnSuccess;
    if (checkPairMode && source != 102) checkPairEnvelopeWrites++;
    if (checkPairMode && [record[@"Part Identifier"] isEqual:@"Combined"]) {
        if ([record[@"Combined Parts"] count]) {
            [checkPairHistory addObject:record.copy];
            [checkPairEnvelopeHistory addObject:@(checkPairEnvelopeWrites)];
            if ([record[@"Combined Parts"] count] == 3 && [record[@"Combined Parts"][2][@"Current Capacity"] isEqual:@63]) {
                checkTime += checkPairHistory.count == 1 ? 30 : 16;
            }
        } else {
            NSUInteger parent = [checkRecords indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
                return [candidate[ownerKey] isEqual:@"cleanup-check/parent"];
            }];
            if (parent != NSNotFound) {
                NSMutableDictionary *details = [checkRecords[parent] mutableCopy];
                details[@"Part Identifier"] = @"Combined";
                details[@"Combined Parts"] = @[];
                checkRecords[parent] = details;
            }
        }
    }
    if (checkDisconnectAfterUpdate) checkBluetoothClassicConnected = NO;
    return KERN_SUCCESS;
}

static void reset(NSArray *records) {
    checkTime = 0;
    checkPairMode = NO;
    checkPairHistory = NSMutableArray.array;
    checkPairEnvelopeHistory = NSMutableArray.array;
    checkPairEnvelopeWrites = 0;
    checkRecords = records.mutableCopy;
    checkRemoved = NSMutableArray.array;
    checkUnavailable = checkRetainAfterRemoval = checkStall = NO;
    checkFailures = 0;
    checkBluetoothPresent = checkBluetoothConnected = checkBluetoothClassicConnected = checkDisconnectAfterUpdate = NO;
    checkNextSource = 100;
    creationFinished = NO;
    stopped = 0;
    removeSource = checkRemoveSource;
    createSource = checkCreateSource;
    updateSource = checkUpdateSource;
}

static int checkChild(NSDictionary *sample, NSString *session, NSDictionary *native, BOOL stall) {
    NSMutableDictionary *parent = [single(native, [session stringByAppendingString:@"/parent"]) mutableCopy];
    parent[@"Power Source ID"] = @2;
    reset(@[native, parent]);
    checkFailures = 1000;
    checkStall = stall;
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    NSMutableData *commands = [[NSJSONSerialization dataWithJSONObject:@{@"command": @"prepare", @"sample": sample} options:0 error:nil] mutableCopy];
    [commands appendData:[@"\n{\"command\":\"stop\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    assert(write(descriptors[1], commands.bytes, commands.length) == commands.length);
    close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    int result = child(sample[@"identifier"], session);
    alarm(0);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    return result;
}

static int checkPreparingChild(NSString *session) {
    NSString *directory = NSProcessInfo.processInfo.environment[@"ACOUPLET_BATTERY_CHECK_DIRECTORY"];
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *command = nil;
    double deadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        if (receive(STDIN_FILENO, buffer, &command) > 0) break;
    }
    if (![command[@"command"] isEqual:@"prepare"]) return 2;
    if (getenv("ACOUPLET_BATTERY_CHECK_WITHDRAWAL")) {
        NSDictionary *sample = command[@"sample"];
        assert([NSData.data writeToFile:[directory stringByAppendingPathComponent:@"prepared"] atomically:YES]);
        NSDictionary *markers = @{@"guard": [session stringByAppendingString:@"/a"],
            @"pair": [session stringByAppendingString:@"/b"], @"trailer": [session stringByAppendingString:@"/c"]};
        event(@"prepared", markers);
        command = nil;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            if (receive(STDIN_FILENO, buffer, &command) > 0) break;
        }
        if (![command[@"command"] isEqual:@"activate"]) return 5;
        assert([NSData.data writeToFile:[directory stringByAppendingPathComponent:@"submitted"] atomically:YES]);
        event(@"pair-submitted", @{@"sample": sample, @"sourcesUnchanged": @YES});
        NSString *acknowledged = [directory stringByAppendingPathComponent:@"acknowledged"];
        while (![NSFileManager.defaultManager fileExistsAtPath:acknowledged] && NSProcessInfo.processInfo.systemUptime < deadline) tick();
        if (![NSFileManager.defaultManager fileExistsAtPath:acknowledged]) return 6;
        assert([NSData.data writeToFile:[directory stringByAppendingPathComponent:@"withdrawing"] atomically:YES]);
        event(@"components-absent", markers);
        NSString *released = [directory stringByAppendingPathComponent:@"parent-removed"];
        while (![NSFileManager.defaultManager fileExistsAtPath:released] && NSProcessInfo.processInfo.systemUptime < deadline) tick();
        return [NSFileManager.defaultManager fileExistsAtPath:released] ? atoi(getenv("ACOUPLET_BATTERY_CHECK_WITHDRAWAL")) : 7;
    }
    if (getenv("ACOUPLET_BATTERY_CHECK_EOF")) {
        command = nil;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            int received = receive(STDIN_FILENO, buffer, &command);
            if (received < 0 || received > 0) break;
        }
        if (![command[@"command"] isEqual:@"stop"]) return 3;
    }
    event(@"components-absent", @{@"guard": [session stringByAppendingString:@"/a"],
        @"pair": [session stringByAppendingString:@"/b"], @"trailer": [session stringByAppendingString:@"/c"]});
    NSString *released = [directory stringByAppendingPathComponent:@"parent-removed"];
    while (![[NSFileManager defaultManager] fileExistsAtPath:released] && NSProcessInfo.processInfo.systemUptime < deadline) tick();
    if (![[NSFileManager defaultManager] fileExistsAtPath:released]) return 4;
    assert([NSData.data writeToFile:[directory stringByAppendingPathComponent:@"child-finished"] atomically:YES]);
    event(@"child-exit", @{@"result": @0});
    return 0;
}

static void checkSupervisor(NSDictionary *sample, NSDictionary *native, BOOL closesInput, int childWithdrawal) {
    reset(@[native]);
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]);
    checkReleasePath = [directory stringByAppendingPathComponent:@"parent-removed"];
    checkSupervisorDirectory = childWithdrawal ? directory : nil;
    assert(setenv("ACOUPLET_BATTERY_CHECK_DIRECTORY", directory.fileSystemRepresentation, 1) == 0);
    if (closesInput) assert(setenv("ACOUPLET_BATTERY_CHECK_EOF", "1", 1) == 0);
    if (childWithdrawal) assert(setenv("ACOUPLET_BATTERY_CHECK_WITHDRAWAL", [@(childWithdrawal) stringValue].UTF8String, 1) == 0);
    int descriptors[2];
    assert(pipe(descriptors) == 0 && fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0);
    NSMutableData *input = [[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] mutableCopy];
    [input appendBytes:"\n" length:1];
    assert(write(descriptors[1], input.bytes, input.length) == input.length);
    if (closesInput) close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    assert(supervisor(NSProcessInfo.processInfo.arguments.firstObject, sample[@"identifier"], @"cleanup-check") == (childWithdrawal ? childWithdrawal : closesInput ? 0 : 1));
    alarm(0);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    if (!closesInput) close(descriptors[1]);
    if (!childWithdrawal) assert([[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"child-finished"]]);
    assert([checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native]]);
    checkReleasePath = nil;
    checkSupervisorDirectory = nil;
    assert(unsetenv("ACOUPLET_BATTERY_CHECK_DIRECTORY") == 0 && unsetenv("ACOUPLET_BATTERY_CHECK_EOF") == 0);
    assert(unsetenv("ACOUPLET_BATTERY_CHECK_WITHDRAWAL") == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
}

static void checkCasePublisher(NSDictionary *sample, NSDictionary *native, NSString *failure) {
    NSString *identifier = sample[@"identifier"], *session = @"cleanup-check";
    NSString *marker = [[identifier stringByAppendingString:@"/case/"] stringByAppendingString:session];
    reset(@[native]);
    checkBluetoothPresent = YES;
    checkBluetoothConnected = [failure isEqual:@"classic"];
    checkBluetoothClassicConnected = ![failure isEqual:@"classic"];
    checkDisconnectAfterUpdate = [failure isEqual:@"disconnect"];
    checkRetainAfterRemoval = [failure isEqual:@"retained"];
    if ([failure isEqual:@"duplicate"]) {
        NSMutableDictionary *previous = [casePublication(sample, [[identifier stringByAppendingString:@"/case/"] stringByAppendingString:@"previous"]) mutableCopy];
        previous[@"Power Source ID"] = @99;
        [checkRecords addObject:previous];
    }
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    if ([failure isEqual:@"old"]) {
        NSMutableDictionary *oldSample = sample.mutableCopy, *oldReading = [sample[@"caseBattery"] mutableCopy];
        oldReading[@"observedAt"] = @(NSDate.date.timeIntervalSince1970 - maximumSampleAge - 0.1);
        oldSample[@"caseBattery"] = oldReading;
        sample = oldSample;
    }
    NSMutableData *input = [[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] mutableCopy];
    [input appendBytes:"\n" length:1];
    if ([failure isEqual:@"malformed"]) [input appendData:[@"{}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    assert(write(descriptors[1], input.bytes, input.length) == input.length);
    if (![failure isEqual:@"disconnect"]) close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    int result = casePublisher(identifier, session);
    alarm(0);
    if ([failure isEqual:@"disconnect"]) close(descriptors[1]);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    BOOL refused = [failure isEqual:@"duplicate"] || [failure isEqual:@"old"] || [failure isEqual:@"classic"];
    assert(result == (refused ? 75
        : (!failure || [failure isEqual:@"disconnect"]) ? ([failure isEqual:@"disconnect"] ? nativeDisconnectedExit : 0) : 1));
    if ([failure isEqual:@"duplicate"]) {
        assert(checkRemoved.count == 0 && checkRecords.count == 2);
    } else if (refused) {
        assert(checkRemoved.count == 0 && [checkRecords isEqual:@[native]]);
    } else if ([failure isEqual:@"retained"]) {
        assert(([checkRemoved isEqual:@[@101]] && checkRecords.count == 2));
    } else {
        assert(([checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native]]));
    }
}

static void checkIntegratedPair(NSDictionary *baseline, NSString *identifier, NSString *ending) {
    NSMutableDictionary *parent = [single(baseline, @"cleanup-check/parent") mutableCopy];
    parent[@"Power Source ID"] = @2;
    reset(@[baseline, parent]);
    checkPairMode = YES;
    double began = NSDate.date.timeIntervalSince1970;
    checkTime = began;
    NSDictionary *left = @{@"level": @40, @"isCharging": @NO, @"observedAt": @(began)};
    NSDictionary *right = @{@"level": @36, @"isCharging": @YES, @"observedAt": @(began)};
    NSDictionary *sample = @{@"identifier": identifier, @"name": @"WF-1000XM5", @"address": @"02:00:00:00:00:19", @"controlSession": @1,
        @"left": left, @"right": right, @"caseBattery": @{@"level": @63, @"isCharging": @NO, @"observedAt": @(began)}};
    NSMutableDictionary *buds = sample.mutableCopy;
    buds[@"left"] = @{@"level": @39, @"isCharging": @NO, @"observedAt": @(began + 30)};
    buds[@"right"] = @{@"level": @35, @"isCharging": @YES, @"observedAt": @(began + 30)};
    NSMutableDictionary *lateBuds = buds.mutableCopy;
    lateBuds[@"left"] = @{@"level": @39, @"isCharging": @NO, @"observedAt": @(began + 46)};
    lateBuds[@"right"] = @{@"level": @35, @"isCharging": @YES, @"observedAt": @(began + 46)};
    NSMutableDictionary *returned = lateBuds.mutableCopy;
    returned[@"caseBattery"] = @{@"level": @62, @"isCharging": @YES, @"observedAt": @(began + 46)};
    NSArray *commands = @[@{@"command": @"prepare", @"sample": sample}, @{@"command": @"activate", @"sample": sample},
        @{@"command": @"sample", @"sample": buds}, @{@"command": @"sample", @"sample": lateBuds},
        @{@"command": @"sample", @"sample": returned}];
    if ([ending isEqual:@"stop"]) commands = [commands arrayByAddingObject:@{@"command": @"stop"}];
    if ([ending isEqual:@"malformed"]) commands = [commands arrayByAddingObject:@{@"command": @"sample", @"sample": @{}}];
    NSMutableData *input = NSMutableData.data;
    for (NSDictionary *command in commands) {
        [input appendData:[NSJSONSerialization dataWithJSONObject:command options:0 error:nil]];
        [input appendBytes:"\n" length:1];
    }
    int descriptors[2];
    assert(pipe(descriptors) == 0 && write(descriptors[1], input.bytes, input.length) == input.length);
    close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    assert(child(identifier, @"cleanup-check") == ([ending isEqual:@"malformed"] ? 1 : 0));
    alarm(0);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    assert(checkPairHistory.count == 5);
    assert([checkPairEnvelopeHistory[1] isEqual:checkPairEnvelopeHistory[2]]);
    assert([checkPairEnvelopeHistory[2] isEqual:checkPairEnvelopeHistory[3]]);
    assert([checkPairEnvelopeHistory[3] isEqual:checkPairEnvelopeHistory[4]]);
    assert([checkPairHistory[0][@"Combined Parts"] count] == 3);
    assert([checkPairHistory[1][@"Combined Parts"] count] == 3);
    assert([checkPairHistory[2][@"Combined Parts"] count] == 2);
    assert([checkPairHistory[3][@"Combined Parts"] count] == 2);
    assert([checkPairHistory[4][@"Combined Parts"] count] == 3);
    assert([checkPairHistory[4][@"Combined Parts"][2][@"Current Capacity"] isEqual:@62]);
    for (NSUInteger index = 0; index < 2; index++) {
        assert([checkPairHistory[1][@"Combined Parts"][index] isEqual:checkPairHistory[2][@"Combined Parts"][index]]);
        assert([checkPairHistory[2][@"Combined Parts"][index] isEqual:checkPairHistory[3][@"Combined Parts"][index]]);
        assert([checkPairHistory[3][@"Combined Parts"][index] isEqual:checkPairHistory[4][@"Combined Parts"][index]]);
    }
    assert([checkRecords isEqual:@[baseline]]);
    assert(([checkRemoved isEqual:@[@102, @101, @103]]));
    printf("PASS integrated child %s: Case uses the same fixture identity, independent L/R samples, Case expiry while L/R remain leased, fresh Case return and owned source release; all source and peer calls mocked\n", ending.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc == 4 && !strcmp(argv[1], "--child")) return checkPreparingChild([NSString stringWithUTF8String:argv[3]]);
        NSString *identifier = @"00000000-0000-4000-8000-000000000019";
        NSDictionary *reading = @{@"level": @40, @"isCharging": @NO, @"observedAt": @(NSDate.date.timeIntervalSince1970)};
        NSDictionary *sample = @{@"identifier": identifier, @"name": @"WF-1000XM5", @"address": @"02:00:00:00:00:19", @"controlSession": @1, @"left": reading, @"right": reading};
        NSMutableDictionary *baseline = [publication(sample, @"unused") mutableCopy];
        [baseline removeObjectForKey:ownerKey];
        [baseline removeObjectForKey:@"Combined Parts"];
        baseline[@"Part Identifier"] = @"Single";
        baseline[@"Power Source ID"] = @1;
        if (argc == 2 && !strcmp(argv[1], "--stall")) return checkChild(sample, @"cleanup-check", baseline, YES);
        NSDictionary *native = @{@"Power Source ID": @1, @"Accessory Identifier": identifier};
        NSDictionary *owned = @{@"Power Source ID": @101, @"Accessory Identifier": identifier, ownerKey: @"owned"};
        EnvelopeSource source = {101, YES};
        reset(@[native, owned]);
        checkFailures = 1;
        assert(releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 1));
        assert((!source.allocated && [checkRemoved isEqual:@[@101, @101]] && [checkRecords isEqual:@[native]]));

        reset(@[native, owned]);
        source.allocated = YES;
        checkRetainAfterRemoval = YES;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]]);

        reset(@[native, owned]);
        source.allocated = YES;
        checkFailures = 1000;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert((source.allocated && [checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native, owned]]));

        reset(@[native, owned]);
        source.allocated = YES;
        checkUnavailable = YES;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]]);

        reset(@[native, owned]);
        EnvelopeSource none = {0};
        assert(!releaseOwned(&none, nil, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert((checkRemoved.count == 0 && [checkRecords isEqual:@[native, owned]]));
        reset(@[native]);
        assert(releaseOwned(&none, nil, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(checkRemoved.count == 0);
        source.allocated = YES;
        assert(releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native]]);

        NSDictionary *caseSample = @{@"identifier": identifier, @"name": @"WF-1000XM5", @"address": sample[@"address"], @"controlSession": @1,
            @"caseBattery": @{@"level": @0, @"isCharging": @NO, @"observedAt": @(NSDate.date.timeIntervalSince1970)}};
        for (NSString *ending in @[@"stop", @"eof", @"malformed"]) checkIntegratedPair(baseline, identifier, ending);
        checkCasePublisher(caseSample, baseline, nil);
        checkCasePublisher(caseSample, baseline, @"malformed");
        checkCasePublisher(caseSample, baseline, @"duplicate");
        checkCasePublisher(caseSample, baseline, @"classic");
        checkCasePublisher(caseSample, baseline, @"old");
        checkCasePublisher(caseSample, baseline, @"retained");
        checkCasePublisher(caseSample, baseline, @"disconnect");
        checkSupervisor(sample, baseline, NO, 0);
        checkSupervisor(sample, baseline, YES, 0);
        checkSupervisor(sample, baseline, NO, leaseExpiredExit);
        checkSupervisor(sample, baseline, NO, 1);

        FILE *output = tmpfile();
        assert(output);
        fflush(stdout);
        int savedOutput = dup(STDOUT_FILENO);
        assert(savedOutput >= 0 && dup2(fileno(output), STDOUT_FILENO) == STDOUT_FILENO);
        double began = NSProcessInfo.processInfo.systemUptime;
        assert(checkChild(sample, @"cleanup-check", baseline, NO) == 1);
        assert(NSProcessInfo.processInfo.systemUptime - began < 6);
        assert(checkRemoved.count > 1 && [[NSSet setWithArray:checkRemoved] isEqual:[NSSet setWithObject:@102]]);
        assert(checkRecords.count == 5);
        fflush(stdout);
        assert(dup2(savedOutput, STDOUT_FILENO) == STDOUT_FILENO);
        close(savedOutput);
        rewind(output);
        char bytes[16384];
        size_t count = fread(bytes, 1, sizeof(bytes), output);
        fclose(output);
        NSString *events = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
        assert([events containsString:@"source-disposal-unconfirmed"] && [events containsString:@"child-exit"]);
        assert(![events containsString:@"components-absent"] && ![events containsString:@"final-inventory"]);
        NSTask *task = NSTask.new;
        task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
        task.arguments = @[@"--stall"];
        task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        assert([task launchAndReturnError:nil]);
        double deadline = NSProcessInfo.processInfo.systemUptime + 15;
        while (task.running && NSProcessInfo.processInfo.systemUptime < deadline) tick();
        BOOL overran = task.running;
        if (overran) kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
        assert(!overran && task.terminationReason == NSTaskTerminationReasonUncaughtSignal && task.terminationStatus == SIGALRM);
        puts("PASS isolated Case EOF, invalid input, duplicate owner, retained source and disconnect; bounded native battery release retries, retained ownership, asynchronous absence, unavailable inventory, monitor-only cleanup, early setup withdrawal, app EOF, ordered child failure and stalled-call termination; no native source calls");
    }
    return 0;
}
