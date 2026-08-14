// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>

#include "snrt.h"

// A cluster on chiplet0 pushes a payload plus a flag into chiplet1's L2
// through the ucie0 window, and a cluster on chiplet1 polls the flag
// locally, then fetches and checks the payload through the local NoC.
// The flag is raised only after the payload DMA is fully acked.

#define NUM_ELEM 256
#define FLAG_DONE 0xcafebeef

#define SENDER_CLUSTER 0
#define RECEIVER_CLUSTER 8

uint32_t *local_vec;

uint32_t vec_inp [NUM_ELEM] __attribute__ ((aligned(64)));
volatile uint32_t flag __attribute__ ((aligned(64)));

int main() {

  uint32_t errors = 0;

  uint32_t cluster_idx = snrt_cluster_idx();
  uint32_t core_idx = snrt_cluster_core_idx();
  uint32_t vec_size = NUM_ELEM * sizeof(uint32_t);

  // Offsets of the L2 globals within the L2 SPM region
  uintptr_t l2_base = (uintptr_t)&gwaihir_addrmap_32b.l2_spm[0];
  uintptr_t vec_off = (uintptr_t)vec_inp - l2_base;
  uintptr_t flag_off = (uintptr_t)&flag - l2_base;

  // Chiplet1's copies as seen from chiplet0, through the ucie0 alias window
  volatile uint32_t *vec_alias = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_32b.ucie0.l2_spm[0] + vec_off);
  volatile uint32_t *flag_alias = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_32b.ucie0.l2_spm[0] + flag_off);

  // The physical locations the alias maps to, as seen from chiplet1 (half-shift: l2_spm[i] -> l2_spm[i+2])
  volatile uint32_t *vec_phys = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_32b.l2_spm[2] + vec_off);
  volatile uint32_t *flag_phys = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_32b.l2_spm[2] + flag_off);

  // The consumer's mailbox is uninitialized memory;
  // clear it before any cluster starts sending
  if (cluster_idx == RECEIVER_CLUSTER && snrt_is_dm_core()) {
    *flag_phys = 0;
  }
  snrt_global_barrier();

  if (cluster_idx == SENDER_CLUSTER) {
    if (core_idx == 0) {
      for (uint32_t i = 0; i < NUM_ELEM; i++) {
        vec_inp[i] = i*4;
      }
    }
    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
      // Push the payload to the peer L2 through ucie0, then raise the flag
      snrt_dma_start_1d((void *)vec_alias, vec_inp, vec_size);
      snrt_dma_wait_all();
      *flag_alias = FLAG_DONE;
    }
  } else if (cluster_idx == RECEIVER_CLUSTER) {
    if (snrt_is_dm_core()) {
      local_vec = (uint32_t *) snrt_l1_alloc_cluster_local(vec_size, 64);

      // Wait for the producer's flag, then fetch the payload into TCDM
      // through the local NoC
      while (*flag_phys != FLAG_DONE);
      snrt_dma_start_1d(local_vec, (void *)vec_phys, vec_size);
      snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    // Check the payload against the expected pattern
    if (core_idx == 0) {
      for (uint32_t i = 0; i < NUM_ELEM; i++) {
        errors += (local_vec[i] != i*4);
      }
    }
  }

  return errors;
}
