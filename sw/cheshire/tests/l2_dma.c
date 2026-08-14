// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// L2-to-L2 DMA burst test (viDMA in passthrough == iDMA).
//
// Tile-1's DMA copies data from Tile-0's L2 SPM into Tile-1's L2 SPM in up to
// five phases, each individually enabled via the ENABLE_PHASE_* switches below.
// Each phase has its own size knobs so transfers can be scaled up to force
// multi-burst / page-split DMA traffic ("super large" vectors/matrices):
//   Phase 1 — 1D aligned vector
//   Phase 2 — 1D vector, UNALIGNED at both ends (src and dst)
//   Phase 3 — 2D aligned, strided matrix (gaps between rows; gaps verified
//             untouched). Asymmetric src/dst strides preserved.
//   Phase 4 — 2D UNALIGNED, contiguous matrix (rows x cols, stride == row)
//   Phase 5 — concurrent row-arbiter test (local DMA read vs CVA6 read)
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

#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"   // for GW_L2_SPM_NUM (number of L2 mem tiles)
#include "memtile_idma.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
// Tile indices (0..GW_L2_SPM_NUM-1). Change these three to retarget the
// entire test: source buffer, destination buffer, and which tile's DMA drives
// the copy.
#define SRC_TILE     3
#define DST_TILE     1
#define DRIVER_TILE  1

// The DMA helpers (memtile_dma_*) take the driver tile's SAM index as their
// first argument, selecting which tile's iDMA register file is configured.
// DRIVER_TILE drives Phases 1-4; Phase 5 deliberately drives SRC_TILE's own DMA
// so its reads hit the source tile's banks via the LOCAL path.

// ---- Debug: encode "which stage + where it first broke" into the exit code -
#define BAD_CODE(stage, idx)  ((int)((uint32_t)(stage) * 1000000u + (uint32_t)(idx)))

// ---- Phase enable switches (1 = run, 0 = skip) -----------------------------
// Phases are independent (each inits/poisons its own buffers), so any subset
// may be enabled; disabled phases compile to nothing. Fail-fast still applies
// across the enabled phases (the first failing one returns immediately).
#define ENABLE_PHASE_1   1   // 1D aligned vector
#define ENABLE_PHASE_2   1   // 1D unaligned (both ends)
#define ENABLE_PHASE_3   1   // 2D aligned, strided (gap-checked)
#define ENABLE_PHASE_4   1   // 2D unaligned, contiguous (ND)
#define ENABLE_PHASE_5   1   // concurrent row-arbiter

// ---- Geometry --------------------------------------------------------------
#define WORD_BYTES   sizeof(uint32_t)
#define BEAT_BYTES   (512/8)              // 512-bit wide AXI beat (alignment unit)
#define TILE_BYTES   GW_L2_SPM_SIZE     // L2 tile size

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
// gaps, so src_stride != dst_stride (asymmetric strides). The setting below
// (row 256, src strides 512, dst stride 320, 8 rows).
#define P3_ROW_BYTES   256         // inner length (in bytes) per row (64-B aligned)
#define P3_NUM_ROWS    8           // reps_2
#define P3_SRC_GAP     256         // Bytes gap till next src matrix row
#define P3_DST_GAP     64          // Bytes gap till next dst matrix row
#define P3_SRC_STRIDE  (P3_ROW_BYTES + P3_SRC_GAP) // src_stride = ROW + SRC_GAP = 512 bytes
#define P3_DST_STRIDE  (P3_ROW_BYTES + P3_DST_GAP) // dst_stride = ROW + DST_GAP = 320 bytes

// Phase 4 — 2D unaligned, contiguous matrix (stride == row length, no gap).
#define P4_ROW_BYTES   324              // non-64B-multiple inner length in bytes
#define P4_NUM_ROWS    8
#define P4_SRC_OFF     32               // unaligned src base (word-aligned, !=BEAT_BYTES)
#define P4_DST_OFF     96               // unaligned dst base
#define P4_STRIDE      (P4_ROW_BYTES)   // contiguous

// Phase 5 — concurrent arbiter test. Tile-SRC's own DMA reads tile-SRC's L2
// (LOCAL path -> payload_dma) while CVA6 reads the SAME region (NoC path ->
// payload_ext); both collide at tile-SRC's per-row rr_arb_tree. The window is
// placed at the base of a chosen macro row (rows are addr[19:16] = 64 KiB each)
// so the contention lands on that row's arbiter.
#define P5_LEN_BYTES          8192               // 8 KiB window (<= one 64 KiB row)
#define P5_SRC_ROW            3                  // macro row to contend on (0..15)
// ** This needs to be changed if the row size is changed. Currently the row size is 64 KiB (0x10000).
#define P5_SRC_OFF            (P5_SRC_ROW * 0x10000)  // row base; 64 KiB per macro row, dependent on the bank size //
#define P5_SWEEP_STRIDE_WORDS 10                 // 1 = densest collisions; raise to speed sim

// ---- Derived: source ramp init span (union of all phase reads) -------------
#define MAX2(a, b)     ((a) > (b) ? (a) : (b))
#define P1_SRC_END     (P1_LEN_BYTES)
#define P2_SRC_END     (P2_SRC_OFF + P2_LEN_BYTES)
#define P3_SRC_END     ((P3_NUM_ROWS - 1) * P3_SRC_STRIDE + P3_ROW_BYTES)
#define P4_SRC_END     (P4_SRC_OFF + P4_NUM_ROWS * P4_ROW_BYTES)
// Phase 5 self-inits its own (row-P5_SRC_ROW) source window, so it is
// intentionally NOT part of the global ramp span; P5_SRC_END is the ceiling
// check only.
#define P5_SRC_END     (P5_SRC_OFF + P5_LEN_BYTES)
#define SRC_SPAN_BYTES MAX2(MAX2(P1_SRC_END, P2_SRC_END), MAX2(P3_SRC_END, P4_SRC_END))
#define SRC_INIT_WORDS (SRC_SPAN_BYTES / WORD_BYTES)

// ---- Derived: dst spans (for the 1-MiB ceiling assertions) -----------------
#define P1_DST_END (P1_LEN_BYTES)
#define P2_DST_END (P2_DST_OFF + P2_LEN_BYTES)
#define P3_DST_END ((P3_NUM_ROWS - 1) * P3_DST_STRIDE + P3_ROW_BYTES)
#define P4_DST_END (P4_DST_OFF + P4_NUM_ROWS * P4_ROW_BYTES)
#define P5_DST_END (P5_LEN_BYTES)

// ---- Compile-time invariants -----------------------------------------------
// Tile indices in range.
static_assert(SRC_TILE < GW_L2_SPM_NUM && DST_TILE < GW_L2_SPM_NUM &&
              DRIVER_TILE < GW_L2_SPM_NUM, "tile index out of range");
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
static_assert(P5_LEN_BYTES % WORD_BYTES == 0 && P5_LEN_BYTES % BEAT_BYTES == 0 &&
              P5_SRC_OFF % BEAT_BYTES == 0,
              "P5 length/offset must be 64-B aligned");
// 1-MiB-per-tile ceiling.
static_assert(SRC_SPAN_BYTES <= TILE_BYTES, "source span exceeds 1 MiB tile");
static_assert(P5_SRC_END <= TILE_BYTES, "P5 source window exceeds 1 MiB tile");
static_assert(P1_DST_END <= TILE_BYTES && P2_DST_END <= TILE_BYTES &&
              P3_DST_END <= TILE_BYTES && P4_DST_END <= TILE_BYTES &&
              P5_DST_END <= TILE_BYTES,
              "a destination span exceeds 1 MiB tile");

// ---- Main ------------------------------------------------------------------

int main(void) {
    volatile uint32_t *src = gwaihir_addrmap_64b.l2_spm[SRC_TILE].mem;
    volatile uint32_t *dst = gwaihir_addrmap_64b.l2_spm[DST_TILE].mem;

    // Initialize source ramp src[i] = i over the union of all phase reads.
    for (uint32_t i = 0; i < SRC_INIT_WORDS; i++) {
        src[i] = i;
    }

    // -----------------------------------------------------------------------
    // Phase 1: 1D aligned vector (P1_LEN_BYTES).
    //   dst[i] should equal src[i] = i. Aligned at both ends.
    // -----------------------------------------------------------------------
#if ENABLE_PHASE_1
    {
        const uint32_t n_words = P1_LEN_BYTES / WORD_BYTES;

        for (uint32_t i = 0; i < n_words; i++) {
            dst[i] = ~i;          // poison
        }

        memtile_dma_blk_memcpy(
            /*tile=*/ DRIVER_TILE,
            /*dst=*/  (uint64_t)(uintptr_t)&dst[0],
            /*src=*/  (uint64_t)(uintptr_t)&src[0],
            /*size=*/ P1_LEN_BYTES,
            /*conf=*/ 0);

        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[i] != i) {
                return BAD_CODE(1, i);          // skip Phases 2-5
            }
        }
    }
#endif

    // -----------------------------------------------------------------------
    // Phase 2: 1D vector, UNALIGNED at both ends (P2_SRC_OFF / P2_DST_OFF are
    //   word-aligned but not 64-B aligned; P2_LEN_BYTES is not a 64-B multiple
    //   either, so the final beat is partial). Stresses the legalizer and the
    //   write strobes on both read and write sides.
    //   dst[dst_w + i] should equal src[src_w + i] = src_w + i.
    // -----------------------------------------------------------------------
#if ENABLE_PHASE_2
    {
        const uint32_t n_words = P2_LEN_BYTES / WORD_BYTES;
        const uint32_t dst_w   = P2_DST_OFF / WORD_BYTES;
        const uint32_t src_w   = P2_SRC_OFF / WORD_BYTES;

        for (uint32_t i = 0; i < n_words; i++) {
            dst[dst_w + i] = ~(src_w + i);          // poison
        }

        memtile_dma_blk_memcpy(
            /*tile=*/ DRIVER_TILE,
            /*dst=*/  (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/  (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/ P2_LEN_BYTES,
            /*conf=*/ 0);

        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                return BAD_CODE(2, dst_w + i);  // skip Phases 3-5
            }
        }
    }
#endif

    // -----------------------------------------------------------------------
    // Phase 3: 2D aligned, strided matrix. P3_NUM_ROWS rows of P3_ROW_BYTES,
    //   with independent src/dst strides (gaps between rows).
    //     row r: src = r*P3_SRC_STRIDE, dst = r*P3_DST_STRIDE
    //     dst[row r][i] should equal src[row r][i] = r*(P3_SRC_STRIDE/4) + i
    // -----------------------------------------------------------------------
#if ENABLE_PHASE_3
    {
        const uint32_t n_words   = P3_ROW_BYTES   / WORD_BYTES;   // per row
        const uint32_t src_str_w = P3_SRC_STRIDE  / WORD_BYTES;
        const uint32_t dst_str_w = P3_DST_STRIDE  / WORD_BYTES;
        const uint32_t dst_gap_w = P3_DST_GAP     / WORD_BYTES;

        // Poison each dst row window and each inter-row dst gap.
        for (uint32_t r = 0; r < P3_NUM_ROWS; r++) {
            const uint32_t drow = r * dst_str_w;
            const uint32_t srow = r * src_str_w;
            for (uint32_t i = 0; i < n_words; i++) {
                dst[drow + i] = ~(srow + i);
            }
            if (r + 1 < P3_NUM_ROWS) {             // gap follows all but last row
                for (uint32_t g = 0; g < dst_gap_w; g++) {
                    dst[drow + n_words + g] = 0xDEADBEEF;
                }
            }
        }

        memtile_dma_2d_blk_memcpy(
            /*tile=*/       DRIVER_TILE,
            /*dst=*/        (uint64_t)(uintptr_t)&dst[0],
            /*src=*/        (uint64_t)(uintptr_t)&src[0],
            /*size=*/       P3_ROW_BYTES,
            /*dst_stride=*/ P3_DST_STRIDE,
            /*src_stride=*/ P3_SRC_STRIDE,
            /*num_reps=*/   P3_NUM_ROWS,
            /*conf=*/       (uint64_t)(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));

        // Verify each row, and that each gap stayed poisoned.
        for (uint32_t r = 0; r < P3_NUM_ROWS; r++) {
            const uint32_t drow = r * dst_str_w;
            const uint32_t srow = r * src_str_w;
            for (uint32_t i = 0; i < n_words; i++) {
                if (dst[drow + i] != (srow + i)) {
                    return BAD_CODE(3, drow + i); // skip Phase 4-5
                }
            }
            if (r + 1 < P3_NUM_ROWS) {
                for (uint32_t g = 0; g < dst_gap_w; g++) {
                    if (dst[drow + n_words + g] != 0xDEADBEEF) {
                        return BAD_CODE(3, drow + n_words + g); // skip Phase 4-5
                    }
                }
            }
        }
    }
#endif

    // -----------------------------------------------------------------------
    // Phase 4: 2D UNALIGNED, contiguous matrix. stride == row length (no gap),
    //   so the P4_NUM_ROWS rows form one contiguous block, but it is issued via
    //   the ND path (reps > 1) from an unaligned base with a non-64-B row
    //   length. Exercises ND + unaligned + partial-beat handling together.
    //     dst[dst_w + k] should equal src[src_w + k] = src_w + k.
    // -----------------------------------------------------------------------
#if ENABLE_PHASE_4
    {
        const uint32_t row_w   = P4_ROW_BYTES / WORD_BYTES;
        const uint32_t total_w = P4_NUM_ROWS * row_w;
        const uint32_t dst_w   = P4_DST_OFF / WORD_BYTES;
        const uint32_t src_w   = P4_SRC_OFF / WORD_BYTES;

        for (uint32_t i = 0; i < total_w; i++) {
            dst[dst_w + i] = ~(src_w + i);          // poison
        }

        memtile_dma_2d_blk_memcpy(
            /*tile=*/       DRIVER_TILE,
            /*dst=*/        (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/        (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/       P4_ROW_BYTES,
            /*dst_stride=*/ P4_STRIDE,
            /*src_stride=*/ P4_STRIDE,
            /*num_reps=*/   P4_NUM_ROWS,
            /*conf=*/       (uint64_t)(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));

        for (uint32_t i = 0; i < total_w; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                return BAD_CODE(4, dst_w + i); // skip Phase 5
            }
        }
    }
#endif

    // -----------------------------------------------------------------------
    // Phase 5: CONCURRENT row-arbiter test. Driver DMA = SRC_TILE.
    //   - DMA read of the source hits SRC_TILE's own banks via the LOCAL path
    //     (mem_tile.sv routing_rules_dma LOCAL -> payload_dma).
    //   - DMA write of the destination leaves the tile (EXTERNAL -> NoC -> DST).
    //   - CVA6 concurrently reads the SAME SRC_TILE region, arriving as an
    //     external request (chimney -> narrow MEM demux -> payload_ext).
    //   Both clients walk the same window at src[P5_SRC_OFF..], which lies in a
    //   single macro row (addr[19:16] = P5_SRC_ROW), so they collide at that
    //   row's rr_arb_tree (ext wins ties; the DMA read's gnt deasserts and
    //   obi_sram_shim retries). We keep CVA6 hammering until the DMA reports
    //   done, so the overlap spans the transfer.
    //     dst[i] should equal src[src_w+i] = src_w+i; CVA6 reads must match too.
    // -----------------------------------------------------------------------
#if ENABLE_PHASE_5
    {
        const uint32_t n_words = P5_LEN_BYTES / WORD_BYTES;
        const uint32_t src_w   = P5_SRC_OFF / WORD_BYTES;  // base in macro row P5_SRC_ROW
        const uint32_t dst_w   = 0;                        // DST_TILE base

        // The row-P5_SRC_ROW source window is outside the global ramp span, so
        // initialize it here (keeping the src[j] = j ramp), then poison the dst.
        for (uint32_t i = 0; i < n_words; i++) {
            src[src_w + i] = src_w + i;
            dst[dst_w + i] = ~(src_w + i);
        }

        // Non-blocking 1D issue (conf=0 => ND off => reps ignored). Reading
        // NEXT_ID_0 inside the helper both launches the transfer and returns id.
        uint64_t tf_id = memtile_dma_2d_memcpy(
            /*tile=*/       SRC_TILE,
            /*dst=*/        (uint64_t)(uintptr_t)&dst[dst_w],
            /*src=*/        (uint64_t)(uintptr_t)&src[src_w],
            /*size=*/       P5_LEN_BYTES,
            /*dst_stride=*/ 0,
            /*src_stride=*/ 0,
            /*num_reps=*/   1,
            /*conf=*/       0);

        // Concurrent CVA6 traffic onto SRC_TILE's row-P5_SRC_ROW banks until the
        // DMA is done. src is volatile, so each load is issued (generates
        // payload_ext); the value is consumed by the check, so it is not elided.
        // (uintptr_t)&gwaihir_addrmap_64b.l2_spm_dma[SRC_TILE].mem[0] is the base
        // address of SRC_TILE's iDMA registers.
        const uintptr_t done_reg =
            (uintptr_t)&gwaihir_addrmap_64b.l2_spm_dma[SRC_TILE].mem[0] +
            IDMA_REG64_2D_DONE_ID_0_REG_OFFSET;
        do {
            for (uint32_t i = 0; i < n_words; i += P5_SWEEP_STRIDE_WORDS) {
                uint32_t v = src[src_w + i];               // ext read of SRC_TILE
            }
        } while (*(volatile uint64_t *)done_reg != tf_id);

        // Verify the DMA result (DST_TILE) and the concurrent reads (SRC_TILE).
        for (uint32_t i = 0; i < n_words; i++) {
            if (dst[dst_w + i] != (src_w + i)) {
                return BAD_CODE(6, dst_w + i); // STAGE 6 = concurrent
            }
        }
    }
#endif

    return 0;
}
