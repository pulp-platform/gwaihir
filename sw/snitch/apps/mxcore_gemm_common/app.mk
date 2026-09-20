# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# One resident GEMM per invocation. Override with make ... M=64 N=128 K=256.
M ?= 64
N ?= 64
K ?= 256

$(APP)_INCDIRS += $(GW_SNITCH_SW_DIR)/apps/mxcore_gemm_common
$(APP)_RISCV_CFLAGS += -DMXCORE_GEMM_M=$(M) -DMXCORE_GEMM_N=$(N) -DMXCORE_GEMM_K=$(K)
# The DM core has neither an FPU nor a vector unit. This also prevents vector
# lowering of memset/memcpy, which -fno-vectorize alone does not disable.
$(APP)_RISCV_CFLAGS += -mno-implicit-float

include $(SN_ROOT)/sw/kernels/common.mk

# common.mk does not track command-line flag changes. These small applications
# are rebuilt when requested, so changing M/N/K cannot silently reuse an ELF.
.PHONY: $(APP)-config
$(ELF): $(APP)-config
