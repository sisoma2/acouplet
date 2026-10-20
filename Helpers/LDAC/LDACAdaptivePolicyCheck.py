import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
fixture = r"""
#include <assert.h>
#include <stdio.h>
#include "AdaptiveLDAC/LDACAdaptivePolicy.h"

static int Observe(LDACAdaptivePolicy *policy, int eqmid, double *now, double drain,
        double gap, double lateness, bool ready, double queued) {
    *now += 0.008;
    return LDACAdaptivePolicyObserve(policy, eqmid, 0.008, drain, gap, lateness, ready, queued, *now);
}

static void Healthy(LDACAdaptivePolicy *policy, int eqmid, double *now, double seconds) {
    for (int index = 0; index < (int)(seconds / 0.008); index++)
        assert(Observe(policy, eqmid, now, 0.001, 0.001, 0, true, 0) == 0);
}

static void CheckPolicy(void) {
    double now = 1;
    LDACAdaptivePolicy policy = LDACAdaptivePolicyInit();
    Healthy(&policy, LDACBT_EQMID_MQ, &now, 6);
    assert(Observe(&policy, LDACBT_EQMID_SQ, &now, 0.018, 0.001, 0, true, 0) == 0);
    Healthy(&policy, LDACBT_EQMID_SQ, &now, 1);
    int demotions = 0;
    for (int index = 0; index < 10; index++)
        demotions += Observe(&policy, LDACBT_EQMID_SQ, &now, 0.018, 0.001, 0, true, 0) == LDACBT_EQMID_INC_CONNECTION;
    assert(demotions == 1 && policy.promotionSeconds == 30);
    assert(Observe(&policy, LDACBT_EQMID_SQ, &now, 0.045, 0.001, 0, true, 0) == LDACBT_EQMID_INC_CONNECTION);
    assert(policy.promotionSeconds == 30);
    assert(Observe(&policy, LDACBT_EQMID_MQ, &now, 0.045, 0.001, 0, true, 0) == 0);
    Healthy(&policy, LDACBT_EQMID_MQ, &now, 29);
    int promotions = 0;
    for (int index = 0; index < 150; index++)
        promotions += Observe(&policy, LDACBT_EQMID_MQ, &now, 0.001, 0.001, 0, true, 0) == LDACBT_EQMID_INC_QUALITY;
    assert(promotions == 1);
    assert(Observe(&policy, LDACBT_EQMID_SQ, &now, 0.001, 0.001, 0, true, 0.048) == LDACBT_EQMID_INC_CONNECTION);
    assert(policy.promotionSeconds == 60);
    for (int episode = 0; episode < 3; episode++) {
        policy.congestionBackoff = false;
        assert(Observe(&policy, LDACBT_EQMID_SQ, &now, 0.045, 0.001, 0, true, 0) == LDACBT_EQMID_INC_CONNECTION);
    }
    assert(policy.promotionSeconds == 120);

    policy = LDACAdaptivePolicyInit();
    assert(Observe(&policy, LDACBT_EQMID_HQ, &now, 0.050, 0.050, 0, true, 0.050) == 0);
    assert(Observe(&policy, LDACBT_EQMID_HQ, &now, 0.050, 0.001, 0, false, 0.050) == 0);
    assert(policy.promotionSeconds == 15);
    for (int index = 0; index < 5000; index++) {
        assert(Observe(&policy, LDACBT_EQMID_MQ, &now, 0.001, 0.001, 0.025, true, 0) == 0);
        assert(Observe(&policy, LDACBT_EQMID_MQ, &now, 0.010, 0.001, 0, true, 0) == 0);
        assert(Observe(&policy, LDACBT_EQMID_MQ, &now, 0.001, 0.001, 0, true, 0.008) == 0);
    }
    for (int index = 0; index < 5000; index++)
        assert(LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_MQ, 0.008, 0.001, 0.001, 0, true, 0, now) == 0);
    assert(policy.healthySeconds == 0);
    Healthy(&policy, LDACBT_EQMID_MQ, &now, 14);
    promotions = 0;
    for (int index = 0; index < 150; index++)
        promotions += Observe(&policy, LDACBT_EQMID_MQ, &now, 0.001, 0.001, 0, true, 0) == LDACBT_EQMID_INC_QUALITY;
    assert(promotions == 1);
    Healthy(&policy, LDACBT_EQMID_HQ, &now, 14);
    for (int index = 0; index < 150; index++)
        assert(Observe(&policy, LDACBT_EQMID_HQ, &now, 0.001, 0.001, 0, true, 0) == 0);
    puts("PASS adaptive replay: sustained small delays, early queue pressure, immediate severe delay, transient/source/scheduler isolation, real-time promotion accounting and bounded retry backoff");
}

static void CheckEncoder(int rate) {
    HANDLE_LDAC_BT encoder = ldacBT_get_handle();
    assert(encoder && ldacBT_init_handle_encode(encoder, 895, LDACBT_EQMID_HQ,
        LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, rate) == 0);
    LDACAdaptivePolicy policy = LDACAdaptivePolicyInit();
    double now = 1;
    for (int index = 0; index < 12; index++) {
        int priority = Observe(&policy, ldacBT_get_eqmid(encoder), &now, 0.045, 0.001, 0, true, 0.048);
        if (priority) assert(ldacBT_alter_eqmid_priority(encoder, priority) == 0);
        float pcm[256] = {0};
        unsigned char packet[LDACBT_MAX_NBYTES];
        int used, bytes, frames;
        assert(ldacBT_encode(encoder, pcm, &used, packet, &bytes, &frames) == 0);
    }
    assert(ldacBT_get_eqmid(encoder) == LDACBT_EQMID_MQ);
    for (int step = 0; step < 4; step++) {
        int priority = 0;
        for (int index = 0; index < 4000 && !priority; index++)
            priority = Observe(&policy, ldacBT_get_eqmid(encoder), &now, 0.001, 0.001, 0, true, 0);
        assert(priority == LDACBT_EQMID_INC_QUALITY);
        assert(ldacBT_alter_eqmid_priority(encoder, priority) == 0);
    }
    assert(ldacBT_get_eqmid(encoder) == LDACBT_EQMID_HQ);
    ldacBT_free_handle(encoder);
    printf("PASS encoder rate=%d: adaptive steps reach minimum and maximum without invalid quality requests\n", rate);
}

int main(void) {
    CheckPolicy();
    int rates[] = {44100, 48000, 88200, 96000};
    for (int index = 0; index < 4; index++) CheckEncoder(rates[index]);
    return 0;
}
"""

with tempfile.TemporaryDirectory(prefix="acouplet-adaptive-policy-") as directory:
    path = pathlib.Path(directory)
    check, binary = path / "Adaptive.c", path / "adaptive"
    check.write_text(fixture)
    subprocess.run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            str(root / "Helpers/LDAC"),
            "-I",
            str(root / "Vendor/libldac/inc"),
            "-I",
            str(root / "Vendor/libldac/src"),
            str(check),
            str(root / "Vendor/libldac/src/ldacBT.c"),
            str(root / "Vendor/libldac/src/ldaclib.c"),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True, timeout=10)
