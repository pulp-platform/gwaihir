// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// L2-to-L2 DMA burst test (viDMA in passthrough == iDMA).
//
// Tile-1's DMA copies data from Tile-0's L2 SPM into Tile-1's L2 SPM in four
// phases. Each phase has its own size knobs so transfers can be scaled up to
// force multi-burst / page-split DMA traffic ("super large" vectors/matrices):
//   Phase 1 — 1D aligned vector
//   Phase 2 — 1D vector, UNALIGNED at both ends (src and dst)
//   Phase 3 — 2D aligned, strided matrix (gaps between rows; gaps verified
//             untouched). Asymmetric src/dst strides preserved.
//   Phase 4 — 2D UNALIGNED, contiguous matrix (rows x cols, stride == row)
//
// Source pattern is a ramp src[i] = i. After each phase CVA6 reads back the
// destination and tallies mismatches. Verification is fail-fast: the first
// failing stage returns immediately.
//
// *** DEBUG RETURN ENCODING (temporary, for root-causing a failure) ***
// On any mismatch a stage returns  STAGE*1000000 + <first bad dst word index>
// (source self-check uses STAGE 5). A fully passing run still returns 0.
// e.g. 1001728 => Phase 1, first wrong at dst word 1728. Revert to a plain
// error count once the failure is understood.

#include <stdint.h>
#include <assert.h>

#include "gw_addrmap.h"
#include "memtile_idma.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
// Tile indices (0..NUM_L2_MEM_TILES-1). Change these three to retarget the
// entire test: source buffer, destination buffer, and which tile's DMA drives
// the copy. DRIVER_TILE may be the src tile, the dst tile, or a third tile that
// owns neither buffer (then both the read and the write traverse the NoC).
#define SRC_TILE     0
#define DST_TILE     1
#define DRIVER_TILE  1

// Select the driver tile's DMA helpers from DRIVER_TILE. Token paste needs a
// bare integer (hence no 'u' suffix on the tile indices). Resolves e.g.
// DRIVER_TILE=5 -> memtile5_dma_blk_memcpy / memtile5_dma_2d_blk_memcpy.
#define MEMTILE_CONCAT_(tile, fn) memtile##tile##fn
#define MEMTILE_CONCAT(tile, fn)  MEMTILE_CONCAT_(tile, fn)
#define DMA_BLK_MEMCPY            MEMTILE_CONCAT(DRIVER_TILE, _dma_blk_memcpy)
#define DMA_2D_BLK_MEMCPY         MEMTILE_CONCAT(DRIVER_TILE, _dma_2d_blk_memcpy)

// ---- Debug: encode "which stage + where it first broke" into the exit code -
#define NO_BAD                0xFFFFFFFFu
#define BAD_CODE(stage, idx)  ((int)((uint32_t)(stage) * 1000000u + (uint32_t)(idx)))

// ---- Geometry --------------------------------------------------------------
#define WORD_BYTES   4             // sizeof(uint32_t)
#define BEAT_BYTES   64            // 512-bit wide AXI beat (alignment unit)
#define TILE_BYTES   0x100000      // 1 MiB per L2 tile

// All *_BYTES / *_OFF / *_GAP MUST be multiples of WORD_BYTES (exact word
// verify). "Unaligned" => NOT a multiple of BEAT_BYTES. Defaults are > 4 KiB to
// force multi-burst, page-split traffic; raise them (keep each phase's span
// <= TILE_BYTES) for super-large runs.

// Phase 1 — 1D aligned vector
#define P1_LEN_BYTES   8192        // 8 KiB, 64-B aligned

// Phase 2 — 1D vector, unaligned at both ends
#define P2_LEN_BYTES   8224        // non-64B-multiple => stresses the tail beat
#define P2_SRC_OFF     32          // src byte offset (word-aligned, !=64-mult)
#define P2_DST_OFF     96          // dst byte offset (word-aligned, !=64-mult)

// Phase 3 — 2D aligned, strided (gaps between rows) with INDEPENDENT src/dst
// gaps, so src_stride != dst_stride (asymmetric strides). The defaults below
// (row 256, strides 512/320, 8 rows) are scaled UP from the original test
// (row 128, strides 256/192, 2 rows) to push more/larger bursts. To reproduce
// the original exactly: row=128, SRC_GAP=128, DST_GAP=64, NUM_ROWS=2.
#define P3_ROW_BYTES   256         // inner length per row (64-B aligned)
#define P3_NUM_ROWS    8           // reps_2
#define P3_SRC_GAP     256         // src_stride = ROW + SRC_GAP = 512
#define P3_DST_GAP     64          // dst_stride = ROW + DST_GAP = 320
#define P3_SRC_STRIDE  (P3_ROW_BYTES + P3_SRC_GAP)
#define P3_DST_STRIDE  (P3_ROW_BYTES + P3_DST_GAP)

// Phase 4 — 2D unaligned, contiguous matrix (stride == row length, no gap).
#define P4_ROW_BYTES   324         // non-64B-multiple inner length
#define P4_NUM_ROWS    8
#define P4_SRC_OFF     32          // unaligned src base (word-aligned, !=64)
#define P4_DST_OFF     96          // unaligned dst base
#define P4_STRIDE      (P4_ROW_BYTES)   // contiguous

// ---- Derived: source ramp init span (union of all phase reads) -------------
#define MAX2(a, b)     ((a) > (b) ? (a) : (b))
#define P1_SRC_END     (P1_LEN_BYTES)
#define P2_SRC_END     (P2_SRC_OFF + P2_LEN_BYTES)
#define P3_SRC_END     ((P3_NUM_ROWS - 1) * P3_SRC_STRIDE + P3_ROW_BYTES)
#define P4_SRC_END     (P4_SRC_OFF + P4_NUM_ROWS * P4_ROW_BYTES)
#define SRC_SPAN_BYTES MAX2(MAX2(P1_SRC_END, P2_SRC_END), MAX2(P3_SRC_END, P4_SRC_END))
#define SRC_INIT_WORDS (SRC_SPAN_BYTES / WORD_BYTES)

// ---- Derived: dst spans (for the 1-MiB ceiling assertions) -----------------
#define P1_DST_END (P1_LEN_BYTES)
#define P2_DST_END (P2_DST_OFF + P2_LEN_BYTES)
#define P3_DST_END ((P3_NUM_ROWS - 1) * P3_DST_STRIDE + P3_ROW_BYTES)
#define P4_DST_END (P4_DST_OFF + P4_NUM_ROWS * P4_ROW_BYTES)

// ---- Compile-time invariants -----------------------------------------------
// Tile indices in range (memtile<N>_* helpers exist for N in 0..NUM-1).
static_assert(SRC_TILE < NUM_L2_MEM_TILES && DST_TILE < NUM_L2_MEM_TILES &&
              DRIVER_TILE < NUM_L2_MEM_TILES, "tile index out of range");
// Word alignment (exact CVA6 word verify).
static_assert(P1_LEN_BYTES % WORD_BYTES == 0, "P1 length must be word-aligned");
static_assert(P2_LEN_BYTES % WORD_BYTES == 0 && P2_SRC_OFF % WORD_BYTES == 0 &&
              P2_DST_OFF % WORD_BYTES == 0, "P2 params must be word-aligned");
static_assert(P3_ROW_BYTES % WORD_BYTES == 0 && P3_SRC_GAP % WORD_BYTES == 0 &&
              P3_DST_GAP % WORD_BYTES == 0, "P3 params must be word-aligned");
static_assert(P4_ROW_BYTES % WORD_BYTES == 0 && P4_SRC_OFF % WORD_BYTES == 0 &&
              P4_DST_OFF % WORD_BYTES == 0, "P4 params must be word-aligned");
// Intended (un)alignment per phase.
static_assert(P1_LEN_BYTES % BEAT_BYTES == 0, "P1 must be 64-B aligned");
static_assert(P2_SRC_OFF % BEAT_BYTES != 0 && P2_DST_OFF % BEAT_BYTES != 0,
              "P2 must be unaligned at both ends");
static_assert(P4_SRC_OFF % BEAT_BYTES != 0 && P4_DST_OFF % BEAT_BYTES != 0,
              "P4 base must be unaligned");
// 1-MiB-per-tile ceiling (src in SRC_TILE, dst in DST_TILE).
static_assert(SRC_SPAN_BYTES <= TILE_BYTES, "source span exceeds 1 MiB tile");
static_assert(P1_DST_END <= TILE_BYTES && P2_DST_END <= TILE_BYTES &&
              P3_DST_END <= TILE_BYTES && P4_DST_END <= TILE_BYTES,
              "a destination span exceeds 1 MiB tile");

// ---- Main ------------------------------------------------------------------

int main(void) {
    volatile uint32_t *src = gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint32_t *dst = gwaihir_addrmap.l2_spm[DST_TILE].mem;

    uint32_t n_errors  = 0;
    uint32_t first_bad = NO_BAD;

    // Initialize source ramp src[i] = i over the union of all phase reads.
    for (uint32_t i = 0; i < SRC_INIT_WORDS; i++) {
        src[i] = i;
    }
    // ****************************************************************************************************** //
    // // CVA6 self-check of the source: validates the CVA6 -> Tile-SRC path
    // // before any DMA is involved.
    // for (uint32_t i = 0; i < SRC_INIT_WORDS; i++) {
    //     if (src[i] != i) {
    //         n_errors++;
    //         if (first_bad == NO_BAD) first_bad = i;
    //     }
    // }
    // if (n_errors != 0) {
    //     return BAD_CODE(5, first_bad);   // source path broken (STAGE 5)
    // }
    // ****************************************************************************************************** //

    // -----------------------------------------------------------------------
    // Phase 1: 1D aligned vector (P1_LEN_BYTES).
    //   dst[i] should equal src[i] = i. Aligned at both ends.
    // -----------------------------------------------------------------------
    {
        const uint32_t n_words = P1_LEN_BYTES / WORD_BYTES;
        const uint32_t dst_w   = 0;
        const uint32_t src_w   = 0;

        for (uint32_t i = 0; i < n_words; i++) {
            dst[dst_w + i] = ~(src_w + i);          // poison
        }

        DMA_BLK_MEMCPY(
            /*dst=*/  (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/  (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/ P1_LEN_BYTES,
            /*conf=*/ 0);

        first_bad = NO_BAD;
        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                n_errors++;
                if (first_bad == NO_BAD) first_bad = dst_w + i;
            }
        }
        if (n_errors != 0) {
            return BAD_CODE(1, first_bad);          // skip Phases 2-4
        }
    }

    // -----------------------------------------------------------------------
    // Phase 2: 1D vector, UNALIGNED at both ends (P2_SRC_OFF / P2_DST_OFF are
    //   word-aligned but not 64-B aligned; P2_LEN_BYTES is not a 64-B multiple
    //   either, so the final beat is partial). Stresses the legalizer and the
    //   write strobes on both read and write sides.
    //   dst[dst_w + i] should equal src[src_w + i] = src_w + i.
    // -----------------------------------------------------------------------
    {
        const uint32_t n_words = P2_LEN_BYTES / WORD_BYTES;
        const uint32_t dst_w   = P2_DST_OFF / WORD_BYTES;
        const uint32_t src_w   = P2_SRC_OFF / WORD_BYTES;

        for (uint32_t i = 0; i < n_words; i++) {
            dst[dst_w + i] = ~(src_w + i);          // poison
        }

        DMA_BLK_MEMCPY(
            /*dst=*/  (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/  (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/ P2_LEN_BYTES,
            /*conf=*/ 0);

        first_bad = NO_BAD;
        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                n_errors++;
                if (first_bad == NO_BAD) first_bad = dst_w + i;
            }
        }
        if (n_errors != 0) {
            return BAD_CODE(2, first_bad);          // skip Phases 3-4
        }
    }

    // -----------------------------------------------------------------------
    // Phase 3: 2D aligned, strided matrix. P3_NUM_ROWS rows of P3_ROW_BYTES,
    //   with independent src/dst strides (gaps between rows). Each dst row is
    //   verified against its src row; each inter-row dst gap is poisoned and
    //   verified to remain untouched. All quantities are 64-B aligned.
    //     row r: src = src_base + r*P3_SRC_STRIDE, dst = dst_base + r*P3_DST_STRIDE
    //     dst[row r][i] should equal src[row r][i] = r*(P3_SRC_STRIDE/4) + i
    // -----------------------------------------------------------------------
    {
        const uint32_t n_words   = P3_ROW_BYTES   / WORD_BYTES;   // per row
        const uint32_t src_str_w = P3_SRC_STRIDE  / WORD_BYTES;
        const uint32_t dst_str_w = P3_DST_STRIDE  / WORD_BYTES;
        const uint32_t dst_gap_w = P3_DST_GAP     / WORD_BYTES;
        const uint32_t dst_base  = 0;
        const uint32_t src_base  = 0;

        // Poison each dst row window and each inter-row dst gap.
        for (uint32_t r = 0; r < P3_NUM_ROWS; r++) {
            const uint32_t drow = dst_base + r * dst_str_w;
            const uint32_t srow = src_base + r * src_str_w;
            for (uint32_t i = 0; i < n_words; i++) {
                dst[drow + i] = ~(srow + i);
            }
            if (r + 1 < P3_NUM_ROWS) {             // gap follows all but last row
                for (uint32_t g = 0; g < dst_gap_w; g++) {
                    dst[drow + n_words + g] = 0xDEADBEEF;
                }
            }
        }

        DMA_2D_BLK_MEMCPY(
            /*dst=*/        (uint64_t)(uintptr_t)&dst[dst_base],
            /*src=*/        (uint64_t)(uintptr_t)&src[src_base],
            /*size=*/       P3_ROW_BYTES,
            /*dst_stride=*/ P3_DST_STRIDE,
            /*src_stride=*/ P3_SRC_STRIDE,
            /*num_reps=*/   P3_NUM_ROWS,
            /*conf=*/       (uint64_t)(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));

        // Verify each row, and that each gap stayed poisoned.
        first_bad = NO_BAD;
        for (uint32_t r = 0; r < P3_NUM_ROWS; r++) {
            const uint32_t drow = dst_base + r * dst_str_w;
            const uint32_t srow = src_base + r * src_str_w;
            for (uint32_t i = 0; i < n_words; i++) {
                if (dst[drow + i] != (srow + i)) {
                    n_errors++;
                    if (first_bad == NO_BAD) first_bad = drow + i;
                }
            }
            if (r + 1 < P3_NUM_ROWS) {
                for (uint32_t g = 0; g < dst_gap_w; g++) {
                    if (dst[drow + n_words + g] != 0xDEADBEEF) {
                        n_errors++;
                        if (first_bad == NO_BAD) first_bad = drow + n_words + g;
                    }
                }
            }
        }
        if (n_errors != 0) {
            return BAD_CODE(3, first_bad);          // skip Phase 4
        }
    }

    // -----------------------------------------------------------------------
    // Phase 4: 2D UNALIGNED, contiguous matrix. stride == row length (no gap),
    //   so the P4_NUM_ROWS rows form one contiguous block, but it is issued via
    //   the ND path (reps > 1) from an unaligned base with a non-64-B row
    //   length. Exercises ND + unaligned + partial-beat handling together.
    //     dst[dst_w + k] should equal src[src_w + k] = src_w + k.
    // -----------------------------------------------------------------------
    {
        const uint32_t row_w   = P4_ROW_BYTES / WORD_BYTES;
        const uint32_t total_w = P4_NUM_ROWS * row_w;
        const uint32_t dst_w   = P4_DST_OFF / WORD_BYTES;
        const uint32_t src_w   = P4_SRC_OFF / WORD_BYTES;

        for (uint32_t i = 0; i < total_w; i++) {
            dst[dst_w + i] = ~(src_w + i);          // poison
        }

        DMA_2D_BLK_MEMCPY(
            /*dst=*/        (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/        (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/       P4_ROW_BYTES,
            /*dst_stride=*/ P4_STRIDE,
            /*src_stride=*/ P4_STRIDE,
            /*num_reps=*/   P4_NUM_ROWS,
            /*conf=*/       (uint64_t)(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));

        first_bad = NO_BAD;
        for (uint32_t i = 0; i < total_w; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                n_errors++;
                if (first_bad == NO_BAD) first_bad = dst_w + i;
            }
        }
        if (n_errors != 0) {
            return BAD_CODE(4, first_bad);
        }
    }

    return 0;
}
