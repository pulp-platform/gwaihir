// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "gw_raw_addrmap_32b.h"
#include "snitch_cluster_cfg.h"

// The H tile takes the cluster slot after the cluster array.
#define GW_HTILE_CLUSTER_IDX SNRT_CLUSTER_NUM

// The H tile keeps this cluster index, so its TCDM starts at that cluster slot. Only the
// TCDM size and the cluster layout differ from a cluster.
#ifdef GW_HTILE_RUNTIME
#undef SNRT_TCDM_SIZE
#undef SNRT_TCDM_HYPERBANK_SIZE
#define SNRT_TCDM_SIZE           GW_HTILE_TCDM_SIZE
#define SNRT_TCDM_HYPERBANK_SIZE GW_HTILE_TCDM_SIZE
// snrt.h makes `snitch_cluster_t` from the cluster type; the H tile uses its own type.
#define snitch_cluster__stride40000_t htile_t
#endif
