# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

# main.c is a copy of the snitch_cluster kernel that runs only on cluster 0;
# the kernel sources, data headers and scripts come from snitch_cluster.
SPATZ_FMATMUL_DIR := $(GW_SNITCH_SW_DIR)/apps/spatz-fmatmul
SPATZ_FMATMUL_SN  := $(SN_ROOT)/sw/kernels/blas/spatz-fmatmul

APP               := spatz-fmatmul
$(APP)_BUILD_DIR  ?= $(SPATZ_FMATMUL_DIR)/build
$(APP)_DATA_CFG   := $(SPATZ_FMATMUL_DIR)/data/params.json
$(APP)_SCRIPT_DIR := $(SPATZ_FMATMUL_SN)/scripts
SRC_DIR           := $(SPATZ_FMATMUL_DIR)/src
SRCS              := $(SRC_DIR)/main.c
$(APP)_INCDIRS    := $(SPATZ_FMATMUL_SN)/data $(SPATZ_FMATMUL_SN)/src

include $(SN_ROOT)/sw/kernels/datagen.mk
include $(SN_ROOT)/sw/kernels/common.mk

# FP32 variant
APP               := spatz-fmatmul_fp32
$(APP)_BUILD_DIR  ?= $(SPATZ_FMATMUL_DIR)/build/fp32
$(APP)_DATA_CFG   := $(SPATZ_FMATMUL_DIR)/data/params_fp32.json
$(APP)_SCRIPT_DIR := $(SPATZ_FMATMUL_SN)/scripts
SRC_DIR           := $(SPATZ_FMATMUL_DIR)/src
SRCS              := $(SRC_DIR)/main.c
$(APP)_INCDIRS    := $(SPATZ_FMATMUL_SN)/data $(SPATZ_FMATMUL_SN)/src

include $(SN_ROOT)/sw/kernels/datagen.mk
include $(SN_ROOT)/sw/kernels/common.mk
