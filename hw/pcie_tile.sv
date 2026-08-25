// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module pcie_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic test_enable_i,

  // Ref clk
  inout wire  pcie_refclk_n,
  inout wire  pcie_refclk_p,
  input logic pcie_button_rst_ni,

  // Serdes
  inout wire [1:0] pcie_rx_p,
  inout wire [1:0] pcie_rx_n,
  inout wire [1:0] pcie_tx_p,
  inout wire [1:0] pcie_tx_n,

  // Test
  input logic test_clk_en_i,
  input logic test_coreclk_i,
  input logic test_rst_en_i,
  input logic test_rst_n_i,
  input logic test_phy_rst_n_i,

  // JTAG
  input  logic jtag_phys_tdi_i,
  input  logic jtag_phys_tck_i,
  input  logic jtag_phys_tms_i,
  input  logic jtag_phys_trst_ni,
  output logic jtag_phys_tdo_o,

  // Router ID
  input id_t id_i,

  // Router mesh ports
  output floo_req_t  floo_req_east_o,
  input  floo_rsp_t  floo_rsp_east_i,
  output floo_wide_t floo_wide_east_o,
  input  floo_req_t  floo_req_east_i,
  output floo_rsp_t  floo_rsp_east_o,
  input  floo_wide_t floo_wide_east_i,
  output floo_req_t  floo_req_south_o,
  input  floo_rsp_t  floo_rsp_south_i,
  output floo_wide_t floo_wide_south_o,
  input  floo_req_t  floo_req_south_i,
  output floo_rsp_t  floo_rsp_south_o,
  input  floo_wide_t floo_wide_south_i
);

  ////////////
  // Router //
  ////////////

  floo_req_t [Eject:North] router_floo_req_out, router_floo_req_in;
  floo_rsp_t [Eject:North] router_floo_rsp_out, router_floo_rsp_in;
  floo_wide_t [Eject:North] router_floo_wide_in;
  floo_wide_t [Eject:North] router_floo_wide_out;

  floo_nw_router #(
    .AxiCfgN       (AxiCfgN),
    .AxiCfgW       (AxiCfgW),
    .RouteAlgo     (RouteCfg.RouteAlgo),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl)
  ) i_router (
    .clk_i,
    .rst_ni,
    .test_enable_i,
    .id_i,
    .id_route_map_i      ('0),
    .floo_req_i          (router_floo_req_in),
    .floo_rsp_o          (router_floo_rsp_out),
    .floo_req_o          (router_floo_req_out),
    .floo_rsp_i          (router_floo_rsp_in),
    .floo_wide_i         (router_floo_wide_in),
    .floo_wide_o         (router_floo_wide_out),
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  assign floo_req_east_o            = router_floo_req_out[East];
  assign router_floo_req_in[East]   = floo_req_east_i;
  assign floo_rsp_east_o            = router_floo_rsp_out[East];
  assign router_floo_rsp_in[East]   = floo_rsp_east_i;
  assign floo_wide_east_o           = router_floo_wide_out[East];
  assign router_floo_wide_in[East]  = floo_wide_east_i;
  assign floo_req_south_o           = router_floo_req_out[South];
  assign router_floo_req_in[South]  = floo_req_south_i;
  assign floo_rsp_south_o           = router_floo_rsp_out[South];
  assign router_floo_rsp_in[South]  = floo_rsp_south_i;
  assign floo_wide_south_o          = router_floo_wide_out[South];
  assign router_floo_wide_in[South] = floo_wide_south_i;
  assign router_floo_req_in[West]   = '0;
  assign router_floo_req_in[North]  = '0;
  assign router_floo_rsp_in[West]   = '0;
  assign router_floo_rsp_in[North]  = '0;
  assign router_floo_wide_in[West]  = '0;
  assign router_floo_wide_in[North] = '0;

  // Eject port: no real endpoint yet, tied to zero
  assign router_floo_req_in[Eject]  = '0;
  assign router_floo_rsp_in[Eject]  = '0;
  assign router_floo_wide_in[Eject] = '0;
  assign jtag_phys_tdo_o            = 1'b0;

endmodule : pcie_tile
