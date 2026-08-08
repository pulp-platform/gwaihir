// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// UCIe-specific SystemRDL wrapper used by the full-chip software address map.
// The RTL APB register block is still generated directly from serial_link's
// slink_reg.rdl so its hwif shape stays compatible with slink_serializer.

`ifndef __UCIE_SLINK_REG_RDL__
`define __UCIE_SLINK_REG_RDL__

`include "slink_reg.rdl"

addrmap ucie_slink_reg {
  slink_reg #(.NumLanes(@UCIE_SLINK_NUM_LANES@), .EnDdr(@UCIE_SLINK_EN_DDR@)) regs @0x0;
};

`endif // __UCIE_SLINK_REG_RDL__
