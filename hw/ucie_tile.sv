// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
// Chen Wu <chenwu@iis.ee.ethz.ch>

`include "axi/assign.svh"
`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"
`include "axi/typedef.svh"

module ucie_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
  import ucie_slink_reg_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic clk_rst_bypass_i,
  input logic test_enable_i,

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

  // Half-bandwidth mode for debug output channels
  localparam int unsigned UcieHalfPhyWidth = NumBitsPerCycle / 2;

  // Tile-specific reset and clock signals
  logic tile_clk;
  logic tile_rst_n;
  logic tile_rst_apb_n;

  ////////////
  // Router //
  ////////////

  // Router interfaces
  floo_req_t [Eject:North] router_floo_req_out, router_floo_req_in;
  floo_rsp_t [Eject:North] router_floo_rsp_out, router_floo_rsp_in;
  floo_wide_t [Eject:North] router_floo_wide_in;
  floo_wide_t [Eject:North] router_floo_wide_out;

  // NW Join AXI interface
  gwaihir_pkg::axi_utile_nw_join_req_t axi_utile_nw_join_out_req;
  gwaihir_pkg::axi_utile_nw_join_rsp_t axi_utile_nw_join_out_rsp;
  gwaihir_pkg::axi_utile_nw_join_req_t axi_utile_nw_join_in_req;
  gwaihir_pkg::axi_utile_nw_join_rsp_t axi_utile_nw_join_in_rsp;

  // SLink configuration registers.
  ucie_slink_reg_pkg::slink_reg__in_t  slink_hw2reg;
  ucie_slink_reg_pkg::slink_reg__out_t slink_reg2hw;

  // Clock/rst configuration registers.
  gw_ucie_tile_regs_pkg::gw_ucie_tile_regs__out_t hwif_out;

  // The tile AXI domain (tile_clk, tile_rst_n) is clocked and out of reset.
  // While it is off, accesses to it are answered with an error.
  logic tile_axi_avail;
  assign tile_axi_avail = clk_rst_bypass_i | (hwif_out.clk.en.value & hwif_out.rst_axi.n.value);

  // Slink interface
  logic [NumChannels-1:0][NumBitsPerCycle-1:0] slink_phy_data_out;
  logic [NumChannels-1:0]                      slink_phy_data_out_valid;
  logic [NumChannels-1:0]                      slink_phy_data_out_ready;
  logic [NumChannels-1:0][NumBitsPerCycle-1:0] slink_phy_data_in;
  logic [NumChannels-1:0]                      slink_phy_data_in_valid;
  logic [NumChannels-1:0]                      slink_phy_data_in_ready;

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
    .VcImpl        (VcImpl),
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
    // Wide Reduction offload port
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    // Narrow Reduction offload port
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  assign floo_req_o                      = router_floo_req_out[West:North];
  assign router_floo_req_in[West:North]  = floo_req_i;
  assign floo_rsp_o                      = router_floo_rsp_out[West:North];
  assign router_floo_rsp_in[West:North]  = floo_rsp_i;
  assign floo_wide_o                     = router_floo_wide_out[West:North];
  assign router_floo_wide_in[West:North] = floo_wide_i;

  /////////////
  // Chimney //
  /////////////

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_chim_out_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t axi_narrow_chim_out_rsp;
  floo_gwaihir_noc_pkg::axi_narrow_out_req_t axi_narrow_out_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t axi_narrow_out_rsp;
  floo_gwaihir_noc_pkg::axi_wide_in_req_t    axi_wide_in_req;
  floo_gwaihir_noc_pkg::axi_wide_in_rsp_t    axi_wide_in_rsp;
  floo_gwaihir_noc_pkg::axi_wide_out_req_t   axi_wide_chim_out_req;
  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t   axi_wide_chim_out_rsp;
  floo_gwaihir_noc_pkg::axi_wide_out_req_t   axi_wide_out_req;
  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t   axi_wide_out_rsp;

  // From IW Converter to chimney
  floo_gwaihir_noc_pkg::axi_wide_in_req_t axi_wide_req_iw_conv;
  floo_gwaihir_noc_pkg::axi_wide_in_rsp_t axi_wide_rsp_iw_conv;

  floo_nw_chimney #(
    .AxiCfgN             (floo_gwaihir_noc_pkg::AxiCfgN),
    .AxiCfgW             (floo_gwaihir_noc_pkg::AxiCfgW),
    .ChimneyCfgN         (floo_pkg::ChimneyDefaultCfg),
    .ChimneyCfgW         (floo_pkg::ChimneyDefaultCfg),
    .RouteCfg            (RouteCfgNoMcast),
    .AtopSupport         (1'b1),
    .collect_op_t        (floo_gwaihir_noc_pkg::collect_op_t),
    .WideRwDecouple      (floo_gwaihir_noc_pkg::WideRwDecouple),
    .VcImpl              (VcImpl),
    // ATOPs are rejected by the filter below, they are never executed here
    .MaxAtomicTxns       (1),
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
    // AXI Narrow channels: no narrow ingress for this tile
    .axi_narrow_in_req_i ('0),
    .axi_narrow_in_rsp_o (),
    .axi_narrow_out_req_o(axi_narrow_chim_out_req),
    .axi_narrow_out_rsp_i(axi_narrow_chim_out_rsp),
    // AXI wide channels:
    // - Ingress: from the other chiplet (serializer)
    // - Egress: towards the other chiplet (nw join -> serializer)
    .axi_wide_in_req_i   (axi_wide_in_req),
    .axi_wide_in_rsp_o   (axi_wide_rsp_iw_conv),
    .axi_wide_out_req_o  (axi_wide_chim_out_req),
    .axi_wide_out_rsp_i  (axi_wide_chim_out_rsp),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  // Neither the cfg registers nor the UCIe link support ATOPs: reject them with
  // an error right at the chimney, so nothing downstream ever sees one
  axi_atop_filter #(
    .AxiIdWidth     ($bits(axi_narrow_out_id_t)),
    .AxiMaxWriteTxns(4),                           // MaxSlvTrans of the narrow xbar
    .axi_req_t      (axi_narrow_out_req_t),
    .axi_resp_t     (axi_narrow_out_rsp_t)
  ) i_chim_narrow_atop_filter (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .slv_req_i (axi_narrow_chim_out_req),
    .slv_resp_o(axi_narrow_chim_out_rsp),
    .mst_req_o (axi_narrow_out_req),
    .mst_resp_i(axi_narrow_out_rsp)
  );

  // Translate ingress addresses to their canonical form
  // The serial link carries the join type (AxiCfgUcieJoin), not the chimney types:
  // - user: 1 bit. On egress the narrow user (6 bits) is cut to bit 0 before the
  //   join; the wide user is 1 bit. The chimney ignores it, as collectives are
  //   off (RouteCfgNoMcast); enabling them over UCIe needs a real transport.
  // - id: narrow 2 -> 1 bit (iw converter), plus 1 bit added by the join to
  //   select narrow or wide; converted back to the chimney wide-in width below.
  always_comb begin
    axi_wide_in_req         = axi_wide_req_iw_conv;
    axi_wide_in_req.aw.addr = unalias_ucie_address(axi_wide_req_iw_conv.aw.addr, ucie_id_i);
    axi_wide_in_req.ar.addr = unalias_ucie_address(axi_wide_req_iw_conv.ar.addr, ucie_id_i);
  end

  // ID Converter from Slink to Chimney
  axi_iw_converter #(
    .AxiSlvPortIdWidth(AxiCfgUcieJoin.OutIdWidth),  // Chimney Output ID
    .AxiMstPortIdWidth(AxiCfgW.InIdWidth),  // ID of the chimney's input port
    .AxiSlvPortMaxUniqIds(2 ** AxiCfgUcieJoin.OutIdWidth),  // Max num of IDs
    .AxiSlvPortMaxTxnsPerId(32),  // TODO: Probably overkilling, reduce if you have area issue
    .AxiSlvPortMaxTxns(32),
    .AxiMstPortMaxUniqIds(2 ** AxiCfgW.InIdWidth),
    .AxiMstPortMaxTxnsPerId(32),
    .AxiAddrWidth(AxiCfgW.AddrWidth),
    .AxiDataWidth(AxiCfgW.DataWidth),
    .AxiUserWidth(AxiCfgW.UserWidth),  // Convert after ID
    .slv_req_t(gwaihir_pkg::axi_utile_nw_join_req_t),
    .slv_resp_t(gwaihir_pkg::axi_utile_nw_join_rsp_t),
    .mst_req_t(axi_wide_in_req_t),
    .mst_resp_t(axi_wide_in_rsp_t)
  ) i_slink2chim_wide_iw_converter (
    .clk_i     (tile_clk),
    .rst_ni    (tile_rst_n),
    .slv_req_i (axi_utile_nw_join_in_req),
    .slv_resp_o(axi_utile_nw_join_in_rsp),
    .mst_req_o (axi_wide_req_iw_conv),
    .mst_resp_i(axi_wide_rsp_iw_conv)
  );

  /////////////////
  // Narrow XBAR //
  /////////////////

  typedef enum logic [1:0] {
    JOIN     = 2'd0,
    LITE_CFG = 2'd1,
    ERR      = 2'd2
  } ucie_xbar_sel_e;

  localparam int unsigned NumUcieXbarMstPorts = 3;
  // Tile cfg, serial link cfg and UCIe PCS cfg (LITE_CFG), plus the join path
  localparam int unsigned NumUcieXbarRules = 4;

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
      NoAddrRules: NumUcieXbarRules,
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
  localparam int AxiSerialCfgIdxOffset = int'(Ucie0AxiSerialCfgSamIdx) - int'(Ucie0SamIdx);
  // Sam Idx offset between UCIe base and the UCIe PCS macro APB (ucie_cfg).
  // NOTE: name generated by floogen from the "ucie_cfg" range; adjust if regen
  // emits a different symbol.
  localparam int UcieCfgIdxOffset = int'(Ucie0UcieCfgSamIdx) - int'(Ucie0SamIdx);
  localparam int TileCfgIdxOffset = int'(Ucie0TileCfgSamIdx) - int'(Ucie0SamIdx);

  ucie_rule_t [NumUcieXbarRules-1:0] tile_addrmap;
  // 3 rules: the AXI-Lite config port serves both the Tile cfg regs (tile_cfg),
  // the Slink registers (axi_serial_cfg) and the UCIe PCS macro APB (ucie_cfg)
  // -> all routed to LITE_CFG and demuxed downstream by axi_lite_to_apb; plus the join path.
  assign tile_addrmap = '{
          '{
              idx: LITE_CFG,
              start_addr: Sam[int'(samidx_i)+TileCfgIdxOffset].start_addr,
              end_addr  : Sam[int'(samidx_i)+TileCfgIdxOffset].end_addr
          },
          '{
              idx: LITE_CFG,
              start_addr: Sam[int'(samidx_i)+AxiSerialCfgIdxOffset].start_addr,
              end_addr  : Sam[int'(samidx_i)+AxiSerialCfgIdxOffset].end_addr
          },
          '{
              idx: LITE_CFG,
              start_addr: Sam[int'(samidx_i)+UcieCfgIdxOffset].start_addr,
              end_addr  : Sam[int'(samidx_i)+UcieCfgIdxOffset].end_addr
          },
          // The join path is in the tile AXI domain: error while it is off
          '{
              idx: tile_axi_avail ? JOIN : ERR,
              start_addr: Sam[samidx_i].start_addr,
              end_addr  : Sam[samidx_i].end_addr
          }
      };

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t [NumUcieXbarMstPorts-1:0] axi_narrow_xbar_out_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t [NumUcieXbarMstPorts-1:0] axi_narrow_xbar_out_rsp;

  axi_xbar #(
    .Cfg          (AxiNarrowXbarCfg),
    .ATOPs        ('0),                        // filtered at the chimney
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

  // Narrow accesses to the join path while the tile AXI domain is off
  axi_err_slv #(
    .AxiIdWidth($bits(axi_narrow_out_id_t)),
    .axi_req_t (axi_narrow_out_req_t),
    .axi_resp_t(axi_narrow_out_rsp_t),
    .Resp      (axi_pkg::RESP_SLVERR),
    .RespData  ('0),
    .ATOPs     (1'b0),
    .MaxTrans  (1)
  ) i_narrow_err_slv (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .slv_req_i (axi_narrow_xbar_out_req[ERR]),
    .slv_resp_o(axi_narrow_xbar_out_rsp[ERR])
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

  // Three APB slaves on the tile config port:
  // 1. the clk/rst enable registers (tile_cfg SAM range)
  // 2. the Slink registers (axi_serial_cfg SAM range)
  // 3. the UCIe PCS macro APB (ucie_cfg SAM range).
  // These ranges reach the LITE_CFG xbar port; split here by address.
  localparam int unsigned NumCfgApbSlaves = 3;

  typedef enum logic [1:0] {
    ApbSlink = 0,
    ApbTile  = 1,
    ApbUcie  = 2
  } ucie_apb_sel_e;

  addr_rule_t [NumCfgApbSlaves-1:0] CfgApbAddrMap;
  always_comb begin
    CfgApbAddrMap[ApbSlink] = '{
        idx       : ApbSlink,
        start_addr: Sam[int'(samidx_i)+AxiSerialCfgIdxOffset].start_addr,
        end_addr  : Sam[int'(samidx_i)+AxiSerialCfgIdxOffset].end_addr
    };
    CfgApbAddrMap[ApbTile] = '{
        idx       : ApbTile,
        start_addr: Sam[int'(samidx_i)+TileCfgIdxOffset].start_addr,
        end_addr  : Sam[int'(samidx_i)+TileCfgIdxOffset].end_addr
    };
    CfgApbAddrMap[ApbUcie] = '{
        idx       : ApbUcie,
        start_addr: Sam[int'(samidx_i)+UcieCfgIdxOffset].start_addr,
        end_addr  : Sam[int'(samidx_i)+UcieCfgIdxOffset].end_addr
    };
  end

  ucie_cfg_apb_req_t  [NumCfgApbSlaves-1:0] cfg_apb_req;
  ucie_cfg_apb_resp_t [NumCfgApbSlaves-1:0] cfg_apb_rsp;

  axi_lite_to_apb #(
    .NoApbSlaves    (NumCfgApbSlaves),
    .NoRules        (NumCfgApbSlaves),
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
    .apb_req_o      (cfg_apb_req),
    .apb_resp_i     (cfg_apb_rsp),
    .addr_map_i     (CfgApbAddrMap)
  );

  // Clk/Rst Enable Registers.
  gw_ucie_tile_regs i_gw_ucie_tile_regs (
    .clk(clk_i),
    .arst_n(rst_ni),
    .s_apb_paddr  (cfg_apb_req[ApbTile].paddr[
      gw_ucie_tile_regs_pkg::GW_UCIE_TILE_REGS_MIN_ADDR_WIDTH-1:0]),
    .s_apb_penable(cfg_apb_req[ApbTile].penable),
    .s_apb_psel(cfg_apb_req[ApbTile].psel),
    .s_apb_pwrite(cfg_apb_req[ApbTile].pwrite),
    .s_apb_pprot(cfg_apb_req[ApbTile].pprot),
    .s_apb_pwdata(cfg_apb_req[ApbTile].pwdata),
    .s_apb_pstrb(cfg_apb_req[ApbTile].pstrb),
    .s_apb_prdata(cfg_apb_rsp[ApbTile].prdata),
    .s_apb_pready(cfg_apb_rsp[ApbTile].pready),
    .s_apb_pslverr(cfg_apb_rsp[ApbTile].pslverr),
    .hwif_out(hwif_out)
  );

  // An access to a domain that is off is answered with an error.
  logic slink_apb_avail, ucie_apb_avail;
  assign slink_apb_avail = tile_axi_avail;
  assign ucie_apb_avail  = clk_rst_bypass_i | (hwif_out.clk.en.value & hwif_out.rst_apb.n.value);

  logic slink_apb_pready, slink_apb_pslverr;
  ucie_cfg_reg_data_t slink_apb_prdata;

  assign cfg_apb_rsp[ApbSlink].pready  = slink_apb_avail ? slink_apb_pready :
                                                           cfg_apb_req[ApbSlink].penable;
  assign cfg_apb_rsp[ApbSlink].prdata = slink_apb_avail ? slink_apb_prdata : '0;
  assign cfg_apb_rsp[ApbSlink].pslverr = slink_apb_avail ? slink_apb_pslverr : 1'b1;

  // SLink configuration registers.
  ucie_slink_reg i_serial_link_reg (
    .clk          (tile_clk),
    .arst_n       (tile_rst_n),
    .s_apb_psel   (cfg_apb_req[ApbSlink].psel & slink_apb_avail),
    .s_apb_penable(cfg_apb_req[ApbSlink].penable),
    .s_apb_pwrite (cfg_apb_req[ApbSlink].pwrite),
    .s_apb_pprot  (cfg_apb_req[ApbSlink].pprot),
    // paddr is the full 48-bit address: the low bits are the offset, as the
    // window is aligned to 4 KiB (it aliases every 256 B within it)
    .s_apb_paddr  (cfg_apb_req[ApbSlink].paddr[UCIE_SLINK_REG_MIN_ADDR_WIDTH-1:0]),
    .s_apb_pwdata (cfg_apb_req[ApbSlink].pwdata),
    .s_apb_pstrb  (cfg_apb_req[ApbSlink].pstrb),
    .s_apb_pready (slink_apb_pready),
    .s_apb_prdata (slink_apb_prdata),
    .s_apb_pslverr(slink_apb_pslverr),
    .hwif_in      (slink_hw2reg),
    .hwif_out     (slink_reg2hw)
  );

  //////////////////////////
  // Clock Gating & Reset //
  //////////////////////////

  tc_clk_gating i_tc_clk_gating_ucie (
    .clk_i,
    .en_i     (hwif_out.clk.en.value),
    .test_en_i(clk_rst_bypass_i),
    .clk_o    (tile_clk)
  );

`ifdef TARGET_XILINX
  // Using clk cells makes Vivado flag the reset as a clock tree
  assign tile_rst_n     = (clk_rst_bypass_i) ? rst_ni : tile_rst_ni;
  assign tile_rst_apb_n = (clk_rst_bypass_i) ? rst_ni : tile_rst_ni;
`else
  tc_clk_mux2 i_tc_reset_axi_mux (
    .clk0_i   (hwif_out.rst_axi.n.value),
    .clk1_i   (rst_ni),
    .clk_sel_i(clk_rst_bypass_i),
    .clk_o    (tile_rst_n)
  );

  tc_clk_mux2 i_tc_reset_apb_mux (
    .clk0_i   (hwif_out.rst_apb.n.value),
    .clk1_i   (rst_ni),
    .clk_sel_i(clk_rst_bypass_i),
    .clk_o    (tile_rst_apb_n)
  );
`endif

  //////////////////
  // NW Join Path //
  /////////////////

  // Narrow axi with 1 ID bit and no user field
  typedef logic no_outstanding_id_t;
  typedef logic no_atop_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_narrow_iw_out, axi_narrow_iw_out_req_t, axi_narrow_iw_out_rsp_t,
                      axi_narrow_out_addr_t, no_outstanding_id_t, axi_narrow_out_data_t,
                      axi_narrow_out_strb_t, axi_narrow_out_user_t)

  `AXI_TYPEDEF_ALL_CT(axi_narrow_noatop_out, axi_narrow_noatop_out_req_t,
                      axi_narrow_noatop_out_rsp_t, axi_narrow_out_addr_t, no_outstanding_id_t,
                      axi_narrow_out_data_t, axi_narrow_out_strb_t, no_atop_user_t)

  axi_narrow_iw_out_req_t axi_narrow_iw_out_req;
  axi_narrow_iw_out_rsp_t axi_narrow_iw_out_rsp;

  axi_narrow_noatop_out_req_t axi_narrow_noatop_out_req;
  axi_narrow_noatop_out_rsp_t axi_narrow_noatop_out_rsp;

  // Convert incoming narrow ID to 1 bit to avoid serialization deadlock in SLink
  axi_iw_converter #(
    .AxiSlvPortIdWidth     (AxiCfgN.OutIdWidth),               // Chimney Output ID
    .AxiMstPortIdWidth     ($bits(no_outstanding_id_t)),       // ID of the chimney's input port
    .AxiSlvPortMaxUniqIds  (2 ** AxiCfgN.OutIdWidth),          // Max num of IDs
    .AxiSlvPortMaxTxnsPerId(32),
    .AxiSlvPortMaxTxns     (32),
    .AxiMstPortMaxUniqIds  (2 ** $bits(no_outstanding_id_t)),
    .AxiMstPortMaxTxnsPerId(32),
    .AxiAddrWidth          (AxiCfgN.AddrWidth),
    .AxiDataWidth          (AxiCfgN.DataWidth),
    .AxiUserWidth          (AxiCfgN.UserWidth),                // Convert after ID
    .slv_req_t             (axi_narrow_out_req_t),
    .slv_resp_t            (axi_narrow_out_rsp_t),
    .mst_req_t             (axi_narrow_iw_out_req_t),
    .mst_resp_t            (axi_narrow_iw_out_rsp_t)
  ) i_chim2nw_narrow_iw_converter (
    .clk_i     (tile_clk),
    .rst_ni    (tile_rst_n),
    .slv_req_i (axi_narrow_xbar_out_req[JOIN]),
    .slv_resp_o(axi_narrow_xbar_out_rsp[JOIN]),
    .mst_req_o (axi_narrow_iw_out_req),
    .mst_resp_i(axi_narrow_iw_out_rsp)
  );

  // Strip the user field from the narrow AXI (ATOPs were filtered at the chimney)
  // Reuse the AXI STRUCT ASSIGN macro. Since the dst user is a logic,
  // the struct assign will truncate the field.
  `AXI_ASSIGN_REQ_STRUCT(axi_narrow_noatop_out_req, axi_narrow_iw_out_req)
  `AXI_ASSIGN_RESP_STRUCT(axi_narrow_iw_out_rsp, axi_narrow_noatop_out_rsp)

  // Wide egress: to the join, or to an error slave while the tile AXI domain is
  // off. The demux keeps the transactions of one ID on the same port.
  floo_gwaihir_noc_pkg::axi_wide_out_req_t [1:0] axi_wide_out_demux_req;
  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t [1:0] axi_wide_out_demux_rsp;

  axi_demux_simple #(
    .AxiIdWidth (AxiCfgW.OutIdWidth),
    .AtopSupport(1'b0),
    .axi_req_t  (axi_wide_out_req_t),
    .axi_resp_t (axi_wide_out_rsp_t),
    .NoMstPorts (2),
    .MaxTrans   (floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .AxiLookBits(AxiCfgW.OutIdWidth),
    .UniqueIds  (1'b0)
  ) i_wide_out_demux (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .slv_req_i      (axi_wide_chim_out_req),
    .slv_aw_select_i(~tile_axi_avail),
    .slv_ar_select_i(~tile_axi_avail),
    .slv_resp_o     (axi_wide_chim_out_rsp),
    .mst_reqs_o     (axi_wide_out_demux_req),
    .mst_resps_i    (axi_wide_out_demux_rsp)
  );

  assign axi_wide_out_req          = axi_wide_out_demux_req[0];
  assign axi_wide_out_demux_rsp[0] = axi_wide_out_rsp;

  axi_err_slv #(
    .AxiIdWidth(AxiCfgW.OutIdWidth),
    .axi_req_t (axi_wide_out_req_t),
    .axi_resp_t(axi_wide_out_rsp_t),
    .Resp      (axi_pkg::RESP_SLVERR),
    .RespData  ('0),
    .ATOPs     (1'b0),
    .MaxTrans  (1)
  ) i_wide_err_slv (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .slv_req_i (axi_wide_out_demux_req[1]),
    .slv_resp_o(axi_wide_out_demux_rsp[1])
  );

  floo_nw_join #(
    .AxiCfgN         (axi_cfg_swap_iw(AxiCfgNoAtop)),
    .AxiCfgW         (axi_cfg_swap_iw(AxiCfgW)),
    .AxiCfgJoin      (axi_cfg_swap_iw(AxiCfgUcieJoin)),
    .EnAtopAdapter   (1'b0),
    .AtopUserAsId    (1'b1),
    .axi_narrow_req_t(axi_narrow_noatop_out_req_t),
    .axi_narrow_rsp_t(axi_narrow_noatop_out_rsp_t),
    .axi_wide_req_t  (axi_wide_out_req_t),
    .axi_wide_rsp_t  (axi_wide_out_rsp_t),
    .axi_req_t       (gwaihir_pkg::axi_utile_nw_join_req_t),
    .axi_rsp_t       (gwaihir_pkg::axi_utile_nw_join_rsp_t)
  ) i_floo_nw_join (
    .clk_i           (tile_clk),
    .rst_ni          (tile_rst_n),
    .test_enable_i   (test_enable_i),
    .axi_narrow_req_i(axi_narrow_noatop_out_req),
    .axi_narrow_rsp_o(axi_narrow_noatop_out_rsp),
    .axi_wide_req_i  (axi_wide_out_req),
    .axi_wide_rsp_o  (axi_wide_out_rsp),
    .axi_req_o       (axi_utile_nw_join_out_req),
    .axi_rsp_i       (axi_utile_nw_join_out_rsp)
  );

  //////////////////
  // AXI Streamer //
  /////////////////

  // Serializer PHY backend: the stream between the bandwidth-mode adapter and
  // the UCIe adapter below, in front of the macro (`ucie_macro_wrap`).
  logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_out_data;
  logic [NumChannels-1:0]                      phy_out_valid;
  logic [NumChannels-1:0]                      phy_out_ready;
  logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_in_data;
  logic [NumChannels-1:0]                      phy_in_valid;
  logic [NumChannels-1:0]                      phy_in_ready;

  // TODO (lleone): Check all the parameters
  slink_serializer #(
    .NumCredits            (8),
    .NumChannels           (NumChannels),
    .NumLanes              (NumLanes),
    .EnDdr                 (EnDdr),
    .Log2MaxClkDiv         (Log2MaxClkDiv),
    .Log2RawModeTXFifoDepth(Log2RawModeTXFifoDepth),
    .EnChAlloc             (EnChAlloc),
    .axi_req_t             (gwaihir_pkg::axi_utile_nw_join_req_t),
    .axi_rsp_t             (gwaihir_pkg::axi_utile_nw_join_rsp_t),
    .aw_chan_t             (gwaihir_pkg::axi_utile_nw_join_aw_chan_t),
    .ar_chan_t             (gwaihir_pkg::axi_utile_nw_join_ar_chan_t),
    .r_chan_t              (gwaihir_pkg::axi_utile_nw_join_r_chan_t),
    .w_chan_t              (gwaihir_pkg::axi_utile_nw_join_w_chan_t),
    .b_chan_t              (gwaihir_pkg::axi_utile_nw_join_b_chan_t),
    .hwif_in_t             (ucie_slink_reg_pkg::slink_reg__in_t),
    .hwif_out_t            (ucie_slink_reg_pkg::slink_reg__out_t)
  ) i_ucie_slink_serializer (
    .clk_i                   (tile_clk),
    .rst_ni                  (tile_rst_n),
    .clk_sl_i                (tile_clk),
    .rst_sl_ni               (tile_rst_n),
    .axi_in_req_i            (axi_utile_nw_join_out_req),
    .axi_in_rsp_o            (axi_utile_nw_join_out_rsp),
    .axi_out_req_o           (axi_utile_nw_join_in_req),
    .axi_out_rsp_i           (axi_utile_nw_join_in_rsp),
    .hwif_out_i              (slink_reg2hw),
    .hwif_in_o               (slink_hw2reg),
    // PHY backend
    .phy_data_out_o          (slink_phy_data_out),
    .phy_data_out_valid_o    (slink_phy_data_out_valid),
    .phy_data_out_ready_i    (slink_phy_data_out_ready),
    .phy_data_in_i           (slink_phy_data_in),
    .phy_data_in_valid_i     (slink_phy_data_in_valid),
    .phy_data_in_ready_o     (slink_phy_data_in_ready),
    // Unused
    .tx_phy_clk_div_o        (  /* Unconnect */),
    .tx_phy_clk_shift_start_o(  /* Unconnect */),
    .tx_phy_clk_shift_end_o  (  /* Unconnect */),
    .isolated_i              ('0),
    .isolate_o               (  /* Unconnect */),
    .clk_ena_o               (  /* Unconnect */),
    .reset_no                (  /* Unconnect */)
  );

  ////////////////////////////////////
  // PHY bandwidth-mode mux/adapter //
  ///////////////////////////////////

  for (genvar ch = 0; ch < NumChannels; ch++) begin : gen_phy_bw_adapt
    logic [UcieHalfPhyWidth-1:0] tx_half_data;
    logic tx_half_valid, tx_half_ready;

    cc_stream_downsizer #(
      .NarrowWidth(UcieHalfPhyWidth),
      .WideWidth  (NumBitsPerCycle)
    ) i_phy_tx_downsizer (
      .clk_i      (tile_clk),
      .rst_ni     (tile_rst_n),
      .inp_data_i (slink_phy_data_out[ch]),
      .inp_valid_i(slink_phy_data_out_valid[ch] && hwif_out.phy_mode.half_bw_en.value),
      .inp_ready_o(tx_half_ready),
      .oup_data_o (tx_half_data),
      .oup_valid_o(tx_half_valid),
      .oup_ready_i(phy_out_ready[ch] && hwif_out.phy_mode.half_bw_en.value)
    );

    assign slink_phy_data_out_ready[ch] =
        hwif_out.phy_mode.half_bw_en.value ? tx_half_ready : phy_out_ready[ch];
    assign phy_out_valid[ch] =
        hwif_out.phy_mode.half_bw_en.value ? tx_half_valid : slink_phy_data_out_valid[ch];
    assign phy_out_data[ch] =
        hwif_out.phy_mode.half_bw_en.value ? {2{tx_half_data}} : slink_phy_data_out[ch];

    logic [NumBitsPerCycle-1:0] rx_full_data;
    logic rx_full_valid, rx_full_ready;

    cc_stream_upsizer #(
      .NarrowWidth(UcieHalfPhyWidth),
      .WideWidth  (NumBitsPerCycle)
    ) i_phy_rx_upsizer (
      .clk_i      (tile_clk),
      .rst_ni     (tile_rst_n),
      .inp_data_i (phy_in_data[ch][UcieHalfPhyWidth-1:0]),
      .inp_valid_i(phy_in_valid[ch] && hwif_out.phy_mode.half_bw_en.value),
      .inp_ready_o(rx_full_ready),
      .oup_data_o (rx_full_data),
      .oup_valid_o(rx_full_valid),
      .oup_ready_i(slink_phy_data_in_ready[ch] && hwif_out.phy_mode.half_bw_en.value)
    );

    assign phy_in_ready[ch] =
        hwif_out.phy_mode.half_bw_en.value ? rx_full_ready : slink_phy_data_in_ready[ch];
    assign slink_phy_data_in_valid[ch] =
        hwif_out.phy_mode.half_bw_en.value ? rx_full_valid : phy_in_valid[ch];
    assign slink_phy_data_in[ch] =
        hwif_out.phy_mode.half_bw_en.value ? rx_full_data : phy_in_data[ch];
  end

  //////////////////
  // UCIe adapter //
  //////////////////

  // RDI adapter between the serializer stream and the UCIe macro
  // (`ucie_macro_wrap`): stream <-> RDI. The stream is as wide as the RDI.
  logic        link_rx_drop_err;
  logic [15:0] link_rx_drop_count;

  localparam int unsigned RdiDataWidth = 256;  // RDI mainband width of the macro
  localparam int unsigned StreamWidth = NumChannels * NumBitsPerCycle;
  // The macro's APB space spans 0x0_0000-0x2_7FFF (18 bit); the SAM base is masked off
  localparam int unsigned UcieApbAddrWidth = 18;
  // Register every RDI pin of the macro in the adapters
  localparam bit CutRdi = 1'b1;

  logic [RdiDataWidth-1:0] lp_data, pl_data;
  logic lp_valid, lp_irdy, pl_trdy, pl_valid;
  // RDI state reported by the macro. The link itself is brought up and managed
  // by the PCS through its registers (APB).
  rdi_state_e pl_state_sts;
  logic       link_active;
  logic       link_en;

  // Link gate: the serial link's `ctrl.clk_ena` (0 at reset). Software opens it
  // once the PCS is configured; while closed the serial link sees no traffic.
  assign link_en = slink_reg2hw.ctrl.clk_ena.value;

  // Move data only while the link is ACTIVE. With `CutRdi` the state is
  // registered like the RDI data, so it stays aligned with the registered RX
  // words and gates TX from a flop.
  rdi_state_e pl_state;

  if (CutRdi) begin : gen_cut_rdi_state
    `FF(pl_state, pl_state_sts, RdiReset, tile_clk, tile_rst_n)
  end else begin : gen_no_cut_rdi_state
    assign pl_state = pl_state_sts;
  end

  assign link_active = (pl_state == RdiActive);

  // TX: serializer stream -> RDI
  logic tx_rdi_ready;

  assign phy_out_ready = {NumChannels{tx_rdi_ready & link_en}};

  stream2rdi #(
    .DataWidth(RdiDataWidth),
    .CutRdi   (CutRdi)
  ) i_stream2rdi (
    .clk_i        (tile_clk),
    .rst_ni       (tile_rst_n),
    .inp_data_i   (phy_out_data),
    .inp_valid_i  (phy_out_valid[0] & link_en),
    .inp_ready_o  (tx_rdi_ready),
    .lp_data_o    (lp_data),
    .lp_valid_o   (lp_valid),
    .lp_irdy_o    (lp_irdy),
    .pl_trdy_i    (pl_trdy),
    .link_active_i(link_active)
  );

  // RX: RDI -> serializer stream. RDI RX has no backpressure: `rdi2stream`
  // holds one word, the serial link's credit-based flow control keeps its
  // input ready in normal mode.
  logic rx_valid;

  // Drain (and drop) received data while the link gate is closed
  logic rx_oup_ready;
  assign rx_oup_ready = link_en ? phy_in_ready[0] : 1'b1;

  rdi2stream #(
    .DataWidth(RdiDataWidth),
    .CutRdi   (CutRdi)
  ) i_rdi2stream (
    .clk_i          (tile_clk),
    .rst_ni         (tile_rst_n),
    .pl_data_i      (pl_data),
    .pl_valid_i     (pl_valid),
    .oup_data_o     (phy_in_data),
    .oup_valid_o    (rx_valid),
    .oup_ready_i    (rx_oup_ready),
    .link_active_i  (link_active),
    .rx_drop_err_o  (link_rx_drop_err),
    .rx_drop_count_o(link_rx_drop_count)
  );

  assign phy_in_valid = {NumChannels{rx_valid & link_en}};

  // UCIe macro APB slave at slower clock
  localparam int unsigned UcieApbClkDiv = 20;

  logic               ucie_apb_clk;
  ucie_cfg_apb_req_t  ucie_apb_req;
  ucie_cfg_apb_resp_t ucie_apb_rsp;

  cc_clk_int_div_static #(
    .DivValue(UcieApbClkDiv)
  ) i_ucie_apb_clk_div (
    .clk_i         (tile_clk),
    .rst_ni        (tile_rst_apb_n),
    .en_i          (1'b1),
    .test_mode_en_i(test_enable_i),
    .clk_o         (ucie_apb_clk)
  );

  // APB crossing to the macro clock
  logic ucie_apb_busy_d, ucie_apb_busy_q;
  logic ucie_apb_src_req_valid, ucie_apb_src_req_ready;
  logic ucie_apb_src_rsp_valid;
  logic ucie_apb_dst_req_valid, ucie_apb_dst_done;
  logic ucie_apb_access_d, ucie_apb_access_q;
  ucie_cfg_apb_resp_t ucie_apb_src_rsp, ucie_apb_cfg_rsp;

  // Source side: forward the access phase, then hold off `pready` until the
  // response is back. One transfer in flight at a time. While the macro domain
  // is off, the access is answered with an error and not forwarded.
  always_comb begin
    ucie_apb_src_req_valid  = 1'b0;
    ucie_apb_busy_d         = ucie_apb_busy_q;
    ucie_apb_cfg_rsp        = ucie_apb_src_rsp;
    ucie_apb_cfg_rsp.pready = 1'b0;
    if (ucie_apb_busy_q) begin
      // Complete the transfer when the response is back
      ucie_apb_cfg_rsp.pready = ucie_apb_src_rsp_valid;
      ucie_apb_busy_d         = ~ucie_apb_src_rsp_valid;
    end else if (cfg_apb_req[ApbUcie].psel && cfg_apb_req[ApbUcie].penable) begin
      if (ucie_apb_avail) begin
        // Forward the access, busy once the request is pushed
        ucie_apb_src_req_valid = 1'b1;
        ucie_apb_busy_d        = ucie_apb_src_req_ready;
      end else begin
        ucie_apb_cfg_rsp = '{pready: 1'b1, prdata: '0, pslverr: 1'b1};
      end
    end
  end

  always_ff @(posedge clk_i or negedge tile_rst_apb_n) begin
    if (!tile_rst_apb_n) ucie_apb_busy_q <= 1'b0;
    else ucie_apb_busy_q <= ucie_apb_busy_d;
  end

  assign cfg_apb_rsp[ApbUcie] = ucie_apb_cfg_rsp;

  // Only the request handshake crosses here
  cc_isochronous_spill_register #(
    .data_t(logic)
  ) i_ucie_apb_req_spill_register (
    .src_clk_i  (clk_i),
    .src_rst_ni (tile_rst_apb_n),
    .src_valid_i(ucie_apb_src_req_valid),
    .src_ready_o(ucie_apb_src_req_ready),
    .src_data_i (1'b0),
    .dst_clk_i  (ucie_apb_clk),
    .dst_rst_ni (tile_rst_apb_n),
    .dst_valid_o(ucie_apb_dst_req_valid),
    .dst_ready_i(ucie_apb_dst_done),
    .dst_data_o ()
  );

  // Destination side: replay the transfer with its setup and access phases
  // and push the response back on `pready`
  always_comb begin
    ucie_apb_req         = cfg_apb_req[ApbUcie];
    ucie_apb_req.psel    = ucie_apb_dst_req_valid;
    ucie_apb_req.penable = ucie_apb_access_q;
    // Setup phase for one cycle, then access phase until `pready`
    ucie_apb_dst_done    = ucie_apb_access_q & ucie_apb_rsp.pready;
    ucie_apb_access_d    = ucie_apb_dst_req_valid & ~ucie_apb_dst_done;
  end

  always_ff @(posedge ucie_apb_clk or negedge tile_rst_apb_n) begin
    if (!tile_rst_apb_n) ucie_apb_access_q <= 1'b0;
    else ucie_apb_access_q <= ucie_apb_access_d;
  end

  cc_isochronous_spill_register #(
    .data_t(ucie_cfg_apb_resp_t)
  ) i_ucie_apb_rsp_spill_register (
    .src_clk_i  (ucie_apb_clk),
    .src_rst_ni (tile_rst_apb_n),
    .src_valid_i(ucie_apb_dst_done),
    .src_ready_o(),
    .src_data_i (ucie_apb_rsp),
    .dst_clk_i  (clk_i),
    .dst_rst_ni (tile_rst_apb_n),
    .dst_valid_o(ucie_apb_src_rsp_valid),
    .dst_ready_i(ucie_apb_busy_q),
    .dst_data_o (ucie_apb_src_rsp)
  );

  // UCIe PHY + PCS macro
  ucie_macro_wrap i_ucie_macro_wrap (
    .rdi_clk      (tile_clk),
    .refclk       (ucie_refclk_i),
    // The whole macro is on the APB reset: software configures the PCS
    // before releasing the serial link (AXI reset)
    .rst_async_n  (tile_rst_apb_n),
    .txckn        (ucie_txckn_o),
    .txckp        (ucie_txckp_o),
    .txdata0      (ucie_txdata_o[0]),
    .txdata1      (ucie_txdata_o[1]),
    .txdata2      (ucie_txdata_o[2]),
    .txdata3      (ucie_txdata_o[3]),
    .txdata4      (ucie_txdata_o[4]),
    .txdata5      (ucie_txdata_o[5]),
    .txdata6      (ucie_txdata_o[6]),
    .txdata7      (ucie_txdata_o[7]),
    .txtrk        (ucie_txtrk_o),
    .txvld        (ucie_txvld_o),
    .rxckn        (ucie_rxckn_i),
    .rxckp        (ucie_rxckp_i),
    .rxdata0      (ucie_rxdata_i[0]),
    .rxdata1      (ucie_rxdata_i[1]),
    .rxdata2      (ucie_rxdata_i[2]),
    .rxdata3      (ucie_rxdata_i[3]),
    .rxdata4      (ucie_rxdata_i[4]),
    .rxdata5      (ucie_rxdata_i[5]),
    .rxdata6      (ucie_rxdata_i[6]),
    .rxdata7      (ucie_rxdata_i[7]),
    .rxtrk        (ucie_rxtrk_i),
    .rxvld        (ucie_rxvld_i),
    // Sideband bumps
    .rxclksb      (ucie_rxclksb_i),
    .rxdatasb     (ucie_rxdatasb_i),
    .txclksb      (ucie_txclksb_o),
    .txdatasb     (ucie_txdatasb_o),
    // APB slave: PCS CSRs (ucie_cfg SAM range), slow side of the CDC
    .apb_s_paddr  (32'(ucie_apb_req.paddr[UcieApbAddrWidth-1:0])),
    .apb_s_pclk   (ucie_apb_clk),
    .apb_s_penable(ucie_apb_req.penable),
    .apb_s_prdata (ucie_apb_rsp.prdata),
    .apb_s_pready (ucie_apb_rsp.pready),
    .apb_s_presetn(tile_rst_apb_n),
    .apb_s_psel   (ucie_apb_req.psel),
    .apb_s_pslverr(ucie_apb_rsp.pslverr),
    .apb_s_pstrb  (ucie_apb_req.pstrb),
    .apb_s_pwdata (ucie_apb_req.pwdata),
    .apb_s_pwrite (ucie_apb_req.pwrite),
    // RDI: adapter -> PHY. The unused RDI pins are tied off in the wrapper.
    .lp_data      (lp_data),
    .lp_irdy      (lp_irdy),
    // ACTIVE while the link gate is open: with the PCS in state follow mode,
    // pl_state_sts mirrors it and the PCS holds TX while the gate is closed
    .lp_state_req (link_en ? RdiActive : RdiReset),
    .lp_valid     (lp_valid),
    // RDI: PHY -> adapter
    .pl_data      (pl_data),
    .pl_state_sts (pl_state_sts),
    .pl_trdy      (pl_trdy),
    .pl_valid     (pl_valid)
  );

  `ASSERT_INIT(SingleChannel, NumChannels == 1, "only valid/ready of channel 0 is used")
  `ASSERT_INIT(RdiWidth, StreamWidth == RdiDataWidth,
               "NumChannels * NumBitsPerCycle must match the RDI width")

endmodule : ucie_tile
