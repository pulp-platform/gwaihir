// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

/// Right-column UCIe tile merged with the dummy tile above it, to be hardened as one macro.
/// Physical layout reasons
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

  // UCIe north <-> dummy south
  floo_req_t ucie_req_north_out, ucie_req_north_in;
  floo_rsp_t ucie_rsp_north_out, ucie_rsp_north_in;
  floo_wide_t ucie_wide_north_out, ucie_wide_north_in;

  ///////////
  // Tiles //
  ///////////

  ucie_tile i_ucie_tile (
    .clk_i,
    .rst_ni,
    .clk_rst_bypass_i,
    .test_enable_i,
    .id_i             (id_i),
    .ucie_id_i,
    .samidx_i,
    .floo_req_north_o (ucie_req_north_out),
    .floo_rsp_north_i (ucie_rsp_north_in),
    .floo_wide_north_o(ucie_wide_north_out),
    .floo_req_north_i (ucie_req_north_in),
    .floo_rsp_north_o (ucie_rsp_north_out),
    .floo_wide_north_i(ucie_wide_north_in),
    .floo_req_west_o  (floo_req_ucie_west_o),
    .floo_rsp_west_i  (floo_rsp_ucie_west_i),
    .floo_wide_west_o (floo_wide_ucie_west_o),
    .floo_req_west_i  (floo_req_ucie_west_i),
    .floo_rsp_west_o  (floo_rsp_ucie_west_o),
    .floo_wide_west_i (floo_wide_ucie_west_i),
    // Chip boundary: tied off
    .floo_req_east_o  (),
    .floo_rsp_east_i  ('0),
    .floo_wide_east_o (),
    .floo_req_east_i  ('0),
    .floo_rsp_east_o  (),
    .floo_wide_east_i ('0),
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

  assign ucie_req_north_in    = dummy_req_out[South];
  assign ucie_rsp_north_in    = dummy_rsp_out[South];
  assign ucie_wide_north_in   = dummy_wide_out[South];
  assign dummy_req_in[South]  = ucie_req_north_out;
  assign dummy_rsp_in[South]  = ucie_rsp_north_out;
  assign dummy_wide_in[South] = ucie_wide_north_out;

  ///////////////////
  // Exposed ports //
  ///////////////////

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

  /////////////////////////////
  // Chip boundary: tie offs //
  /////////////////////////////

  assign dummy_req_in[East]  = '0;
  assign dummy_rsp_in[East]  = '0;
  assign dummy_wide_in[East] = '0;

endmodule : ucie_tile_right
