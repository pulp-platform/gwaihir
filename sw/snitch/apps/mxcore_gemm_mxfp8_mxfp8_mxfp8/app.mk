# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

APP              := mxcore_gemm_mxfp8_mxfp8_mxfp8
$(APP)_BUILD_DIR ?= $(GW_SNITCH_SW_DIR)/apps/$(APP)/build
SRC_DIR          := $(GW_SNITCH_SW_DIR)/apps/$(APP)/src
SRCS             := $(SRC_DIR)/$(APP).c

include $(GW_SNITCH_SW_DIR)/apps/mxcore_gemm_common/app.mk
