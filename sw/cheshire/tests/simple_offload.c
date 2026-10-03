// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

#include <stdint.h>
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

#include "snitch_cluster_cfg.h"

// Return code array placed at the last 4K page of the L2 SPM region.
// This address scales automatically with the number and size of memory tiles.
#define RETURN_CODE_ADDR \
  (GW_L2_SPM_BASE_ADDR(0) + GW_L2_SPM_TOTAL_SIZE - 0x1000)

// This needs to be in a region which is not cached
volatile uint32_t (*return_code_array)[CFG_CLUSTER_NR_CORES] = (uint32_t (*)[CFG_CLUSTER_NR_CORES])RETURN_CODE_ADDR;

void setup_iommu();

int main() {

  setup_iommu();

  // Write entry point to scratch register 1
  // and return code address to scratch register 0
  // Initalize return address loaction before offloading.
  for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
    *(volatile uint64_t *)&(gwaihir_addrmap_64b.cluster[i].peripheral_reg.scratch[1].w) = (uintptr_t) 0x00200000; //&gwaihir_addrmap_64b.l2_spm_0;
    *(volatile uint64_t *)&(gwaihir_addrmap_64b.cluster[i].peripheral_reg.scratch[0].w) = (uintptr_t)&return_code_array[i];
    for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
      return_code_array[i][j] = 0;
    }
  }

  // Start all cores in Cluster 0, which will wake up all other clusters
  *(volatile uint64_t *)&(gwaihir_addrmap_64b.cluster[0].peripheral_reg.cl_clint_set.w) = (1 << CFG_CLUSTER_NR_CORES) - 1;

  // Wait until all cores have finished
  int all_finished = 0;
  while (!all_finished) {
    all_finished = 1;
    for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
      for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
        if ((return_code_array[i][j] & 1) == 0) {
          all_finished = 0;
          break;
        }
      }
    }
  }

  // Sum up the return codes
  uint32_t sum = 0;
  for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
    for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
      sum += (return_code_array[i][j] >> 1);
    }
  }

  return sum;
}

//////////////////////
// PAGE TABLE SETUP //
//////////////////////

#include <stdint.h>

// Minimal Sv39 page tables: identity-map SPM and DRAM regions for U-mode.
#define PAGE_SHIFT   12UL
#define PAGE_SIZE    (1UL << PAGE_SHIFT)
#define PT_ENTRIES   512UL

#define PTE_V (1UL << 0)
#define PTE_R (1UL << 1)
#define PTE_W (1UL << 2)
#define PTE_X (1UL << 3)
#define PTE_U (1UL << 4)
#define PTE_G (1UL << 5)
#define PTE_A (1UL << 6)
#define PTE_D (1UL << 7)

#define DC_TC_VALID     (1ULL << 0)

#define IOSATP_MODE_BARE    (0x0ULL << 60)
#define IOSATP_MODE_SV39    (0x8ULL << 60)

#define DDTP_MODE_OFF   (0ULL)
#define DDTP_MODE_BARE  (1ULL)
#define DDTP_MODE_1LVL  (2ULL)
#define DDTP_MODE_2LVL  (3ULL)
#define DDTP_MODE_3LVL  (4ULL)

#define DDTP_PPN_MASK    (0x3FFFFFFFFFFC00ULL)

typedef struct ddt{
  uint64_t tc; // translation control
  uint64_t iohgatp; // IO hypervisor guest address translation and protection
  uint64_t ta; // translation attributes
  uint64_t fsc; // first-stage context
} ddt_t;

// DDTP (one device entry)
ddt_t root_ddt[1] __attribute__((aligned(PAGE_SIZE)));

// L2 PTEs: 0x000000000 - 0x8000000000 (512 GiB = 512 * 512 * 512 * 4KiB)
static uint64_t l2_pt[PT_ENTRIES] __attribute__((aligned(PAGE_SIZE)));
// L1 PTEs: 0x00000000 - 0x40000000 (1 GiB = 512 * 512 * 4 KiB)
static uint64_t l1_pt[PT_ENTRIES] __attribute__((aligned(PAGE_SIZE)));
// L0 PTEs: 0x21200000 - 0x21400000 (2 MiB = 512 * 4 KiB)
static uint64_t l0_pt[PT_ENTRIES] __attribute__((aligned(PAGE_SIZE)));

static void map_range(uint64_t *l1_pt, uint64_t *l0_pt, uintptr_t base, uintptr_t end, uintptr_t phys) {
  const uint64_t vpn2 = (base >> 30) & 0x1FF;
  const uint64_t vpn1 = (base >> 21) & 0x1FF;

  l2_pt[vpn2] = (((uint64_t)((uintptr_t)l1_pt >> PAGE_SHIFT)) << 10) | PTE_V;
  l1_pt[vpn1] = (((uint64_t)((uintptr_t)l0_pt >> PAGE_SHIFT)) << 10) | PTE_V;

  for (uintptr_t va = base, pa = phys; va < end; va += PAGE_SIZE, pa += PAGE_SIZE) {
      const uint64_t vpn0 = (va >> 12) & 0x1FF;
      const uint64_t ppn  = (uint64_t)(pa >> PAGE_SHIFT);
      l0_pt[vpn0] = (ppn << 10) | (PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D);
  }
}

void setup_iommu() {
  // Create IO-virtual mapping 0x0020_0000 -> 0x2120_0000 (2 MiB)
  map_range(l1_pt, l0_pt, 0x00200000, 0x00400000, 0x21200000);

  // Set DDT leaf entry 0
	root_ddt[0].tc = DC_TC_VALID;
	root_ddt[0].iohgatp = 0;
	root_ddt[0].ta = 0;
	root_ddt[0].fsc = (((uintptr_t)l2_pt) >> 12) | (IOSATP_MODE_SV39);

  // Write DDTP to IOMMU register
  uint64_t ddtp = ((((uintptr_t)root_ddt) >> 2) & DDTP_PPN_MASK) | (DDTP_MODE_1LVL);
  (*(uint64_t*)( ((void*) &(gwaihir_addrmap_64b.cheshire_internal.cheshire.iommu)) + 0x10)) = ddtp;

  asm volatile ("fence" ::: "memory");
}
