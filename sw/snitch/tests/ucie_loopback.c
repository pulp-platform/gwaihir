// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "snrt.h"
#include "data/ucie_tensors.h"

uint16_t *local_x;
uint16_t *local_w;
uint16_t *local_y;
uint32_t *local_z;

int main() {

  if (snrt_cluster_idx() > 0) return 0;

  uint32_t errors = 0;

  uint32_t core_idx = snrt_global_core_idx();

  uint32_t x_size = M_SIZE * N_SIZE * sizeof(uint16_t);
  uint32_t w_size = N_SIZE * K_SIZE * sizeof(uint16_t);
  uint32_t y_size = M_SIZE * K_SIZE * sizeof(uint16_t);
  uint32_t z_size = sizeof(golden);

  // Sum ucie 0 base address to all vectors to be transferred
  volatile uint32_t* x_inp_ucie = (volatile uint32_t*)((uintptr_t)&gwaihir_addrmap_32b.ucie[0] + (uintptr_t)x_inp);
  volatile uint32_t* w_inp_ucie = (volatile uint32_t*)((uintptr_t)&gwaihir_addrmap_32b.ucie[0] + (uintptr_t)w_inp);
  volatile uint32_t* y_inp_ucie = (volatile uint32_t*)((uintptr_t)&gwaihir_addrmap_32b.ucie[0] + (uintptr_t)y_inp);
  volatile uint32_t* golden_ucie = (volatile uint32_t*)((uintptr_t)&gwaihir_addrmap_32b.ucie[0] + (uintptr_t)golden);

  // Allocate space in TCDM and copy input vectors from L2 to TCDM
  if (snrt_is_dm_core()) {
    local_x = (uint16_t *) snrt_l1_alloc_cluster_local(x_size, 64);
    local_w = (uint16_t *) snrt_l1_alloc_cluster_local(w_size, 64);
    local_y = (uint16_t *) snrt_l1_alloc_cluster_local(y_size, 64);
    local_z = (uint32_t *) snrt_l1_alloc_cluster_local(z_size, 64);
    snrt_dma_start_1d(local_x, x_inp_ucie, x_size);
    snrt_dma_start_1d(local_w, w_inp_ucie, w_size);
    snrt_dma_start_1d(local_y, y_inp_ucie, y_size);
    snrt_dma_start_1d(local_z, golden_ucie, z_size);
    snrt_dma_wait_all();
  }

  snrt_cluster_hw_barrier();

  // Compare original vectors in L2 with the ones transferred in TCDM
  if (core_idx == 0) {

    for (uint32_t i = 0; i < M_SIZE * N_SIZE; i++) {
      errors += (local_x[i] != x_inp[i]);
    }

    for (uint32_t j = 0; j < N_SIZE * K_SIZE; j++) {
      errors += (local_w[j] != w_inp[j]);
    }

    for (uint32_t k = 0; k < M_SIZE * K_SIZE; k++) {
      errors += (local_y[k] != y_inp[k]);
    }

    for (uint32_t z = 0; z < sizeof(golden) / sizeof(golden[0]); z++) {
      errors += (local_z[z] != golden[z]);
    }
  }

  snrt_cluster_hw_barrier();

  return errors;
}