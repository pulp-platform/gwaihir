// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module ucie_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
(
  input  logic                                                    clk_i,
  input  logic                                                    rst_ni,
  input  logic                                                    test_enable_i,
  // Router ID
  input  id_t                                                     id_i,
  input  floo_gwaihir_noc_pkg::axi_narrow_out_addr_t              base_addr_i,
  input  floo_gwaihir_noc_pkg::axi_narrow_out_addr_t              addr_size_i,
  // Router mesh ports (all 4 directions; boundary tie-offs handled by mesh)
  output floo_req_t                                  [West:North] floo_req_o,
  input  floo_rsp_t                                  [West:North] floo_rsp_i,
  output floo_wide_t                                 [West:North] floo_wide_o,
  input  floo_req_t                                  [West:North] floo_req_i,
  output floo_rsp_t                                  [West:North] floo_rsp_o,
  input  floo_wide_t                                 [West:North] floo_wide_i,

  // AXI narrow channels
  output floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_out_req_o,
  input  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t axi_narrow_out_rsp_i,
  input  floo_gwaihir_noc_pkg::axi_narrow_in_req_t  axi_narrow_in_req_i,
  output floo_gwaihir_noc_pkg::axi_narrow_in_rsp_t  axi_narrow_in_rsp_o,
  // AXI wide channels
  output floo_gwaihir_noc_pkg::axi_wide_out_req_t   axi_wide_out_req_o,
  input  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t   axi_wide_out_rsp_i,
  input  floo_gwaihir_noc_pkg::axi_wide_in_req_t    axi_wide_in_req_i,
  output floo_gwaihir_noc_pkg::axi_wide_in_rsp_t    axi_wide_in_rsp_o
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
    .RouteAlgo     (RouteCfgNoMcast.RouteAlgo),
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
    // Wide Reduction offload port
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    // Narrow Reduction offload port
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

  /////////////
  // Chimney //
  /////////////

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_out_req;
  floo_gwaihir_noc_pkg::axi_wide_out_req_t   axi_wide_out_req;

  floo_nw_chimney #(
    .AxiCfgN             (floo_gwaihir_noc_pkg::AxiCfgN),
    .AxiCfgW             (floo_gwaihir_noc_pkg::AxiCfgW),
    .ChimneyCfgN         (floo_pkg::ChimneyDefaultCfg),
    .ChimneyCfgW         (floo_pkg::ChimneyDefaultCfg),
    .RouteCfg            (RouteCfgNoMcast),
    .AtopSupport         (1'b1),
    .WideRwDecouple      (floo_gwaihir_noc_pkg::WideRwDecouple),
    .VcImpl              (VcImpl),
    .MaxAtomicTxns       (3),                                           // TODO: CHECK
    .Sam                 (floo_gwaihir_noc_pkg::Sam),
    .id_t                (floo_gwaihir_noc_pkg::id_t),
    .rob_idx_t           (floo_gwaihir_noc_pkg::rob_idx_t),
    .hdr_t               (floo_gwaihir_noc_pkg::hdr_t),
    .sam_rule_t          (floo_gwaihir_noc_pkg::sam_rule_t),
    //CHECK PARAMS!!
    .axi_narrow_in_req_t (floo_gwaihir_noc_pkg::axi_narrow_in_req_t),
    .axi_narrow_in_rsp_t (floo_gwaihir_noc_pkg::axi_narrow_in_rsp_t),
    .axi_narrow_out_req_t(floo_gwaihir_noc_pkg::axi_narrow_out_req_t),
    .axi_narrow_out_rsp_t(floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t),
    .axi_wide_in_req_t   (floo_gwaihir_noc_pkg::axi_wide_in_req_t),
    .axi_wide_in_rsp_t   (floo_gwaihir_noc_pkg::axi_wide_in_rsp_t),
    .axi_wide_out_req_t  (floo_gwaihir_noc_pkg::axi_wide_out_req_t),
    .axi_wide_out_rsp_t  (floo_gwaihir_noc_pkg::axi_wide_out_rsp_t),

    .floo_req_t (floo_gwaihir_noc_pkg::floo_req_t),
    .floo_rsp_t (floo_gwaihir_noc_pkg::floo_rsp_t),
    .floo_wide_t(floo_gwaihir_noc_pkg::floo_wide_t)
  ) i_chimney (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .test_enable_i,
    .id_i,
    .route_table_i       ('0),
    .sram_cfg_i          ('0),
    // AXI narrow channels
    .axi_narrow_in_req_i (axi_narrow_in_req_i),
    .axi_narrow_in_rsp_o (axi_narrow_in_rsp_o),
    .axi_narrow_out_req_o(axi_narrow_out_req),
    .axi_narrow_out_rsp_i(axi_narrow_out_rsp_i),
    // AXI wide channels
    .axi_wide_in_req_i   (axi_wide_in_req_i),
    .axi_wide_in_rsp_o   (axi_wide_in_rsp_o),
    .axi_wide_out_req_o  (axi_wide_out_req),
    .axi_wide_out_rsp_i  (axi_wide_out_rsp_i),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  logic aw_narrow_addr_match;
  logic ar_narrow_addr_match;
  logic aw_wide_addr_match;
  logic ar_wide_addr_match;

  // Check if incoming addresses fall within [base_addr_i, base_addr_i + addr_size_i - 1]
  assign aw_narrow_addr_match = (axi_narrow_out_req.aw.addr >= base_addr_i) &&
                                (axi_narrow_out_req.aw.addr <  (base_addr_i + addr_size_i));

  assign ar_narrow_addr_match = (axi_narrow_out_req.ar.addr >= base_addr_i) &&
                                (axi_narrow_out_req.ar.addr <  (base_addr_i + addr_size_i));

  assign aw_wide_addr_match = (axi_wide_out_req.aw.addr >= base_addr_i) &&
                              (axi_wide_out_req.aw.addr <  (base_addr_i + addr_size_i));

  assign ar_wide_addr_match = (axi_wide_out_req.ar.addr >= base_addr_i) &&
                              (axi_wide_out_req.ar.addr <  (base_addr_i + addr_size_i));

  always_comb begin
    axi_narrow_out_req_o = axi_narrow_out_req;
    axi_narrow_out_req_o.aw.addr = (aw_narrow_addr_match) ? (axi_narrow_out_req.aw.addr - base_addr_i) : '0;
    axi_narrow_out_req_o.ar.addr = (ar_narrow_addr_match) ? (axi_narrow_out_req.ar.addr - base_addr_i) : '0;

    axi_wide_out_req_o = axi_wide_out_req;
    axi_wide_out_req_o.aw.addr   = (aw_wide_addr_match) ? (axi_wide_out_req.aw.addr - base_addr_i) : '0;
    axi_wide_out_req_o.ar.addr   = (ar_wide_addr_match) ? (axi_wide_out_req.ar.addr - base_addr_i) : '0;
  end

endmodule : ucie_tile
