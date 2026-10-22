// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

#pragma once

#define SNRT_INIT_BSS
#define SNRT_WAKE_UP
#define SNRT_INIT_TLS
#define SNRT_INIT_CLS
#define SNRT_INIT_LIBS
#define SNRT_CRT0_PRE_BARRIER
#define SNRT_INVOKE_MAIN
#define SNRT_CRT0_POST_BARRIER
#define SNRT_CRT0_EXIT
#define SNRT_CRT0_ALTERNATE_EXIT

// The H tile runs a job alone. No cluster 0 clears the .bss for it, and its
// world communicator holds no other cluster, so no global barrier waits for one.
#define SNRT_CRT0_CALLBACK0
static inline void snrt_crt0_callback0() {
    extern volatile uint32_t __bss_start, __bss_end;
    if (snrt_cluster_idx() == GW_HTILE_CLUSTER_IDX) {
        if (snrt_is_dm_core()) {
            size_t size = (size_t)(&__bss_end) - (size_t)(&__bss_start);
            snrt_dma_memset((void*)&__bss_start, 0, size);
            snrt_dma_wait_all();
        }
        snrt_cluster_hw_barrier();
    }
}

#define SNRT_CRT0_CALLBACK2
static inline void snrt_crt0_callback2() {
    extern __thread snrt_comm_info_t snrt_comm_world_info;
    if (snrt_cluster_idx() == GW_HTILE_CLUSTER_IDX) {
        snrt_comm_world_info.size = 1;
        snrt_comm_world_info.mask = 0;
        snrt_comm_world_info.base = GW_HTILE_CLUSTER_IDX;
        snrt_comm_world_info.is_participant = 0;
    }
}


static inline volatile uint32_t* snrt_exit_code_destination() {
    return (volatile uint32_t*)snrt_cluster()->peripheral_reg.scratch[0].f.scratch;
}

inline void snrt_exit(int exit_code) {
    *(snrt_exit_code_destination() + snrt_cluster_core_idx()) = (exit_code << 1) | 1;
}

#include "start.h"
