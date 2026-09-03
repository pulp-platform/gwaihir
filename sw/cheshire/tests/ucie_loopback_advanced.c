// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// UCIe AXI loopback: prove that AXI traffic aimed at a peer chiplet's L2 really
// crosses the UCIe serial link and re-enters the NoC at the right canonical
// address. This is the AXI-level counterpart of `ucie_raw_mode_loopback.c`,
// which only checks the raw (link bring-up) path.
//
// `gwaihir_top` wires TX0->RX1 and TX1->RX0, so both alias windows resolve back
// into this chiplet's own NoC, each through a different ingress translation
// (`unalias_ucie_address` in `gwaihir_pkg`):
//   * a request into the ucie0 window leaves through ucie0 and enters ucie1,
//     which clears the alias bits AND applies the half shift
//     (l2_spm[i] -> l2_spm[i + NumMemTiles/2]): ucie0.l2_spm_0 -> l2_spm_2;
//   * a request into the ucie1 window leaves through ucie1 and enters ucie0,
//     which only clears the alias bits (pass-through): ucie1.l2_spm_0 ->
//     l2_spm_0.
// Both windows are exercised, and each in both traffic directions: written
// through the alias and read back canonically (AW/W/B over the link), then
// written canonically and read back through the alias (AR/R over the link).
// Every target block is poisoned with the complement of the payload first, so a
// request that never crosses the link cannot pass by finding the expected value
// already in memory.
//
// Returns 0 on success; on failure the exit code localizes the access, see the
// ERR_/DIR_/PHASE_ defines below.

#include <stdint.h>
#include <assert.h>

#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

// ---- Failure codes --------------------------------------------------------
// Tile bring-up (< 100): one code per tile config block.
#define ERR_UCIE0_TILE_CFG 1
#define ERR_UCIE1_TILE_CFG 2
#define ERR_MEM_TILE_CFG(t) (3 + (int)(t))
// Data checks: DIR + PHASE + index of the failing word within the probe set.
#define DIR_VIA_UCIE0 1000
#define DIR_VIA_UCIE1 2000
#define PHASE_LOCAL_WR_32 100   // poison read-back; the link is not involved
#define PHASE_REMOTE_WR_32 200  // written through the alias, read canonically
#define PHASE_LOCAL_RD_32 300   // local fill read-back; the link is not involved
#define PHASE_REMOTE_RD_32 400  // written canonically, read through the alias
#define PHASE_LOCAL_WR_64 500
#define PHASE_REMOTE_WR_64 600
#define PHASE_LOCAL_RD_64 700
#define PHASE_REMOTE_RD_64 800

// ---- Payloads -------------------------------------------------------------
// Index-dependent payloads: a dropped, duplicated or shifted beat cannot look
// like a match. One seed per phase, so a stale value left by the previous phase
// is caught as well.
#define SEED_REMOTE_WR 0xdead0000u
#define SEED_REMOTE_RD 0xbeef0000u
#define PATTERN_64 0x0123456789abcdefULL

// ---- Probe geometry -------------------------------------------------------
// Words probed inside each window: the first block, one in the middle and the
// last one, so a decode error in the upper alias-address bits cannot hide
// behind an offset-0-only check.
#define BLOCK_WORDS 8
#define NUM_PROBES 3
#define WINDOW_WORDS (sizeof(gwaihir_addrmap_64b.ucie0.l2_spm_0.mem) / sizeof(uint32_t))
// One doubleword probe as well: CVA6 issues 64-bit accesses, so the link sees a
// size/strobe pattern the 32-bit probes above never produce. Kept 8-byte
// aligned and clear of the 32-bit blocks.
#define DWORD_WORD_OFF ((WINDOW_WORDS / 4) & ~1u)

// The probes assume an alias window and the canonical tile it maps to have the
// same size: the half shift maps a large tile onto a large tile.
static_assert(sizeof(gwaihir_addrmap_64b.ucie0.l2_spm_0) == sizeof(gwaihir_addrmap_64b.l2_spm_2),
              "ucie0.l2_spm_0 and l2_spm_2 must have the same size");
static_assert(sizeof(gwaihir_addrmap_64b.ucie1.l2_spm_0) == sizeof(gwaihir_addrmap_64b.l2_spm_0),
              "ucie1.l2_spm_0 and l2_spm_0 must have the same size");

static const uint32_t probe_word[NUM_PROBES] = {0, WINDOW_WORDS / 2, WINDOW_WORDS - BLOCK_WORDS};

static inline uint32_t pattern(uint32_t seed, uint32_t i) {
  return seed + i * 0x01010101u;
}

// Check one alias window against the canonical address it resolves to.
// `dir` is the DIR_* base folded into every failure code.
static int check_window(volatile uint32_t *alias, volatile uint32_t *canon, int dir) {
  // Poison the target through the local NoC, then read it back. The read-back
  // both proves the local path works (so a later mismatch is the link's fault,
  // not the memory's) and guarantees the poison has landed before any remote
  // write is issued.
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      canon[probe_word[p] + w] = ~pattern(SEED_REMOTE_WR, w);
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      if (canon[probe_word[p] + w] != ~pattern(SEED_REMOTE_WR, w))
        return dir + PHASE_LOCAL_WR_32 + (int)(p * BLOCK_WORDS + w);

  // Remote write: cross the link through the alias window, read back locally.
  fence();
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      alias[probe_word[p] + w] = pattern(SEED_REMOTE_WR, w);
  fence();
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      if (canon[probe_word[p] + w] != pattern(SEED_REMOTE_WR, w))
        return dir + PHASE_REMOTE_WR_32 + (int)(p * BLOCK_WORDS + w);

  // Remote read: write locally, then pull the data back over the link. The
  // canonical read-back again forces the local writes to complete first.
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      canon[probe_word[p] + w] = pattern(SEED_REMOTE_RD, w);
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      if (canon[probe_word[p] + w] != pattern(SEED_REMOTE_RD, w))
        return dir + PHASE_LOCAL_RD_32 + (int)(p * BLOCK_WORDS + w);
  fence();
  for (uint32_t p = 0; p < NUM_PROBES; p++)
    for (uint32_t w = 0; w < BLOCK_WORDS; w++)
      if (alias[probe_word[p] + w] != pattern(SEED_REMOTE_RD, w))
        return dir + PHASE_REMOTE_RD_32 + (int)(p * BLOCK_WORDS + w);

  // The same two link directions once more, with a single 64-bit access.
  volatile uint64_t *alias_dw = (volatile uint64_t *)(alias + DWORD_WORD_OFF);
  volatile uint64_t *canon_dw = (volatile uint64_t *)(canon + DWORD_WORD_OFF);

  *canon_dw = ~PATTERN_64;
  if (*canon_dw != ~PATTERN_64) return dir + PHASE_LOCAL_WR_64;
  fence();
  *alias_dw = PATTERN_64;
  fence();
  if (*canon_dw != PATTERN_64) return dir + PHASE_REMOTE_WR_64;

  *canon_dw = ~PATTERN_64;
  if (*canon_dw != ~PATTERN_64) return dir + PHASE_LOCAL_RD_64;
  fence();
  if (*alias_dw != ~PATTERN_64) return dir + PHASE_REMOTE_RD_64;

  return 0;
}

int main(void) {

  // Bring up every tile this test drives traffic through. The testbench already
  // ungates the L2 tiles over JTAG / serial link, but not the UCIe tiles; doing
  // all of them here keeps the test self-contained. The UCIe tile config block
  // itself sits on the always-on clock and reset, so it stays reachable while
  // the tile is gated.
  CHECK_ASSERT(ERR_UCIE0_TILE_CFG, tile_enable(&gwaihir_addrmap_64b.ucie0_tile_cfg));
  CHECK_ASSERT(ERR_UCIE1_TILE_CFG, tile_enable(&gwaihir_addrmap_64b.ucie1_tile_cfg));

  for (uint32_t t = 0; t < GW_L2_SPM_NUM; t++) {
    volatile gw_tile_regs_t *mem_cfg =
        (volatile gw_tile_regs_t *)(uintptr_t)GW_L2_SPM_CONFIG_BASE_ADDR(t);
    CHECK_ASSERT(ERR_MEM_TILE_CFG(t), tile_enable(mem_cfg));
  }

  // ucie0 window: alias bits cleared plus half shift, so tile 0 as seen from
  // the peer is this chiplet's tile 2.
  CHECK_CALL(check_window((volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm_0,
                          (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm_2, DIR_VIA_UCIE0));

  // ucie1 window: pass-through, so tile 0 stays tile 0.
  CHECK_CALL(check_window((volatile uint32_t *)&gwaihir_addrmap_64b.ucie1.l2_spm_0,
                          (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm_0, DIR_VIA_UCIE1));

  return 0;
}
