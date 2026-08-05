// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
// Chen Wu <chenwu@iis.ee.ethz.ch>

module ucie_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
(
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              test_enable_i,
  // Router ID
  input  id_t                               id_i,
  input  logic                              ucie_id_i,
  // Sam idx
  input  logic       [$bits(sam_idx_e)-1:0] samidx_i,
  // Router mesh ports
  output floo_req_t  [          West:North] floo_req_o,
  input  floo_rsp_t  [          West:North] floo_rsp_i,
  output floo_wide_t [          West:North] floo_wide_o,
  input  floo_req_t  [          West:North] floo_req_i,
  output floo_rsp_t  [          West:North] floo_rsp_o,
  input  floo_wide_t [          West:North] floo_wide_i,

  // AXI wide ingress (from the other chiplet, towards the mesh)
  input  floo_gwaihir_noc_pkg::axi_wide_in_req_t axi_wide_in_req_i,
  output floo_gwaihir_noc_pkg::axi_wide_in_rsp_t axi_wide_in_rsp_o,
  // Joined AXI egress (mesh towards the other chiplet)
  output gwaihir_pkg::axi_wide_join_req_t        axi_wide_out_req_o,
  input  gwaihir_pkg::axi_wide_join_rsp_t        axi_wide_out_rsp_i
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
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t axi_narrow_out_rsp;
  floo_gwaihir_noc_pkg::axi_wide_out_req_t   axi_wide_out_req;
  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t   axi_wide_out_rsp;

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
    // AXI narrow channels: no narrow ingress for this tile (folded into the
    // joined wide egress below), so tie the chimney's narrow-in off.
    .axi_narrow_in_req_i ('0),
    .axi_narrow_in_rsp_o (),
    .axi_narrow_out_req_o(axi_narrow_out_req),
    .axi_narrow_out_rsp_i(axi_narrow_out_rsp),
    // AXI wide channels
    .axi_wide_in_req_i   (axi_wide_in_req),
    .axi_wide_in_rsp_o   (axi_wide_in_rsp_o),
    .axi_wide_out_req_o  (axi_wide_out_req),
    .axi_wide_out_rsp_i  (axi_wide_out_rsp),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  // Translate ingress addresses to their canonical form
  always_comb begin
    axi_wide_in_req         = axi_wide_in_req_i;
    axi_wide_in_req.aw.addr = unalias_ucie_address(axi_wide_in_req_i.aw.addr, ucie_id_i);
    axi_wide_in_req.ar.addr = unalias_ucie_address(axi_wide_in_req_i.ar.addr, ucie_id_i);
  end

  /////////////////
  // Narrow XBAR //
  /////////////////

  typedef enum logic {
    JOIN     = 1'b0,
    LITE_CFG = 1'b1
  } ucie_xbar_sel_e;

  localparam int unsigned NumUcieXbarMstPorts = 2;

  localparam axi_pkg::xbar_cfg_t AxiNarrowXbarCfg = '{
      NoSlvPorts: 1,
      NoMstPorts: NumUcieXbarMstPorts,
      MaxMstTrans: 4,
      MaxSlvTrans: 4,
      FallThrough: 0,
      // If you have timing issues, change latency to cut ports
      PipelineStages:
      0,
      AxiIdWidthSlvPorts: $bits(axi_narrow_out_id_t),
      AxiIdUsedSlvPorts: $bits(axi_narrow_out_id_t),
      UniqueIds: 0,
      AxiAddrWidth: $bits(axi_narrow_out_addr_t),
      AxiDataWidth: $bits(axi_narrow_out_data_t),
      NoAddrRules: 2,
      default: '0
  };

  typedef struct packed {
    logic [cc_pkg::idx_width(NumUcieXbarMstPorts)-1:0] idx;
    axi_narrow_out_addr_t                              start_addr;
    axi_narrow_out_addr_t                              end_addr;
  } ucie_rule_t;

  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } addr_rule_t;

  // Sam Idx offset between UCIe base and AxiCfg
  localparam int CfgIdxOffset = int'(Ucie0AxiSerialCfgSamIdx) - int'(Ucie0SamIdx);

  ucie_rule_t [1:0] tile_addrmap;
  assign tile_addrmap = '{
          '{
              idx: LITE_CFG,
              start_addr: Sam[int'(samidx_i)+CfgIdxOffset].start_addr,
              end_addr  : Sam[int'(samidx_i)+CfgIdxOffset].end_addr
          },
          '{idx: JOIN, start_addr: Sam[samidx_i].start_addr, end_addr  : Sam[samidx_i].end_addr}
      };

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t [NumUcieXbarMstPorts-1:0] axi_narrow_xbar_out_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t [NumUcieXbarMstPorts-1:0] axi_narrow_xbar_out_rsp;

  axi_xbar #(
    .Cfg          (AxiNarrowXbarCfg),
    .ATOPs        ('0),
    .Connectivity ('1),
    .slv_aw_chan_t(axi_narrow_out_aw_chan_t),
    .mst_aw_chan_t(axi_narrow_out_aw_chan_t),
    .w_chan_t     (axi_narrow_out_w_chan_t),
    .slv_b_chan_t (axi_narrow_out_b_chan_t),
    .mst_b_chan_t (axi_narrow_out_b_chan_t),
    .slv_ar_chan_t(axi_narrow_out_ar_chan_t),
    .mst_ar_chan_t(axi_narrow_out_ar_chan_t),
    .slv_r_chan_t (axi_narrow_out_r_chan_t),
    .mst_r_chan_t (axi_narrow_out_r_chan_t),
    .slv_req_t    (axi_narrow_out_req_t),
    .slv_resp_t   (axi_narrow_out_rsp_t),
    .mst_req_t    (axi_narrow_out_req_t),
    .mst_resp_t   (axi_narrow_out_rsp_t),
    .rule_t       (ucie_rule_t)
  ) i_narrow_xbar (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .slv_ports_req_i      (axi_narrow_out_req),
    .slv_ports_resp_o     (axi_narrow_out_rsp),
    .mst_ports_req_o      (axi_narrow_xbar_out_req),
    .mst_ports_resp_i     (axi_narrow_xbar_out_rsp),
    .addr_map_i           (tile_addrmap),
    .en_default_mst_port_i(1'b0),
    .default_mst_port_i   ('0)
  );

  ///////////////////////
  // Cfg Register Path //
  ///////////////////////

  // narrow AXI (64b) -> AXI-Lite (64b) -> AXI-Lite (32b) -> APB (32b).
  ucie_cfg_axi_lite_req_t     ucie_cfg_axi_lite_req;
  ucie_cfg_axi_lite_resp_t    ucie_cfg_axi_lite_rsp;
  ucie_cfg_axi_lite_32_req_t  ucie_cfg_reg_lite_req;
  ucie_cfg_axi_lite_32_resp_t ucie_cfg_reg_lite_rsp;

  axi_to_axi_lite #(
    .AxiAddrWidth   (AxiCfgN.AddrWidth),
    .AxiDataWidth   (AxiCfgN.DataWidth),
    .AxiIdWidth     (AxiCfgN.OutIdWidth),
    .AxiUserWidth   (AxiCfgN.UserWidth),
    .AxiMaxWriteTxns(floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .AxiMaxReadTxns (floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .full_req_t     (floo_gwaihir_noc_pkg::axi_narrow_out_req_t),
    .full_resp_t    (floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t),
    .lite_req_t     (ucie_cfg_axi_lite_req_t),
    .lite_resp_t    (ucie_cfg_axi_lite_resp_t)
  ) i_axi_to_axi_lite_slink_cfg (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .slv_req_i (axi_narrow_xbar_out_req[LITE_CFG]),
    .slv_resp_o(axi_narrow_xbar_out_rsp[LITE_CFG]),
    .mst_req_o (ucie_cfg_axi_lite_req),
    .mst_resp_i(ucie_cfg_axi_lite_rsp)
  );

  axi_lite_dw_converter #(
    .AxiAddrWidth       (AxiCfgN.AddrWidth),
    .AxiSlvPortDataWidth(AxiCfgN.DataWidth),
    .AxiMstPortDataWidth(UcieCfgRegDataWidth),
    .axi_lite_aw_t      (ucie_cfg_axi_lite_aw_chan_t),
    .axi_lite_slv_w_t   (ucie_cfg_axi_lite_w_chan_t),
    .axi_lite_mst_w_t   (ucie_cfg_axi_lite_32_w_chan_t),
    .axi_lite_b_t       (ucie_cfg_axi_lite_b_chan_t),
    .axi_lite_ar_t      (ucie_cfg_axi_lite_ar_chan_t),
    .axi_lite_slv_r_t   (ucie_cfg_axi_lite_r_chan_t),
    .axi_lite_mst_r_t   (ucie_cfg_axi_lite_32_r_chan_t),
    .axi_lite_slv_req_t (ucie_cfg_axi_lite_req_t),
    .axi_lite_slv_res_t (ucie_cfg_axi_lite_resp_t),
    .axi_lite_mst_req_t (ucie_cfg_axi_lite_32_req_t),
    .axi_lite_mst_res_t (ucie_cfg_axi_lite_32_resp_t)
  ) i_axi_lite_dw_converter_slink_cfg (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .slv_req_i(ucie_cfg_axi_lite_req),
    .slv_res_o(ucie_cfg_axi_lite_rsp),
    .mst_req_o(ucie_cfg_reg_lite_req),
    .mst_res_i(ucie_cfg_reg_lite_rsp)
  );

  // The narrow xbar already isolated this port to the "axi_serial_cfg" SAM
  // range, so everything reaching here is in range: a single wildcard rule.
  localparam int unsigned NumSlinkCfgApbRules = 1;
  addr_rule_t [NumSlinkCfgApbRules-1:0] SlinkCfgApbAddrMap = '{
      '{idx: 0, start_addr: '0, end_addr: '1}
  };

  // TODO (lleone): Temporary code before connecting an actual APB subordinate.
  localparam ucie_cfg_reg_data_t StubApbRdata = ucie_cfg_reg_data_t'(32'hFEEDFACE);

  ucie_cfg_apb_req_t  ucie_cfg_apb_req;
  ucie_cfg_apb_resp_t ucie_cfg_apb_rsp;
  assign ucie_cfg_apb_rsp = '{pready: 1'b1, prdata: StubApbRdata, pslverr: 1'b0};

  axi_lite_to_apb #(
    .NoApbSlaves    (1),
    .NoRules        (NumSlinkCfgApbRules),
    .AddrWidth      (AxiCfgN.AddrWidth),
    .DataWidth      (UcieCfgRegDataWidth),
    .axi_lite_req_t (ucie_cfg_axi_lite_32_req_t),
    .axi_lite_resp_t(ucie_cfg_axi_lite_32_resp_t),
    .apb_req_t      (ucie_cfg_apb_req_t),
    .apb_resp_t     (ucie_cfg_apb_resp_t),
    .rule_t         (addr_rule_t)
  ) i_axi_lite_to_apb_slink_cfg (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .axi_lite_req_i (ucie_cfg_reg_lite_req),
    .axi_lite_resp_o(ucie_cfg_reg_lite_rsp),
    .apb_req_o      (ucie_cfg_apb_req),
    .apb_resp_i     (ucie_cfg_apb_rsp),
    .addr_map_i     (SlinkCfgApbAddrMap)
  );

  //////////////////
  // NW Join Path //
  /////////////////

  floo_nw_join #(
    .AxiCfgN         (axi_cfg_swap_iw(AxiCfgN)),
    .AxiCfgW         (axi_cfg_swap_iw(AxiCfgW)),
    .AxiCfgJoin      (axi_cfg_swap_iw(AxiCfgNwJoin)),
    .EnAtopAdapter   (1'b0),
    .AtopUserAsId    (1'b1),
    .axi_narrow_req_t(axi_narrow_out_req_t),
    .axi_narrow_rsp_t(axi_narrow_out_rsp_t),
    .axi_wide_req_t  (axi_wide_out_req_t),
    .axi_wide_rsp_t  (axi_wide_out_rsp_t),
    .axi_req_t       (gwaihir_pkg::axi_wide_join_req_t),
    .axi_rsp_t       (gwaihir_pkg::axi_wide_join_rsp_t)
  ) i_floo_nw_join (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .test_enable_i   (test_enable_i),
    .axi_narrow_req_i(axi_narrow_xbar_out_req[JOIN]),
    .axi_narrow_rsp_o(axi_narrow_xbar_out_rsp[JOIN]),
    .axi_wide_req_i  (axi_wide_out_req),
    .axi_wide_rsp_o  (axi_wide_out_rsp),
    .axi_req_o       (axi_wide_out_req_o),
    .axi_rsp_i       (axi_wide_out_rsp_i)
  );

endmodule : ucie_tile
