// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// LLC cache-mode test. Switches all LLC ways from SPM to cache, then checks
// misses vs hits, dirty evictions and a flush. Needs PRELMODE=4 (DRAM build);
// skips when not running from DRAM.

#include <stdint.h>
#include "regs/cheshire.h"
#include "regs/axi_llc.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"
#include "printf.h"

#define LINE_BYTES 64
#define LINE_DWORDS (LINE_BYTES / 8)
#define BUF_BASE 0x80400000UL
#define COLD_BASE (BUF_BASE + 0x100000UL)
#define EVICT_BASE (BUF_BASE + 0x200000UL)

extern void *__dram_base_addr__, *__dram_size__;

static inline uint32_t llc_rd(int offs) { return *reg32(&__llc_base_addr__, offs); }
static inline void llc_wr(int offs, uint32_t v) { *reg32(&__llc_base_addr__, offs) = v; }

static uint64_t pat(uint64_t i) { return 0x5a5a000000000000ULL ^ (i * 0x9e3779b97f4a7c15ULL); }

// One dword per LLC line
static uint64_t wr_pass(volatile uint64_t *b, uint64_t lines, uint64_t salt) {
  uint64_t t0 = get_mcycle();
  for (uint64_t i = 0; i < lines; i++) b[i * LINE_DWORDS] = pat(i + salt);
  fence();
  return get_mcycle() - t0;
}

static uint64_t rd_pass(volatile uint64_t *b, uint64_t lines, uint64_t salt, uint64_t *err) {
  uint64_t t0 = get_mcycle();
  for (uint64_t i = 0; i < lines; i++)
    if (b[i * LINE_DWORDS] != pat(i + salt)) (*err)++;
  return get_mcycle() - t0;
}

// Evict the L1 D$ by streaming through a region that aliases nothing we check
static void l1_evict(void) {
  volatile uint64_t *s = (volatile uint64_t *)EVICT_BASE;
  uint64_t acc = 0;
  for (uint64_t i = 0; i < (64 * 1024) / 8; i += LINE_DWORDS) acc += s[i];
  (void)acc;
  fence();
}

int main(void) {
  uint32_t rtc_freq = CHS_REGS->rtc_freq.f.ref_freq;
  uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
  uart_init(&__uart_base_addr__, reset_freq, __BOOT_BAUDRATE);

  // Switching the SPM ways to cache drops their contents, so run from DRAM only
  uintptr_t pc = (uintptr_t)&main, dram = (uintptr_t)&__dram_base_addr__;
  if (pc < dram || pc >= dram + (uintptr_t)&__dram_size__) {
    printf("[LLC] skip: not running from DRAM\n");
    uart_write_flush(&__uart_base_addr__);
    return 0;
  }

  uint32_t ways = llc_rd(AXI_LLC_SET_ASSO_LOW_REG_OFFSET);
  uint64_t llc_bytes = CHS_REGS->llc_size.f.llc_size;
  uint64_t small = (llc_bytes / 4) / LINE_BYTES;
  uint64_t big = (2 * llc_bytes) / LINE_BYTES;
  volatile uint64_t *buf = (volatile uint64_t *)BUF_BASE;
  volatile uint64_t *cold = (volatile uint64_t *)COLD_BASE;
  uint64_t err = 0;

  // Initialize the test regions while the LLC is still all SPM (not cached)
  wr_pass(cold, small, 3);
  wr_pass((volatile uint64_t *)EVICT_BASE, (64 * 1024) / LINE_BYTES, 0);

  llc_wr(AXI_LLC_CFG_SPM_LOW_REG_OFFSET, 0);
  llc_wr(AXI_LLC_CFG_SPM_HIGH_REG_OFFSET, 0);
  llc_wr(AXI_LLC_COMMIT_CFG_REG_OFFSET, 1);
  fence();
  l1_evict();

  // 1) Working set a quarter of the LLC: misses, then hits
  uint64_t t_miss = rd_pass(cold, small, 3, &err);
  l1_evict();
  uint64_t t_hit = rd_pass(cold, small, 3, &err);

  // 2) Working set 2x LLC: dirty evictions and refills
  wr_pass(buf, big, 7);
  rd_pass(buf, big, 7, &err);

  // 3) Dirty lines in the LLC, flush all ways, re-read from DRAM
  wr_pass(buf, small, 13);
  llc_wr(AXI_LLC_CFG_FLUSH_LOW_REG_OFFSET, (1u << ways) - 1);
  llc_wr(AXI_LLC_COMMIT_CFG_REG_OFFSET, 1);
  fence();
  // CFG_FLUSH clears when done; FLUSHED is reset to CFG_SPM at flush end
  while (llc_rd(AXI_LLC_CFG_FLUSH_LOW_REG_OFFSET) != 0);
  l1_evict();
  rd_pass(buf, small, 13, &err);

  printf("[LLC] miss=%lu hit=%lu err=%lu\n", t_miss, t_hit, err);
  uart_write_flush(&__uart_base_addr__);
  if (err) return 1;
  if (t_hit >= t_miss) return 2;
  return 0;
}
