// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DMA transpose from L2 to L1. The source is a global array, which the linker
// puts in the L2 SPM next to the program.

#include "dma_transpose_common.h"

#ifdef SNRT_SUPPORTS_DMA_COMPUTE
static uint8_t l2_src[BUF_BYTES] __attribute__((aligned(64)));
#endif

int main() {
#ifdef SNRT_SUPPORTS_DMA_COMPUTE
    // The DMA is driven by the DM core of the first cluster
    if (snrt_cluster_idx() != 0 || !snrt_is_dm_core()) return 0;

    void *dst = snrt_l1_alloc_cluster_local(BUF_BYTES, SNRT_DMA_BYTES_PER_BEAT);
    return run_all(l2_src, dst) ? 1 : 0;
#endif
}
