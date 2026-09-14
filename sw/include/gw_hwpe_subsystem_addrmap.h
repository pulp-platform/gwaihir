// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Address map of the HWPE subsystem of a cluster tile. Window 0 holds the
// accelerator, window 1 the datamover, and the control block follows both
// windows. The frame is the same for MXCore and Surya.

#pragma once

#include <stdint.h>

// The subsystem sits in the `ext_mem` window of the cluster, after the zero memory.
#define GW_HWPE_BASE_ADDR(cluster) \
  ((uintptr_t)(cluster)->zeromem.mem + sizeof((cluster)->zeromem.mem))

#define GW_HWPE_ACC_WINDOW 0x200

#define GW_HWPE_ACC_OFFS       (0 * GW_HWPE_ACC_WINDOW)
#define GW_HWPE_DATAMOVER_OFFS (1 * GW_HWPE_ACC_WINDOW)
#define GW_HWPE_CTRL_OFFS      (2 * GW_HWPE_ACC_WINDOW)

#define GW_HWPE_EVT_CLR_OFFS (GW_HWPE_CTRL_OFFS + 0x0)
#define GW_HWPE_MUX_SEL_OFFS (GW_HWPE_CTRL_OFFS + 0x4)
#define GW_HWPE_CLK_EN_OFFS  (GW_HWPE_CTRL_OFFS + 0x8)

#define GW_HWPE_CLK_EN_ACC       0x1
#define GW_HWPE_CLK_EN_DATAMOVER 0x2

#define GW_HWPE_MUX_SEL_ACC       0x0
#define GW_HWPE_MUX_SEL_DATAMOVER 0x1
