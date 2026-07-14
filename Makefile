# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

GW_ROOT ?= $(shell pwd -P)
GW_GEN_DIR = $(GW_ROOT)/.generated
BENDER_ROOT ?= $(GW_ROOT)/.bender
UTIL_DIR = $(GW_ROOT)/util

# Executables — must be defined before dependency paths that call $(BENDER)
BENDER           ?= bender --suppress W22 -d $(GW_ROOT)
FLOO_GEN         ?= floogen
VERIBLE_FMT      ?= verible-verilog-format
VERIBLE_FMT_ARGS ?= --flagfile .verilog_format --inplace --verbose
PEAKRDL          ?= peakrdl

# Configuration files
FLOO_CFG  ?= $(GW_ROOT)/cfg/gwaihir_noc.yml
SN_CFG	  ?= $(GW_ROOT)/cfg/snitch_cluster.json
PLIC_CFG  ?= $(GW_ROOT)/cfg/rv_plic.cfg.hjson
SLINK_CFG ?= $(GW_ROOT)/cfg/serial_link.hjson

# Root directories of dependencies
CHS_ROOT  = $(shell $(BENDER) path cheshire)
SN_ROOT   = $(shell $(BENDER) path snitch_cluster)
FLOO_ROOT = $(shell $(BENDER) path floo_noc)

# Bender prerequisites
BENDER_YML = $(GW_ROOT)/Bender.yml
BENDER_LOCK = $(GW_ROOT)/Bender.lock

################
# Bender flags #
################

COMMON_TARGS += -t rtl -t cva6 -t cv64a6_rt_hpdcache -t snitch_cluster -t gw_gen_rtl
SIM_TARGS += -t simulation -t test -t idma_test

#############
# systemRDL #
#############
SLINK_NUM_LANES ?= 8
PEAKRDL_PARAMS   += -P SlinkNumLanes=$(SLINK_NUM_LANES)
DOCS_DIR         ?= $(GW_ROOT)/docs
DOCS_ADDRMAP_MD  ?= $(DOCS_DIR)/addressmap.md
DOCS_SITE_DIR    ?= $(GW_GEN_DIR)/docs-site

GW_RDL_ALL += $(GW_GEN_DIR)/gwaihir_addrmap.rdl
GW_RDL_ALL += $(GW_GEN_DIR)/fll.rdl $(GW_GEN_DIR)/gw_chip_regs.rdl
GW_RDL_ALL += $(GW_GEN_DIR)/snitch_cluster.rdl
GW_RDL_ALL += $(wildcard $(GW_ROOT)/cfg/rdl/*.rdl)

PEAKRDL_INCLUDES += -I $(GW_ROOT)/cfg/rdl
PEAKRDL_INCLUDES += -I $(SN_ROOT)/hw/snitch_cluster/src/snitch_cluster_peripheral
PEAKRDL_INCLUDES += -I $(CHS_ROOT)/hw
PEAKRDL_INCLUDES += $(CHS_PEAKRDL_INCLUDES)

PEAKRDL_INCLUDES += -I $(GW_GEN_DIR)

$(GW_GEN_DIR)/gw_tile_regs.sv: $(GW_GEN_DIR)/gw_tile_regs_pkg.sv
$(GW_GEN_DIR)/gw_tile_regs_pkg.sv: $(GW_ROOT)/cfg/rdl/gw_tile_regs.rdl
	$(PEAKRDL) regblock $< -o $(GW_GEN_DIR) --cpuif apb4-flat --default-reset arst_n

$(GW_GEN_DIR)/gwaihir_addrmap.rdl: $(FLOO_CFG)
	$(FLOO_GEN) rdl -c $(FLOO_CFG) -o $(GW_GEN_DIR) --as-mem --memwidth=32

# Those are dummy RDL files, for generation without access to the PD repository.
$(GW_GEN_DIR)/fll.rdl $(GW_GEN_DIR)/gw_chip_regs.rdl: | $(GW_GEN_DIR)
	@touch $@

$(GW_GEN_DIR)/gw_addrmap.h: $(GW_GEN_DIR)/gwaihir_addrmap.rdl $(GW_RDL_ALL)
	$(PEAKRDL) c-header $< $(PEAKRDL_INCLUDES) $(PEAKRDL_DEFINES) -o $@ -i -b ltoh

$(GW_GEN_DIR)/gw_addrmap.svh: $(GW_RDL_ALL)
	$(PEAKRDL) raw-header $< -o $@ $(PEAKRDL_INCLUDES) $(PEAKRDL_DEFINES) --format svh --no-prefix

$(GW_GEN_DIR)/gw_raw_addrmap.h: $(GW_RDL_ALL)
	$(PEAKRDL) raw-header $< -o $@ $(PEAKRDL_INCLUDES) $(PEAKRDL_DEFINES) --format c --base-name gw

GW_RDL_HW_ALL += $(GW_GEN_DIR)/gw_tile_regs.sv
GW_RDL_HW_ALL += $(GW_GEN_DIR)/gw_tile_regs_pkg.sv
GW_RDL_HW_ALL += $(GW_GEN_DIR)/gw_addrmap.svh

.PHONY: docs docs-build docs-serve docs-clean rdl-markdown

docs rdl-markdown: $(DOCS_ADDRMAP_MD)
$(DOCS_ADDRMAP_MD): $(GW_GEN_DIR)/gwaihir_addrmap.rdl $(GW_RDL_ALL) | $(DOCS_DIR)
	$(PEAKRDL) markdown $< $(PEAKRDL_INCLUDES) $(PEAKRDL_DEFINES) -o $@

$(DOCS_DIR):
	mkdir -p $@

docs-build: $(DOCS_ADDRMAP_MD)
	$(UV) run --group docs zensical build --clean

docs-serve: $(DOCS_ADDRMAP_MD)
	$(UV) run --group docs zensical serve --open

docs-clean:
	rm -rf $(DOCS_ADDRMAP_MD) $(GW_GEN_DIR)/docs-site

############
# Cheshire #
############

CLINTCORES ?= 17
include $(CHS_ROOT)/cheshire.mk

$(CHS_ROOT)/hw/rv_plic.cfg.hjson: $(OTPROOT)/.generated2
$(OTPROOT)/.generated2: $(PLIC_CFG)
	flock -x $@ sh -c "cp $< $(CHS_ROOT)/hw/" && touch $@

$(CHS_ROOT)/hw/serial_link.hjson: $(CHS_SLINK_DIR)/.generated2
$(CHS_SLINK_DIR)/.generated2:	$(SLINK_CFG)
	flock -x $@ sh -c "cp $< $(CHS_ROOT)/hw/" && touch $@

##################
# Snitch Cluster #
##################

SN_GEN_DIR = $(GW_GEN_DIR)
include $(SN_ROOT)/make/common.mk
include $(SN_ROOT)/make/rtl.mk

$(SN_CFG): SN_CLUSTERS = $(shell $(FLOO_GEN) query -c $(FLOO_CFG) endpoints.cluster.num 2>/dev/null)
$(SN_CFG): $(FLOO_CFG)
	@sed -i 's/nr_clusters: .*/nr_clusters: $(SN_CLUSTERS),/' $@

.PHONY: sn-hw-clean sn-hw-all

sn-hw-all: $(SN_CFG) $(SN_CLUSTER_WRAPPER) $(SN_CLUSTER_PKG)
sn-hw-clean:
	rm -rf $(SN_CLUSTER_WRAPPER) $(SN_CLUSTER_PKG)

###########
# FlooNoC #
###########

.PHONY: floo-hw-all floo-clean

# Check if `VERIBLE_FMT` executable is valid, otherwise don't format FlooGen output
FLOO_GEN_FLAGS = --no-format
ifeq ($(shell $(VERIBLE_FMT) --version >/dev/null 2>&1 && echo OK),OK)
	FLOO_GEN_FLAGS = --verible-fmt-bin="$(VERIBLE_FMT)" --verible-fmt-args="$(VERIBLE_FMT_ARGS)"
endif

floo-hw-all: $(GW_GEN_DIR)/floo_gwaihir_noc_pkg.sv
$(GW_GEN_DIR)/floo_gwaihir_noc_pkg.sv: $(FLOO_CFG)
	$(FLOO_GEN) pkg -c $(FLOO_CFG) -o $(GW_GEN_DIR) $(FLOO_GEN_FLAGS)


floo-clean: gw-addrmap-clean
	rm -f $(GW_GEN_DIR)/floo_gwaihir_noc_pkg.sv
	rm -f $(GW_GEN_DIR)/gwaihir_addrmap.rdl

###################
# Physical Design #
###################

PD_REMOTE ?= git@iis-git.ee.ethz.ch:gwaihir/gwaihir-pd.git
PD_COMMIT ?= 9e12557f72bfb8d60133d811b7ca8103f5b53934
PD_DIR = $(GW_ROOT)/pd

PCIE_REMOTE ?= git@iis-git.ee.ethz.ch:gwaihir/pcie.git
PCIE_COMMIT ?= 17bdc3024b9790c36600f327db3024f00b74f2c9
PCIE_DIR = $(GW_ROOT)/.deps/pcie

.PHONY: init-pd clean-pd update-pd-commit

init-pd: $(PD_DIR) $(PCIE_DIR)
$(PD_DIR):
	git clone $(PD_REMOTE) $(PD_DIR)
	cd $(PD_DIR) && git checkout $(PD_COMMIT)

$(PCIE_DIR):
	git clone $(PCIE_REMOTE) $(PCIE_DIR)
	cd $(PCIE_DIR) && git checkout $(PCIE_COMMIT)

update-pd-commit:
	sed -i 's/^PD_COMMIT ?= .*/PD_COMMIT ?= $(shell git -C $(PD_DIR) rev-parse HEAD)/' $(firstword $(MAKEFILE_LIST))

clean-pd:
	rm -rf $(PD_DIR) $(PCIE_DIR)

-include $(PD_DIR)/pd.mk


#########################
# General Phony targets #
#########################

GW_HW_ALL += $(CHS_HW_ALL)
GW_HW_ALL += $(CHS_MODELS_ALL)
GW_HW_ALL += $(GW_RDL_HW_ALL)

.PHONY: gwaihir-hw-all gwaihir-hw-clean clean

gwaihir-hw-all all: $(GW_HW_ALL) sn-hw-all floo-hw-all

gwaihir-hw-clean: sn-hw-clean floo-clean
	rm -rf $(GW_HW_ALL)

clean: gwaihir-hw-clean docs-clean
	rm -rf $(BENDER_ROOT)

############
# Software #
############

include $(GW_ROOT)/sw/sw.mk

##############
# Simulation #
##############

TB_DUT = tb_gwaihir_top
SIM_DIR = $(GW_ROOT)

include $(GW_ROOT)/target/sim/vsim/vsim.mk
include $(GW_ROOT)/target/sim/vcs/vcs.mk
include $(GW_ROOT)/target/sim/traces.mk

##################
# Snitch cluster #
##################

# Skip the expensive dep tracking (make -pq via list-dependent-make-targets) for
# hw-only and informational goals. For unknown targets (e.g. app names), still run it.
# %-all / %-clean cover all hw-all/hw-clean variants; vsim-% / gw-% cover sim/rdl targets.
# Clean targets never need dep tracking regardless of subsystem.
_GW_NO_DEPS_GOALS := help all clean traces annotate dvt-flist slang-flist verible-fmt \
                     init-pd clean-pd update-pd-commit python-venv% %-all %-clean vsim-% gw-% rdl-% docs%
ifeq ($(filter-out $(_GW_NO_DEPS_GOALS),$(MAKECMDGOALS)),)
# All requested goals are hw-only/informational — skip dep tracking.
else
$(call sn_include_deps)
endif

########
# Misc #
########


.PHONY: dvt-flist dvt-flist-clean verible-fmt slang-flist slang-flist-clean

DVT_FLIST   ?= $(GW_ROOT)/.dvt/default.build
SLANG_FLIST ?= $(GW_ROOT)/sources.flist

dvt-flist: $(DVT_FLIST)
slang-flist: $(SLANG_FLIST)

$(DVT_FLIST) $(SLANG_FLIST): $(BENDER_YML) $(BENDER_LOCK)
	@mkdir -p $(@D)
	$(BENDER) script flist-plus $(COMMON_TARGS) $(SIM_TARGS) --suppress E31 --top tb_gwaihir_top > $@

dvt-flist-clean:
	rm -f $(DVT_FLIST)
slang-flist-clean:
	rm -f $(SLANG_FLIST)

verible-fmt:
	$(VERIBLE_FMT) $(VERIBLE_FMT_ARGS) $(shell $(BENDER) script flist $(SIM_TARGS) --no-deps)

#################
# Documentation #
#################

.PHONY: help

Black=\033[0m
Green=\033[1;32m
help:
	@echo -e "Makefile ${Green}targets${Black} for gwaihir"
	@echo -e "Use 'make <target>' where <target> is one of:"
	@echo -e ""
	@echo -e "${Green}help           	     ${Black}Show an overview of all Makefile targets."
	@echo -e ""
	@echo -e "General targets:"
	@echo -e "${Green}all                  ${Black}Alias for gwaihir-hw-all."
	@echo -e "${Green}clean                ${Black}Alias for gwaihir-hw-clean."
	@echo -e ""
	@echo -e "Source generation targets:"
	@echo -e "${Green}gwaihir-hw-all     ${Black}Build all RTL."
	@echo -e "${Green}gwaihir-hw-clean   ${Black}Clean everything."
	@echo -e "${Green}floo-hw-all          ${Black}Generate FlooNoC RTL."
	@echo -e "${Green}floo-clean           ${Black}Clean FlooNoC RTL."
	@echo -e "${Green}sn-hw-all            ${Black}Generate Snitch Cluster wrapper RTL."
	@echo -e "${Green}sn-hw-clean          ${Black}Clean Snitch Cluster wrapper RTL."
	@echo -e "${Green}chs-hw-all           ${Black}Generate Cheshire RTL."
	@echo -e "${Green}rdl-markdown         ${Black}Generate RDL Markdown documentation."
	@echo -e "${Green}docs                 ${Black}Generate documentation sources."
	@echo -e "${Green}docs-build           ${Black}Build documentation with Zensical."
	@echo -e "${Green}docs-serve           ${Black}Serve documentation with Zensical and open it in a browser."
	@echo -e "${Green}docs-clean           ${Black}Clean generated documentation files."
	@echo -e ""
	@echo -e "Software:"
	@echo -e "${Green}sw                   ${Black}Compile all software tests."
	@echo -e "${Green}sw-clean             ${Black}Clean all software tests."
	@echo -e "${Green}chs-sw-tests         ${Black}Compile Cheshire software tests."
	@echo -e "${Green}chs-sw-tests-clean   ${Black}Clean Cheshire software tests."
	@echo -e "${Green}sn-tests             ${Black}Compile Snitch software tests."
	@echo -e "${Green}sn-clean-tests       ${Black}Clean Snitch software tests."
	@echo -e ""
	@echo -e "Simulation targets (QuestaSim):"
	@echo -e "${Green}vsim-compile         ${Black}Compile with QuestaSim."
	@echo -e "${Green}vsim-run             ${Black}Run QuestaSim simulation in GUI mode w/o optimization."
	@echo -e "${Green}vsim-run-batch       ${Black}Run QuestaSim simulation in batch mode w/ optimization."
	@echo -e "${Green}vsim-clean           ${Black}Clean QuestaSim simulation files."
	@echo -e ""
	@echo -e "Simulation targets (VCS):"
	@echo -e "${Green}vcs-compile          ${Black}Compile with VCS (with full debug access for Verdi GUI)."
	@echo -e "${Green}vcs-compile-batch    ${Black}Compile with VCS in batch mode (no debug overhead)."
	@echo -e "${Green}vcs-run              ${Black}Run VCS simulation in Verdi GUI mode."
	@echo -e "${Green}vcs-run-batch        ${Black}Run VCS simulation in batch mode."
	@echo -e "${Green}vcs-clean            ${Black}Clean VCS simulation files."
	@echo -e ""
	@echo -e "Additional miscellaneous targets:"
	@echo -e "${Green}traces               ${Black}Generate the better readable traces in .logs/trace_hart_<hart_id>.txt."
	@echo -e "${Green}annotate             ${Black}Annotate the better readable traces in .logs/trace_hart_<hart_id>.s with the source code related with the retired instructions."
	@echo -e "${Green}dvt-flist            ${Black}Generate a file list for the VSCode DVT plugin."
	@echo -e "${Green}slang-flist          ${Black}Generate a file list for the slang LSP."
	@echo -e "${Green}python-venv          ${Black}Create a Python virtual environment and install the required packages."
	@echo -e "${Green}python-venv-clean    ${Black}Remove the Python virtual environment."
	@echo -e "${Green}verible-fmt          ${Black}Format SystemVerilog files using Verible."
