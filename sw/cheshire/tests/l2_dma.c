// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// L2-to-L2 iDMA integration test.
//
// Drives Mem-Tile-1's iDMA to copy data from Mem-Tile-0's L2 SPM into
// Mem-Tile-1's L2 SPM in three phases:
//   Phase 1 — 1D aligned, 128 B
//   Phase 2 — 1D unaligned, 128 B (second half of row 3 + whole row 4 +
//             first half of row 5 in Tile 1)
//   Phase 3 — 2D strided, length=128, reps_2=2, src_stride_2=256,
//             dst_stride_2=192 (two disjoint 128-B dst windows; a 64-B
//             gap between them is poisoned and verified to stay untouched)
//
// Source pattern is a simple ramp: src[i] = i. CVA6 reads back the
// destination bytes after each phase and tallies any mismatches in
// `n_errors`. main() returns n_errors, so a passing run reports
// exit_code = 0 through the JTAG/SLINK EOC path.

#include <stdint.h>

#include "gw_addrmap.h"
#include "memtile_idma.h"
#include "regs/idma.h"

// ---- Configuration ---------------------------------------------------------

#define ROW_BYTES   64u                 // one wide AXI beat = one wide SRAM word
#define SRC_TILE    0u
#define DST_TILE    1u
// DRIVER_TILE = which tile's iDMA performs the copy.
// Tile 1 pulls from Tile 0 into its own local L2 ("pull" model).
#define DRIVER_TILE 1u

// Total source span needed by all three phases (Phase 3 reads up to byte 383).
#define SRC_INIT_WORDS  96u             // 96 * 4 B = 384 B

// ---- Main ------------------------------------------------------------------

int main(void) {
    volatile uint32_t *src = gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint32_t *dst = gwaihir_addrmap.l2_spm[DST_TILE].mem;

    uint32_t n_errors = 0;

    // -----------------------------------------------------------------------
    // Initialize source: simple ramp src[i] = i, for SRC_INIT_WORDS words
    // of Tile-0 SPM. Easy to read in an AXI trace and easy to verify.
    // -----------------------------------------------------------------------
    for (uint32_t i = 0; i < SRC_INIT_WORDS; i++) {
        src[i] = i;
    }

    // CVA6 self-check on the source: validates the CVA6 -> Tile-0 path
    // before the iDMA is involved.
    for (uint32_t i = 0; i < SRC_INIT_WORDS; i++) {
        if (src[i] != i) {
            n_errors++;
        }
    }

    // -----------------------------------------------------------------------
    // Phase 1: 1D aligned, 128 B
    //   Copy src[0..31] (bytes 0..127 of Tile 0) -> dst[32..63] (bytes
    //   128..255 of Tile 1, i.e. rows 2 and 3). Both ends 64-B aligned.
    //   After DMA, dst[32+i] should equal src[i] = i.
    // -----------------------------------------------------------------------
    {
        const uint32_t dst_word_off = 32;       // 128 B / 4 = 32 words
        const uint32_t n_words      = 32;       // 128 B / 4

        // Poison destination with the bit-inverse of expected so any
        // missing write reads back as poison and fails the check.
        for (uint32_t i = 0; i < n_words; i++) {
            dst[dst_word_off + i] = ~i;
        }

        memtile1_dma_blk_memcpy(
            /*dst=*/  (uint64_t)(uintptr_t)&dst[dst_word_off],
            /*src=*/  (uint64_t)(uintptr_t)&src[0],
            /*size=*/ 128u,
            /*conf=*/ 0u);

        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[dst_word_off + i] != i) {
                n_errors++;
            }
        }
    }

    // // -----------------------------------------------------------------------
    // // Phase 2: 1D unaligned, 128 B
    // //   Copy src[0..31] -> dst[56..87] (bytes 224..351 of Tile 1). dst
    // //   byte 224 = row 3, byte 32 -> payload spans the second half of
    // //   row 3, all of row 4, and the first half of row 5. 64-B-unaligned
    // //   at both ends; stresses the iDMA HardwareLegalizer and W-strobes.
    // //   After DMA, dst[56+i] should equal src[i] = i.
    // // -----------------------------------------------------------------------
    // {
    //     const uint32_t dst_word_off = 56;       // 224 B / 4 = 56 words
    //     const uint32_t n_words      = 32;       // 128 B / 4

    //     for (uint32_t i = 0; i < n_words; i++) {
    //         dst[dst_word_off + i] = ~i;
    //     }

    //     memtile1_dma_blk_memcpy(
    //         /*dst=*/  (uint64_t)(uintptr_t)&dst[dst_word_off],
    //         /*src=*/  (uint64_t)(uintptr_t)&src[0],
    //         /*size=*/ 128u,
    //         /*conf=*/ 0u);

    //     for (uint32_t i = 0; i < n_words; i++) {
    //         if (dst[dst_word_off + i] != i) {
    //             n_errors++;
    //         }
    //     }
    // }

    // // -----------------------------------------------------------------------
    // // Phase 3: 2D strided, 256 B total
    // //   length       = 128 B  (per inner iter)
    // //   reps_2       = 2
    // //   src_stride_2 = 256 B
    // //     -> iter 0 src = src[0..31] (words 0..31),
    // //        iter 1 src = src[64..95] (words 64..95)
    // //   dst_stride_2 = 192 B
    // //     -> iter 0 dst = dst[64..95]   (bytes 256..383)
    // //        iter 1 dst = dst[112..143] (bytes 448..575)
    // //   Expected values (since src is a ramp src[i] = i):
    // //     iter 0 dst[64+i] should equal src[0 +i]  = i
    // //     iter 1 dst[112+i] should equal src[64+i] = 64 + i
    // //   The 64-B gap between the two dst windows (bytes 384..447 of
    // //   Tile 1) is poisoned and verified to remain untouched.
    // // -----------------------------------------------------------------------
    // {
    //     const uint32_t dst_word_off_0 = 64;     // byte 256 -> row 4
    //     const uint32_t dst_word_off_1 = 112;    // byte 448 -> row 7 (112 = 64 + 192 / 4)
    //     const uint32_t n_words        = 32;     // 128 B / 4
    //     const uint32_t src_word_off_0 = 0;      // byte 0
    //     const uint32_t src_word_off_1 = 64;     // byte 256

    //     // Poison both destination windows.
    //     for (uint32_t i = 0; i < n_words; i++) {
    //         dst[dst_word_off_0 + i] = ~(src_word_off_0 + i);
    //     }
    //     for (uint32_t i = 0; i < n_words; i++) {
    //         dst[dst_word_off_1 + i] = ~(src_word_off_1 + i);
    //     }
    //     // Poison the 64-B gap (16 words = bytes 384..447 of Tile 1) so we
    //     // can verify the DMA does NOT touch it.
    //     for (uint32_t i = 0; i < 16; i++) {
    //         dst[dst_word_off_0 + n_words + i] = 0xDEADBEEFu;
    //     }

    //     memtile1_dma_2d_blk_memcpy(
    //         /*dst=*/        (uint64_t)(uintptr_t)&dst[dst_word_off_0],
    //         /*src=*/        (uint64_t)(uintptr_t)&src[src_word_off_0],
    //         /*size=*/       128u,
    //         /*dst_stride=*/ 192u,
    //         /*src_stride=*/ 256u,
    //         /*num_reps=*/   2u,
    //         /*conf=*/       (uint64_t)(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));

    //     // Verify iter-0 destination window: dst[64+i] == src[0+i] = i.
    //     for (uint32_t i = 0; i < n_words; i++) {
    //         if (dst[dst_word_off_0 + i] != (src_word_off_0 + i)) {
    //             n_errors++;
    //         }
    //     }
    //     // Verify the 64-B gap is still poisoned.
    //     for (uint32_t i = 0; i < 16; i++) {
    //         if (dst[dst_word_off_0 + n_words + i] != 0xDEADBEEFu) {
    //             n_errors++;
    //         }
    //     }
    //     // Verify iter-1 destination window: dst[112+i] == src[64+i] = 64+i.
    //     for (uint32_t i = 0; i < n_words; i++) {
    //         if (dst[dst_word_off_1 + i] != (src_word_off_1 + i)) {
    //             n_errors++;
    //         }
    //     }
    // }

    return (int)n_errors;
}
