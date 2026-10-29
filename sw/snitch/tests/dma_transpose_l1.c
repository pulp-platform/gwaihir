// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DMA transpose from L1 to L1.

#include "dma_transpose_common.h"

int main() {
#ifdef SNRT_SUPPORTS_DMA_COMPUTE
    // The DMA is driven by the DM core of the first cluster
    if (snrt_cluster_idx() != 0 || !snrt_is_dm_core()) return 0;

    void *src = snrt_l1_alloc_cluster_local(BUF_BYTES, SNRT_DMA_BYTES_PER_BEAT);
    void *dst = snrt_l1_alloc_cluster_local(BUF_BYTES, SNRT_DMA_BYTES_PER_BEAT);
    return run_all(src, dst) ? 1 : 0;
#endif
}
