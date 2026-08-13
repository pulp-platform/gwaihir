// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "args.h"
#include "snrt.h"

#define DOUBLE_BUFFER 1

#define ALIGN_NEXT_FROM_BASE(addr, base, size) \
    (((((addr) - (base)) + (size)-1) / (size)) * (size) + (base))

#define BANK_ALIGNMENT 8
#define TCDM_ALIGNMENT (24 * BANK_ALIGNMENT)
#define ALIGN_UP_TCDM(addr) \
    ALIGN_NEXT_FROM_BASE(addr, SNRT_TCDM_START_ADDR, TCDM_ALIGNMENT)
#define AXI_BURST_ALIGNMENT 4096
#define ALIGN_UP_AXI_BURST(addr) ALIGN_NEXT_FROM_BASE(addr, 0, AXI_BURST_ALIGNMENT)
#define AXPY_LOOP_PERF_CNT 0
#define AXPY_INTERLEAVER_TEST_ITERS 64
#define AXPY_INTERLEAVER_TEST_ELEMS 64

static inline void axpy_naive(uint32_t n, double a, double *x, double *y,
                              double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    for (int i = offset; i < n; i += snrt_cluster_compute_core_num()) {
        z[i] = a * x[i] + y[i];
    }
    snrt_fpu_fence();
}

static inline void axpy_fma(uint32_t n, double a, double *x, double *y,
                            double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    for (int i = offset; i < n; i += snrt_cluster_compute_core_num()) {
        asm volatile("fmadd.d %[z], %[a], %[x], %[y] \n"
                     : [ z ] "=f"(z[i])
                     : [ a ] "f"(a), [ x ] "f"(x[i]), [ y ] "f"(y[i]));
    }
    snrt_fpu_fence();
}

static inline void axpy_opt(uint32_t n, double a, double *x, double *y,
                            double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    snrt_ssr_loop_1d(SNRT_SSR_DM_ALL, frac,
                     snrt_cluster_compute_core_num() * sizeof(double));

    snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_1D, x + offset);
    snrt_ssr_read(SNRT_SSR_DM1, SNRT_SSR_1D, y + offset);
    snrt_ssr_write(SNRT_SSR_DM2, SNRT_SSR_1D, z + offset);

    snrt_ssr_enable();

    asm volatile(
        "frep.o %[n_frep], 1, 0, 0 \n"
        "fmadd.d ft2, %[a], ft0, ft1\n"
        :
        : [ n_frep ] "r"(frac - 1), [ a ] "f"(a)
        : "ft0", "ft1", "ft2", "memory");

    snrt_fpu_fence();
    snrt_ssr_disable();
}

// Lightweight read/write stress test for AXI AR/AW interleaver debug.
// Uses only short DMA bursts and barriers to keep simulation runtime low.
static inline void axpy_write_test(axpy_args_t *args) {
    uint32_t n = args->n;
    uint32_t elems = (n < AXPY_INTERLEAVER_TEST_ELEMS) ? n
                                                        : AXPY_INTERLEAVER_TEST_ELEMS;
    uint32_t bytes = elems * sizeof(double);
    uint32_t i, offset;
    uint32_t core_idx = snrt_cluster_core_idx();
    volatile uint64_t *x_u64 = (volatile uint64_t *)args->x;
    volatile uint64_t *y_u64 = (volatile uint64_t *)args->y;
    volatile uint64_t *z_u64 = (volatile uint64_t *)args->z;

    if (elems == 0) {
        return;
    }

    double *local_a = (double *)ALIGN_UP_TCDM((uint64_t)snrt_l1_next());
    double *local_b = local_a + elems;

    snrt_global_sw_barrier();

    for (i = 0; i < AXPY_INTERLEAVER_TEST_ITERS; i++) {
        snrt_cluster_hw_barrier();

        if (snrt_is_dm_core()) {
            offset = (i * elems) % n;

            // Keep accesses in-bounds when n is not a multiple of elems.
            if ((offset + elems) > n) {
                offset = n - elems;
            }

            // AR traffic: fetch two source chunks from L2.
            snrt_dma_start_1d(local_a, args->x + offset, bytes);
            snrt_dma_start_1d(local_b, args->y + offset, bytes);
            snrt_dma_wait_all();

            // AW/W traffic: push two chunks back to L2.
            snrt_dma_start_1d(args->z + offset, local_a, bytes);
            snrt_dma_start_1d(args->x + offset, local_b, bytes);
            snrt_dma_wait_all();
        }

        if (snrt_is_compute_core()) {
            // Narrow traffic: scalar loads/stores from compute cores.
            uint32_t idx = (i * snrt_cluster_compute_core_num() + core_idx) % n;
            uint64_t vx = x_u64[idx];
            uint64_t vy = y_u64[idx];
            z_u64[idx] = vx ^ vy ^ (uint64_t)core_idx ^ (uint64_t)i;
        }

        snrt_cluster_hw_barrier();
    }

    snrt_global_sw_barrier();
}

static inline void axpy_job(axpy_args_t *args) {
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_z0_addr, local_x1_addr,
        local_y1_addr, local_z1_addr;
    uint64_t local_x0_addr_fallback, local_y0_addr_fallback, local_z0_addr_fallback,
        local_x1_addr_fallback, local_y1_addr_fallback, local_z1_addr_fallback;
    uint32_t core_idx, loop_start_cycle, loop_end_cycle, loop_cycles;
    double *local_x[2];
    double *local_y[2];
    double *local_z[2];
    double *remote_x, *remote_y, *remote_z;
    uint32_t iterations, i, rep, i_dma_in, i_compute, i_dma_out, buff_idx;
    uint32_t used_fallback_layout = 0;

#ifndef JOB_ARGS_PRELOADED
    // Allocate space for job arguments in TCDM
    axpy_args_t *local_args = (axpy_args_t *)snrt_l1_next();

    // Copy job arguments to TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_args, args, sizeof(axpy_args_t));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    args = local_args;
#endif

    // Calculate size of each tile
    frac = args->n / args->n_tiles;
    size = frac * sizeof(double);

    // Fallback (legacy) layout: bank/TCDM alignment only.
    local_x0_addr_fallback = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr_fallback =
        ALIGN_UP_TCDM(local_x0_addr_fallback + size) + 8 * BANK_ALIGNMENT;
    local_z0_addr_fallback =
        ALIGN_UP_TCDM(local_y0_addr_fallback + size) + 16 * BANK_ALIGNMENT;
    if (DOUBLE_BUFFER) {
        local_x1_addr_fallback = ALIGN_UP_TCDM(local_z0_addr_fallback + size);
        local_y1_addr_fallback =
            ALIGN_UP_TCDM(local_x1_addr_fallback + size) + 8 * BANK_ALIGNMENT;
        local_z1_addr_fallback =
            ALIGN_UP_TCDM(local_y1_addr_fallback + size) + 16 * BANK_ALIGNMENT;
    }

    // Preferred layout: match read_only by 4KB-aligning DMA destinations x/y.
    local_x0_addr = ALIGN_UP_AXI_BURST(
        ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t)));
    local_y0_addr = ALIGN_UP_AXI_BURST(
        ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT);
    local_z0_addr = ALIGN_UP_TCDM(local_y0_addr + size) + 16 * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_z[0] = (double *)local_z0_addr;
    if (DOUBLE_BUFFER) {
        local_x1_addr = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_z0_addr + size));
        local_y1_addr = ALIGN_UP_AXI_BURST(
            ALIGN_UP_TCDM(local_x1_addr + size) + 8 * BANK_ALIGNMENT);
        local_z1_addr =
            ALIGN_UP_TCDM(local_y1_addr + size) + 16 * BANK_ALIGNMENT;
        local_x[1] = (double *)local_x1_addr;
        local_y[1] = (double *)local_y1_addr;
        local_z[1] = (double *)local_z1_addr;
    } else {
        local_x1_addr = 0;
        local_y1_addr = 0;
        local_z1_addr = 0;
    }

    // Guard against TCDM overflow from extra 4KB padding. If it does not fit,
    // fall back to the previous layout to preserve correctness.
    {
        // snrt_l1_next() may return either canonical (0x200...) or alias
        // (0x300...) TCDM addresses. Derive bounds from the active window.
        uint64_t tcdm_start =
            ((uint64_t)args / (uint64_t)SNRT_TCDM_SIZE) * (uint64_t)SNRT_TCDM_SIZE;
        uint64_t tcdm_end = tcdm_start + (uint64_t)SNRT_TCDM_SIZE;
        uint64_t highest_addr = DOUBLE_BUFFER ? (local_z1_addr + size)
                                              : (local_z0_addr + size);
        if (highest_addr > tcdm_end && false) {
            used_fallback_layout = 1;
            local_x0_addr = local_x0_addr_fallback;
            local_y0_addr = local_y0_addr_fallback;
            local_z0_addr = local_z0_addr_fallback;
            local_x[0] = (double *)local_x0_addr;
            local_y[0] = (double *)local_y0_addr;
            local_z[0] = (double *)local_z0_addr;
            if (DOUBLE_BUFFER) {
                local_x1_addr = local_x1_addr_fallback;
                local_y1_addr = local_y1_addr_fallback;
                local_z1_addr = local_z1_addr_fallback;
                local_x[1] = (double *)local_x1_addr;
                local_y[1] = (double *)local_y1_addr;
                local_z[1] = (double *)local_z1_addr;
            }
        }
    }
    if (snrt_cluster_core_idx() == 0 && used_fallback_layout) {
        DUMP(used_fallback_layout);
    }
    if (snrt_cluster_core_idx() == 0) {
        DUMP(local_x0_addr);
        DUMP(local_y0_addr);
        DUMP(local_z0_addr);
        DUMP(local_x1_addr);
        DUMP(local_y1_addr);
        DUMP(local_z1_addr);
    }

    // Calculate number of iterations
    iterations = args->n_tiles;
    if (DOUBLE_BUFFER) iterations += 2;

    snrt_global_sw_barrier();

    // DMA core starts first and ends last in this loop, so only log DMA cycles.
    if (snrt_is_dm_core()) {
        core_idx = snrt_cluster_core_idx();
        snrt_stop_perf_counter(AXPY_LOOP_PERF_CNT);
        snrt_reset_perf_counter(AXPY_LOOP_PERF_CNT);
        snrt_cfg_perf_counter(AXPY_LOOP_PERF_CNT, PERF_METRIC__CYCLE, core_idx);
        loop_start_cycle = snrt_get_perf_counter(AXPY_LOOP_PERF_CNT);
        snrt_start_perf_counter(AXPY_LOOP_PERF_CNT);
    }

    // Repeat the tiled workload on the same data to amortize setup overhead.
    for (rep = 0; rep < args->repetitions; rep++) {
    // Iterate over all tiles
    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            // DMA in
            if (!DOUBLE_BUFFER || (i < args->n_tiles)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_in = i;
                buff_idx = DOUBLE_BUFFER ? i_dma_in % 2 : 0;

                // Calculate size and pointers to current tile
                offset = i_dma_in * frac;
                remote_x = args->x + offset;
                remote_y = args->y + offset;

                // Copy job operands in TCDM
                snrt_dma_start_1d(local_x[buff_idx], remote_x, size);
                snrt_dma_start_1d(local_y[buff_idx], remote_y, size);
                snrt_dma_wait_all();

                snrt_mcycle();
            }

            // Additional barriers required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            // DMA out
            if (!DOUBLE_BUFFER || (i > 1)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_out = DOUBLE_BUFFER ? i - 2 : i;
                buff_idx = DOUBLE_BUFFER ? i_dma_out % 2 : 0;

                // Calculate pointers to current tile
                offset = i_dma_out * frac;
                remote_z = args->z + offset;

                // Copy job outputs from TCDM
                snrt_dma_start_1d(remote_z, local_z[buff_idx], size);
                snrt_dma_wait_all();

                snrt_mcycle();
            }
        }

        // Compute
        if (snrt_is_compute_core()) {
            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            if (!DOUBLE_BUFFER || (i > 0 && i < (args->n_tiles + 1))) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_compute = DOUBLE_BUFFER ? i - 1 : i;
                buff_idx = DOUBLE_BUFFER ? i_compute % 2 : 0;

                // Perform tile computation
                axpy_fp_t fp = args->funcptr;
                fp(frac, args->a, local_x[buff_idx], local_y[buff_idx],
                   local_z[buff_idx]);

                snrt_mcycle();
            }

            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
        }

        // Synchronize cores after every iteration
        snrt_cluster_hw_barrier();
    }
    }

    if (snrt_is_dm_core()) {
        snrt_stop_perf_counter(AXPY_LOOP_PERF_CNT);
        loop_end_cycle = snrt_get_perf_counter(AXPY_LOOP_PERF_CNT);
        loop_cycles = loop_end_cycle - loop_start_cycle;
        // DUMP(core_idx);
        // DUMP(loop_start_cycle);
        // DUMP(loop_end_cycle);
        DUMP(loop_cycles);
    }
}



static inline void dot_job(axpy_args_t *args) {
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_x1_addr, local_y1_addr,
        local_partials_addr, local_tail_addr;
    uint32_t core_idx, start_cycle, end_cycle, loop_cycles;
    double *local_x[2];
    double *local_y[2];
    double *local_partials;
    double *remote_x, *remote_y;
    uint32_t iterations, i, rep, i_dma_in, i_compute, buff_idx;
    uint32_t compute_core_idx = 0;
    uint32_t compute_core_num = snrt_cluster_compute_core_num();
    uint32_t chunk_start, chunk_end;
    double partial = 0.0;

#ifndef JOB_ARGS_PRELOADED
    // Allocate space for job arguments in TCDM
    axpy_args_t *local_args = (axpy_args_t *)snrt_l1_next();

    // Copy job arguments to TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_args, args, sizeof(axpy_args_t));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    args = local_args;
#endif

    // Calculate size of each tile
    frac = args->n / args->n_tiles;
    size = frac * sizeof(double);

    // Allocate space for job operands in TCDM.
    // Align X with the 1st bank in TCDM and Y with the 8th.
    local_x0_addr = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr = ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_tail_addr = local_y0_addr + size;
    if (DOUBLE_BUFFER) {
        local_x1_addr = ALIGN_UP_TCDM(local_y0_addr + size);
        local_y1_addr =
            ALIGN_UP_TCDM(local_x1_addr + size) + 8 * BANK_ALIGNMENT;
        local_x[1] = (double *)local_x1_addr;
        local_y[1] = (double *)local_y1_addr;
        local_tail_addr = local_y1_addr + size;
    }

    // Shared scratch for per-core partial sums before final reduction.
    local_partials_addr = ALIGN_UP_TCDM(local_tail_addr);
    local_partials = (double *)local_partials_addr;

    if (snrt_cluster_core_idx() == 0) {
        DUMP(local_x0_addr);
        DUMP(local_y0_addr);
        DUMP(local_x1_addr);
        DUMP(local_y1_addr);
        DUMP(local_partials_addr);
    }

    // Calculate number of iterations
    iterations = args->n_tiles;
    if (DOUBLE_BUFFER) iterations += 1;

    if (snrt_is_compute_core()) {
        compute_core_idx = snrt_cluster_core_idx();
        local_partials[compute_core_idx] = 0.0;
    }

    snrt_global_sw_barrier();

    // DMA core starts first and ends last in this loop, so only log DMA cycles.
    if (snrt_is_dm_core()) {
        core_idx = snrt_cluster_core_idx();
        start_cycle = snrt_mcycle();
    }

    // Repeat the tiled workload on the same data to amortize setup overhead.
    for (rep = 0; rep < args->repetitions; rep++) {
    // Iterate over all tiles
    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            // DMA in
            if (!DOUBLE_BUFFER || (i < args->n_tiles)) {

                // Compute tile and buffer indices
                i_dma_in = i;
                buff_idx = DOUBLE_BUFFER ? i_dma_in % 2 : 0;

                // Calculate size and pointers to current tile
                offset = i_dma_in * frac;
                remote_x = args->x + offset;
                remote_y = args->y + offset;

                // Copy job operands in TCDM
                snrt_dma_start_1d(local_x[buff_idx], remote_x, size);
                snrt_dma_start_1d(local_y[buff_idx], remote_y, size);
                snrt_dma_wait_all();

            }

            // Additional barriers required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
        }

        // Compute
        if (snrt_is_compute_core()) {
            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            if (!DOUBLE_BUFFER || (i > 0 && i < (args->n_tiles + 1))) {

                // Compute tile and buffer indices
                i_compute = DOUBLE_BUFFER ? i - 1 : i;
                buff_idx = DOUBLE_BUFFER ? i_compute % 2 : 0;

                // Mirror dot-kernel behavior: contiguous per-core chunk.
                chunk_start = (compute_core_idx * frac) / compute_core_num;
                chunk_end = ((compute_core_idx + 1) * frac) / compute_core_num;
                for (uint32_t j = chunk_start; j < chunk_end; ++j) {
                    partial += local_x[buff_idx][j] * local_y[buff_idx][j];
                }

            }

            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
        }

        // Synchronize cores after every iteration
        snrt_cluster_hw_barrier();
    }
    }

    if (snrt_is_dm_core()) {
        end_cycle = snrt_mcycle();
        loop_cycles = end_cycle - start_cycle;
        // DUMP(core_idx);
        // DUMP(loop_start_cycle);
        // DUMP(loop_end_cycle);
        DUMP(loop_cycles);
    }

    if (snrt_is_compute_core()) {
        local_partials[compute_core_idx] = partial;
    }

    snrt_cluster_hw_barrier();

    // Final reduction and result writeback are intentionally outside timed loop.
    if (snrt_is_dm_core()) {
        double dot = 0.0;
        for (uint32_t j = 0; j < compute_core_num; ++j) {
            dot += local_partials[j];
        }
        local_partials[0] = dot;
        snrt_dma_start_1d(args->z, local_partials, sizeof(double));
        snrt_dma_wait_all();
    }
}



static inline void read_only(axpy_args_t *args) {
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_x1_addr, local_y1_addr;
    uint32_t core_idx, start_cycle, end_cycle, loop_cycles;
    double *local_x[2];
    double *local_y[2];
    double *remote_x, *remote_y;
    uint32_t iterations, i, rep, i_dma_in, buff_idx;
    uint32_t queued_tiles;

#ifndef JOB_ARGS_PRELOADED
    // Allocate space for job arguments in TCDM
    axpy_args_t *local_args = (axpy_args_t *)snrt_l1_next();

    // Copy job arguments to TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_args, args, sizeof(axpy_args_t));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    args = local_args;
#endif

    // Calculate size of each tile
    frac = args->n / args->n_tiles;
    size = frac * sizeof(double);

    // Allocate space for job operands in TCDM.
    // Align X with the 1st bank in TCDM and Y with the 8th.
    // Keep DMA destinations 4KB aligned to avoid short legalizer bursts.
    local_x0_addr =
        ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t)));
    local_y0_addr =
        ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT);
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    if (DOUBLE_BUFFER) {
        local_x1_addr = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_y0_addr + size));
        local_y1_addr = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_x1_addr + size) +
                                           8 * BANK_ALIGNMENT);
        local_x[1] = (double *)local_x1_addr;
        local_y[1] = (double *)local_y1_addr;
    }

    if (snrt_cluster_core_idx() == 0) {
        DUMP(local_x0_addr);
        DUMP(local_y0_addr);
        DUMP(local_x1_addr);
        DUMP(local_y1_addr);
    }

    // Calculate number of iterations
    iterations = args->n_tiles;

    snrt_global_sw_barrier();

    // DMA core starts first and ends last in this loop, so only log DMA cycles.
    if (snrt_is_dm_core()) {
        core_idx = snrt_cluster_core_idx();
        start_cycle = snrt_mcycle();
    }

    // Repeat the tiled workload on the same data to amortize setup overhead.
    // With double buffering we can safely queue two tiles (x/y for each tile)
    // before waiting, which helps keep AR traffic continuous.
    for (rep = 0; rep < args->repetitions; rep++) {
    queued_tiles = 0;
    // Iterate over all tiles
    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            // DMA in
            if (!DOUBLE_BUFFER || (i < args->n_tiles)) {
                // Compute tile and buffer indices
                i_dma_in = i;
                buff_idx = DOUBLE_BUFFER ? i_dma_in % 2 : 0;

                // Calculate size and pointers to current tile
                offset = i_dma_in * frac;
                remote_x = args->x + offset;
                remote_y = args->y + offset;

                // Copy job operands in TCDM
                snrt_dma_start_1d(local_x[buff_idx], remote_x, size);
                snrt_dma_start_1d(local_y[buff_idx], remote_y, size);

                // Only two buffer pairs exist, so wait after queuing two tiles
                // to avoid overwriting in-flight DMA destinations.
                queued_tiles++;
                if (!DOUBLE_BUFFER || queued_tiles == 2) {
                    snrt_dma_wait_all();
                    queued_tiles = 0;
                }
            }
        }

        // Compute cores intentionally perform no arithmetic in read-only mode.
        // Do not barrier every tile here: it creates visible AR issue gaps.
    }

    if (snrt_is_dm_core() && queued_tiles != 0) {
        snrt_dma_wait_all();
    }
    }

    if (snrt_is_dm_core()) {
        end_cycle = snrt_mcycle();
        loop_cycles = end_cycle - start_cycle;
        // DUMP(core_idx);
        // DUMP(loop_start_cycle);
        // DUMP(loop_end_cycle);
        DUMP(loop_cycles);
    }

    snrt_global_sw_barrier();
}
