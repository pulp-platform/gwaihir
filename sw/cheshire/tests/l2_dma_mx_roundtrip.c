// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-device MX quant<->dequant ROUND-TRIP through the mem-tile iDMA, driven by
// CVA6 over the NoC (reg64 frontend). Two chained on-the-fly compute transfers:
//
//   S (FP16, tile SRC)  --MX-quant   (COMPUTE_MXQUANT_FP16)-->  M (MXFP8, tile MID)
//   M (MXFP8, tile MID) --MX-dequant (COMPUTE_MXDEQUANT)    -->  D (FP32,  tile SRC)
//
//   MXFP8 block layout: 33B-inline  [1B E8M0 scale][32B E5M2].
//
// Each transform is selected by writing the DRIVER tile's compute_cfg register
// (sticky; sampled when next_id is read to launch the transfer).
//
// CVA6 verifies BOTH stages against the iDMA goldens (idma_mx_golden.h):
//   - M vs quantize_fp32_e5m2 / block_scale_e5m2  (the quant stage)
//   - D vs dequant_e5m2_fp32                      (the dequant stage)
// so a failure localizes to quant vs dequant. Returns 0 on a byte-exact pass, else:
//   1000000 + block            => M inline SCALE byte mismatch (quant)
//   2000000 + block*32 + elem   => M E5M2 DATA byte mismatch    (quant)
//   3000000 + block*32 + elem   => D FP32 word mismatch         (dequant)

#include <stddef.h>
#include <stdint.h>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"   // GW_L2_SPM_NUM
#include "memtile_idma.h"
#include "idma_mx_golden.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source S (offset 0) and FP32 result D (offset D_OFF)
#define MID_TILE     1   // MXFP8 intermediate M
#define DRIVER_TILE  1   // whose iDMA drives both transfers
#define D_OFF        0x10000u  // D lives well past S inside SRC_TILE's L2 SPM


// ---- Geometry --------------------------------------------------------------
// 64 blocks: quant out = 64*33 = 2112 B and dequant out = 64*128 = 8192 B are
// both 64-B beat-aligned, and 2112 B satisfies the dequant read-length fence
// (multiple of 33*StrbWidth). Corner bands (subnormal/flush/saturation/Inf-NaN)
// live in the LAST 6 blocks (see mx_stim_fp16).
enum { kBlockSize = 32, kTotalBlocks = 64 };
#define MX_BLOCK_OUT_BYTES 33u   // [1B E8M0 scale][32B E5M2]

// ============================================================================

int main(void) {
    volatile uint16_t *S = (volatile uint16_t *)gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint8_t  *M = (volatile uint8_t  *)gwaihir_addrmap.l2_spm[MID_TILE].mem;
    volatile uint32_t *D = (volatile uint32_t *)((uintptr_t)gwaihir_addrmap.l2_spm[SRC_TILE].mem + D_OFF);

    const uint32_t s_elems = (uint32_t)kTotalBlocks * kBlockSize;                            // 2048
    const uint32_t s_bytes = (uint32_t)kTotalBlocks * kBlockSize * (uint32_t)sizeof(uint16_t); // 4096
    const uint32_t m_bytes = (uint32_t)kTotalBlocks * MX_BLOCK_OUT_BYTES;                       // 2112
    const uint32_t d_words = (uint32_t)kTotalBlocks * kBlockSize;                               // 2048 (8192 B)

    // 1) Fill FP16 source.
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            S[b * kBlockSize + lane] = mx_stim_fp16((uint32_t)(b * kBlockSize + lane), s_elems);

    // Poison M and D so a no-op transform cannot masquerade as a pass (64-bit stores).
    volatile uint64_t *M64 = (volatile uint64_t *)M;
    for (uint32_t i = 0; i < m_bytes / 8u; ++i) M64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (m_bytes / 8u) * 8u; i < m_bytes; ++i) M[i] = 0xA5u;
    for (uint32_t i = 0; i < d_words; ++i) D[i] = 0xDEADBEEFu;

    // 2) Quant: FP16 S -> MXFP8 M (descriptor LENGTH = READ bytes = s_bytes).
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXQUANT_FP16);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)M, (uint64_t)(uintptr_t)S, s_bytes, 0);

    // 3) Dequant: MXFP8 M -> FP32 D (LENGTH = READ bytes = m_bytes).
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXDEQUANT);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)D, (uint64_t)(uintptr_t)M, m_bytes, 0);

    // 4) Restore passthrough.
    memtile_dma_passthrough(DRIVER_TILE);

    // 5) Verify both stages against the goldens.
    uint32_t scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32_bits(S[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        int scaled = (int)(int8_t)scale;

        volatile uint8_t *mblk = M + b * MX_BLOCK_OUT_BYTES;
        if (mblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);                        // quant scale

        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t e5m2 = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (mblk[1 + i] != e5m2)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i)); // quant data
            uint32_t expect = dequant_e5m2_fp32(e5m2, scaled);
            if (D[b * kBlockSize + i] != expect)
                return (int)(3000000u + (uint32_t)(b * kBlockSize + i)); // dequant
        }
    }

    return 0;
}
