// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "snrt.h"

#define NUM_ELEM 256

uint32_t *local_vec;

uint32_t vec_inp [NUM_ELEM] __attribute__ ((aligned(64)));

int main() {

  if (snrt_cluster_idx() > 0) return 0;

  uint32_t errors = 0;

  uint32_t core_idx = snrt_global_core_idx();

  uint32_t vec_size = NUM_ELEM * sizeof(uint32_t);

  // Initialize vector
  if (core_idx == 0) {
    for (uint32_t i = 0; i < NUM_ELEM; i++) {
      vec_inp[i] = i*4;
    }
  }

  snrt_cluster_hw_barrier();

  // Form the ucie0 alias address of the vector: canonical | alias-window base
  // TODO: OR-ing ucie0's base hardcodes chiplet-select bit 25 = 1 (only chiplet0->chiplet1);
  //       a correct alias derives bit 25 from the destination chiplet.
  volatile uint32_t* vec_inp_ucie = (volatile uint32_t*)((uintptr_t)&gwaihir_addrmap_32b.ucie0 | (uintptr_t)vec_inp);

  if (snrt_is_dm_core()) {
    local_vec = (uint32_t *) snrt_l1_alloc_cluster_local(vec_size, 64);

    // Push the vector out to the peer L2 through ucie0
    snrt_dma_start_1d(vec_inp_ucie, vec_inp, vec_size);
    snrt_dma_wait_all();

    // Read it back into TCDM
    snrt_dma_start_1d(local_vec, vec_inp_ucie, vec_size);
    snrt_dma_wait_all();
  }

  snrt_cluster_hw_barrier();

  // Compare original vector in L2 with the one transferred to TCDM
  if (core_idx == 0) {
    for (uint32_t i = 0; i < NUM_ELEM; i++) {
      errors += (local_vec[i] != vec_inp[i]);
    }
  }

  snrt_cluster_hw_barrier();

  return errors;
}