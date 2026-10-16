# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

APP              := spatz-fmatmul
$(APP)_BUILD_DIR ?= $(GW_SNITCH_SW_DIR)/apps/$(APP)/build
$(APP)_DATA_CFG  := $(GW_SNITCH_SW_DIR)/apps/$(APP)/data/params.json
SRC_DIR          := $(SN_ROOT)/sw/kernels/blas/$(APP)/src
SRCS             := $(SRC_DIR)/main.c
$(APP)_INCDIRS   := $(SN_ROOT)/sw/kernels/blas/$(APP)/data

include $(SN_ROOT)/sw/kernels/datagen.mk
include $(SN_ROOT)/sw/kernels/common.mk

# FP32 variant
APP              := spatz-fmatmul_fp32
$(APP)_BUILD_DIR ?= $(GW_SNITCH_SW_DIR)/apps/spatz-fmatmul/build/fp32
$(APP)_DATA_CFG  := $(GW_SNITCH_SW_DIR)/apps/spatz-fmatmul/data/params_fp32.json
SRC_DIR          := $(SN_ROOT)/sw/kernels/blas/spatz-fmatmul/src
SRCS             := $(SRC_DIR)/main.c
$(APP)_INCDIRS   := $(SN_ROOT)/sw/kernels/blas/spatz-fmatmul/data

include $(SN_ROOT)/sw/kernels/datagen.mk
include $(SN_ROOT)/sw/kernels/common.mk
