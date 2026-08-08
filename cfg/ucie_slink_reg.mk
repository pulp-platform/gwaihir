# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# UCIe dummy transport exposes one 256-bit SDR word per link-layer cycle.
UCIE_SLINK_NUM_LANES := 256
UCIE_SLINK_EN_DDR    := 0

UCIE_SLINK_RDL_PARAMS := -P NumLanes=$(UCIE_SLINK_NUM_LANES) -P EnDdr=$(UCIE_SLINK_EN_DDR)
