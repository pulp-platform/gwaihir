#!/bin/bash
# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

export CXX=g++-9.2.0

export VSIM_SEPP="questa-2023.4"
export VSIM="${VSIM_SEPP} vsim"
export VOPT="${VSIM_SEPP} vopt"
export VLIB="${VSIM_SEPP} vlib"

export VCS_SEPP="vcs-2024.09"
export VCS="${VCS_SEPP} vcs"
export VLOGAN="${VCS_SEPP} vlogan"

export CHS_SW_GCC_BINROOT=/usr/pack/riscv-1.0-kgf/riscv64-gcc-12.2.0/bin
export VERIBLE_FMT="oseda -2025.03 verible-verilog-format"
export SN_LLVM_BINROOT=/usr/scratch2/vulcano/colluca/tools/riscv32-snitch-llvm-almalinux8-15.0.0-snitch-0.5.0/bin

bender checkout

/usr/local/uv/uv sync --locked
source .venv/bin/activate
