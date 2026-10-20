# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Cyril Koenig <cykoenig@iis.ee.ethz.ch>

# Self-checking FP32 AXPY with IOMMU-translated DMA transfers; see src/main.c.
APP              := axpy_iommu
$(APP)_BUILD_DIR := $(GW_SNITCH_SW_DIR)/apps/$(APP)/build
SRC_DIR          := $(GW_SNITCH_SW_DIR)/apps/$(APP)/src
SRCS             := $(SRC_DIR)/main.c

include $(SN_ROOT)/sw/kernels/common.mk
