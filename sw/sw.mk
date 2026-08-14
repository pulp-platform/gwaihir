# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Tim Fischer <fischeti@iis.ee.ethz.ch>
#					Lorenzo Leone <fischeti@iis.ee.ethz.ch>

#TODO(lleone): remove if not necessary to redefine. Fix the bender version somewhere
BENDER ?= bender
#TODO(lleone): remove if not necessary to redefine
CHS_ROOT ?= $(shell $(BENDER) path cheshire)
#TODO(lleone): remove if not necessary to redefine
SN_ROOT ?= $(shell $(BENDER) path snitch_cluster)

GW_SW_DIR = $(GW_ROOT)/sw
GW_CHS_SW_DIR = $(GW_SW_DIR)/cheshire
GW_SNITCH_SW_DIR = $(GW_SW_DIR)/snitch

GW_INCDIR = $(GW_SW_DIR)/include

-include $(PD_DIR)/sw/sw.mk

####################
## Snitch Cluster ##
####################

SN_RUNTIME_SRCDIR    = $(GW_SNITCH_SW_DIR)/runtime/impl
SN_RUNTIME_BUILDDIR  = $(GW_SNITCH_SW_DIR)/runtime/build
SN_RUNTIME_INCDIRS  += $(GW_INCDIR)
SN_RUNTIME_INCDIRS  += $(GW_GEN_DIR)
SN_RUNTIME_INCDIRS  += $(GW_SNITCH_SW_DIR)/runtime/src
SN_RUNTIME_HAL_HDRS  = $(GW_GEN_DIR)/gw_addrmap_32b.h
SN_RUNTIME_HAL_HDRS += $(GW_GEN_DIR)/gw_raw_addrmap_32b.h
SN_RUNTIME_HAL_HDRS += $(GW_GEN_DIR)/gw_noc_cfg.h

#TODO(lleone): do we need this?
SN_RVTESTS_BUILDDIR = $(GW_SNITCH_SW_DIR)/riscv-tests/build

SN_TESTS_BUILDDIR = $(GW_SNITCH_SW_DIR)/tests/build
SN_TESTS_INCDIRS  = $(SN_ROOT)/sw/kernels/blas

SN_BUILD_APPS = OFF

SN_APPS  = $(GW_SNITCH_SW_DIR)/apps/gemm_2d
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/gemm
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/axpy
SN_APPS += $(SN_ROOT)/sw/kernels/dnn/flashattention_2
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/fused_concat_linear
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/mha
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/summa_gemm
SN_APPS += $(GW_SNITCH_SW_DIR)/apps/power_benchmarks

SN_TESTS = $(wildcard $(GW_SNITCH_SW_DIR)/tests/*.c)

$(GW_GEN_DIR)/gw_noc_cfg.h: $(UTIL_DIR)/mako_render.py $(FLOO_CFG)
	 $< -t $(SN_RUNTIME_SRCDIR)/gw_noc_cfg.h.tpl -y $(FLOO_CFG) -o $@

include $(SN_ROOT)/make/sw.mk

########################
## H-tile Snitch Test ##
########################

# The h-tile executes the Snitch runtime as a standalone tile, not as one of the
# regular Gwaihir Snitch clusters. Build a separate runtime so GW_HTILE_RUNTIME
# reaches snrt.S/snrt.cc without changing the normal cluster test binaries.
SN_HTILE_RUNTIME_BUILDDIR     = $(GW_SNITCH_SW_DIR)/runtime/build_htile
SN_HTILE_RUNTIME_RISCV_CFLAGS = $(SN_RUNTIME_RISCV_CFLAGS) -DGW_HTILE_RUNTIME
SN_HTILE_RUNTIME_OBJS         = $(addprefix $(SN_HTILE_RUNTIME_BUILDDIR)/,$(addsuffix .o,$(notdir $(SN_RUNTIME_S_SRCS) $(SN_RUNTIME_C_SRCS))))
SN_HTILE_RUNTIME_DEPS         = $(addprefix $(SN_HTILE_RUNTIME_BUILDDIR)/,$(addsuffix .d,$(notdir $(SN_RUNTIME_S_SRCS) $(SN_RUNTIME_C_SRCS))))
SN_HTILE_RUNTIME_LIB          = $(SN_HTILE_RUNTIME_BUILDDIR)/libsnRuntime.a

SN_HTILE_TEST_RISCV_LDFLAGS  = $(SN_RISCV_LDFLAGS)
SN_HTILE_TEST_RISCV_LDFLAGS += -L$(dir $(SN_RUNTIME_MEMORY_LD))
SN_HTILE_TEST_RISCV_LDFLAGS += -T$(SN_RUNTIME_BASE_LD)
SN_HTILE_TEST_RISCV_LDFLAGS += -L$(SN_HTILE_RUNTIME_BUILDDIR)
SN_HTILE_TEST_RISCV_LDFLAGS += -lsnRuntime

.PHONY: sn-htile-runtime sn-clean-htile-runtime

sn-htile-runtime: $(SN_HTILE_RUNTIME_LIB)

sn-clean-htile-runtime:
	rm -rf $(SN_HTILE_RUNTIME_BUILDDIR)

$(SN_HTILE_RUNTIME_BUILDDIR):
	mkdir -p $@

$(SN_HTILE_RUNTIME_OBJS): $(SN_HTILE_RUNTIME_BUILDDIR)/%.o: $(SN_RUNTIME_SRCDIR)/% $(SN_HTILE_RUNTIME_BUILDDIR)/%.d | $(SN_HTILE_RUNTIME_BUILDDIR)
	$(SN_RISCV_CXX) $(SN_HTILE_RUNTIME_RISCV_CFLAGS) -c $< -o $@

$(SN_HTILE_RUNTIME_DEPS): $(SN_HTILE_RUNTIME_BUILDDIR)/%.d: $(SN_RUNTIME_SRCDIR)/% | $(SN_HTILE_RUNTIME_BUILDDIR)
	$(SN_RISCV_CXX) $(SN_HTILE_RUNTIME_RISCV_CFLAGS) -MM -MT '$(@:.d=.o)' $< > $@

$(SN_HTILE_RUNTIME_LIB): $(SN_HTILE_RUNTIME_OBJS) | $(SN_HTILE_RUNTIME_BUILDDIR)
	$(SN_RISCV_AR) $(SN_RISCV_ARFLAGS) $@ $^

$(SN_HTILE_RUNTIME_DEPS): | $(SN_RUNTIME_HAL_HDRS)

$(SN_TESTS_BUILDDIR)/simple_htile.d: SN_TESTS_RISCV_CFLAGS += -DGW_HTILE_RUNTIME
$(SN_TESTS_BUILDDIR)/simple_htile.elf: SN_TESTS_RISCV_CFLAGS += -DGW_HTILE_RUNTIME
$(SN_TESTS_BUILDDIR)/simple_htile.elf: SN_TESTS_RISCV_LDFLAGS = $(SN_HTILE_TEST_RISCV_LDFLAGS)
$(SN_TESTS_BUILDDIR)/simple_htile.elf: $(SN_HTILE_RUNTIME_LIB)

sn-clean-runtime: sn-clean-htile-runtime

SN_DEPS += $(SN_HTILE_RUNTIME_DEPS)

##############
## Cheshire ##
##############

GW_LINK_MODE ?= spm

# We need to include the address map and snitch cluster includes
CHS_SW_INCLUDES += -I$(GW_INCDIR)
CHS_SW_INCLUDES += -I$(SN_RUNTIME_SRCDIR)
CHS_SW_INCLUDES += -I$(GW_GEN_DIR)

# Collect tests, which should be build for all modes, and their .dump targets
GW_CHS_SW_TEST_SRC   += $(wildcard $(GW_CHS_SW_DIR)/tests/*.c)
GW_CHS_SW_TEST_SRC_S += $(wildcard $(GW_CHS_SW_DIR)/tests/*.S)
GW_CHS_SW_TEST_DUMP  += $(GW_CHS_SW_TEST_SRC:.c=.$(GW_LINK_MODE).dump) $(patsubst %.$(GW_LINK_MODE).S,%.$(GW_LINK_MODE).dump,$(GW_CHS_SW_TEST_SRC_S))
GW_CHS_SW_TEST_ELF  += $(GW_CHS_SW_TEST_SRC:.c=.$(GW_LINK_MODE).elf) $(patsubst %.$(GW_LINK_MODE).S,%.$(GW_LINK_MODE).elf,$(GW_CHS_SW_TEST_SRC_S))

GW_CHS_SW_TEST = $(GW_CHS_SW_TEST_DUMP)

$(GW_CHS_SW_TEST_DUMP): $(GW_CHS_SW_TEST_ELF)
$(GW_CHS_SW_TEST_ELF): $(GW_GEN_DIR)/gw_addrmap_64b.h $(GW_GEN_DIR)/gw_raw_addrmap_64b.h $(SN_RUNTIME_HAL_HDRS)

.PHONY: chs-sw-tests chs-sw-tests-clean

chs-sw-tests: $(GW_CHS_SW_TEST)

chs-sw-tests-clean:
	rm -f $(GW_CHS_SW_TEST_DUMP)
	rm -f $(GW_CHS_SW_TEST_ELF)

#########################
# General Phony targets #
#########################

# Alias targets to align them with top-level naming convention
sn-tests-clean: sn-clean-tests
sn-runtime-clean: sn-clean-runtime
sn-apps-clean: sn-clean-apps

.PHONY: sw sw-tests sw-clean sw-tests-clean
sw sw-tests: chs-sw-tests sn-tests sn-apps

sw-clean sw-tests-clean: chs-sw-tests-clean sn-tests-clean sn-runtime-clean sn-apps-clean
	rm $(GW_GEN_DIR)/*.h
