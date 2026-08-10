// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "axi/typedef.svh"
`include "obi/typedef.svh"
`include "common_cells/assertions.svh"

module mem_tile_small
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
#(
  parameter bit          AxiUserAtop    = 1'b1,
  parameter int unsigned AxiUserAtopMsb = 3,
  parameter int unsigned AxiUserAtopLsb = 0,
  parameter int unsigned MemTileId      = 0
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              test_enable_i,
  input  logic                              clk_rst_bypass_i,
  // Chimney ports
  input  id_t                               id_i,
  // Sam idx
  input  logic       [$bits(sam_idx_e)-1:0] samidx_i,
  // Router ports
  output floo_req_t  [          West:North] floo_req_o,
  input  floo_rsp_t  [          West:North] floo_rsp_i,
  output floo_wide_t [          West:North] floo_wide_o,
  input  floo_req_t  [          West:North] floo_req_i,
  output floo_rsp_t  [          West:North] floo_rsp_o,
  input  floo_wide_t [          West:North] floo_wide_i
);

  localparam int unsigned MemTileSize = MemTileSizeSmall;

  mem_tile #(
`ifndef TARGET_SYNTHESIS
    .MemTileId     (MemTileId),
`endif
    .AxiUserAtop   (AxiUserAtop),
    .AxiUserAtopMsb(AxiUserAtopMsb),
    .AxiUserAtopLsb(AxiUserAtopLsb),
    .MemTileSize   (MemTileSize)
  ) i_mem_tile (
    .clk_i,
    .rst_ni,
    .test_enable_i   (test_enable_i),
    .clk_rst_bypass_i(clk_rst_bypass_i),
    .id_i            (id_i),
    .samidx_i        (samidx_i),
    .floo_req_o      (floo_req_o),
    .floo_rsp_i      (floo_rsp_i),
    .floo_wide_o     (floo_wide_o),
    .floo_req_i      (floo_req_i),
    .floo_rsp_o      (floo_rsp_o),
    .floo_wide_i     (floo_wide_i)
  );

endmodule
