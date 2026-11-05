// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// `mxcore_multi` with 32 GEMMs per cluster, to run next to `surya_mx` on the H tile.

#define MXCORE_MULTI_REPEAT 32
#include "mxcore_multi.c"
