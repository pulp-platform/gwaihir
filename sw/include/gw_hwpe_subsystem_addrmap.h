// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Address map of the H tile HWPE subsystem

#pragma once

#define GW_HWPE_ACC_WINDOW 0x200

#define GW_HWPE_SURYA_OFFS     (0 * GW_HWPE_ACC_WINDOW)
#define GW_HWPE_DATAMOVER_OFFS (1 * GW_HWPE_ACC_WINDOW)
#define GW_HWPE_CTRL_OFFS      (2 * GW_HWPE_ACC_WINDOW)

#define GW_HWPE_EVT_CLR_OFFS (GW_HWPE_CTRL_OFFS + 0x0)
#define GW_HWPE_MUX_SEL_OFFS (GW_HWPE_CTRL_OFFS + 0x4)
#define GW_HWPE_CLK_EN_OFFS  (GW_HWPE_CTRL_OFFS + 0x8)

#define GW_HWPE_CLK_EN_SURYA     0x1
#define GW_HWPE_CLK_EN_DATAMOVER 0x2

#define GW_HWPE_MUX_SEL_SURYA     0x0
#define GW_HWPE_MUX_SEL_DATAMOVER 0x1
