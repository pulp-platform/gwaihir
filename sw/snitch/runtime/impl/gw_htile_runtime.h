// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "gw_noc_cfg.h"
#include "gw_raw_addrmap_32b.h"
#include "snitch_cluster_cfg.h"

#ifdef GW_HTILE_RUNTIME

#undef SNRT_BASE_HARTID
#undef SNRT_CLUSTER_NUM
#undef SNRT_TCDM_START_ADDR

#define SNRT_BASE_HARTID \
  (CFG_CLUSTER_BASE_HARTID + \
   GW_CLUSTER_PER_ROW * GW_CLUSTER_PER_COL * CFG_CLUSTER_NR_CORES)
#define SNRT_CLUSTER_NUM 1
#define SNRT_TCDM_START_ADDR GW_HTILE_TCDM_BASE_ADDR

#endif
