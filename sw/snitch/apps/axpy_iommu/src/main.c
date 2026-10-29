// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FP32 AXPY whose DMA transfers go through the IOMMU. The compute cores have
// no FP64, so this replaces the double-precision snitch_cluster axpy kernel.
// The host (simple_offload_iommu) maps IOVA 0x0020_0000 onto the 2 MiB L3
// region at 0x2120_0000 that holds this binary's data. The DM core moves x, y
// and z between L1 and L3 using IOVAs only, then checks z through the physical
// address. Returns the number of mismatches.

#include "snrt.h"

#define N 1024
#define L3_BASE 0x21200000
#define L3_SIZE 0x00200000
#define IOVA_BASE 0x00200000

static float x[N] __attribute__((aligned(4096)));
static float y[N] __attribute__((aligned(4096)));
static float z[N] __attribute__((aligned(4096)));

static const float a = 3.0f;

static inline void *iova(void *pa) {
    return (void *)((uintptr_t)pa - L3_BASE + IOVA_BASE);
}

static inline int in_l3(void *pa, size_t size) {
    uintptr_t addr = (uintptr_t)pa;
    return addr >= L3_BASE && addr + size <= L3_BASE + L3_SIZE;
}

int main() {
    // The buffers are shared globals in L3, so a single cluster runs the test
    if (snrt_cluster_idx() != 0) return 0;

    uint32_t size = N * sizeof(float);
    float *l1_x = (float *)snrt_l1_next();
    float *l1_y = l1_x + N;
    float *l1_z = l1_y + N;
    uint32_t nerr = 0;

    // The buffers must lie in the IOMMU-mapped window (link-time constant)
    if (!in_l3(x, size) || !in_l3(y, size) || !in_l3(z, size)) return N + 1;

    // Small integers keep a * x + y exact in FP32
    if (snrt_is_dm_core()) {
        for (int i = 0; i < N; i++) {
            x[i] = (float)(i % 64);
            y[i] = (float)(i % 32);
            z[i] = -1.0f;
        }
        snrt_dma_start_1d(l1_x, iova(x), size);
        snrt_dma_start_1d(l1_y, iova(y), size);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    if (snrt_is_compute_core()) {
        uint32_t ncores = snrt_cluster_compute_core_num();
        for (int i = snrt_cluster_core_idx(); i < N; i += ncores)
            l1_z[i] = a * l1_x[i] + l1_y[i];
        snrt_fpu_fence();
    }
    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(iova(z), l1_z, size);
        snrt_dma_wait_all();
        for (int i = 0; i < N; i++) {
            if (z[i] != a * (float)(i % 64) + (float)(i % 32)) nerr++;
        }
    }

    return nerr;
}
