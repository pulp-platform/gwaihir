# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# The softmax with transposed blocks, and with row blocks.
SPATZ_SOFTMAX_DIR := $(GW_SNITCH_SW_DIR)/apps/spatz_softmax

APP              := spatz_softmax
$(APP)_BUILD_DIR ?= $(SPATZ_SOFTMAX_DIR)/build
SRC_DIR          := $(SPATZ_SOFTMAX_DIR)/src
SRCS             := $(SRC_DIR)/main.c
include $(SN_ROOT)/sw/kernels/pace/common.mk

APP                 := spatz_softmax_rows
$(APP)_BUILD_DIR    ?= $(SPATZ_SOFTMAX_DIR)/build/rows
$(APP)_RISCV_CFLAGS += -DSOFTMAX_ROWS
SRC_DIR             := $(SPATZ_SOFTMAX_DIR)/src
SRCS                := $(SRC_DIR)/main.c
include $(SN_ROOT)/sw/kernels/pace/common.mk
