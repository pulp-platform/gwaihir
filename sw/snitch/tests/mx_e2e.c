// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// iDMA -> MXCore -> iDMA on cluster 0, checked by experiments/mx_e2e/verify.py.
// FP32 A [M][K] and B [N][K] in L2 are gathered per (tile, k-tile) and
// quantized by the cluster DMA into MXCore's operand layout: A [mt][kt][r][32],
// B [nt][kt][n][32], scales [mt][kt][r] and [nt][kt][n] (MXFP8 E5M2, E8M0).
// MXCore computes C once in FP32 and once quantized; the DMA dequantizes the
// quantized result planes back to FP32.

#include "snrt.h"
#include "data/mx_e2e_data.h"
#include "gw_hwpe_subsystem_addrmap.h"

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

// Outputs read back by verify.py
uint8_t a_mx[MX_M * MX_K] __attribute__((aligned(64)));
uint8_t a_scale[MX_M * MX_K / MX_BLK] __attribute__((aligned(64)));
uint8_t b_mx[MX_N * MX_K] __attribute__((aligned(64)));
uint8_t b_scale[MX_N * MX_K / MX_BLK] __attribute__((aligned(64)));
float c_fp32[MX_M * MX_N] __attribute__((aligned(64)));
uint8_t c_mx[MX_M * MX_N] __attribute__((aligned(64)));
uint8_t c_scale[MX_M * MX_N / MX_BLK] __attribute__((aligned(64)));
float c_deq[MX_M * MX_N] __attribute__((aligned(64)));

// Same as snrt_dma_set_mx_scale_addr() from snitch_cluster#353
static inline void mx_set_scale_addr(uint32_t addr) {
    uint32_t v = addr >> IDMA_DMOPC_MX_SCALE_ADDR_UNIT_LOG2;
    snrt_dma_set_opcode_params(
        IDMA_DMOPC_OPC_MX_SCALE_ADDR | ((v & IDMA_DMOPC_RS1_MX_SADDR_LO_MASK)
                                        << IDMA_DMOPC_RS1_MX_SADDR_LO_SHIFT),
        v >> IDMA_DMOPC_RS1_MX_SADDR_LO_WIDTH);
}

// Gather `rows` x 32 FP32 per k-tile into `scratch` as [kt][row][32], then
// quantize it in one pass: data [kt][row][32], scales [kt][row]
static uint32_t mx_tile_quant(uint8_t *data, uint8_t *scale, float *src,
                              uint32_t rows, float *scratch) {
    snrt_dma_disable_compute();
    for (uint32_t kt = 0; kt < MX_KT; kt++)
        snrt_dma_start_2d(scratch + kt * rows * VS, src + kt * VS,
                          VS * sizeof(float), VS * sizeof(float),
                          MX_K * sizeof(float), rows);
    snrt_dma_wait_all();
    mx_set_scale_addr((uint32_t)scale);
    snrt_dma_set_opcode(IDMA_DMOPC_OPC_MX_QUANT | MX_OPTS_E5M2_G64);
    uint32_t id = snrt_dma_start_1d(data, scratch,
                                    MX_KT * rows * VS * sizeof(float));
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
    HWPE_REG(0x34) = (uint32_t)res_scale;
    HWPE_REG(0x38) = MX_M | (MX_K << 10) | (MX_N << 22);
    HWPE_REG(0x3C) = ctrl;
    HWPE_REG(0x40) = MX_MT | (MX_NT << 4) | (MX_KT << 9) |
                     ((MX_K / MX_BLK) << 16);
    HWPE_REG(0x44) = OBUFF * VS * 8;
    HWPE_REG(0x48) = VS * MXU * 8;
    HWPE_REG(0x4C) = MXU * OBUFF * (mxfp8 ? 8 : 32);
    HWPE_REG(0x50) = MX_K * OBUFF / VS;
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

    float *scratch = (float *)snrt_l1_alloc_cluster_local(
        MX_KT * OBUFF * VS * sizeof(float), 64);
    uint8_t *la = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(a_mx), 64);
    uint8_t *lsa = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(a_scale), 64);
    uint8_t *lb = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(b_mx), 64);
    uint8_t *lsb = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(b_scale), 64);
    float *lc = (float *)snrt_l1_alloc_cluster_local(sizeof(c_fp32), 64);
    uint8_t *lcq = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(c_mx), 64);
    uint8_t *lcs = (uint8_t *)snrt_l1_alloc_cluster_local(sizeof(c_scale), 64);

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
        snrt_dma_start_1d(a_mx, la, sizeof(a_mx));
        snrt_dma_start_1d(a_scale, lsa, sizeof(a_scale));
        snrt_dma_start_1d(b_mx, lb, sizeof(b_mx));
        snrt_dma_start_1d(b_scale, lsb, sizeof(b_scale));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    if (snrt_cluster_core_idx() == 0) {
        mxcore_run(la, lb, lsa, lsb, lc, lcs, MXCORE_CTRL_FP32);
        mxcore_run(la, lb, lsa, lsb, lcq, lcs, MXCORE_CTRL_MXFP8);
    }
    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(c_fp32, lc, sizeof(c_fp32));
        snrt_dma_start_1d(c_mx, lcq, sizeof(c_mx));
        snrt_dma_start_1d(c_scale, lcs, sizeof(c_scale));
        snrt_dma_wait_all();
        mx_set_scale_addr((uint32_t)lcs);
        snrt_dma_set_opcode(IDMA_DMOPC_OPC_MX_DEQUANT | MX_OPTS_E5M2_G64);
        if (!snrt_dma_start_1d(c_deq, lcq, sizeof(c_mx))) err++;
        snrt_dma_wait_all();
        snrt_dma_disable_compute();
    }
    snrt_cluster_hw_barrier();

    return err;
}
