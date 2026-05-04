# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

VCS_SEPP 	?=
VCS		    ?= $(VCS_SEPP) vcs
VLOGAN  	?= $(VCS_SEPP) vlogan

VCS_DIR 	= $(GW_ROOT)/target/sim/vcs
VCS_BUILD = $(VCS_DIR)/build

VLOGAN_ARGS := -work work
VLOGAN_ARGS += -full64
VLOGAN_ARGS += -kdb
VLOGAN_ARGS += -assert svaext
VLOGAN_ARGS += -timescale=1ns/1ps
VLOGAN_ARGS += -nc

VCS_FLAGS_GUI  = -debug_access+all

define add_vcs_flag
ifdef $(1)
	VCS_FLAGS += +$(1)=$$($(1))
endif
endef

$(eval $(call add_vcs_flag,CHS_BINARY))
$(eval $(call add_vcs_flag,SN_BINARY))
$(eval $(call add_vcs_flag,BOOTMODE))
$(eval $(call add_vcs_flag,PRELMODE))

.PHONY: vcs-compile vcs-compile-batch vcs-clean vcs-run vcs-run-batch

vcs-clean:
	rm -rf $(VCS_BUILD) vc_hdrs.h

$(VCS_BUILD):
	mkdir -p $@

# Always analyze Verilog before VHDL
$(VCS_BUILD)/compile.sh: $(BENDER_YML) $(BENDER_LOCK) | $(VCS_BUILD)
	$(BENDER) script vcs $(COMMON_TARGS) $(SIM_TARGS) --vlog-arg="$(VLOGAN_ARGS)" --vlogan-bin "$(VLOGAN)" > $@
	chmod +x $@

$(VCS_BUILD)/gwaihir_top.vcs: $(VCS_BUILD)/compile.sh $(GW_HW_ALL)
	cd $(VCS_BUILD) && $< | tee compile.log
	cd $(VCS_BUILD) && $(VCS) -Mlib=$(VCS_BUILD) -Mdir=$(VCS_BUILD) $(VCS_FLAGS_GUI) -o $@ -cpp $(CXX) \
		$(VCS_FLAGS) $(TB_DUT) $(realpath $(CHS_ROOT))/target/sim/src/elfloader.cpp

vcs-compile: $(VCS_BUILD)/gwaihir_top.vcs

vcs-run: $(VCS_BUILD)/gwaihir_top.vcs
	$(VCS_SEPP) $(VCS_BUILD)/gwaihir_top.vcs -verdi $(VCS_FLAGS)

# Compilation + Run for batch mode (no debug overhead)
$(VCS_BUILD)/gwaihir_top_batch.vcs: $(VCS_BUILD)/compile.sh $(GW_HW_ALL)
	cd $(VCS_BUILD) && $< | tee compile.log
	cd $(VCS_BUILD) && $(VCS) -Mlib=$(VCS_BUILD) -Mdir=$(VCS_BUILD) -o $@ -cpp $(CXX) \
		$(VCS_FLAGS) $(TB_DUT) $(realpath $(CHS_ROOT))/target/sim/src/elfloader.cpp

vcs-compile-batch: $(VCS_BUILD)/gwaihir_top_batch.vcs

vcs-run-batch: $(VCS_BUILD)/gwaihir_top_batch.vcs
	$(VCS_SEPP) $(VCS_BUILD)/gwaihir_top_batch.vcs $(VCS_FLAGS)

vcs-run-batch-verify: vcs-run-batch
ifdef VERIFY_PY
	cd $(SIM_DIR) && $(VERIFY_PY) placeholder $(SN_BINARY) --no-ipc --memdump l2mem.bin --memaddr 0x70000000
endif
