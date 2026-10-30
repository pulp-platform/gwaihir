// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

/// Left-column UCIe tile merged with the dummy tile above it, to be hardened as one macro.
/// Physical layout reasons
module ucie_tile_left
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

  // Dummy router, east port
  output floo_req_t  floo_req_dummy_east_o,
  input  floo_rsp_t  floo_rsp_dummy_east_i,
  output floo_wide_t floo_wide_dummy_east_o,
  input  floo_req_t  floo_req_dummy_east_i,
  output floo_rsp_t  floo_rsp_dummy_east_o,
  input  floo_wide_t floo_wide_dummy_east_i,

  // UCIe router, east port
  output floo_req_t  floo_req_ucie_east_o,
  input  floo_rsp_t  floo_rsp_ucie_east_i,
  output floo_wide_t floo_wide_ucie_east_o,
  input  floo_req_t  floo_req_ucie_east_i,
  output floo_rsp_t  floo_rsp_ucie_east_o,
  input  floo_wide_t floo_wide_ucie_east_i,

  // UCIe PHY reference clock (100 MHz)
  input  logic       ucie_refclk_i,
  // UCIe mainband bumps
  output logic       ucie_txckp_o,
  output logic       ucie_txckn_o,
  output logic [7:0] ucie_txdata_o,
  output logic       ucie_txtrk_o,
  output logic       ucie_txvld_o,
  input  logic       ucie_rxckp_i,
  input  logic       ucie_rxckn_i,
  input  logic [7:0] ucie_rxdata_i,
  input  logic       ucie_rxtrk_i,
  input  logic       ucie_rxvld_i,
  // UCIe sideband bumps
  output logic       ucie_txclksb_o,
  output logic       ucie_txdatasb_o,
  input  logic       ucie_rxclksb_i,
  input  logic       ucie_rxdatasb_i
);

  ///////////////////
  // Router arrays //
  ///////////////////

  floo_req_t [West:North] dummy_req_out, dummy_req_in;
  floo_rsp_t [West:North] dummy_rsp_out, dummy_rsp_in;
  floo_wide_t [West:North] dummy_wide_out, dummy_wide_in;

  floo_req_t [West:North] ucie_req_out, ucie_req_in;
  floo_rsp_t [West:North] ucie_rsp_out, ucie_rsp_in;
  floo_wide_t [West:North] ucie_wide_out, ucie_wide_in;

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
    .ucie_refclk_i,
    .ucie_txckp_o,
    .ucie_txckn_o,
    .ucie_txdata_o,
    .ucie_txtrk_o,
    .ucie_txvld_o,
    .ucie_rxckp_i,
    .ucie_rxckn_i,
    .ucie_rxdata_i,
    .ucie_rxtrk_i,
    .ucie_rxvld_i,
    .ucie_txclksb_o,
    .ucie_txdatasb_o,
    .ucie_rxclksb_i,
    .ucie_rxdatasb_i
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

  ////////////////////////////////
  // UCIe north <-> dummy south //
  ////////////////////////////////

  assign ucie_req_in[North]   = dummy_req_out[South];
  assign ucie_rsp_in[North]   = dummy_rsp_out[South];
  assign ucie_wide_in[North]  = dummy_wide_out[South];
  assign dummy_req_in[South]  = ucie_req_out[North];
  assign dummy_rsp_in[South]  = ucie_rsp_out[North];
  assign dummy_wide_in[South] = ucie_wide_out[North];

  ///////////////////
  // Exposed ports //
  ///////////////////

  assign floo_req_dummy_north_o  = dummy_req_out[North];
  assign dummy_rsp_in[North]     = floo_rsp_dummy_north_i;
  assign floo_wide_dummy_north_o = dummy_wide_out[North];
  assign dummy_req_in[North]     = floo_req_dummy_north_i;
  assign floo_rsp_dummy_north_o  = dummy_rsp_out[North];
  assign dummy_wide_in[North]    = floo_wide_dummy_north_i;

  assign floo_req_dummy_east_o  = dummy_req_out[East];
  assign dummy_rsp_in[East]     = floo_rsp_dummy_east_i;
  assign floo_wide_dummy_east_o = dummy_wide_out[East];
  assign dummy_req_in[East]     = floo_req_dummy_east_i;
  assign floo_rsp_dummy_east_o  = dummy_rsp_out[East];
  assign dummy_wide_in[East]    = floo_wide_dummy_east_i;

  assign floo_req_ucie_east_o  = ucie_req_out[East];
  assign ucie_rsp_in[East]     = floo_rsp_ucie_east_i;
  assign floo_wide_ucie_east_o = ucie_wide_out[East];
  assign ucie_req_in[East]     = floo_req_ucie_east_i;
  assign floo_rsp_ucie_east_o  = ucie_rsp_out[East];
  assign ucie_wide_in[East]    = floo_wide_ucie_east_i;

  /////////////////////////////
  // Mesh boundary: tie offs //
  /////////////////////////////

  // Outputs left open, inputs tied off, so synthesis removes these router
  // ports. West is the chip edge; South is below the bottom row of the
  // mesh, where nothing is routed.
  assign dummy_req_in[West]  = '0;
  assign dummy_rsp_in[West]  = '0;
  assign dummy_wide_in[West] = '0;

  assign ucie_req_in[West]  = '0;
  assign ucie_rsp_in[West]  = '0;
  assign ucie_wide_in[West] = '0;

  assign ucie_req_in[South]  = '0;
  assign ucie_rsp_in[South]  = '0;
  assign ucie_wide_in[South] = '0;

endmodule : ucie_tile_left
