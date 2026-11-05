/* Copyright 2026 ETH Zurich and University of Bologna. */
/* Licensed under the Apache License, Version 2.0, see LICENSE for details. */
/* SPDX-License-Identifier: Apache-2.0 */

/* The H tile programs use l2_spm_2, the cacheable region of the H tile config. */
MEMORY
{
    L3 (rwxa) : ORIGIN = 0x21600000, LENGTH = 0x00200000
}
