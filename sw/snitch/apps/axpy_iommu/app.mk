# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Cyril Koenig <cykoenig@iis.ee.ethz.ch>

APP              := axpy_iommu
$(APP)_BUILD_DIR := $(GW_SNITCH_SW_DIR)/apps/$(APP)/build
SRC_DIR          := $(SN_ROOT)/sw/kernels/blas/axpy/src
SRCS             := $(SRC_DIR)/main.c
$(APP)_INCDIRS   := $(SN_ROOT)/sw/kernels/blas

# Rely on axpy's Makefile to generate the data, but edit the addresses to use the IOMMU
$($(APP)_BUILD_DIR)/data.h: $(axpy_BUILD_DIR)/data.h
	cp $< $@
	sed -i 's/x,/(double *)((uintptr_t)x - 0x21200000 + 0x00200000),/g' $@
	sed -i 's/y,/(double *)((uintptr_t)y - 0x21200000 + 0x00200000),/g' $@
	sed -i 's/z,/(double *)((uintptr_t)z - 0x21200000 + 0x00200000),/g' $@

$(APP)_HEADERS := $($(APP)_BUILD_DIR)/data.h
$(APP)_INCDIRS += $($(APP)_BUILD_DIR)

include $(SN_ROOT)/sw/kernels/common.mk
