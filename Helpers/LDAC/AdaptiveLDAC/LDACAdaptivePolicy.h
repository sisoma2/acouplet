#ifndef LDAC_ADAPTIVE_POLICY_H
#define LDAC_ADAPTIVE_POLICY_H

#include <math.h>
#include <stdbool.h>
#include "ldacBT.h"

typedef struct {
    double healthySeconds;
    double promotionSeconds;
    double minimumDrainBudgetSeconds;
    double schedulerGapLimitSeconds;
    double congestionSeconds;
    double lastObservationSeconds;
    bool congestionBackoff;
    double deficitSeconds;
    double previousLatenessSeconds;
} LDACAdaptivePolicy;

static inline LDACAdaptivePolicy LDACAdaptivePolicyInit(void) {
    return (LDACAdaptivePolicy){.promotionSeconds = 15, .minimumDrainBudgetSeconds = 0.012,
        .schedulerGapLimitSeconds = 0.020, .previousLatenessSeconds = -1};
}

static inline int LDACAdaptivePolicyObserve(LDACAdaptivePolicy *policy, int eqmid,
        double packetAudioSeconds, double writeAndDrainSeconds,
        double maximumSchedulerGapSeconds, double pacingLatenessSeconds, bool sourceReady,
        double queuedAudioSeconds, double observationSeconds) {
    double observedSeconds = policy->lastObservationSeconds > 0 ?
        fmin(packetAudioSeconds, fmax(0, observationSeconds - policy->lastObservationSeconds)) : 0;
    policy->lastObservationSeconds = observationSeconds;
    if (!sourceReady || maximumSchedulerGapSeconds > policy->schedulerGapLimitSeconds) {
        policy->healthySeconds = 0;
        policy->congestionSeconds = 0;
        policy->deficitSeconds = 0;
        policy->previousLatenessSeconds = -1;
        return 0;
    }
    if (policy->previousLatenessSeconds >= 0)
        policy->deficitSeconds = fmax(0, policy->deficitSeconds + pacingLatenessSeconds - policy->previousLatenessSeconds);
    policy->previousLatenessSeconds = pacingLatenessSeconds;
    bool accumulatedDeficit = policy->deficitSeconds > 0.020 && pacingLatenessSeconds > 0.020;
    bool delayed = writeAndDrainSeconds > fmax(policy->minimumDrainBudgetSeconds, packetAudioSeconds);
    bool congested = writeAndDrainSeconds >= 0.040 || queuedAudioSeconds >= 0.040 || accumulatedDeficit;
    if (delayed || congested) {
        policy->healthySeconds = 0;
        policy->congestionSeconds += observedSeconds;
        if (!congested && policy->congestionSeconds < 0.060) return 0;
        policy->congestionSeconds = 0;
        policy->deficitSeconds = 0;
        if (!policy->congestionBackoff) {
            policy->promotionSeconds = fmin(120, fmax(30, policy->promotionSeconds * 2));
            policy->congestionBackoff = true;
        }
        return eqmid == LDACBT_EQMID_MQ ? 0 : LDACBT_EQMID_INC_CONNECTION;
    }
    policy->congestionSeconds = 0;
    if (pacingLatenessSeconds > policy->minimumDrainBudgetSeconds || queuedAudioSeconds > packetAudioSeconds) {
        policy->healthySeconds = 0;
        return 0;
    }
    if (writeAndDrainSeconds > fmax(0.006, packetAudioSeconds / 2)) {
        policy->healthySeconds = fmax(0, policy->healthySeconds - observedSeconds);
        return 0;
    }
    policy->healthySeconds += observedSeconds;
    if (policy->healthySeconds < policy->promotionSeconds) return 0;
    policy->healthySeconds = 0;
    policy->congestionBackoff = false;
    return eqmid == LDACBT_EQMID_HQ ? 0 : LDACBT_EQMID_INC_QUALITY;
}

#endif
