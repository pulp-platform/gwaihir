// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-device check of the mem-tile iDMA FP16 MX-quant path (on-the-fly compute,
// COMPUTE_MXQUANT_FP16), driven by CVA6 over the NoC (reg64 frontend).
//
//   FP16 (E5M10) source in SRC_TILE's L2 SPM  --MX-quant-->  MXFP8 (E5M2)
//   in DST_TILE's L2 SPM, one 33B-inline block per 32 elements:
//   [1B E8M0 scale][32B E5M2].
//
// DRIVER_TILE's iDMA does the transfer. The transform is selected by writing
// the tile's compute_cfg register (enable + op); the config is sampled when
// next_id is read to launch the transfer.
//
// CVA6 verifies every output byte against the iDMA golden (idma_mx_golden.h:
// widen FP16->FP32, derive the block scale from the FP32 exponents, run the same
// fp32->e5m2 quantizer). Returns 0 on a byte-exact pass, else a debug code:
//   1000000 + block            => inline SCALE byte mismatch at that block
//   2000000 + block*32 + elem   => E5M2 DATA byte mismatch at that element

#include <stddef.h>
#include <stdint.h>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"   // GW_L2_SPM_NUM
#include "memtile_idma.h"
#include "idma_mx_golden.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source buffer
#define DST_TILE     1   // MXFP8 destination buffer
#define DRIVER_TILE  1   // whose iDMA drives the transfer


// ---- Geometry --------------------------------------------------------------
// The corner-case bands live in the LAST 6 blocks (see mx_stim_fp16), so even a
// small run exercises subnormal / flush / saturation / Inf-NaN. Raise for a more
// exhaustive normal-band sweep (cost is ~linear in CVA6 NoC round-trips).
enum { kBlockSize = 32, kTotalBlocks = 64 };  // 64*33=2112 B dst (64-B beat-aligned)
#define MX_BLOCK_OUT_BYTES 33u   // [1B E8M0 scale][32B E5M2]

// ============================================================================

int main(void) {
    volatile uint16_t *src = (volatile uint16_t *)gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint8_t  *dst = (volatile uint8_t  *)gwaihir_addrmap.l2_spm[DST_TILE].mem;

    const uint32_t src_elems = (uint32_t)kTotalBlocks * kBlockSize;                            // 2048
    const uint32_t src_bytes = (uint32_t)kTotalBlocks * kBlockSize * (uint32_t)sizeof(uint16_t); // 4096
    const uint32_t dst_bytes = (uint32_t)kTotalBlocks * MX_BLOCK_OUT_BYTES;                       // 2112

    // 1) Fill the FP16 source in SRC_TILE's L2 SPM.
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            src[b * kBlockSize + lane] = mx_stim_fp16((uint32_t)(b * kBlockSize + lane), src_elems);

    // Poison the destination so a no-op DMA cannot masquerade as a pass.
    // 64-bit stores keep the NoC round-trip count low (dst_bytes is 8-aligned here).
    volatile uint64_t *dst64 = (volatile uint64_t *)dst;
    for (uint32_t i = 0; i < dst_bytes / 8u; ++i) dst64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (dst_bytes / 8u) * 8u; i < dst_bytes; ++i) dst[i] = 0xA5u;

    // 2) Select the FP16 MX-quant op on the driver tile (sticky compute_cfg).
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXQUANT_FP16);

    // 3) Issue the transfer: read src_bytes of FP16 from SRC_TILE, quantize
    //    on the fly, write the 33B-inline MXFP8 blocks to DST_TILE. The reg64
    //    LENGTH is the READ (input) byte count; the legalizer derives the write
    //    length (src_bytes * 33/64). Blocking (polls done_id).
    memtile_dma_blk_memcpy(
        /*tile=*/ DRIVER_TILE,
        /*dst=*/  (uint64_t)(uintptr_t)dst,
        /*src=*/  (uint64_t)(uintptr_t)src,
        /*size=*/ src_bytes,
        /*conf=*/ 0);

    // 4) Restore passthrough so the sticky op does not leak to later users.
    memtile_dma_passthrough(DRIVER_TILE);

    // 5) Verify every output byte against the golden.
    uint32_t scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32_bits(src[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        volatile uint8_t *oblk = dst + b * MX_BLOCK_OUT_BYTES;
        if (oblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);                  // inline scale mismatch
        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t expect = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (oblk[1 + i] != expect)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i)); // data mismatch
        }
    }

    return 0;
}
