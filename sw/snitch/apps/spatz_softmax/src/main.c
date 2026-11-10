// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Softmax over the rows of the DeiT-tiny attention scores on the Spatz core of
// cluster 0 or of the H tile, in BF16, with PACE for exp and 1/x.
//
// The scores S [HEADS][TOKENS][TOKENS] are one row-major matrix [ROWS][COLS]
// in L2. The DM core moves blocks of BLOCK_ROWS rows through two TCDM buffers,
// so that the DMA of one block overlaps the compute of the other, and Spatz
// computes each block in place. A block has one of two layouts:
// - Columns (default): the DMA transposes the block to [COLS][rows], so one
//   column is one vector with lane i for row i. m, s and r are vectors with
//   one lane per row, and the kernel needs no reduction across lanes.
// - Rows (-DSOFTMAX_ROWS): the block stays [rows][COLS], and one row is one
//   vector. Each row needs two reductions and two round trips through a
//   scalar register. This layout needs no DMA transpose.
//
// Per row:
//   m = max(x)
//   e = exp(x - m)      vpace.pwpa
//   s = sum(e)          in FP32
//   r = 1 / s           vpace.inv, one Newton step
//   p = e * r
//
// Build both layouts and run on cluster 0:
//   make spatz_softmax spatz_softmax_rows
//   APP=sw/snitch/apps/spatz_softmax
//   make vsim-run-batch-verify PRELMODE=5 \
//     SN_BINARY=$APP/build/spatz_softmax.elf \
//     VERIFY_PY=$APP/scripts/verify.py
// The rows layout is $APP/build/rows/spatz_softmax_rows.elf. On the H tile,
// Cheshire starts the program:
//   make chs-sw-tests
//   make vsim-run-batch-verify PRELMODE=3 \
//     CHS_BINARY=sw/cheshire/tests/simple_htile_offload.spm.elf \
//     SN_BINARY=$APP/build/spatz_softmax.elf \
//     VERIFY_PY=$APP/scripts/verify.py

#include <stdint.h>

#include "data.h"
#include "snrt.h"

#define ROWS (HEADS * TOKENS)
#define COLS TOKENS
// 128 BF16 lanes are an LMUL-4 register group.
#define BLOCK_ROWS 128
#define NUM_BLOCKS ((ROWS + BLOCK_ROWS - 1) / BLOCK_ROWS)
#define BLOCK_BYTES (BLOCK_ROWS * COLS * sizeof(uint16_t))

#define CSR_FMODE 0x800
#define FMODE_BF16 3
#define CSR_PACE_DEGREE 0x7d2
#define PACE_DEGREE 1
#define BF16_ZERO 0x0000
#define BF16_TWO 0x4000

// Cycles from the start to the last output in L2, and the Spatz cycles of the
// blocks. verify.py prints them.
__attribute__((section(".dram"))) uint32_t cycles[2];

static uint16_t *buf[2];

static inline float bf16(uint32_t bits) {
    float f;
    asm volatile("fmv.h.x %0, %1" : "=f"(f) : "r"(bits));
    return f;
}

// The core waits until the Spatz stores before this call are in the TCDM: a
// scalar load goes through the Spatz VLSU behind them, and the move to an
// integer register makes the core wait for it. The cluster barrier does not
// wait for Spatz.
static inline void spatz_wait(const uint16_t *p) {
    uint32_t v;
    asm volatile("flh ft0, (%1)\n fmv.x.h %0, ft0"
                 : "=r"(v)
                 : "r"(p)
                 : "ft0", "memory");
}

static uint32_t block_rows(uint32_t b) {
    const uint32_t left = ROWS - b * BLOCK_ROWS;
    return left < BLOCK_ROWS ? left : BLOCK_ROWS;
}

#ifdef SOFTMAX_ROWS

// FP32 values in an LMUL-8 register group. sum_row widens the row in two parts.
#define WIDE_VL 128
static_assert(WIDE_VL < COLS && COLS <= 2 * WIDE_VL, "two parts per row");

// v8 = x
static inline void load_row(const uint16_t *row) {
    asm volatile("vsetvli zero, %0, e16, m8, ta, ma" ::"r"(COLS));
    asm volatile("vle16.v v8, (%0)" ::"r"(row) : "memory");
}

// v8 = x - max(x). The reduction starts from x[0].
static inline void subtract_max(void) {
    float m;
    asm volatile("vfredmax.vs v16, v8, v8\n vfmv.f.s %0, v16" : "=f"(m));
    asm volatile("vfsub.vf v8, v8, %0" ::"f"(m));
}

// v8 = exp(v8). vpace names the vector registers as f registers.
static inline void exp_row(void) { asm volatile("vpace.pwpa.h f8, f8, f8"); }

// v24[0] = sum of v8 in FP32. Spatz has no vfwredusum, and the widened row
// needs two LMUL-8 groups, so the sum widens v8[0..127] (in v8) and adds
// v8[128..] (in v12) before one FP32 reduction.
static inline void sum_row(float zero) {
    asm volatile(
        "vsetvli zero, %[lo], e16, m4, ta, ma\n"
        "vfwadd.vf v16, v8, %[zero]\n"
        "vsetvli zero, %[hi], e16, m4, tu, ma\n"
        "vfwadd.wv v16, v16, v12\n"
        "vsetvli zero, %[lo], e32, m8, ta, ma\n"
        "vmv.s.x v24, zero\n"
        "vfredusum.vs v24, v16, v24\n" ::[lo] "r"(WIDE_VL),
        [hi] "r"(COLS - WIDE_VL), [zero] "f"(zero));
}

// Returns 1 / v24[0] in BF16: PACE (2 % error), then one Newton step
// r (2 - s r) (0.6 %).
static inline float inverse(float two) {
    float r;
    asm volatile(
        "vsetivli zero, 1, e16, m1, ta, ma\n"
        "vfncvt.f.f.w v28, v24\n"      // v28 = s in BF16
        "vpace.inv.h f29, f28, f28\n"  // v29 = r
        "vfmul.vv v30, v28, v29\n"
        "vfrsub.vf v30, v30, %[two]\n"  // v30 = 2 - s r
        "vfmul.vv v29, v29, v30\n"
        "vfmv.f.s %[r], v29\n"
        : [r] "=f"(r)
        : [two] "f"(two));
    return r;
}

// row = v8 * r
static inline void scale_store(uint16_t *row, float r) {
    asm volatile("vsetvli zero, %0, e16, m8, ta, ma" ::"r"(COLS));
    asm volatile("vfmul.vf v8, v8, %0" ::"f"(r));
    asm volatile("vse16.v v8, (%0)" ::"r"(row) : "memory");
}

static void softmax_block(uint16_t *x, uint32_t rows) {
    const float zero = bf16(BF16_ZERO), two = bf16(BF16_TWO);
    for (uint32_t i = 0; i < rows; i++) {
        uint16_t *row = x + i * COLS;
        load_row(row);
        subtract_max();
        exp_row();
        sum_row(zero);
        scale_store(row, inverse(two));
    }
}

static void dma_in(uint32_t b) {
    snrt_dma_start_1d(buf[b % 2], s + b * BLOCK_ROWS * COLS,
                      block_rows(b) * COLS * sizeof(uint16_t));
}

static void dma_out(uint32_t b) {
    snrt_dma_start_1d(p + b * BLOCK_ROWS * COLS, buf[b % 2],
                      block_rows(b) * COLS * sizeof(uint16_t));
}

#else

static_assert(COLS >= 4, "pass 1 loads four columns before its loop");
// The DMA transposes tiles of TILE x TILE elements, one 64 B beat per tile row.
#define TILE (SNRT_DMA_BYTES_PER_BEAT / sizeof(uint16_t))

// A block of `rows` rows has lanes(rows) lanes in the TCDM, so that every
// column starts on an 8 B word: Spatz loads unaligned columns at under half
// the rate. The lanes past `rows` hold stale data, which is not copied out.
static inline uint32_t lanes(uint32_t rows) { return (rows + 3) / 4 * 4; }

// Column c of the block into or from the register group v<r>
#define COLUMN(c) (x + (c) * vl)
#define LOAD(r, c) \
    asm volatile("vle16.v v" #r ", (%0)" ::"r"(COLUMN(c)) : "memory")
#define STORE(r, c) \
    asm volatile("vse16.v v" #r ", (%0)" ::"r"(COLUMN(c)) : "memory")

// Pass 1 step: v<acc> = max(v<acc>, column k in v<r>), while column k + 2
// loads into v<next>.
#define MAX_STEP(acc, r, next, k)            \
    if ((k) + 2 < COLS) LOAD(next, (k) + 2); \
    if ((k) < COLS) asm volatile("vfmax.vv v" #acc ", v" #acc ", v" #r)

// Pass 2 step: e = exp(x - m) for column c in v<r>, added to the FP32 sum
// v<sum>, then stored.
// clang-format off
#define EXP_COLUMN(r, sum, c)                               \
    asm volatile("vfsub.vv v" #r ", v" #r ", v0\n"           \
                 "vpace.pwpa.h f" #r ", f" #r ", f" #r "\n" \
                 "vfwadd.wv v" #sum ", v" #sum ", v" #r);    \
    STORE(r, c)
// clang-format on

// The VFU and the VLSU run in order. Each pass loads ahead, so that the VLSU
// loads while the VFU computes.
static void softmax_block(uint16_t *x, uint32_t rows) {
    const float two = bf16(BF16_TWO);
    const uint32_t vl = lanes(rows);
    uint32_t c;
    asm volatile("vsetvli zero, %0, e16, m4, ta, ma" ::"r"(vl));

    // 1. v0 = m, from the even columns in v0 and the odd ones in v4. The
    //    columns rotate through v8, v12, v16 and v20.
    LOAD(0, 0);
    LOAD(4, 1);
    LOAD(8, 2);
    LOAD(12, 3);
    for (c = 2; c < COLS; c += 4) {
        MAX_STEP(0, 8, 16, c);
        MAX_STEP(4, 12, 20, c + 1);
        MAX_STEP(0, 16, 8, c + 2);
        MAX_STEP(4, 20, 12, c + 3);
    }
    asm volatile("vfmax.vv v0, v0, v4");

    // 2. e = exp(x - m) in place. The columns alternate between v8 and v12,
    //    and add up in FP32 in v16 (even) and v24 (odd). v4 = s in BF16.
    asm volatile("vsetvli zero, %0, e32, m8, ta, ma" ::"r"(vl));
    asm volatile("vmv.v.i v16, 0\n vmv.v.i v24, 0");
    asm volatile("vsetvli zero, %0, e16, m4, ta, ma" ::"r"(vl));
    LOAD(8, 0);
    for (c = 0; c + 1 < COLS; c += 2) {
        LOAD(12, c + 1);
        EXP_COLUMN(8, 16, c);
        if (c + 2 < COLS) LOAD(8, c + 2);
        EXP_COLUMN(12, 24, c + 1);
    }
    if (c < COLS) EXP_COLUMN(8, 16, c);
    asm volatile("vsetvli zero, %0, e32, m8, ta, ma" ::"r"(vl));
    asm volatile("vfadd.vv v16, v16, v24");
    asm volatile("vsetvli zero, %0, e16, m4, ta, ma" ::"r"(vl));
    asm volatile("vfncvt.f.f.w v4, v16");

    // 3. v4 = r: PACE (2 % error), then one Newton step r (2 - s r) (0.6 %).
    asm volatile(
        "vpace.inv.h f20, f4, f4\n"
        "vfmul.vv v24, v4, v20\n"
        "vfrsub.vf v24, v24, %0\n"
        "vfmul.vv v4, v20, v24\n" ::"f"(two));

    // 4. p = e * r in place, four columns at a time in v8, v12, v16 and v20:
    //    the VLSU switches between loads and stores once per four columns.
    for (c = 0; c < COLS; c += 4) {
        LOAD(8, c);
        if (c + 1 < COLS) LOAD(12, c + 1);
        if (c + 2 < COLS) LOAD(16, c + 2);
        if (c + 3 < COLS) LOAD(20, c + 3);
        asm volatile(
            "vfmul.vv v8, v8, v4\n vfmul.vv v12, v12, v4\n"
            "vfmul.vv v16, v16, v4\n vfmul.vv v20, v20, v4");
        STORE(8, c);
        if (c + 1 < COLS) STORE(12, c + 1);
        if (c + 2 < COLS) STORE(16, c + 2);
        if (c + 3 < COLS) STORE(20, c + 3);
    }
}

// dst [n][ld_dst] = transpose of src [m][ld_src], tile by tile. An edge tile
// reads and writes (with a zero strobe) whole tile rows past the matrix.
static void dma_transpose(uint16_t *dst, uint32_t ld_dst, const uint16_t *src,
                          uint32_t ld_src, uint32_t m, uint32_t n) {
    for (uint32_t c = 0; c < n; c += TILE) {
        for (uint32_t r = 0; r < m; r += TILE) {
            snrt_dma_enable_transpose(1, m - r < TILE ? m - r : TILE,
                                      n - c < TILE ? n - c : TILE);
            snrt_dma_start_2d(
                dst + c * ld_dst + r, (uint16_t *)src + r * ld_src + c,
                SNRT_DMA_BYTES_PER_BEAT, ld_dst * sizeof(uint16_t),
                ld_src * sizeof(uint16_t), TILE);
        }
    }
    snrt_dma_disable_compute();
}

static void dma_in(uint32_t b) {
    const uint32_t rows = block_rows(b);
    dma_transpose(buf[b % 2], lanes(rows), s + b * BLOCK_ROWS * COLS, COLS,
                  rows, COLS);
}

static void dma_out(uint32_t b) {
    const uint32_t rows = block_rows(b);
    dma_transpose(p + b * BLOCK_ROWS * COLS, COLS, buf[b % 2], lanes(rows),
                  COLS, rows);
}

#endif

int main(void) {
    // Cluster 0 runs the softmax, or the H tile when Cheshire starts it alone.
    const uint32_t cluster = snrt_cluster_idx();
    if (cluster != 0 && cluster != GW_HTILE_CLUSTER_IDX) return 0;
    const int dm = snrt_is_dm_core();
    const uint32_t t0 = snrt_mcycle();

    if (dm) {
        buf[0] = (uint16_t *)snrt_l1_alloc_cluster_local(BLOCK_BYTES, 64);
        buf[1] = (uint16_t *)snrt_l1_alloc_cluster_local(BLOCK_BYTES, 64);
        snrt_dma_start_1d((void *)snrt_cluster()->pacemem.mem, pace_table,
                          sizeof(pace_table));
        dma_in(0);
        snrt_dma_wait_all();
    } else {
        asm volatile("csrw %0, %1" ::"i"(CSR_FMODE), "r"(FMODE_BF16));
        asm volatile("csrw %0, %1" ::"i"(CSR_PACE_DEGREE), "r"(PACE_DEGREE));
    }
    snrt_cluster_hw_barrier();

    for (uint32_t b = 0; b < NUM_BLOCKS; b++) {
        if (dm) {
            // Block b - 1 leaves the other buffer before block b + 1 comes in.
            if (b > 0) dma_out(b - 1);
            snrt_dma_wait_all();
            if (b + 1 < NUM_BLOCKS) dma_in(b + 1);
            snrt_dma_wait_all();
        } else {
            const uint32_t t = snrt_mcycle();
            softmax_block(buf[b % 2], block_rows(b));
            // The DM core copies the block out after the next barrier.
            spatz_wait(buf[b % 2]);
            cycles[1] += snrt_mcycle() - t;
        }
        snrt_cluster_hw_barrier();
    }
    if (dm) {
        dma_out(NUM_BLOCKS - 1);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    if (!dm) cycles[0] = snrt_mcycle() - t0;
    return 0;
}
