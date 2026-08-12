// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

// Two-phase raw-mode SLINK proof:
//
// Phase 1 injects a single AXI write through the UCIe0 raw-mode TX path,
// hand-encoding real `slink_prot_layer` flits so UCIe1's *normal* (non-raw)
// AXI decode path deserializes them into an actual NoC write, verified
// through the local NoC address map. This exercises raw mode purely as a TX
// injection mechanism.
//
// Phase 2 covers what Phase 1 cannot: a real receiver polling
// `raw_mode_in_data_valid[]`/reading `raw_mode_in_data[]` while *it* is in
// raw mode too. It sends one plain (non-AXI) pattern sample UCIe0->UCIe1,
// then repeats UCIe1->UCIe0, comparing the received words verbatim. This is
// the actual diagnostic/calibration use case raw mode exists for. Phase 2's
// machinery (`slink_raw_round_trip` & friends) lives in `slink_raw.h` since
// it's scenario-agnostic and reusable by other raw-mode tests; only Phase 1's
// AXI-injection trick, which is specific to this test, stays here.
//
// `build_aw_packet`/`build_w_packet` (Phase 1 only) hand-encode `slink_serializer.sv`'s
// internal `payload_t` (credit/hdr/b/b_valid/axi_ch, LSB-to-MSB) with the
// `axi_ch` field cast to `AXI_DECL_AW_CHAN_T`/`AXI_DECL_W_CHAN_T`
// (`axi/typedef.svh`, packed field order id/addr/len/size/burst/lock/cache/
// prot/qos/region/atop/user for AW; data/strb/last/user for W, MSB-to-LSB as
// listed). The bit offsets below are only valid for the current UCIe join
// parametrization and must be re-derived if any of these change:
//   - credit_t width (4b)   = $clog2(NumCredits)+1, NumCredits=8 (slink_serializer.sv)
//   - hdr width (4b)        = $bits(slink_pkg::tag_e)
//   - b_chan_t width (5b)   = id(2) + resp(2) + user(1), from
//                             AxiCfgUcieJoin = axi_join_cfg(AxiCfgNoAtop, AxiCfgW)
//                             -> OutIdWidth=2 (max(1,1)+1 mux bit), UserWidth=1
//                             (gwaihir_pkg.sv)
//   - axi_ch base (14b)     = credit(4) + hdr(4) + b_valid(1) + b_chan_t(5)
//   - aw addr/id widths     = AxiCfgUcieJoin.AddrWidth=48, OutIdWidth=2
//   - w data/strb widths    = AxiCfgUcieJoin.DataWidth=512 (max of narrow 64b,
//                             wide 512b)
// RAW_WORDS_PER_SAMPLE/RAW_SAMPLES_PER_PKT (in slink_raw.h) likewise depend on
// NumLanes=256, EnDdr=0 (one raw sample == one `NumBitsPerCycle`-wide
// phy_data cycle) and on $bits(payload_t) (3 samples needed to fit one AW or
// W flit).

#include <stdint.h>

#include "gw_addrmap_64b.h"
#include "slink_raw.h"

#define TEST_DATA 0x51a5cafeu
#define POISON_DATA 0x0badf00du

#define SLINK_TAG_AW 1u
#define SLINK_TAG_W 2u

#define AXI_BURST_INCR 1u
#define AXI_SIZE_64B 6u
#define AXI_CACHE_MODIFIABLE_BUFFERABLE 0x3u

#define RAW_PATTERN_SEED_FWD 0xdead0000u  // UCIe0 -> UCIe1
#define RAW_PATTERN_SEED_REV 0xbeef0000u  // UCIe1 -> UCIe0

// Phase 2 exit codes, offset past Phase 1's (1..5) so a failure's phase is
// unambiguous from the return code alone.
#define ERR_FWD_PUSH 6
#define ERR_FWD_RX_TIMEOUT 7
#define ERR_FWD_MISMATCH 8
#define ERR_REV_PUSH 9
#define ERR_REV_RX_TIMEOUT 10
#define ERR_REV_MISMATCH 11

static void build_aw_packet(uint32_t *packet, uintptr_t addr) {
  const uint32_t axi_ch = 14;

  clear_packet(packet);

  set_bits(packet, 0, 4, 0);              // credit
  set_bits(packet, 4, 4, SLINK_TAG_AW);   // hdr
  set_bits(packet, axi_ch + 0, 1, 0);     // aw.user
  set_bits(packet, axi_ch + 1, 6, 0);     // aw.atop
  set_bits(packet, axi_ch + 7, 4, 0);     // aw.region
  set_bits(packet, axi_ch + 11, 4, 0);    // aw.qos
  set_bits(packet, axi_ch + 15, 3, 0);    // aw.prot
  set_bits(packet, axi_ch + 18, 4, AXI_CACHE_MODIFIABLE_BUFFERABLE);
  set_bits(packet, axi_ch + 22, 1, 0);    // aw.lock
  set_bits(packet, axi_ch + 23, 2, AXI_BURST_INCR);
  set_bits(packet, axi_ch + 25, 3, AXI_SIZE_64B);
  set_bits(packet, axi_ch + 28, 8, 0);    // aw.len
  set_bits(packet, axi_ch + 36, 48, addr);
  set_bits(packet, axi_ch + 84, 2, 0);    // aw.id
}

static void build_w_packet(uint32_t *packet, uint32_t data) {
  uint32_t wide_data[16] = {0};
  uint32_t wide_strb[2] = {0xffffffffu, 0xffffffffu};

  clear_packet(packet);
  wide_data[0] = data;

  set_bits(packet, 0, 4, 0);             // credit
  set_bits(packet, 4, 4, SLINK_TAG_W);   // hdr
  set_bits(packet, 14 + 0, 1, 0);        // w.user
  set_bits(packet, 14 + 1, 1, 1);        // w.last
  set_u32_words(packet, 14 + 2, wide_strb, 2);
  set_u32_words(packet, 14 + 66, wide_data, 16);
}

int main() {
  uint32_t aw_packet[PACKET_WORDS];
  uint32_t w_packet[PACKET_WORDS];

  slink_regs_t *ucie0_slink = &gwaihir_addrmap_64b.ucie0_axi_serial_cfg.regs;
  slink_regs_t *ucie1_slink = &gwaihir_addrmap_64b.ucie1_axi_serial_cfg.regs;

  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm[0];
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm[2];

  *local_rd = POISON_DATA;
  fence();

  slink_raw_disable(ucie1_slink);
  slink_raw_configure_tx(ucie0_slink);

  build_aw_packet(aw_packet, (uintptr_t)alias_wr);
  build_w_packet(w_packet, TEST_DATA);

  if (slink_raw_push_packet(ucie0_slink, aw_packet)) {
    slink_raw_disable(ucie0_slink);
    return 2;
  }

  if (slink_raw_push_packet(ucie0_slink, w_packet)) {
    slink_raw_disable(ucie0_slink);
    return 3;
  }

  int phase1_ok = 0;
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    fence();
    if (*local_rd == TEST_DATA) {
      phase1_ok = 1;
      break;
    }
  }

  if (!phase1_ok) {
    slink_raw_disable(ucie0_slink);
    return 4;
  }

  if (slink_raw_drop_packet(ucie0_slink)) {
    return 5;
  }
  slink_raw_disable(ucie0_slink);

  // Phase 2: symmetric raw round-trip, exercising the raw_mode_in_data[]/
  // raw_mode_in_data_valid[] RX path that Phase 1's AXI-injection trick never
  // touches (ucie1 there stays in normal mode throughout).
  int rc = slink_raw_round_trip(ucie0_slink, ucie1_slink, RAW_PATTERN_SEED_FWD);
  if (rc) {
    return ERR_FWD_PUSH + (rc - 1);
  }

  rc = slink_raw_round_trip(ucie1_slink, ucie0_slink, RAW_PATTERN_SEED_REV);
  if (rc) {
    return ERR_REV_PUSH + (rc - 1);
  }

  return 0;
}
