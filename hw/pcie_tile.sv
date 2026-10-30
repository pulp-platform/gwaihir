// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

`include "axi/assign.svh"
`include "common_cells/assertions.svh"

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
    .RouteAlgo     (RouteCfgMcastOnly.RouteAlgo),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl),
    // This tile never initiates collectives: no loopback needed
    .NoLoopback    (1'b1),
    .CollectiveCfg (RouteCfgMcastOnly.CollectiveCfg),
    .collect_op_t  (floo_gwaihir_noc_pkg::collect_op_t)
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

  /////////////
  // Chimney //
  /////////////

  collective_axi_narrow_out_req_t pcie_slv_req;
  collective_axi_narrow_out_rsp_t pcie_slv_rsp;
  collective_axi_narrow_in_req_t  pcie_mst_req;
  collective_axi_narrow_in_rsp_t  pcie_mst_rsp;

  localparam chimney_cfg_t ChimneyCfgN = ChimneyDefaultCfg;
  localparam chimney_cfg_t ChimneyCfgW = set_ports(ChimneyDefaultCfg, 1'b1, 1'b0);

  floo_nw_chimney #(
    .AxiCfgN             (AxiCfgN),
    .AxiCfgW             (AxiCfgW),
    .ChimneyCfgN         (ChimneyCfgN),
    .ChimneyCfgW         (ChimneyCfgW),
    .RouteCfg            (RouteCfgNoMcast),
    .AtopSupport         (1'b1),
    .collect_op_t        (floo_gwaihir_noc_pkg::collect_op_t),
    .WideRwDecouple      (WideRwDecouple),
    .VcImpl              (VcImpl),
    .MaxAtomicTxns       (AxiCfgN.OutIdWidth - 1),
    .Sam                 (Sam),
    .id_t                (id_t),
    .rob_idx_t           (rob_idx_t),
    .hdr_t               (hdr_t),
    .sam_rule_t          (sam_rule_t),
    .axi_narrow_in_req_t (floo_gwaihir_noc_pkg::collective_axi_narrow_in_req_t),
    .axi_narrow_in_rsp_t (floo_gwaihir_noc_pkg::collective_axi_narrow_in_rsp_t),
    .axi_narrow_out_req_t(floo_gwaihir_noc_pkg::collective_axi_narrow_out_req_t),
    .axi_narrow_out_rsp_t(floo_gwaihir_noc_pkg::collective_axi_narrow_out_rsp_t),
    .axi_wide_in_req_t   (floo_gwaihir_noc_pkg::collective_axi_wide_in_req_t),
    .axi_wide_in_rsp_t   (floo_gwaihir_noc_pkg::collective_axi_wide_in_rsp_t),
    .axi_wide_out_req_t  (floo_gwaihir_noc_pkg::collective_axi_wide_out_req_t),
    .axi_wide_out_rsp_t  (floo_gwaihir_noc_pkg::collective_axi_wide_out_rsp_t),
    .floo_req_t          (floo_req_t),
    .floo_rsp_t          (floo_rsp_t),
    .floo_wide_t         (floo_wide_t),
    .user_narrow_struct_t(floo_gwaihir_noc_pkg::collective_axi_narrow_in_user_t),
    .user_wide_struct_t  (floo_gwaihir_noc_pkg::collective_axi_wide_in_user_t)
  ) i_chimney (
    .clk_i,
    .rst_ni,
    .id_i,
    .test_enable_i,
    .sram_cfg_i          ('0),
    .route_table_i       ('0),
    .axi_narrow_in_req_i (pcie_mst_req),
    .axi_narrow_in_rsp_o (pcie_mst_rsp),
    .axi_narrow_out_req_o(pcie_slv_req),
    .axi_narrow_out_rsp_i(pcie_slv_rsp),
    .axi_wide_in_req_i   ('0),
    .axi_wide_in_rsp_o   (),
    .axi_wide_out_req_o  (),
    .axi_wide_out_rsp_i  ('0),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  /////////////
  // Wrapper //
  /////////////

  // The NoC's narrow `user` carries the collective fields next to the plain AXI user bits; the
  // PCIe controller knows only about the latter. Convert between the two explicitly rather than
  // letting the field-wise struct assign truncate: the silent truncation is what let the two
  // widths drift apart unnoticed until elaboration. `nw_axi_collectives_filter` does not fit
  // here, since it keeps the collective struct on its manager-side port, which the controller
  // cannot carry.
  pcie_axi_slv_req_t pcie_slv_plain_req;
  pcie_axi_slv_rsp_t pcie_slv_plain_rsp;
  pcie_axi_mst_req_t pcie_mst_plain_req;
  pcie_axi_mst_rsp_t pcie_mst_plain_rsp;

  always_comb begin
    // NoC -> controller: drop the collective fields.
    `AXI_SET_REQ_STRUCT(pcie_slv_plain_req, pcie_slv_req)
    pcie_slv_plain_req.aw.user = pcie_slv_req.aw.user.user;
    pcie_slv_plain_req.w.user  = pcie_slv_req.w.user.user;
    pcie_slv_plain_req.ar.user = pcie_slv_req.ar.user.user;

    `AXI_SET_RESP_STRUCT(pcie_slv_rsp, pcie_slv_plain_rsp)
    pcie_slv_rsp.b.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: pcie_slv_plain_rsp.b.user
    };
    pcie_slv_rsp.r.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: pcie_slv_plain_rsp.r.user
    };
  end

  always_comb begin
    // Controller -> NoC: the PCIe port never issues collectives.
    `AXI_SET_REQ_STRUCT(pcie_mst_req, pcie_mst_plain_req)
    pcie_mst_req.aw.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: pcie_mst_plain_req.aw.user
    };
    pcie_mst_req.w.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: pcie_mst_plain_req.w.user
    };
    pcie_mst_req.ar.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: pcie_mst_plain_req.ar.user
    };

    `AXI_SET_RESP_STRUCT(pcie_mst_plain_rsp, pcie_mst_rsp)
    pcie_mst_plain_rsp.b.user = pcie_mst_rsp.b.user.user;
    pcie_mst_plain_rsp.r.user = pcie_mst_rsp.r.user.user;
  end

  // `PcieAxiUserWidth` is taken from the cluster's atomic ID, the NoC's `user` field from the
  // FlooNoC config. The two are required to agree; check it here rather than trust the comment.
  `ASSERT_INIT(PcieSlvUserWidthMatch, PcieAxiUserWidth == $bits(pcie_slv_req.aw.user.user))
  `ASSERT_INIT(PcieMstUserWidthMatch, PcieAxiUserWidth == $bits(pcie_mst_req.aw.user.user))

  // The bender target `pcie` swaps this module for the one in the closed-source repository,
  // which wraps the real PCIe controller and PHY.
  pcie_top_wrap i_pcie_top_wrap (
    // From SoC
    .host_clk_i(clk_i),
    .rst_ni    (rst_ni),

    // Serdes
    .pcie_refclk_n     (pcie_refclk_n),
    .pcie_refclk_p     (pcie_refclk_p),
    .pcie_button_rst_ni(pcie_button_rst_ni),

    .pcie_rx_p(pcie_rx_p),
    .pcie_rx_n(pcie_rx_n),
    .pcie_tx_p(pcie_tx_p),
    .pcie_tx_n(pcie_tx_n),

    // Debug
    .test_clk_en_i   (test_clk_en_i),
    .test_coreclk_i  (test_coreclk_i),
    .test_rst_en_i   (test_rst_en_i),
    .test_rst_n_i    (test_rst_n_i),
    .test_phy_rst_n_i(test_phy_rst_n_i),

    // JTAG
    .jtag_phys_tdi_i  (jtag_phys_tdi_i),
    .jtag_phys_tck_i  (jtag_phys_tck_i),
    .jtag_phys_tms_i  (jtag_phys_tms_i),
    .jtag_phys_trst_ni(jtag_phys_trst_ni),
    .jtag_phys_tdo_o  (jtag_phys_tdo_o),

    // Slv
    .pcie_req_i(pcie_slv_plain_req),
    .pcie_rsp_o(pcie_slv_plain_rsp),

    // Mst
    .pcie_req_o(pcie_mst_plain_req),
    .pcie_rsp_i(pcie_mst_plain_rsp)
  );

endmodule : pcie_tile
