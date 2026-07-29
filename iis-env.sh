#!/bin/bash
# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

export CXX=g++-9.2.0

export VSIM_SEPP="questa-2023.4"
export VSIM="${VSIM_SEPP} vsim"
export VOPT="${VSIM_SEPP} vopt"
export VLIB="${VSIM_SEPP} vlib"
export WLF2VCD="${VSIM_SEPP} wlf2vcd"
export WLFMAN="${VSIM_SEPP} wlfman"

export OSEDA="oseda -2026.04"
export VCD2FST="${OSEDA} vcd2fst"

export VCS_SEPP="vcs-2024.09-zr"
export VCS="${VCS_SEPP} vcs"
export VLOGAN="${VCS_SEPP} vlogan"
export VCS_HOME=/usr/pack/${VCS_SEPP}/vcs

export DESIGNWARE_HOME=/usr/pack/tsmc-7-kgf/gwaihir/configurable_ips

export CHS_SW_GCC_BINROOT=/usr/pack/riscv-1.0-kgf/riscv64-gcc-12.2.0/bin
export VERIBLE_FMT="oseda -2025.03 verible-verilog-format"
export SN_LLVM_BINROOT=/usr/scratch2/vulcano/colluca/tools/riscv32-pulp-llvm-almalinux8-22.1.7-pulp-0.1.0/bin/

export UV=uv

bender checkout

env --unset=TMPDIR $UV sync --locked
source .venv/bin/activate
