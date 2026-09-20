// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "benchmark.h"

int main(void) {
    return mxcore_gemm_benchmark(MXCORE_GEMM_M, MXCORE_GEMM_N, MXCORE_GEMM_K,
                                 MXCORE_OUTPUT_MXFP8);
}
