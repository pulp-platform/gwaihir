# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

APP              := spatz-fgemv
$(APP)_BUILD_DIR ?= $(GW_SNITCH_SW_DIR)/apps/spatz-fgemv/build
$(APP)_DATA_CFG  := $(GW_SNITCH_SW_DIR)/apps/spatz-fgemv/data/params.json
SRC_DIR          := $(SN_ROOT)/sw/kernels/blas/spatz-fgemv/src
SRCS             := $(SRC_DIR)/main.c

include $(SN_ROOT)/sw/kernels/datagen.mk
$(APP)_INCDIRS += $(DATA_DIR)

include $(SN_ROOT)/sw/kernels/common.mk
