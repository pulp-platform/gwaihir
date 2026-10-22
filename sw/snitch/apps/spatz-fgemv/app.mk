# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# main.c is a copy of the snitch_cluster kernel that runs only on cluster 0;
# the kernel sources, data headers and scripts come from snitch_cluster.
SPATZ_FGEMV_SN    := $(SN_ROOT)/sw/kernels/blas/spatz-fgemv

APP               := spatz-fgemv
$(APP)_BUILD_DIR  ?= $(GW_SNITCH_SW_DIR)/apps/spatz-fgemv/build
$(APP)_DATA_CFG   := $(GW_SNITCH_SW_DIR)/apps/spatz-fgemv/data/params.json
$(APP)_SCRIPT_DIR := $(SPATZ_FGEMV_SN)/scripts
SRC_DIR           := $(GW_SNITCH_SW_DIR)/apps/spatz-fgemv/src
SRCS              := $(SRC_DIR)/main.c
$(APP)_INCDIRS    := $(SPATZ_FGEMV_SN)/data $(SPATZ_FGEMV_SN)/src

include $(SN_ROOT)/sw/kernels/datagen.mk

include $(SN_ROOT)/sw/kernels/common.mk
