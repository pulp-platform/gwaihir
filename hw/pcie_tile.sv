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
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    test_enable_i,
  // Ref clk
  inout  wire                     pcie_refclk_n,
  inout  wire                     pcie_refclk_p,
  input  logic                    pcie_button_rst_ni,
  // Serdes
  inout  wire        [       1:0] pcie_rx_p,
  inout  wire        [       1:0] pcie_rx_n,
  inout  wire        [       1:0] pcie_tx_p,
  inout  wire        [       1:0] pcie_tx_n,
  // Test
  input  logic                    test_clk_en_i,
  input  logic                    test_coreclk_i,
  input  logic                    test_rst_en_i,
  input  logic                    test_rst_n_i,
  input  logic                    test_phy_rst_n_i,
  // JTAG
  input  logic                    jtag_phys_tdi_i,
  input  logic                    jtag_phys_tck_i,
  input  logic                    jtag_phys_tms_i,
  input  logic                    jtag_phys_trst_ni,
  output logic                    jtag_phys_tdo_o,
  // Router ID
  input  id_t                     id_i,
  // Router mesh ports (all 4 directions; boundary tie-offs handled by mesh)
  output floo_req_t  [West:North] floo_req_o,
  input  floo_rsp_t  [West:North] floo_rsp_i,
  output floo_wide_t [West:North] floo_wide_o,
  input  floo_req_t  [West:North] floo_req_i,
  output floo_rsp_t  [West:North] floo_rsp_o,
  input  floo_wide_t [West:North] floo_wide_i
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

  // Connect all 4 mesh directions; top-level mesh handles boundary tie-offs
  assign floo_req_o                      = router_floo_req_out[West:North];
  assign router_floo_req_in[West:North]  = floo_req_i;
  assign floo_rsp_o                      = router_floo_rsp_out[West:North];
  assign router_floo_rsp_in[West:North]  = floo_rsp_i;
  assign floo_wide_o                     = router_floo_wide_out[West:North];
  assign router_floo_wide_in[West:North] = floo_wide_i;

  // Eject port: no real endpoint yet, tied to zero
  assign router_floo_req_in[Eject]       = '0;
  assign router_floo_rsp_in[Eject]       = '0;
  assign router_floo_wide_in[Eject]      = '0;
  assign jtag_phys_tdo_o                 = 1'b0;

endmodule : pcie_tile
