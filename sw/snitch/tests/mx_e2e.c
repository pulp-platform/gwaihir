// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// iDMA -> MXCore -> iDMA on cluster 0, checked by experiments/mx_e2e/verify.py.
// FP32 (FP16 with MX_E2E_FP16) A [M][K] and B [N][K] in L2 are gathered per
// (tile, k-tile) and quantized by the cluster DMA into MXCore's operand layout:
// A [mt][kt][r][32], B [nt][kt][n][32], scales [mt][kt][r] and [nt][kt][n]
// (MXFP8 E5M2, E8M0). MXCore computes C once in FP32 and once quantized; the
// DMA dequantizes the quantized result planes back to the source format.

#include "snrt.h"
#include "gw_hwpe_subsystem_addrmap.h"

#ifdef MX_E2E_FP16
#include "data/mx_e2e_fp16_data.h"
typedef uint16_t mx_src_t;
#define MX_OPC_QUANT IDMA_DMOPC_OPC_MX_QUANT_FP16
#define MX_OPC_DEQUANT IDMA_DMOPC_OPC_MX_DEQUANT_FP16
#else
#include "data/mx_e2e_data.h"
typedef float mx_src_t;
#define MX_OPC_QUANT IDMA_DMOPC_OPC_MX_QUANT
#define MX_OPC_DEQUANT IDMA_DMOPC_OPC_MX_DEQUANT
#endif

#define VS 32
#define MXU 32
#define OBUFF 64
#define MX_BLK 32
#define MX_MT (MX_M / OBUFF)
#define MX_NT (MX_N / MXU)
#define MX_KT (MX_K / VS)

// MXCore REG_CTRL_ENGINE: MXDOTP, FP8 (E5M2) sources, FP32 result, RNE
#define MXCORE_CTRL_FP32 0x00000678u
#define MXCORE_CTRL_MXFP8 (MXCORE_CTRL_FP32 | (1u << 22))

#define HWPE_BASE GW_HWPE_BASE_ADDR(snrt_cluster_alias())
#define HWPE_REG(off) (*(volatile uint32_t *)(HWPE_BASE + (off)))

#define MX_OPTS_E5M2_G64 0u

#define A_BYTES (MX_M * MX_K)
#define B_BYTES (MX_N * MX_K)
#define C_BYTES (MX_M * MX_N)
#define C_DEQ_BYTES (C_BYTES * sizeof(mx_src_t))

// Outputs read back by verify.py, each between two GUARD-byte canaries. The
// canaries are preloaded: core stores to them made MXCore hang.
#define GUARD 64
#define C8 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5
#define C64 C8, C8, C8, C8, C8, C8, C8, C8
#define GUARDED(name, n)                                     \
    struct {                                                 \
        uint8_t pre[GUARD], buf[n], post[GUARD];             \
    } name __attribute__((aligned(64))) = {{C64}, {}, {C64}}
GUARDED(a_mx, A_BYTES);
GUARDED(a_scale, A_BYTES / MX_BLK);
GUARDED(b_mx, B_BYTES);
GUARDED(b_scale, B_BYTES / MX_BLK);
GUARDED(c_fp32, C_BYTES * sizeof(float));
GUARDED(c_mx, C_BYTES);
GUARDED(c_scale, C_BYTES / MX_BLK);
GUARDED(c_deq, C_DEQ_BYTES);

static uint8_t *l1_alloc(uint32_t n) {
    return (uint8_t *)snrt_l1_alloc_cluster_local(n, 64);
}

// Same as snrt_dma_set_mx_scale_addr() from snitch_cluster#353
static inline void mx_set_scale_addr(uint32_t addr) {
    uint32_t v = addr >> IDMA_DMOPC_MX_SCALE_ADDR_UNIT_LOG2;
    snrt_dma_set_opcode_params(
        IDMA_DMOPC_OPC_MX_SCALE_ADDR | ((v & IDMA_DMOPC_RS1_MX_SADDR_LO_MASK)
                                        << IDMA_DMOPC_RS1_MX_SADDR_LO_SHIFT),
        v >> IDMA_DMOPC_RS1_MX_SADDR_LO_WIDTH);
}

// Gather `rows` x 32 elements per k-tile into `scratch` as [kt][row][32], then
// quantize it in one pass: data [kt][row][32], scales [kt][row]
static uint32_t mx_tile_quant(uint8_t *data, uint8_t *scale, mx_src_t *src,
                              uint32_t rows, mx_src_t *scratch) {
    snrt_dma_disable_compute();
    for (uint32_t kt = 0; kt < MX_KT; kt++)
        snrt_dma_start_2d(scratch + kt * rows * VS, src + kt * VS,
                          VS * sizeof(mx_src_t), VS * sizeof(mx_src_t),
                          MX_K * sizeof(mx_src_t), rows);
    snrt_dma_wait_all();
    mx_set_scale_addr((uint32_t)scale);
    snrt_dma_set_opcode(MX_OPC_QUANT | MX_OPTS_E5M2_G64);
    uint32_t id = snrt_dma_start_1d(data, scratch,
                                    MX_KT * rows * VS * sizeof(mx_src_t));
    snrt_dma_wait_all();
    snrt_dma_disable_compute();
    return id == 0;
}

static void mxcore_run(void *a, void *b, void *sa, void *sb, void *res,
                       void *res_scale, uint32_t ctrl) {
    uint32_t mxfp8 = (ctrl >> 22) & 1u;
    HWPE_REG(GW_HWPE_CLK_EN_OFFS) = GW_HWPE_CLK_EN_ACC;
    HWPE_REG(0x14) = 0;
    while ((int32_t)HWPE_REG(0x04) < 0);
    HWPE_REG(0x20) = (uint32_t)a;
    HWPE_REG(0x24) = (uint32_t)b;
    HWPE_REG(0x28) = (uint32_t)sa;
    HWPE_REG(0x2C) = (uint32_t)sb;
    HWPE_REG(0x30) = (uint32_t)res;
    HWPE_REG(0x34) = (uint32_t)res;
    HWPE_REG(0x38) = (uint32_t)res_scale;
    HWPE_REG(0x3C) = MX_M | (MX_K << 10) | (MX_N << 22);
    HWPE_REG(0x40) = ctrl;
    HWPE_REG(0x44) = MX_MT | (MX_NT << 4) | (MX_KT << 9) |
                     ((MX_K / MX_BLK) << 16) | ((MX_BLK / VS) << 23);
    HWPE_REG(0x48) = OBUFF * VS * 8;
    HWPE_REG(0x4C) = VS * MXU * 8;
    HWPE_REG(0x50) = MXU * OBUFF * 32;
    HWPE_REG(0x54) = MXU * OBUFF * (mxfp8 ? 8 : 32);
    HWPE_REG(0x58) = (MXU / MX_BLK) * OBUFF * 8;
    HWPE_REG(0x5C) = MX_K * OBUFF / VS;
    HWPE_REG(0x00) = 0;
    snrt_interrupt_enable(IRQ_M_ACC);
    while (HWPE_REG(0x0C) != 0) snrt_wfi();
    *(volatile uint32_t *)(HWPE_BASE + GW_HWPE_EVT_CLR_OFFS) =
        1u << snrt_cluster_core_idx();
    snrt_interrupt_disable(IRQ_M_ACC);
    HWPE_REG(GW_HWPE_CLK_EN_OFFS) = 0;
}

int main() {
    if (snrt_cluster_idx() != 0) return 0;

    snrt_int_clr_mcip();

    // Same TCDM layout for both variants
    mx_src_t *scratch = (mx_src_t *)l1_alloc(MX_KT * OBUFF * VS * sizeof(float));
    uint8_t *la = l1_alloc(A_BYTES);
    uint8_t *lsa = l1_alloc(A_BYTES / MX_BLK);
    uint8_t *lb = l1_alloc(B_BYTES);
    uint8_t *lsb = l1_alloc(B_BYTES / MX_BLK);
    uint8_t *lc = l1_alloc(C_BYTES * sizeof(float));
    uint8_t *lcq = l1_alloc(C_BYTES);
    uint8_t *lcs = l1_alloc(C_BYTES / MX_BLK);

    uint32_t err = 0;
    if (snrt_is_dm_core()) {
        for (uint32_t mt = 0; mt < MX_MT; mt++)
            err += mx_tile_quant(la + mt * MX_KT * OBUFF * VS,
                                 lsa + mt * MX_KT * OBUFF,
                                 mx_a + mt * OBUFF * MX_K, OBUFF, scratch);
        for (uint32_t nt = 0; nt < MX_NT; nt++)
            err += mx_tile_quant(lb + nt * MX_KT * MXU * VS,
                                 lsb + nt * MX_KT * MXU,
                                 mx_b + nt * MXU * MX_K, MXU, scratch);
        snrt_dma_start_1d(a_mx.buf, la, A_BYTES);
        snrt_dma_start_1d(a_scale.buf, lsa, A_BYTES / MX_BLK);
        snrt_dma_start_1d(b_mx.buf, lb, B_BYTES);
        snrt_dma_start_1d(b_scale.buf, lsb, B_BYTES / MX_BLK);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    if (snrt_cluster_core_idx() == 0) {
        mxcore_run(la, lb, lsa, lsb, lc, lcs, MXCORE_CTRL_FP32);
        mxcore_run(la, lb, lsa, lsb, lcq, lcs, MXCORE_CTRL_MXFP8);
    }
    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(c_fp32.buf, lc, C_BYTES * sizeof(float));
        snrt_dma_start_1d(c_mx.buf, lcq, C_BYTES);
        snrt_dma_start_1d(c_scale.buf, lcs, C_BYTES / MX_BLK);
        snrt_dma_wait_all();
        mx_set_scale_addr((uint32_t)lcs);
        snrt_dma_set_opcode(MX_OPC_DEQUANT | MX_OPTS_E5M2_G64);
        if (!snrt_dma_start_1d(c_deq.buf, lcq, C_BYTES)) err++;
        snrt_dma_wait_all();
        snrt_dma_disable_compute();
    }
    snrt_cluster_hw_barrier();

    return err;
}
