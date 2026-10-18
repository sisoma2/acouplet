import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path

vendor = Path(__file__).resolve().parent.parent / 'Vendor/libldac'
notice = '/* Modified by Acouplet on 2026-10-03: defined unsigned packing shift. */\n\n'
fixed = '((unsigned int)idata << (24-nbits))'
original = '(idata << (24-nbits))'
upstream_sha = '61efb10d366a0d72c6a933abc22a87e2c891a8b2ab63f391655a79b7cc2f9952'
source = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ldacBT.h"
#include "ldaclib.c"

static void check_field(int value, int width, int offset) {
    unsigned char packed[8] = {0x53, 0x27, 0xb9}, expected[8];
    packed[3] = 0xa5 & (0xff << (8 - offset));
    memcpy(expected, packed, sizeof(packed));
    int start = 24 + offset, location = start;
    uint32_t bits = (uint32_t)value;
    for (int bit = 0; bit < width; bit++) {
        int position = start + bit;
        if ((bits >> (width - 1 - bit)) & 1)
            expected[position / 8] |= 1u << (7 - position % 8);
    }
    pack_store_ldac(value, width, packed, &location);
    assert(location == start + width);
    assert(memcmp(packed, expected, sizeof(packed)) == 0);
}

static void check_packing(void) {
    assert(CHAR_BIT == 8 && sizeof(unsigned int) == 4);
    for (int width = 2; width <= 16; width++)
        for (int value = -32768; value <= 32767; value++)
            for (int offset = 0; offset < 8; offset++)
                check_field(value, width, offset);
    for (int width = 0; width <= 16; width++)
        for (int offset = 0; offset < 8; offset++) {
            check_field(INT_MIN, width, offset);
            check_field(INT_MAX, width, offset);
            for (int value = -32768; width < 2 && value <= 32767; value++)
                check_field(value, width, offset);
        }
    puts("UBSan independent packing reference: signed-short values, widths 0–16, offsets 0–7, int extrema: passed");
}

static void encode(int rate, int quality, int floating) {
    HANDLE_LDAC_BT encoder = ldacBT_get_handle();
    assert(encoder);
    assert(ldacBT_init_handle_encode(encoder, 895, quality,
        LDACBT_CHANNEL_MODE_STEREO, floating ? LDACBT_SMPL_FMT_F32 : LDACBT_SMPL_FMT_S16, rate) == 0);
    int frame_size = (int[]){330, 220, 110}[quality];
    int total_frames = 0, drained = 0;
    for (int block = 0; block < 192 + 16; block++) {
        int16_t pcm[LDACBT_ENC_LSU * 2];
        float pcm_float[LDACBT_ENC_LSU * 2];
        for (int i = 0; i < LDACBT_ENC_LSU; i++)
            for (int channel = 0; channel < 2; channel++) {
                double t = (double)(block * LDACBT_ENC_LSU + i) / rate;
                double value = 5000 * sin(2 * 3.14159265358979323846 *
                    ((channel ? 713 : 431) * t + 83 * t * t)) +
                    1700 * sin(2 * 3.14159265358979323846 * (channel ? 2911 : 1723) * t);
                pcm[i * 2 + channel] = (int16_t)value;
                pcm_float[i * 2 + channel] = (float)(value / 32768 + 0x1p-20);
            }
        unsigned char encoded[LDACBT_MAX_NBYTES];
        int used = 0, wrote = 0, frames = 0;
        assert(ldacBT_encode(encoder, block < 192 ? (floating ? (void *)pcm_float : (void *)pcm) : NULL,
            &used, encoded, &wrote, &frames) == 0);
        assert(used == (block < 192 ? (floating ? sizeof(pcm_float) : sizeof(pcm)) : 0));
        assert(wrote == frames * frame_size && wrote <= sizeof(encoded));
        for (int frame = 0; frame < frames; frame++) {
            unsigned char *header = encoded + frame * frame_size;
            assert(header[0] == 0xaa && (header[1] >> 5) ==
                (rate == 44100 ? 0 : rate == 48000 ? 1 : rate == 88200 ? 2 : 3));
            assert(((header[1] >> 3) & 3) == 2);
            assert((((header[1] & 7) << 6) | (header[2] >> 2)) + 4 == frame_size);
        }
        assert(fwrite(encoded, 1, wrote, stdout) == wrote);
        total_frames += frames;
        if (block >= 192 && !wrote) { drained = 1; break; }
    }
    assert(drained && total_frames * (rate > 48000 ? 256 : 128) >= 192 * LDACBT_ENC_LSU);
    ldacBT_free_handle(encoder);
}

int main(int argc, char **argv) {
    if (argc == 1) check_packing();
    else {
        assert(argc == 4);
        encode(atoi(argv[1]), atoi(argv[2]), atoi(argv[3]));
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='acouplet-ldac-packing-') as directory:
    root = Path(directory)
    prior = root / 'prior'
    shutil.copytree(vendor, prior)
    packer = prior / 'src/pack_ldac.c'
    text = packer.read_text().replace(notice, '').replace(fixed, original)
    assert hashlib.sha256(text.encode()).hexdigest() == upstream_sha
    packer.write_text(text)
    check = root / 'check.c'
    check.write_text(source)
    executables = {}
    for name, tree, sanitized in [('original', prior, False), ('original-ubsan', prior, True), ('fixed', vendor, True)]:
        executable = root / name
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O2', '-std=c11',
                        *(['-fsanitize=undefined', '-fno-sanitize-recover=undefined'] if sanitized else []),
                        '-I', str(tree / 'inc'), '-I', str(tree / 'src'), str(check),
                        str(tree / 'src/ldacBT.c'), '-o', str(executable)], check=True)
        executables[name] = executable
    reproduced = subprocess.run([str(executables['original-ubsan'])], check=False, capture_output=True, text=True)
    assert reproduced.returncode != 0 and 'left shift of negative value' in reproduced.stderr, reproduced
    print('Original pinned packer: UBSan negative-left-shift reproduced', flush=True)
    subprocess.run([str(executables['fixed'])], check=True)
    for rate in (44100, 48000, 88200, 96000):
        for quality in (0, 1, 2):
            for floating in (0, 1):
                args = [str(rate), str(quality), str(floating)]
                golden = subprocess.check_output([str(executables['original']), *args])
                result = subprocess.check_output([str(executables['fixed']), *args])
                assert result == golden, args
                print(f'{rate} Hz quality={quality} {"F32" if floating else "S16"}: '
                      f'{len(result)} bytes identical, sha256={hashlib.sha256(result).hexdigest()}')
print('LDAC defined packing and 24 complete-frame golden comparisons: passed')
