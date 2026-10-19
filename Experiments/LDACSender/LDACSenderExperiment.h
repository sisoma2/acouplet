#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { LDACPacketWindowMaximum = 16, LDACTraceCapacity = 65536 };

typedef enum {
    LDACTraceEnqueue,
    LDACTraceSubmit,
    LDACTraceReturn,
    LDACTraceSocketDrain,
    LDACTraceAPIComplete
} LDACTraceEvent;

typedef struct {
    uint64_t packet, fingerprint;
    uint32_t rtp;
    uint16_t sequence, length;
    LDACTraceEvent event;
    double at;
    long status;
} LDACPacketTraceRecord;

typedef struct {
    LDACPacketTraceRecord *records;
    NSUInteger count, dropped;
    double start, end, wall;
} LDACPacketTrace;

static uint64_t LDACPacketFingerprint(const uint8_t *bytes, NSUInteger length) {
    uint64_t value = UINT64_C(14695981039346656037);
    for (NSUInteger index = 0; index < length; index++) value = (value ^ bytes[index]) * UINT64_C(1099511628211);
    return value;
}

static BOOL LDACPacketTraceInit(LDACPacketTrace *trace, unsigned int seconds, double start, double wall) {
    *trace = (LDACPacketTrace){.start = start, .end = start + seconds, .wall = wall};
    if (seconds) trace->records = calloc(LDACTraceCapacity, sizeof(LDACPacketTraceRecord));
    return !seconds || trace->records != NULL;
}

static void LDACPacketTraceAppend(LDACPacketTrace *trace, LDACTraceEvent event, uint64_t packet,
                                  const uint8_t *bytes, NSUInteger length, double at, long status) {
    if (!trace->records || at > trace->end || length < 13 || length > UINT16_MAX) return;
    if (trace->count == LDACTraceCapacity) { trace->dropped++; return; }
    trace->records[trace->count++] = (LDACPacketTraceRecord){
        .packet = packet, .fingerprint = LDACPacketFingerprint(bytes, length),
        .rtp = (uint32_t)bytes[4] << 24 | (uint32_t)bytes[5] << 16 | (uint32_t)bytes[6] << 8 | bytes[7],
        .sequence = (uint16_t)bytes[2] << 8 | bytes[3], .length = (uint16_t)length,
        .event = event, .at = at, .status = status
    };
}

static void LDACPacketTraceFinish(LDACPacketTrace *trace, FILE *output) {
    if (!trace->records) return;
    const char *names[] = {"enqueue", "submit", "return", "socket-drain", "api-complete"};
    fprintf(output, "PACKET_TRACE_BEGIN monotonic=%.9f wall=%.9f seconds=%.3f records=%lu dropped=%lu controllerCompletion=external-hci\n",
        trace->start, trace->wall, trace->end - trace->start, trace->count, trace->dropped);
    for (NSUInteger index = 0; index < trace->count; index++) {
        LDACPacketTraceRecord record = trace->records[index];
        fprintf(output, "PACKET_TRACE event=%s packet=%llu sequence=%u rtp=%u length=%u fingerprint=%016llX monotonic=%.9f status=%ld\n",
            names[record.event], record.packet, record.sequence, record.rtp, record.length, record.fingerprint, record.at, record.status);
    }
    fprintf(output, "PACKET_TRACE_END records=%lu dropped=%lu\n", trace->count, trace->dropped);
    if (fflush(output) != 0 || ferror(output)) printf("PACKET_TRACE_WRITE_FAILED errno=%d\n", errno);
    free(trace->records);
    trace->records = NULL;
}

typedef struct {
    uint64_t packet;
    BOOL used, complete;
    double at;
    long status;
    char domain[96];
} LDACPacketCompletion;

@interface LDACPacketCompletions : NSObject {
    NSLock *_lock;
    LDACPacketCompletion _slots[LDACPacketWindowMaximum];
}
- (BOOL)registerPacket:(uint64_t)packet;
- (void)completePacket:(uint64_t)packet at:(double)at status:(long)status;
- (void)completePacket:(uint64_t)packet at:(double)at status:(long)status domain:(NSString *)domain;
- (BOOL)takePacket:(uint64_t)packet completion:(LDACPacketCompletion *)completion;
@end

@implementation LDACPacketCompletions
- (instancetype)init {
    if ((self = [super init])) _lock = [NSLock new];
    return self;
}
- (BOOL)registerPacket:(uint64_t)packet {
    [_lock lock];
    LDACPacketCompletion *slot = &_slots[packet % LDACPacketWindowMaximum];
    BOOL available = !slot->used;
    if (available) *slot = (LDACPacketCompletion){.packet = packet, .used = YES};
    [_lock unlock];
    return available;
}
- (void)completePacket:(uint64_t)packet at:(double)at status:(long)status {
    [self completePacket:packet at:at status:status domain:nil];
}
- (void)completePacket:(uint64_t)packet at:(double)at status:(long)status domain:(NSString *)domain {
    [_lock lock];
    LDACPacketCompletion *slot = &_slots[packet % LDACPacketWindowMaximum];
    if (slot->used && slot->packet == packet && !slot->complete) {
        slot->at = at;
        slot->status = status;
        if (domain) snprintf(slot->domain, sizeof(slot->domain), "%s", domain.UTF8String);
        slot->complete = YES;
    }
    [_lock unlock];
}
- (BOOL)takePacket:(uint64_t)packet completion:(LDACPacketCompletion *)completion {
    [_lock lock];
    LDACPacketCompletion *slot = &_slots[packet % LDACPacketWindowMaximum];
    BOOL ready = slot->used && slot->packet == packet && slot->complete;
    if (ready) { *completion = *slot; slot->used = NO; }
    [_lock unlock];
    return ready;
}
@end
