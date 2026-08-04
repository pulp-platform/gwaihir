// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
// Chen Wu <chenwu@iis.ee.ethz.ch>

`include "axi/typedef.svh"

module ucie_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
(
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    test_enable_i,
  // Router ID
  input  id_t                     id_i,
  input  logic                    ucie_id_i,
  // Router mesh ports (all 4 directions; boundary tie-offs handled by mesh)
  output floo_req_t  [West:North] floo_req_o,
  input  floo_rsp_t  [West:North] floo_rsp_i,
  output floo_wide_t [West:North] floo_wide_o,
  input  floo_req_t  [West:North] floo_req_i,
  output floo_rsp_t  [West:North] floo_rsp_o,
  input  floo_wide_t [West:North] floo_wide_i,

  // AXI narrow channels
  // output floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_out_req_o, //TODO(lleone): delete
  // input  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t axi_narrow_out_rsp_i, //TODO(lleone): delete
  input  floo_gwaihir_noc_pkg::axi_narrow_in_req_t axi_narrow_in_req_i,
  output floo_gwaihir_noc_pkg::axi_narrow_in_rsp_t axi_narrow_in_rsp_o,
  // AXI wide channels
  output floo_gwaihir_noc_pkg::axi_wide_out_req_t  axi_wide_out_req_o,
  input  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t  axi_wide_out_rsp_i,
  input  floo_gwaihir_noc_pkg::axi_wide_in_req_t   axi_wide_in_req_i,
  output floo_gwaihir_noc_pkg::axi_wide_in_rsp_t   axi_wide_in_rsp_o
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

  floo_gwaihir_noc_pkg::axi_wide_in_req_t    axi_wide_in_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_out_req;

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
    .axi_narrow_in_req_i ('0),
    .axi_narrow_in_rsp_o (),
    .axi_narrow_out_req_o(axi_narrow_out_req),
    .axi_narrow_out_rsp_i(axi_narrow_out_rsp_i),
    // AXI wide channels
    .axi_wide_in_req_i   (axi_wide_in_req),
    .axi_wide_in_rsp_o   (axi_wide_in_rsp_o),
    .axi_wide_out_req_o  (axi_wide_out_req_o),
    .axi_wide_out_rsp_i  (axi_wide_out_rsp_i),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  // Translate ingress addresses to their canonical form
  always_comb begin
    axi_narrow_in_req         = axi_narrow_in_req_i;
    axi_narrow_in_req.aw.addr = unalias_ucie_address(axi_narrow_in_req_i.aw.addr, ucie_id_i);
    axi_narrow_in_req.ar.addr = unalias_ucie_address(axi_narrow_in_req_i.ar.addr, ucie_id_i);

    axi_wide_in_req           = axi_wide_in_req_i;
    axi_wide_in_req.aw.addr   = unalias_ucie_address(axi_wide_in_req_i.aw.addr, ucie_id_i);
    axi_wide_in_req.ar.addr   = unalias_ucie_address(axi_wide_in_req_i.ar.addr, ucie_id_i);
  end

  localparam axi_cfg_t AxiCfgJoin = floo_pkg::axi_join_cfg(AxiCfgN, AxiCfgW);

  typedef logic [AxiCfgJoin.OutIdWidth-1:0] nw_join_id_t;
  typedef logic [AxiCfgJoin.UserWidth-1:0] nw_join_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_wide_join, axi_wide_join_req_t, axi_wide_join_rsp_t, axi_wide_in_addr_t,
                      nw_join_id_t, axi_wide_in_data_t, axi_wide_in_strb_t, nw_join_user_t)

  /////////////////
  // Narrow XBAR //
  /////////////////

  localparam axi_pkg::xbar_cfg_t AxiWideXbarCfg = '{
      NoSlvPorts: 1,
      NoMstPorts: 2,
      MaxMstTrans: 4,
      MaxSlvTrans: 4,
      FallThrough: 0,
      // If you have timing issue, change latency to cut ports
      PipelineStages:
      0,
      AxiIdWidthSlvPorts: $bits(axi_wide_in_id_t),
      AxiIdUsedSlvPorts: $bits(axi_wide_in_id_t),
      UniqueIds: 0,
      AxiAddrWidth: $bits(axi_wide_in_addr_t),
      AxiDataWidth: $bits(axi_wide_in_data_t),
      NoAddrRules: 2,
      default: '0
  };

  typedef enum logic {
    APB     = 0,
    CHIPLET = 1
  } ucie_rule_idx_t;

  typedef struct packed {
    logic [$clog2(AxiWideXbarCfg.NoMstPorts)-1:0] idx;
    axi_wide_in_addr_t                            start_addr;
    axi_wide_in_addr_t                            end_addr;
  } ucie_rule_t;

  // Two regions:
  //   1. The APB cfg region (either UCIe or axi_serializer)
  //   2. The other chiplet region
  ucie_rule_t [1:0] tile_addrmap;

  assign tile_addrmap = '{
          // Address range to the axi serializer cfg interface
          '{
              idx: APB,
              start_addr: Sam[Ucie0SamIdx].start_addr,
              end_addr  : Sam[Ucie0SamIdx].end_addr
          },
          // TODO: Address range to the ucie cfg interface -- placeholder until defined
          '{
              idx: CHIPLET,
              start_addr: '0,
              end_addr  : '0
          }
      };

  axi_xbar #(
    .Cfg          (AxiWideXbarCfg),
    .ATOPs        ('0),
    .Connectivity ('1),
    .slv_aw_chan_t(axi_narrow_in_aw_chan_t),
    .mst_aw_chan_t(axi_narrow_in_aw_chan_t),
    .w_chan_t     (axi_narrow_in_w_chan_t),
    .slv_b_chan_t (axi_narrow_in_b_chan_t),
    .mst_b_chan_t (axi_narrow_in_b_chan_t),
    .slv_ar_chan_t(axi_narrow_in_ar_chan_t),
    .mst_ar_chan_t(axi_narrow_in_ar_chan_t),
    .slv_r_chan_t (axi_narrow_in_r_chan_t),
    .mst_r_chan_t (axi_narrow_in_r_chan_t),
    .slv_req_t    (axi_narrow_in_req_t),
    .slv_resp_t   (axi_narrow_in_rsp_t),
    .mst_req_t    (axi_narrow_in_req_t),
    .mst_resp_t   (axi_narrow_in_rsp_t),
    .rule_t       (ucie_rule_t)
  ) i_narrow_xbar (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .test_i   (test_enable_i),
    .slv_req_i(),
    .slv_rsp_o(),
    .mst_req_o(),
    .mst_rsp_i(),
    .rule_i   ()
  );

  floo_nw_join #(
    .AxiCfgN         (axi_cfg_swap_iw(AxiCfgN)),
    .AxiCfgW         (axi_cfg_swap_iw(AxiCfgW)),
    .AxiCfgJoin      (axi_cfg_swap_iw(AxiCfgJoin)),
    .EnAtopAdapter   (1'b0),
    .AtopUserAsId    (1'b1),
    .axi_narrow_req_t(axi_narrow_out_req_t),
    .axi_narrow_rsp_t(axi_narrow_out_rsp_t),
    .axi_wide_req_t  (axi_wide_out_req_t),
    .axi_wide_rsp_t  (axi_wide_out_rsp_t),
    .axi_req_t       (axi_wide_join_req_t),
    .axi_rsp_t       (axi_wide_join_rsp_t)
  ) i_floo_nw_join (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .test_enable_i   (test_enable_i),
    .axi_narrow_req_i(axi_demux_out_req[Mem]),
    .axi_narrow_rsp_o(axi_demux_out_rsp[Mem]),
    .axi_wide_req_i  (axi_wide_req),
    .axi_wide_rsp_o  (axi_wide_rsp),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp)
  );


endmodule : ucie_tile
