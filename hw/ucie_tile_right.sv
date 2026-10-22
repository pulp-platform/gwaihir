// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

/// Right-column UCIe tile merged with the dummy tile above it, to be hardened as one macro.
///
/// Physical layout (x = MeshDim.x-1, UCIe 1 at the bottom of the column):
///
///             north (L2 SPM)
///                 |
///   west (cluster) -- dummy -- (tie off)
///                 |
///   west (cluster) -- UCIe  -- (tie off)
///                 |
///             (tie off)
///
/// Only the ports towards a neighbouring tile are exposed. The ports on the chip boundary are
/// tied off inside the macro. The UCIe/dummy link is a plain wire.
module ucie_tile_right
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
  import ucie_slink_reg_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic clk_rst_bypass_i,
  input logic test_enable_i,

  // Router IDs and UCIe configuration
  input id_t                         id_i,
  input id_t                         dummy_id_i,
  input logic                        ucie_id_i,
  input logic [$bits(sam_idx_e)-1:0] samidx_i,

  // Dummy router, north port
  output floo_req_t  floo_req_dummy_north_o,
  input  floo_rsp_t  floo_rsp_dummy_north_i,
  output floo_wide_t floo_wide_dummy_north_o,
  input  floo_req_t  floo_req_dummy_north_i,
  output floo_rsp_t  floo_rsp_dummy_north_o,
  input  floo_wide_t floo_wide_dummy_north_i,

  // Dummy router, west port
  output floo_req_t  floo_req_dummy_west_o,
  input  floo_rsp_t  floo_rsp_dummy_west_i,
  output floo_wide_t floo_wide_dummy_west_o,
  input  floo_req_t  floo_req_dummy_west_i,
  output floo_rsp_t  floo_rsp_dummy_west_o,
  input  floo_wide_t floo_wide_dummy_west_i,

  // UCIe router, west port
  output floo_req_t  floo_req_ucie_west_o,
  input  floo_rsp_t  floo_rsp_ucie_west_i,
  output floo_wide_t floo_wide_ucie_west_o,
  input  floo_req_t  floo_req_ucie_west_i,
  output floo_rsp_t  floo_rsp_ucie_west_o,
  input  floo_wide_t floo_wide_ucie_west_i,

  // UCIe PHY interface (to the peer tile)
  output logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_out_o,
  output logic [NumChannels-1:0]                      phy_data_out_valid_o,
  input  logic [NumChannels-1:0]                      phy_data_out_ready_i,
  input  logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_in_i,
  input  logic [NumChannels-1:0]                      phy_data_in_valid_i,
  output logic [NumChannels-1:0]                      phy_data_in_ready_o
);

  // The tile must sit in the bottom-left corner with a dummy tile right above it.
  localparam int unsigned UcieX = int'(SamPhysical[Ucie1SamIdx].idx.x);
  localparam int unsigned UcieY = int'(SamPhysical[Ucie1SamIdx].idx.y);

  if (UcieX != MeshDim.x - 1 || UcieY != 0) begin : gen_check_corner
    $fatal(
        1,
        "[ucie_tile_right] UCIe 1 is at (%0d, %0d), expected the bottom-right corner (%0d, 0).",
        UcieX,
        UcieY,
        MeshDim.x - 1
    );
  end

  ///////////////////
  // Router arrays //
  ///////////////////

  floo_req_t [West:North] ucie_req_out, ucie_req_in;
  floo_rsp_t [West:North] ucie_rsp_out, ucie_rsp_in;
  floo_wide_t [West:North] ucie_wide_out, ucie_wide_in;

  floo_req_t [West:North] dummy_req_out, dummy_req_in;
  floo_rsp_t [West:North] dummy_rsp_out, dummy_rsp_in;
  floo_wide_t [West:North] dummy_wide_out, dummy_wide_in;

  ///////////
  // Tiles //
  ///////////

  ucie_tile i_ucie_tile (
    .clk_i,
    .rst_ni,
    .clk_rst_bypass_i,
    .test_enable_i,
    .id_i       (id_i),
    .ucie_id_i,
    .samidx_i,
    .floo_req_o (ucie_req_out),
    .floo_rsp_i (ucie_rsp_in),
    .floo_wide_o(ucie_wide_out),
    .floo_req_i (ucie_req_in),
    .floo_rsp_o (ucie_rsp_out),
    .floo_wide_i(ucie_wide_in),
    .phy_data_out_o,
    .phy_data_out_valid_o,
    .phy_data_out_ready_i,
    .phy_data_in_i,
    .phy_data_in_valid_i,
    .phy_data_in_ready_o
  );

  dummy_tile i_dummy_tile (
    .clk_i,
    .rst_ni,
    .test_enable_i,
    .id_i       (dummy_id_i),
    .floo_req_o (dummy_req_out),
    .floo_rsp_i (dummy_rsp_in),
    .floo_wide_o(dummy_wide_out),
    .floo_req_i (dummy_req_in),
    .floo_rsp_o (dummy_rsp_out),
    .floo_wide_i(dummy_wide_in)
  );

  //////////////////////////////
  // UCIe north <-> dummy south //
  //////////////////////////////

  assign ucie_req_in[North]   = dummy_req_out[South];
  assign ucie_rsp_in[North]   = dummy_rsp_out[South];
  assign ucie_wide_in[North]  = dummy_wide_out[South];
  assign dummy_req_in[South]  = ucie_req_out[North];
  assign dummy_rsp_in[South]  = ucie_rsp_out[North];
  assign dummy_wide_in[South] = ucie_wide_out[North];

  ////////////////////
  // Exposed ports //
  ////////////////////

  assign floo_req_dummy_north_o  = dummy_req_out[North];
  assign dummy_rsp_in[North]     = floo_rsp_dummy_north_i;
  assign floo_wide_dummy_north_o = dummy_wide_out[North];
  assign dummy_req_in[North]     = floo_req_dummy_north_i;
  assign floo_rsp_dummy_north_o  = dummy_rsp_out[North];
  assign dummy_wide_in[North]    = floo_wide_dummy_north_i;

  assign floo_req_dummy_west_o  = dummy_req_out[West];
  assign dummy_rsp_in[West]     = floo_rsp_dummy_west_i;
  assign floo_wide_dummy_west_o = dummy_wide_out[West];
  assign dummy_req_in[West]     = floo_req_dummy_west_i;
  assign floo_rsp_dummy_west_o  = dummy_rsp_out[West];
  assign dummy_wide_in[West]    = floo_wide_dummy_west_i;

  assign floo_req_ucie_west_o  = ucie_req_out[West];
  assign ucie_rsp_in[West]     = floo_rsp_ucie_west_i;
  assign floo_wide_ucie_west_o = ucie_wide_out[West];
  assign ucie_req_in[West]     = floo_req_ucie_west_i;
  assign floo_rsp_ucie_west_o  = ucie_rsp_out[West];
  assign ucie_wide_in[West]    = floo_wide_ucie_west_i;

  /////////////////////////////
  // Chip boundary: tie offs //
  /////////////////////////////

  assign ucie_req_in[South]  = '0;
  assign ucie_rsp_in[South]  = '0;
  assign ucie_wide_in[South] = '0;
  assign ucie_req_in[East]   = '0;
  assign ucie_rsp_in[East]   = '0;
  assign ucie_wide_in[East]  = '0;

  assign dummy_req_in[East]  = '0;
  assign dummy_rsp_in[East]  = '0;
  assign dummy_wide_in[East] = '0;

endmodule : ucie_tile_right
