# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Spatz PACE PWPA loop in FP32 and BF16. The PACE verifier reads the
# generated data.h next to each ELF, so every variant has its own build dir.
# main.c is a copy of the snitch_cluster kernel that runs only on cluster 0.
SPATZ_PACE_LOOP_DIR := $(GW_SNITCH_SW_DIR)/apps/spatz_pace_loop

APP              := spatz_pace_loop
$(APP)_BUILD_DIR ?= $(SPATZ_PACE_LOOP_DIR)/build
$(APP)_DATA_CFG  ?= $(SPATZ_PACE_LOOP_DIR)/data/params.json
$(APP)_SCRIPT_DIR ?= $(SN_ROOT)/sw/kernels/pace/elementwise/scripts
SRC_DIR          := $(SPATZ_PACE_LOOP_DIR)/src
SRCS             := $(SRC_DIR)/main.c
include $(SN_ROOT)/sw/kernels/pace/common.mk

APP              := spatz_pace_loop_pwpa_bfp16
$(APP)_BUILD_DIR ?= $(SPATZ_PACE_LOOP_DIR)/build/pwpa_bfp16
$(APP)_DATA_CFG  ?= $(SPATZ_PACE_LOOP_DIR)/data/params_bfp16.json
$(APP)_SCRIPT_DIR ?= $(SN_ROOT)/sw/kernels/pace/elementwise/scripts
SRC_DIR          := $(SPATZ_PACE_LOOP_DIR)/src
SRCS             := $(SRC_DIR)/main.c
include $(SN_ROOT)/sw/kernels/pace/common.mk
