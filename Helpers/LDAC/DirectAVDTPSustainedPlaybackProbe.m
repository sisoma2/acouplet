#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#include "../SonyClassicConnection.h"
#include "LDACParentLifetime.h"
#include <poll.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <sys/event.h>

#ifndef ACOUPLET_LDAC_PROBE_ONLY
#define ACOUPLET_LDAC_PROBE_ONLY 1
#endif

@interface CBClassicPeer : CBPeer
@property(readonly) id manager;
@property(copy) void (^connectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^disconnectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
- (void)openL2CAPChannel:(UInt16)psm;
- (void)closeL2CAPChannel:(UInt16)psm;
@end

@interface CBClassicManager : CBManager
@property(copy) void (^connectionStatusHandler)(CBClassicPeer *, NSInteger);
@end

@interface IOBluetoothCoreBluetoothCoordinator : NSObject
+ (instancetype)sharedInstance;
@property(readonly) dispatch_queue_t coordinatorQueue;
@end

@interface DirectSignalingCallbacks : NSObject
@property CBClassicPeer *peer;
@property CBClassicManager *manager;
@property dispatch_queue_t queue;
@property(copy) void (^opened)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^closed)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^previousOpened)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^previousClosed)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^previousConnection)(CBClassicPeer *, NSInteger);
@property(copy) void (^connection)(CBClassicPeer *, NSInteger);
- (instancetype)initWithPeer:(CBClassicPeer *)peer
                     opened:(void (^)(CBL2CAPChannel *, NSInteger))opened
                     closed:(void (^)(CBL2CAPChannel *, NSInteger))closed;
- (void)invalidate;
@end

@implementation DirectSignalingCallbacks
- (instancetype)initWithPeer:(CBClassicPeer *)peer
                     opened:(void (^)(CBL2CAPChannel *, NSInteger))opened
                     closed:(void (^)(CBL2CAPChannel *, NSInteger))closed {
    self = [super init];
    if (!self) return nil;
    self.peer = peer;
    self.manager = peer.manager;
    self.queue = [IOBluetoothCoreBluetoothCoordinator sharedInstance].coordinatorQueue;
    if (!self.manager || !self.queue || ![self.manager respondsToSelector:@selector(connectionStatusHandler)]) return nil;
    self.opened = opened;
    self.closed = closed;
    dispatch_sync(self.queue, ^{
        self.previousOpened = peer.connectL2CAPCallback;
        self.previousClosed = peer.disconnectL2CAPCallback;
        self.previousConnection = self.manager.connectionStatusHandler;
        __weak DirectSignalingCallbacks *weakSelf = self;
        self.connection = ^(CBClassicPeer *value, NSInteger error) {
            DirectSignalingCallbacks *owner = weakSelf;
            if (!owner) return;
            if (owner.previousConnection) owner.previousConnection(value, error);
            if (value == owner.peer) {
                value.connectL2CAPCallback = owner.opened;
                value.disconnectL2CAPCallback = owner.closed;
            }
        };
        self.manager.connectionStatusHandler = self.connection;
        peer.connectL2CAPCallback = self.opened;
        peer.disconnectL2CAPCallback = self.closed;
    });
    return self;
}
- (void)invalidate {
    dispatch_sync(self.queue, ^{
        if (self.manager.connectionStatusHandler == self.connection)
            self.manager.connectionStatusHandler = self.previousConnection;
        if (self.peer.connectL2CAPCallback == self.opened)
            self.peer.connectL2CAPCallback = self.previousOpened;
        if (self.peer.disconnectL2CAPCallback == self.closed)
            self.peer.disconnectL2CAPCallback = self.previousClosed;
    });
}
@end

@interface IOBluetoothDevice (ClassicPeerAccess)
@property(readonly) CBClassicPeer *classicPeer;
@end

@interface CBL2CAPChannel (ChannelInspection)
@property(readonly) UInt16 cid;
@property(readonly) UInt16 outgoingMTU;
@property(readonly) int socketFD;
@end

static void RunLoopFor(NSTimeInterval seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static double MonotonicTime(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000.0;
}

static NSString *NormalizeAddress(const char *value) {
    if (strlen(value) != 17 || (value[2] != ':' && value[2] != '-')) return nil;
    for (NSUInteger index = 0; index < 17; index++) {
        if (index % 3 == 2) {
            if (value[index] != value[2]) return nil;
        } else if (!((value[index] >= '0' && value[index] <= '9') ||
                     (value[index] >= 'a' && value[index] <= 'f') ||
                     (value[index] >= 'A' && value[index] <= 'F'))) return nil;
    }
    return [[[NSString stringWithUTF8String:value] uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

static uint8_t RateBit(uint32_t sampleRate) {
    switch (sampleRate) {
        case 44100: return 0x20;
        case 48000: return 0x10;
        case 88200: return 0x08;
        case 96000: return 0x04;
        default: return 0;
    }
}

static BOOL ParseSampleRate(const char *input, uint32_t *sampleRate) {
    if (input[0] < '0' || input[0] > '9') return NO;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(input, &end, 10);
    if (errno || *end || parsed > UINT32_MAX || !RateBit((uint32_t)parsed)) return NO;
    *sampleRate = (uint32_t)parsed;
    return YES;
}

static void PrintChannel(const char *event, CBL2CAPChannel *channel) {
    printf("%s time=%.6f channel=%p PSM=%04X localCID=%04X outgoingMTU=%u\n",
           event, NSDate.date.timeIntervalSince1970, (__bridge void *)channel, channel.PSM,
           channel.cid, channel.outgoingMTU);
}

@interface DirectPlaybackProbe : NSObject
@property BOOL closed;
@property BOOL closing;
@property BOOL failed;
@property NSUInteger received;
@property UInt16 realCID;
@property(strong) CBL2CAPChannel *channel;
@property(strong) NSInputStream *input;
@property(strong) NSOutputStream *output;
@property NSMutableData *pending;
@property NSMutableData *raw;
@property NSMutableData *controlPending;
@property BOOL playback;
@property BOOL continuous;
@property BOOL stopRequested;
@property BOOL stdinEnded;
@property BOOL connectionDone;
@property IOReturn connectionStatus;
@property(copy) NSString *connectionAddress;
@property BOOL protocolCleanup;
@property BOOL inputEnded;
@property BOOL configurationSent;
@property BOOL configured;
@property BOOL streamOpened;
@property BOOL peerStopped;
@property BOOL delayReporting;
@property BOOL lastRejected;
@property BOOL mediaExpected;
@property UInt8 selectedSink;
@property UInt16 mediaCID;
@property uint32_t sampleRate;
@property(strong) NSString *quality;
- (void)pollInput;
@end

@implementation DirectPlaybackProbe
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![device.addressString isEqualToString:self.connectionAddress]) {
            self.failed = YES;
            return;
        }
        if (!self.connectionDone) {
            self.connectionStatus = status;
            self.connectionDone = YES;
        }
        printf("SIGNALING_REGISTRATION status=0x%08X connected=%d\n", (unsigned int)status, SonyClassicIsConnected(device));
    });
}
- (void)pollInput {
    if (self.closed || self.failed || !self.input) return;
    while (self.input.hasBytesAvailable) {
        uint8_t bytes[4096];
        NSInteger length = [self.input read:bytes maxLength:sizeof(bytes)];
        printf("RX time=%.6f channel=%p length=%ld bytes=", NSDate.date.timeIntervalSince1970,
               (__bridge void *)self.channel, length);
        for (NSInteger i = 0; i < MIN(length, 256); i++) printf("%s%02X", i ? " " : "", bytes[i]);
        if (length > 256) printf(" ...");
        printf("\n");
        if (length <= 0) {
            if (!length) self.inputEnded = YES;
            if (!self.closing) self.failed = YES;
            return;
        }
        if (self.raw.length + (NSUInteger)length > 65536) {
            self.failed = YES;
            return;
        }
        [self.pending appendBytes:bytes length:(NSUInteger)length];
        [self.raw appendBytes:bytes length:(NSUInteger)length];
        self.received += (NSUInteger)length;
    }
    if (self.input.streamStatus == NSStreamStatusAtEnd) self.inputEnded = YES;
    if (!self.closing && (self.input.streamStatus == NSStreamStatusError || self.inputEnded)) {
        printf("INPUT_TERMINAL time=%.6f status=%lu error=%s\n", NSDate.date.timeIntervalSince1970,
               self.input.streamStatus, self.input.streamError.description.UTF8String);
        self.failed = YES;
    }
}
@end

static NSString *ReadLine(DirectPlaybackProbe *probe, double deadline, BOOL requireLink, NSTimeInterval interval) {
    while (!probe.stdinEnded && (!requireLink || (!probe.closed && !probe.failed)) && MonotonicTime() < deadline) {
        struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&descriptor, 1, 0);
        if (ready < 0) {
            if (errno == EINTR) continue;
            probe.failed = YES;
            break;
        }
        if (descriptor.revents & (POLLIN | POLLHUP | POLLERR)) {
            char value;
            ssize_t length = read(STDIN_FILENO, &value, 1);
            if (length != 1) {
                if (length < 0 && errno == EINTR) continue;
                probe.stdinEnded = YES;
                probe.stopRequested = YES;
                printf("PARENT_INPUT_END errno=%d\n", length < 0 ? errno : 0);
                break;
            }
            if (value == '\n') {
                NSString *line = [[NSString alloc] initWithData:probe.controlPending encoding:NSUTF8StringEncoding];
                [probe.controlPending setLength:0];
                if (!line) probe.failed = YES;
                if ([line isEqualToString:@"stop"]) {
                    probe.stopRequested = YES;
                    printf("STOP_REQUESTED\n");
                }
                return line;
            }
            if (!value || probe.controlPending.length == 127) { probe.failed = YES; break; }
            [probe.controlPending appendBytes:&value length:1];
            continue;
        }
        [probe pollInput];
        RunLoopFor(interval);
    }
    return nil;
}

static NSData *ConsumeSDU(DirectPlaybackProbe *probe, NSString *line, double deadline) {
    unsigned int cid = 0, length = 0;
    char extra;
    if (sscanf(line.UTF8String, "%x %u %c", &cid, &length, &extra) != 2 ||
        !cid || cid > UINT16_MAX || length < 2 || length > 4096 ||
        (probe.realCID && probe.realCID != cid)) {
        printf("INVALID_SDU_GATE\n");
        return nil;
    }
    probe.realCID = (UInt16)cid;
    printf("SDU_GATE time=%.6f CID=%04X length=%u\n",
           NSDate.date.timeIntervalSince1970, probe.realCID, length);
    while (probe.pending.length < length && !probe.closed && !probe.failed && MonotonicTime() < deadline) {
        [probe pollInput];
        RunLoopFor(0.001);
    }
    if (probe.pending.length >= length && (probe.playback || probe.pending.length == length)) {
        NSData *reply = [probe.pending subdataWithRange:NSMakeRange(0, length)];
        [probe.pending replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        return reply;
    }
    printf("NO_FRAMED_REPLY pending=%lu closed=%d failed=%d\n",
           probe.pending.length, probe.closed, probe.failed);
    return nil;
}

static NSData *FramedReply(DirectPlaybackProbe *probe, double deadline) {
    printf("WAIT_SDU gate=realCID decimalLength deadline=30s\n");
    while (!probe.stdinEnded && MonotonicTime() < deadline) {
        NSString *line = ReadLine(probe, deadline, YES, 0.001);
        if ([line isEqualToString:@"stop"]) continue;
        return line ? ConsumeSDU(probe, line, deadline) : nil;
    }
    return nil;
}

static NSArray<NSNumber *> *DecodeReply(NSData *reply, uint8_t transaction, uint8_t signal,
                                      uint8_t seid, BOOL emit) {
    const uint8_t *bytes = reply.bytes;
    NSUInteger length = reply.length;
    if (length < 2 || bytes[0] != ((transaction << 4) | 2) || bytes[1] != signal) return nil;
    NSMutableArray<NSNumber *> *sinks = [NSMutableArray array];
    if (signal == 1) {
        if (length < 4 || (length - 2) % 2 || length > 126) return nil;
        BOOL seen[63] = {NO};
        for (NSUInteger i = 2; i < length; i += 2) {
            uint8_t endpoint = bytes[i] >> 2;
            if (!endpoint || endpoint > 62 || seen[endpoint] || bytes[i] & 1 || bytes[i + 1] & 7)
                return nil;
            seen[endpoint] = YES;
            BOOL inUse = bytes[i] & 2;
            uint8_t mediaType = bytes[i + 1] >> 4;
            BOOL sink = bytes[i + 1] & 8;
            if (emit) printf("SEP %u inUse=%d mediaType=%u sink=%d\n", endpoint, inUse, mediaType, sink);
            if (!inUse && mediaType == 0 && sink) [sinks addObject:@(endpoint)];
        }
    } else {
        BOOL seen[9] = {NO};
        for (NSUInteger offset = 2; offset < length;) {
            if (length - offset < 2) return nil;
            uint8_t category = bytes[offset++];
            uint8_t size = bytes[offset++];
            if (!category || category > 8 || seen[category] || size > length - offset) return nil;
            seen[category] = YES;
            if (category == 1 && size != 0) return nil;
            if (category == 7) {
                if (size < 2 || bytes[offset] != 0) return nil;
                if (bytes[offset + 1] == 0xFF && size < 8) return nil;
                const uint8_t ldac[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
                BOOL isLDAC = size >= sizeof(ldac) && memcmp(bytes + offset, ldac, sizeof(ldac)) == 0;
                if (isLDAC && size != 10) return nil;
            }
            offset += size;
        }
        if (!seen[1] || !seen[7]) return nil;
        if (emit) {
            for (NSUInteger offset = 2; offset < length;) {
                uint8_t category = bytes[offset++];
                uint8_t size = bytes[offset++];
                printf("CAPABILITY SEID=%u category=%u bytes=", seid, category);
                for (NSUInteger i = 0; i < size; i++) printf("%s%02X", i ? " " : "", bytes[offset + i]);
                printf("\n");
                const uint8_t ldac[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
                if (category == 7 && size == 10 && memcmp(bytes + offset, ldac, sizeof(ldac)) == 0)
                    printf("LDAC SEID=%u rates=%02X modes=%02X supportsStereo=%d\n", seid,
                           bytes[offset + 8], bytes[offset + 9],
                           !!(bytes[offset + 9] & 1));
                offset += size;
            }
        }
    }
    return sinks;
}

static BOOL SendSignal(DirectPlaybackProbe *probe, NSData *packet) {
    if (probe.closed || probe.failed || !probe.output || packet.length > (NSUInteger)MIN(probe.channel.outgoingMTU, 2570))
        return NO;
    int queue = kqueue();
    struct kevent change, state;
    struct timespec immediate = {0, 0};
    EV_SET(&change, probe.channel.socketFD, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
    int count = queue < 0 ? -1 : kevent(queue, &change, 1, &state, 1, &immediate);
    if (count != 1 || state.flags & (EV_ERROR | EV_EOF) || state.data < (intptr_t)packet.length) {
        printf("SIGNAL_WRITE_CAPACITY_FAILED errno=%d\n", errno);
        if (queue >= 0) close(queue);
        probe.failed = YES;
        return NO;
    }
    intptr_t baseline = state.data;
    const uint8_t *bytes = packet.bytes;
    printf("TX_BEGIN time=%.6f bytes=", NSDate.date.timeIntervalSince1970);
    for (NSUInteger i = 0; i < packet.length; i++) printf("%s%02X", i ? " " : "", bytes[i]);
    printf("\n");
    NSInteger sent = [probe.output write:bytes maxLength:packet.length];
    printf("TX_RETURN time=%.6f sent=%ld expected=%lu errno=%d mode=drained-stream\n",
           NSDate.date.timeIntervalSince1970, sent, packet.length, sent < 0 ? errno : 0);
    if (sent != (NSInteger)packet.length) {
        printf("PUBLIC_STREAM_WRITE_FAILED error=%s\n", probe.output.streamError.description.UTF8String);
        close(queue);
        probe.failed = YES;
        return NO;
    }
    BOOL drained = NO;
    double deadline = MonotonicTime() + 2;
    while (!probe.closed && !probe.failed && MonotonicTime() < deadline) {
        count = kevent(queue, NULL, 0, &state, 1, &immediate);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || (count == 1 && state.flags & (EV_ERROR | EV_EOF))) break;
        if (count == 1 && state.data >= baseline) { drained = YES; break; }
        [probe pollInput];
        RunLoopFor(0.001);
    }
    close(queue);
    if (!drained) {
        printf("SIGNAL_WRITE_DRAIN_FAILED baseline=%ld errno=%d closed=%d\n", (long)baseline, errno, probe.closed);
        probe.failed = YES;
    }
    return drained && !probe.closed && !probe.failed;
}

static NSData *ServiceBytes(uint32_t sampleRate, BOOL delayReporting) {
    const uint8_t bytes[] = {0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF, 0x2D, 0x01,
                             0x00, 0x00, 0xAA, 0x00, RateBit(sampleRate), 0x01, 0x08, 0x00};
    return [NSData dataWithBytes:bytes length:delayReporting ? sizeof(bytes) : sizeof(bytes) - 2];
}

static NSData *PeerReply(DirectPlaybackProbe *probe, NSData *packet) {
    const uint8_t *bytes = packet.bytes;
    if (packet.length < 2 || (bytes[0] & 15) || bytes[1] & 0xC0) return nil;
    uint8_t response[] = {(uint8_t)((bytes[0] & 0xF0) | 2), bytes[1], 0, 0};
    uint8_t error = 0;
    switch (bytes[1]) {
        case 1:
            if (packet.length != 2) { error = 0x11; break; }
            response[2] = probe.configured ? 0x06 : 0x04;
            return [NSData dataWithBytes:response length:4];
        case 2:
        case 4:
        case 12:
            if (packet.length != 3) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (bytes[1] == 4 && !probe.configured) { error = 0x31; break; }
            {
                NSMutableData *reply = [NSMutableData dataWithBytes:response length:2];
                [reply appendData:ServiceBytes(probe.sampleRate, bytes[1] == 12 || (bytes[1] == 4 && probe.delayReporting))];
                return reply;
            }
        case 6:
            if (packet.length != 3) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            error = 0x31;
            break;
        case 8:
            if (packet.length != 3) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (!probe.streamOpened) { error = 0x31; break; }
            probe.peerStopped = YES;
            probe.configured = NO;
            probe.configurationSent = NO;
            probe.streamOpened = NO;
            return [NSData dataWithBytes:response length:2];
        case 10:
            if (packet.length != 3 || bytes[2] != 0x04) return nil;
            probe.peerStopped = YES;
            probe.configured = NO;
            probe.configurationSent = NO;
            probe.streamOpened = NO;
            return [NSData dataWithBytes:response length:2];
        case 13:
            if (packet.length != 5) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (!probe.delayReporting || (!probe.configured && !probe.configurationSent)) { error = 0x31; break; }
            if (((bytes[3] << 8) | bytes[4]) > 20000) { error = 0x19; break; }
            return [NSData dataWithBytes:response length:2];
        case 3:
        case 5:
            response[0] |= 1;
            response[2] = 0;
            response[3] = 0x19;
            return [NSData dataWithBytes:response length:4];
        default:
            if (bytes[1] >= 1 && bytes[1] <= 13) return nil;
            response[0] = (bytes[0] & 0xF0) | 1;
            return [NSData dataWithBytes:response length:2];
    }
    response[0] |= 1;
    response[2] = error;
    return [NSData dataWithBytes:response length:3];
}

static BOOL HandlePeerCommand(DirectPlaybackProbe *probe, NSData *packet) {
    const uint8_t *bytes = packet.bytes;
    NSData *reply = PeerReply(probe, packet);
    if (!reply) {
        printf("PEER_COMMAND_UNSUPPORTED\n");
        return NO;
    }
    printf("PEER_COMMAND transaction=%u signal=%02X length=%lu\n", bytes[0] >> 4, bytes[1], packet.length);
    if (!SendSignal(probe, reply)) return NO;
    if (bytes[1] == 13 && packet.length == 5 && (((const uint8_t *)reply.bytes)[0] & 3) == 2)
        printf("DELAY_REPORT value=%u units=0.1ms\n", (bytes[3] << 8) | bytes[4]);
    if (probe.peerStopped) printf("STREAM_CLOSED peerSignal=%02X\n", bytes[1]);
    return YES;
}

static NSData *AwaitResponse(DirectPlaybackProbe *probe, uint8_t transaction, uint8_t signal) {
    probe.lastRejected = NO;
    double deadline = MonotonicTime() + 30;
    while (!probe.closed && !probe.failed && !probe.peerStopped && MonotonicTime() < deadline) {
        NSData *packet = FramedReply(probe, deadline);
        if (!packet) break;
        const uint8_t *bytes = packet.bytes;
        if ((bytes[0] & 15) == 0) {
            if (!HandlePeerCommand(probe, packet)) break;
            continue;
        }
        if (packet.length < 2 || bytes[0] >> 4 != transaction || bytes[1] != signal || bytes[0] & 12)
            break;
        if ((bytes[0] & 3) == 3) {
            NSUInteger expected = (signal == 3 || signal == 5 || signal == 7 || signal == 9) ? 4 : 3;
            if (signal != 10 && packet.length == expected) {
                probe.lastRejected = YES;
                printf("RESPONSE_REJECTED transaction=%u signal=%02X error=%02X\n",
                       transaction, signal, bytes[packet.length - 1]);
            }
            break;
        }
        if ((bytes[0] & 3) != 2) break;
        printf("RESPONSE_ACCEPTED transaction=%u signal=%02X length=%lu CID=%04X\n",
               transaction, signal, packet.length, probe.realCID);
        return packet;
    }
    printf("RESPONSE_FAILED transaction=%u signal=%02X rejected=%d\n", transaction, signal, probe.lastRejected);
    return nil;
}

static NSData *Query(DirectPlaybackProbe *probe, uint8_t *transaction, uint8_t signal, NSData *payload) {
    probe.lastRejected = NO;
    if (probe.stdinEnded || (probe.stopRequested && !probe.protocolCleanup)) return nil;
    double deadline = MonotonicTime() + 30;
    while (probe.pending.length && !probe.closed && !probe.failed && !probe.peerStopped) {
        NSData *packet = FramedReply(probe, deadline);
        if (!packet || !HandlePeerCommand(probe, packet)) return nil;
    }
    if (probe.closed || probe.failed || probe.peerStopped || (probe.stopRequested && !probe.protocolCleanup)) return nil;
    uint8_t label = *transaction;
    *transaction = (label + 1) & 15;
    uint8_t header[] = {(uint8_t)(label << 4), signal};
    NSMutableData *request = [NSMutableData dataWithBytes:header length:2];
    [request appendData:payload];
    if (signal == 3) probe.configurationSent = YES;
    if (!SendSignal(probe, request)) return nil;
    return AwaitResponse(probe, label, signal);
}

static BOOL EmptyAcceptance(NSData *reply) { return reply != nil && reply.length == 2; }

static BOOL WaitControl(DirectPlaybackProbe *probe, NSString *command) {
    NSTimeInterval timeout = [command isEqualToString:@"media-finished"] ? 70 : [command isEqualToString:@"media-ready"] ? 60 : 30;
#if ACOUPLET_LDAC_PROBE_ONLY
    BOOL continuous = probe.continuous && [command isEqualToString:@"media-finished"];
#else
    BOOL continuous = [command isEqualToString:@"media-finished"];
#endif
    if (continuous) printf("WAIT_CONTROL %s deadline=unbounded\n", command.UTF8String);
    else printf("WAIT_CONTROL %s deadline=%.0fs\n", command.UTF8String, timeout);
    double deadline = continuous ? INFINITY : MonotonicTime() + timeout;
    while (MonotonicTime() < deadline) {
        if (probe.stdinEnded || (probe.stopRequested && ![command isEqualToString:@"media-closed"])) break;
        NSString *line = ReadLine(probe, deadline, ![command isEqualToString:@"media-closed"], continuous ? 0.02 : 0.001);
        if (!line) break;
        if ([line isEqualToString:@"stop"]) {
            if (![command isEqualToString:@"media-closed"]) break;
            continue;
        }
        if ([line isEqualToString:@"media-failed"]) {
            printf("MEDIA_FAILED\n");
            return NO;
        }
        if (![command isEqualToString:@"media-closed"] && (probe.closed || probe.failed || probe.peerStopped))
            break;
        if ([command isEqualToString:@"media-ready"] && [line hasPrefix:@"media-ready "]) {
            unsigned int cid = 0, mtu = 0;
            char extra;
            if (sscanf(line.UTF8String, "media-ready %x %u %c", &cid, &mtu, &extra) != 2 ||
                !cid || cid > UINT16_MAX || cid == probe.realCID || mtu < 679 || mtu > UINT16_MAX) break;
            probe.mediaCID = (UInt16)cid;
            printf("MEDIA_READY CID=%04X outgoingMTU=%u\n", probe.mediaCID, mtu);
            return YES;
        }
        if ([line isEqualToString:command]) return YES;
        NSData *packet = ConsumeSDU(probe, line, deadline);
        if (!packet || !HandlePeerCommand(probe, packet) || probe.peerStopped) break;
    }
    printf("CONTROL_FAILED expected=%s closed=%d\n", command.UTF8String, probe.closed);
    return NO;
}

static BOOL LDACSelection(NSData *reply, uint32_t sampleRate, BOOL *delayReporting) {
    const uint8_t *bytes = reply.bytes;
    BOOL ldac = NO;
    *delayReporting = NO;
    for (NSUInteger offset = 2; offset < reply.length;) {
        uint8_t category = bytes[offset++];
        uint8_t size = bytes[offset++];
        const uint8_t vendor[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
        if (category == 7 && size == 10 && memcmp(bytes + offset, vendor, sizeof(vendor)) == 0)
            ldac = !!((bytes[offset + 8] & RateBit(sampleRate)) && (bytes[offset + 9] & 1));
        if (category == 8 && size == 0) *delayReporting = YES;
        offset += size;
    }
    return ldac;
}

static BOOL AwaitConnection(DirectPlaybackProbe *probe, IOBluetoothDevice *device, double deadline) {
    CBClassicManager *manager = device.classicPeer.manager;
    while (manager.state != CBManagerStatePoweredOn && !probe.stopRequested && !probe.failed && MonotonicTime() < deadline) {
        NSString *control = ReadLine(probe, MonotonicTime() + 0.001, NO, 0.001);
        if (control && ![control isEqualToString:@"stop"]) probe.failed = YES;
    }
    if (manager.state != CBManagerStatePoweredOn || probe.stopRequested || probe.failed) return NO;
    if (SonyClassicIsConnected(device)) {
        printf("SIGNALING_WAIT_ENDED reason=already-connected\n");
        return NO;
    }
    printf("SIGNALING_ARMED waitingForACL=1\n");
    BOOL aclConfirmed = NO;
    BOOL registrationIssued = NO;
    while (!probe.stopRequested && !probe.failed && MonotonicTime() < deadline) {
        NSString *control = ReadLine(probe, MonotonicTime() + 0.001, NO, 0.001);
        if (control && ![control isEqualToString:@"stop"] && ![control isEqualToString:@"acl-connected"]) probe.failed = YES;
        if (probe.stopRequested || probe.failed) break;
        if ([control isEqualToString:@"acl-connected"]) {
            if (aclConfirmed) { probe.failed = YES; break; }
            aclConfirmed = YES;
            printf("SIGNALING_ACL_CONFIRMED\n");
            probe.connectionAddress = device.addressString;
            IOReturn status = [device openConnection:probe];
            printf("SIGNALING_REGISTER_RETURN status=0x%08X\n", (unsigned int)status);
            if (status != kIOReturnSuccess) { probe.failed = YES; break; }
            registrationIssued = YES;
        }
        if (probe.connectionDone && probe.connectionStatus != kIOReturnSuccess) { probe.failed = YES; break; }
        if (aclConfirmed && probe.connectionDone && SonyClassicIsConnected(device)) {
            printf("SIGNALING_PEER_READY connected=1\n");
            return YES;
        }
    }
    if (registrationIssued && !probe.connectionDone) {
        double settleDeadline = MonotonicTime() + 5;
        while (!probe.connectionDone && MonotonicTime() < settleDeadline) RunLoopFor(0.001);
        if (!probe.connectionDone) {
            printf("OPEN_CANCELLATION_UNCONFIRMED registration=1\n");
            probe.failed = YES;
        }
    }
    printf("SIGNALING_WAIT_ENDED stopped=%d failed=%d\n", probe.stopRequested, probe.failed);
    return NO;
}

static BOOL PlaybackSequence(DirectPlaybackProbe *probe) {
    uint8_t transaction = 1;
    BOOL completed = NO;
    BOOL started = NO;
    do {
        NSData *discover = Query(probe, &transaction, 1, [NSData data]);
        NSArray<NSNumber *> *sinks = discover ? DecodeReply(discover, 1, 1, 0, YES) : nil;
        if (!sinks) break;
        BOOL capabilitiesComplete = YES;
        for (NSNumber *endpoint in sinks) {
            uint8_t seid = endpoint.unsignedCharValue;
            uint8_t encoded = seid << 2;
            uint8_t label = transaction;
            NSData *reply = Query(probe, &transaction, 12, [NSData dataWithBytes:&encoded length:1]);
            if (!reply || !DecodeReply(reply, label, 12, seid, YES)) {
                capabilitiesComplete = NO;
                break;
            }
            BOOL delayReporting = NO;
            if (!probe.selectedSink && LDACSelection(reply, probe.sampleRate, &delayReporting)) {
                probe.selectedSink = seid;
                probe.delayReporting = delayReporting;
            }
        }
        if (!capabilitiesComplete || probe.peerStopped || probe.closed || probe.failed || probe.stopRequested) break;
        if (!probe.selectedSink) {
            printf("LDAC_UNAVAILABLE rate=%u channels=2\n", probe.sampleRate);
            break;
        }
        printf("PREPARE_MEDIA\n");
        if (!WaitControl(probe, @"media-prepared")) break;
        printf("LDAC_SELECTED remoteSEID=%u localSourceSEID=1 delayReporting=%d rate=%u channels=2 quality=%s\n",
               probe.selectedSink, probe.delayReporting, probe.sampleRate, probe.quality.UTF8String);
        uint8_t seids[] = {(uint8_t)(probe.selectedSink << 2), 0x04};
        NSMutableData *configuration = [NSMutableData dataWithBytes:seids length:2];
        [configuration appendData:ServiceBytes(probe.sampleRate, probe.delayReporting)];
        NSData *reply = Query(probe, &transaction, 3, configuration);
        if (!EmptyAcceptance(reply)) {
            if (probe.lastRejected) probe.configurationSent = NO;
            break;
        }
        probe.configured = YES;
        printf("CONFIGURATION_ACCEPTED remoteSEID=%u localSourceSEID=1 rate=%u channels=2\n", probe.selectedSink, probe.sampleRate);
        if (probe.stopRequested) break;
        NSData *target = [NSData dataWithBytes:seids length:1];
        if (!EmptyAcceptance(Query(probe, &transaction, 6, target))) break;
        probe.streamOpened = YES;
        probe.mediaExpected = YES;
        printf("OPEN_ACCEPTED signalingCID=%04X remoteSEID=%u\n", probe.realCID, probe.selectedSink);
        if (probe.stopRequested) break;
        if (!WaitControl(probe, @"media-ready")) break;
        if (!EmptyAcceptance(Query(probe, &transaction, 7, target))) break;
        started = YES;
        printf("START_ACCEPTED signalingCID=%04X mediaCID=%04X\n", probe.realCID, probe.mediaCID);
        if (probe.stopRequested) break;
        if (!WaitControl(probe, @"media-finished")) break;
        if (!EmptyAcceptance(Query(probe, &transaction, 8, target))) break;
        probe.streamOpened = NO;
        probe.configured = NO;
        probe.configurationSent = NO;
        completed = YES;
        printf("STREAM_CLOSED peerSignal=00\n");
    } while (NO);
    if (!completed && !probe.closed && !probe.failed && !probe.peerStopped && probe.configurationSent) {
        uint8_t target = probe.selectedSink << 2;
        uint8_t signal = probe.streamOpened || started ? 8 : 10;
        probe.protocolCleanup = YES;
        printf("ERROR_CLEANUP signal=%02X\n", signal);
        BOOL accepted = NO;
        if (probe.stdinEnded) {
            uint8_t request[] = {(uint8_t)(transaction << 4), signal, target};
            SendSignal(probe, [NSData dataWithBytes:request length:sizeof(request)]);
            printf("PARENT_EOF_CLEANUP signal=%02X acceptance=unverified\n", signal);
        } else {
            accepted = EmptyAcceptance(Query(probe, &transaction, signal, [NSData dataWithBytes:&target length:1]));
        }
        if (accepted) {
            probe.configurationSent = NO;
            probe.configured = NO;
            probe.streamOpened = NO;
            printf("STREAM_CLOSED cleanupSignal=%02X\n", signal);
        }
    }
    if (probe.stopRequested && !probe.stdinEnded && !probe.failed && !probe.configurationSent) {
        completed = YES;
        printf("STOP_COMPLETE protocolCleanup=1\n");
    }
    if (probe.mediaExpected) {
        printf("MEDIA_CLOSE_REQUIRED CID=%04X\n", probe.mediaCID);
        printf("WAIT_MEDIA_CLOSED\n");
        if (!WaitControl(probe, @"media-closed")) {
            completed = NO;
            if (probe.stdinEnded) {
                printf("MEDIA_CLOSE_UNCONFIRMED parentEOF=1 CID=%04X\n", probe.mediaCID);
                return NO;
            }
            printf("MEDIA_CLOSE_DEADLINE no sends; retaining signaling owner until media-closed\n");
            for (;;) {
                NSString *line = ReadLine(probe, INFINITY, NO, 0.001);
                if (probe.stdinEnded) {
                    printf("MEDIA_CLOSE_UNCONFIRMED parentEOF=1 CID=%04X\n", probe.mediaCID);
                    return NO;
                }
                if ([line isEqualToString:@"media-closed"]) break;
                if ([line isEqualToString:@"stop"]) continue;
                if (line) {
                    NSData *packet = ConsumeSDU(probe, line, MonotonicTime() + 1);
                    if (packet && !probe.closed && !probe.failed) HandlePeerCommand(probe, packet);
                }
                RunLoopFor(0.05);
            }
        }
        printf("MEDIA_CLOSED_CONFIRMED CID=%04X\n", probe.mediaCID);
    }
    return completed || (probe.mediaExpected && probe.peerStopped && !probe.failed && !probe.stdinEnded &&
                         !probe.configurationSent && !probe.pending.length);
}

static BOOL SelfTest(void) {
    const uint8_t discover[] = {0x12, 0x01, 0x04, 0x08, 0x08, 0x08, 0x0C, 0x08};
    const uint8_t caps[] = {0x22, 0x0C, 0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF,
                           0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, 0x10, 0x01};
    NSData *endpoints = [NSData dataWithBytes:discover length:sizeof(discover)];
    NSData *capabilities = [NSData dataWithBytes:caps length:sizeof(caps)];
    BOOL passed = [DecodeReply(endpoints, 1, 1, 0, NO) isEqualToArray:@[@1, @2, @3]] &&
        DecodeReply(capabilities, 2, 12, 1, NO) != nil &&
        DecodeReply(endpoints, 2, 1, 0, NO) == nil &&
        DecodeReply(capabilities, 2, 2, 1, NO) == nil &&
        DecodeReply([endpoints subdataWithRange:NSMakeRange(0, endpoints.length - 1)], 1, 1, 0, NO) == nil &&
        DecodeReply([capabilities subdataWithRange:NSMakeRange(0, capabilities.length - 1)], 2, 12, 1, NO) == nil &&
        DecodeReply([endpoints subdataWithRange:NSMakeRange(0, 2)], 1, 1, 0, NO) == nil;
    DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
    probe.sampleRate = 48000;
    probe.quality = @"low";
    const uint8_t command[] = {0x20, 0x01};
    const uint8_t freeSEP[] = {0x22, 0x01, 0x04, 0x00};
    const uint8_t usedSEP[] = {0x22, 0x01, 0x06, 0x00};
    NSData *request = [NSData dataWithBytes:command length:sizeof(command)];
    passed &= [PeerReply(probe, request) isEqualToData:[NSData dataWithBytes:freeSEP length:sizeof(freeSEP)]];
    probe.configured = YES;
    passed &= [PeerReply(probe, request) isEqualToData:[NSData dataWithBytes:usedSEP length:sizeof(usedSEP)]];
    const uint8_t delay[] = {0x30, 0x0D, 0x04, 0x00, 0x64};
    const uint8_t unnegotiatedDelayReject[] = {0x33, 0x0D, 0x31};
    passed &= [PeerReply(probe, [NSData dataWithBytes:delay length:sizeof(delay)])
        isEqualToData:[NSData dataWithBytes:unnegotiatedDelayReject length:sizeof(unnegotiatedDelayReject)]];
    probe.delayReporting = YES;
    const uint8_t delayAccept[] = {0x32, 0x0D};
    passed &= [PeerReply(probe, [NSData dataWithBytes:delay length:sizeof(delay)])
        isEqualToData:[NSData dataWithBytes:delayAccept length:sizeof(delayAccept)]];
    const uint8_t configurationQuery[] = {0x50, 0x04, 0x04};
    passed &= PeerReply(probe, [NSData dataWithBytes:configurationQuery length:sizeof(configurationQuery)]).length == 18;
    const uint8_t invalidDelay[] = {0x30, 0x0D, 0x04, 0xFF, 0xFF};
    const uint8_t invalidDelayReject[] = {0x33, 0x0D, 0x19};
    passed &= [PeerReply(probe, [NSData dataWithBytes:invalidDelay length:sizeof(invalidDelay)])
        isEqualToData:[NSData dataWithBytes:invalidDelayReject length:sizeof(invalidDelayReject)]];
    const uint8_t shortDelay[] = {0x30, 0x0D, 0x04, 0x00};
    const uint8_t shortDelayReject[] = {0x33, 0x0D, 0x11};
    passed &= [PeerReply(probe, [NSData dataWithBytes:shortDelay length:sizeof(shortDelay)])
        isEqualToData:[NSData dataWithBytes:shortDelayReject length:sizeof(shortDelayReject)]];
    probe.configured = NO;
    const uint8_t delayReject[] = {0x33, 0x0D, 0x31};
    passed &= [PeerReply(probe, [NSData dataWithBytes:delay length:sizeof(delay)])
        isEqualToData:[NSData dataWithBytes:delayReject length:sizeof(delayReject)]];
    probe.configured = YES;
    probe.configurationSent = YES;
    probe.streamOpened = YES;
    const uint8_t close[] = {0x40, 0x08, 0x04};
    const uint8_t closeAccept[] = {0x42, 0x08};
    passed &= [PeerReply(probe, [NSData dataWithBytes:close length:sizeof(close)])
        isEqualToData:[NSData dataWithBytes:closeAccept length:sizeof(closeAccept)]] &&
        probe.peerStopped && !probe.configured && !probe.configurationSent && !probe.streamOpened;
    const uint8_t actualCaps[] = {0x42, 0x0C, 0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF, 0x2D,
                                 0x01, 0x00, 0x00, 0xAA, 0x00, 0x3C, 0x07, 0x04, 0x02,
                                 0x02, 0x00, 0x08, 0x00};
    NSData *actual = [NSData dataWithBytes:actualCaps length:sizeof(actualCaps)];
    const uint8_t sbcCaps[] = {0x22, 0x0C, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F,
                              0xFF, 0x02, 0x23, 0x04, 0x02, 0x02, 0x00, 0x08, 0x00};
    const uint8_t aacCaps[] = {0x32, 0x0C, 0x01, 0x00, 0x07, 0x08, 0x00, 0x02, 0x80,
                              0x01, 0x8C, 0x82, 0xEE, 0x00, 0x04, 0x02, 0x02, 0x00, 0x08, 0x00};
    NSData *sbc = [NSData dataWithBytes:sbcCaps length:sizeof(sbcCaps)];
    NSData *aac = [NSData dataWithBytes:aacCaps length:sizeof(aacCaps)];
    passed &= DecodeReply(sbc, 2, 12, 1, NO) != nil && DecodeReply(aac, 3, 12, 2, NO) != nil;
    BOOL hasDelay = NO;
    passed &= DecodeReply(actual, 4, 12, 3, NO) != nil && LDACSelection(actual, 48000, &hasDelay) && hasDelay;
    probe.delayReporting = NO;
    const uint32_t rates[] = {44100, 48000, 88200, 96000};
    for (NSUInteger rate = 0; rate < 4; rate++) {
        probe.sampleRate = rates[rate];
        probe.configured = YES;
        passed &= LDACSelection(actual, rates[rate], &hasDelay) && hasDelay;
        passed &= LDACSelection(capabilities, rates[rate], &hasDelay) == (rates[rate] == 48000);
        passed &= !LDACSelection(sbc, rates[rate], &hasDelay) && !LDACSelection(aac, rates[rate], &hasDelay);
        const uint8_t signals[] = {2, 4, 12};
        for (NSUInteger index = 0; index < 3; index++) {
            uint8_t signal = signals[index];
            uint8_t query[] = {0x50, signal, 0x04};
            NSData *reply = PeerReply(probe, [NSData dataWithBytes:query length:sizeof(query)]);
            const uint8_t *bytes = reply.bytes;
            passed &= reply.length == (signal == 12 ? 18 : 16) && bytes[0] == 0x52 && bytes[1] == signal &&
                bytes[14] == RateBit(rates[rate]) && bytes[15] == 1 &&
                DecodeReply(reply, 5, signal, 1, NO) != nil;
            NSData *services = ServiceBytes(rates[rate], NO);
            passed &= [[reply subdataWithRange:NSMakeRange(2, services.length)] isEqualToData:services];
        }
    }
    uint32_t parsedRate = 0;
    passed &= ParseSampleRate("44100", &parsedRate) && parsedRate == 44100 &&
        !ParseSampleRate("96000x", &parsedRate) && !ParseSampleRate("32000", &parsedRate) &&
        !ParseSampleRate("4294967296", &parsedRate);
    passed &= !EmptyAcceptance(actual) && EmptyAcceptance([NSData dataWithBytes:closeAccept length:2]);
    probe.pending = [NSMutableData data];
    probe.raw = [NSMutableData data];
    probe.playback = YES;
    probe.realCID = 0x500C;
    probe.closing = YES;
    NSData *closingSDU = [NSData dataWithBytes:closeAccept length:sizeof(closeAccept)];
    probe.input = [NSInputStream inputStreamWithData:closingSDU];
    [probe.input open];
    passed &= [ConsumeSDU(probe, @"0x500C 2", MonotonicTime() + 1) isEqualToData:closingSDU] &&
        !probe.failed && !probe.pending.length && [probe.raw isEqualToData:closingSDU];
    [probe.input close];
    probe.input = [NSInputStream inputStreamWithData:[NSData data]];
    [probe.input open];
    uint8_t emptyByte;
    [probe.input read:&emptyByte maxLength:1];
    probe.closing = YES;
    [probe pollInput];
    passed &= !probe.failed;
    probe.closing = NO;
    [probe pollInput];
    passed &= probe.failed;
    [probe.input close];
    return passed;
}

static void WaitTransportClosed(DirectPlaybackProbe *probe) {
    printf("WAIT_TRANSPORT_CLOSED CID=%04X\n", probe.realCID);
    double deadline = MonotonicTime() + 2;
    BOOL warned = NO;
    while (!probe.closed) {
        NSString *line = ReadLine(probe, MonotonicTime() + 0.25, NO, 0.001);
        if ([line isEqualToString:@"transport-closed"]) {
            probe.closed = YES;
            printf("TRANSPORT_CLOSED_CONFIRMED time=%.6f CID=%04X source=daemon-gate\n",
                   NSDate.date.timeIntervalSince1970, probe.realCID);
        } else if ([line isEqualToString:@"stop"]) {
            continue;
        } else if (line) {
            NSData *packet = ConsumeSDU(probe, line, MonotonicTime() + 1);
            if (packet) {
                printf("CLOSING_SDU CID=%04X length=%lu replies=0\n", probe.realCID, packet.length);
            } else {
                printf("UNEXPECTED_TRANSPORT_CLOSE_CONTROL line=%s\n", line.UTF8String);
                probe.failed = YES;
            }
        }
        [probe pollInput];
        if (probe.stdinEnded && probe.inputEnded) {
            probe.closed = YES;
            printf("TRANSPORT_CLOSED_CONFIRMED time=%.6f CID=%04X source=owned-input-eof\n",
                   NSDate.date.timeIntervalSince1970, probe.realCID);
        }
        if (probe.stdinEnded && !probe.closed && MonotonicTime() >= deadline) {
            printf("TRANSPORT_CLOSE_UNCONFIRMED CID=%04X parentEOF=1 closeRequested=1\n", probe.realCID);
            probe.failed = YES;
            break;
        }
        if (!probe.closed && !warned && MonotonicTime() >= deadline) {
            printf("CLOSE_PENDING retaining channel and coordinator until callback or transport-closed\n");
            warned = YES;
        }
        if (!probe.closed) RunLoopFor(0.001);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            BOOL passed = SelfTest();
            printf("offline parser checks=%s\n", passed ? "PASS" : "FAIL");
            return passed ? 0 : 1;
        }
        BOOL playback = argc >= 3 && strcmp(argv[1], "--playback-disconnected") == 0;
#if ACOUPLET_LDAC_PROBE_ONLY
        BOOL capabilities = argc >= 3 && strcmp(argv[1], "--capabilities-disconnected") == 0;
        BOOL discover = argc >= 2 && (strcmp(argv[1], "--discover") == 0 || strcmp(argv[1], "--discover-disconnected") == 0);
#endif
        NSString *address = nil;
        uint32_t sampleRate = 48000;
        NSString *quality = @"low";
        BOOL addressSeen = NO;
        BOOL rateSeen = NO, qualitySeen = NO;
        BOOL continuous = NO;
        BOOL waitForConnection = NO;
#if ACOUPLET_LDAC_PROBE_ONLY
        BOOL argumentsValid = capabilities || playback || discover;
        int firstOption = capabilities || playback ? 3 : 2;
#else
        BOOL argumentsValid = playback;
        int firstOption = 3;
#endif
        for (int index = firstOption; argumentsValid && index < argc; index++) {
            if (!strcmp(argv[index], "--address") && !addressSeen && index + 1 < argc) {
                address = NormalizeAddress(argv[++index]);
                addressSeen = YES;
                argumentsValid = address != nil;
            } else if (!strcmp(argv[index], "--continuous") && playback && !continuous) {
                continuous = YES;
            } else if (!strcmp(argv[index], "--wait-for-connection") && playback && !waitForConnection) {
                waitForConnection = YES;
            } else if (!strcmp(argv[index], "--sample-rate") && !rateSeen && index + 1 < argc) {
                argumentsValid = ParseSampleRate(argv[++index], &sampleRate);
                rateSeen = YES;
            } else if (!strcmp(argv[index], "--quality") && !qualitySeen && index + 1 < argc) {
                quality = [NSString stringWithUTF8String:argv[++index]];
                argumentsValid = quality && [@[@"auto", @"low", @"mid", @"high"] containsObject:quality];
                qualitySeen = YES;
            } else argumentsValid = NO;
        }
#if !ACOUPLET_LDAC_PROBE_ONLY
        argumentsValid &= continuous;
#endif
        if (!argumentsValid || !addressSeen) {
#if ACOUPLET_LDAC_PROBE_ONLY
            fprintf(stderr, "Usage: %s --discover|--discover-disconnected OR --capabilities-disconnected|--playback-disconnected received.bin --address XX-XX-XX-XX-XX-XX [--continuous for playback] [--wait-for-connection for playback] [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high]\n", argv[0]);
#else
            fprintf(stderr, "Usage: %s --playback-disconnected received.bin --address XX-XX-XX-XX-XX-XX --continuous [--wait-for-connection] [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high]\n", argv[0]);
#endif
            return 2;
        }
        if (!LDACWatchParent(20)) return 3;
        setbuf(stdout, NULL);
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        printf("BEFORE time=%.6f device=%p address=%s paired=%d connected=%d\n",
               NSDate.date.timeIntervalSince1970, (__bridge void *)device,
               device.addressString.UTF8String, device.isPaired, SonyClassicIsConnected(device));
        if (!device || !device.isPaired || (!waitForConnection && !SonyClassicIsConnected(device))) {
            printf("NO_OPEN direct stream acquisition requires an already-paired connected target\n");
            return 3;
        }
        DirectPlaybackProbe *probe __attribute__((objc_precise_lifetime)) = [DirectPlaybackProbe new];
        probe.pending = [NSMutableData data];
        probe.raw = [NSMutableData data];
        probe.controlPending = [NSMutableData data];
        probe.playback = playback;
        probe.continuous = continuous;
        probe.sampleRate = sampleRate;
        probe.quality = quality;
        CBClassicPeer *peer __attribute__((objc_precise_lifetime)) = device.classicPeer;
        if (!peer) {
            printf("NO_OPEN coordinator returned no Classic peer\n");
            return 4;
        }
        printf("SCOPE direct Classic coordinator stream owner; historical disconnected CLI requires connected ACL\n");
        printf("TARGET owner=IOBluetoothCoordinator address=%s UUID=%s\n", device.addressString.UTF8String,
               peer.identifier.UUIDString.UTF8String);
        __block BOOL openDone = NO;
        __block NSInteger openError = 0;
        void (^opened)(CBL2CAPChannel *, NSInteger) = ^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                printf("OPEN_CALLBACK time=%.6f status=0x%08X\n", NSDate.date.timeIntervalSince1970, (unsigned int)error);
                PrintChannel("OPEN_CALLBACK_CHANNEL", value);
                if (openDone || (value && value.PSM != 0x0019)) {
                    probe.failed = YES;
                    openError = -1;
                    openDone = YES;
                    return;
                }
                probe.channel = value;
                probe.realCID = value.cid;
                openError = error;
                openDone = YES;
            });
        };
        void (^closed)(CBL2CAPChannel *, NSInteger) = ^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PrintChannel("CLOSED_CALLBACK", value);
                printf("DIRECT_CLOSE_CALLBACK status=0x%08X\n", (unsigned int)error);
                if (probe.channel && value && value.PSM == 0x0019 && value.cid == probe.realCID)
                    probe.closed = YES;
            });
        };
        DirectSignalingCallbacks *callbacks __attribute__((objc_precise_lifetime)) =
            [[DirectSignalingCallbacks alloc] initWithPeer:peer opened:opened closed:closed];
        if (!callbacks) {
            printf("NO_OPEN coordinator callbacks unavailable\n");
            return 4;
        }
        if (waitForConnection && !AwaitConnection(probe, device, MonotonicTime() + 45)) {
            [callbacks invalidate];
            return probe.stopRequested && !probe.stdinEnded && !probe.failed ? 0 : 5;
        }
        NSString *initialControl = playback ? ReadLine(probe, MonotonicTime() + 0.001, NO, 0.001) : nil;
        if (initialControl && ![initialControl isEqualToString:@"stop"]) probe.failed = YES;
        printf("OPEN_BEGIN time=%.6f PSM=0019\n", NSDate.date.timeIntervalSince1970);
        if (!probe.stopRequested && !probe.failed) [peer openL2CAPChannel:0x0019];
        else openDone = YES;
        double openDeadline = MonotonicTime() + 5;
        while (!openDone && !probe.stopRequested && !probe.failed && MonotonicTime() < openDeadline) {
            NSString *control = playback ? ReadLine(probe, MonotonicTime() + 0.001, NO, 0.001) : nil;
            if (control && ![control isEqualToString:@"stop"]) probe.failed = YES;
            RunLoopFor(0.001);
        }
        BOOL openExpired = !openDone;
        if (openExpired) {
            printf("OPEN_DEADLINE no sends; retaining owner until terminal open callback\n");
            double cancelDeadline = MonotonicTime() + 5;
            while (!openDone) {
                NSString *control = playback ? ReadLine(probe, MonotonicTime() + 0.001, NO, 0.001) : nil;
                if (control && ![control isEqualToString:@"stop"]) probe.failed = YES;
                if ((probe.stopRequested || probe.failed) && MonotonicTime() >= cancelDeadline) {
                    printf("OPEN_CANCELLATION_UNCONFIRMED callback=0\n");
                    probe.failed = YES;
                    break;
                }
                RunLoopFor(0.05);
            }
        }
        printf("OPEN_RETURN time=%.6f status=0x%08X paired=%d connected=%d\n",
               NSDate.date.timeIntervalSince1970, (unsigned int)openError, device.isPaired, SonyClassicIsConnected(device));
        CBL2CAPChannel *channel __attribute__((objc_precise_lifetime)) = probe.channel;
        PrintChannel("RETURNED_CHANNEL", channel);
        int result = probe.stopRequested && !probe.stdinEnded && !probe.failed ? 0 : 5;
        if (channel) {
            printf("OWNED_CHANNEL time=%.6f channel=%p CID=%04X outgoingMTU=%u\n",
                   NSDate.date.timeIntervalSince1970, (__bridge void *)channel, channel.cid, channel.outgoingMTU);
        }
        if (!openExpired && !openError && channel && channel.PSM == 0x0019 && probe.realCID &&
            channel.outgoingMTU >= 2 && !probe.closed && !probe.failed && !probe.stopRequested) {
            probe.input = channel.inputStream;
            probe.output = channel.outputStream;
            [probe.input open];
            [probe.output open];
            printf("SIGNAL_WRITER fd=%d MTU=%u mode=drained-stream\n", channel.socketFD, channel.outgoingMTU);
#if ACOUPLET_LDAC_PROBE_ONLY
            if (playback) {
                result = PlaybackSequence(probe) ? 0 : 5;
            } else if (capabilities) {
                NSArray<NSNumber *> *sinks = @[];
                for (NSUInteger index = 0; index <= sinks.count; index++) {
                    uint8_t transaction = (uint8_t)(index + 1);
                    uint8_t signal = index ? 0x0C : 1;
                    uint8_t seid = index ? sinks[index - 1].unsignedCharValue : 0;
                    uint8_t packet[] = {(uint8_t)(transaction << 4), signal, (uint8_t)(seid << 2)};
                    UInt16 packetLength = index ? 3 : 2;
                    if (index >= 15 || probe.closed || probe.failed || probe.pending.length ||
                        probe.stopRequested ||
                        channel != probe.channel || channel.PSM != 0x0019 || channel.outgoingMTU < packetLength) break;
                    if (!SendSignal(probe, [NSData dataWithBytes:packet length:packetLength])) break;
                    NSData *reply = FramedReply(probe, MonotonicTime() + 30);
                    NSArray<NSNumber *> *decoded = reply ? DecodeReply(reply, transaction, signal, seid, YES) : nil;
                    if (!decoded) {
                        printf("RESPONSE_INVALID transaction=%u signal=%02X SEID=%u\n", transaction, signal, seid);
                        break;
                    }
                    printf("RESPONSE_ACCEPTED transaction=%u signal=%02X SEID=%u length=%lu CID=%04X\n",
                           transaction, signal, seid, reply.length, probe.realCID);
                    if (!index) sinks = decoded;
                    if (index == sinks.count) result = 0;
                }
            } else {
                const uint8_t request[] = {0x10, 0x01};
                if (SendSignal(probe, [NSData dataWithBytes:request length:sizeof(request)])) {
                    double deadline = MonotonicTime() + 3;
                    while (!probe.closed && !probe.failed && MonotonicTime() < deadline) {
                        [probe pollInput];
                        RunLoopFor(0.001);
                    }
                    if (probe.received) result = 0;
                }
            }
#else
            result = PlaybackSequence(probe) ? 0 : 5;
#endif
            printf("SIGNAL_WRITER_RESTORE restored=1 closed=%d mode=drained-stream optionsChanged=0\n", probe.closed);
        } else {
            printf("NO_PLAYBACK realCID=%04X owned=%p openExpired=%d openError=%ld\n",
                   probe.realCID, (__bridge void *)channel, openExpired, openError);
        }
        if (channel && !probe.closed) {
            printf("CLOSE_BEGIN time=%.6f\n", NSDate.date.timeIntervalSince1970);
            probe.closing = YES;
            [peer closeL2CAPChannel:0x0019];
            printf("CLOSE_RETURN time=%.6f requested=1\n", NSDate.date.timeIntervalSince1970);
            WaitTransportClosed(probe);
        }
        [probe.input close];
        [probe.output close];
        [callbacks invalidate];
        printf("DELEGATE_CLEAR time=%.6f status=0x%08X\n", NSDate.date.timeIntervalSince1970, 0);
#if ACOUPLET_LDAC_PROBE_ONLY
        if (capabilities || playback) {
#else
        {
#endif
            NSError *error = nil;
            BOOL saved = [probe.raw writeToFile:[NSString stringWithUTF8String:argv[2]]
                                       options:NSDataWritingAtomic error:&error];
            printf("RAW_SAVE path=%s bytes=%lu saved=%d\n", argv[2], probe.raw.length, saved);
            if (!saved) {
                fprintf(stderr, "%s\n", error.description.UTF8String);
                result = 5;
            }
            if (probe.failed || probe.pending.length) result = 5;
        }
        printf("AFTER time=%.6f result=%d received=%lu closed=%d paired=%d connected=%d\n",
               NSDate.date.timeIntervalSince1970, result, probe.received, probe.closed,
               device.isPaired, SonyClassicIsConnected(device));
        return result;
    }
}
