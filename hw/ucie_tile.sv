// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
// Chen Wu <chenwu@iis.ee.ethz.ch>

`include "axi/assign.svh"
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

  // UCIe PHY interface (to the peer tile)
  output logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_out_o,
  output logic [NumChannels-1:0]                      phy_data_out_valid_o,
  input  logic [NumChannels-1:0]                      phy_data_out_ready_i,
  input  logic [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_in_i,
  input  logic [NumChannels-1:0]                      phy_data_in_valid_i,
  output logic [NumChannels-1:0]                      phy_data_in_ready_o
);

  // Half-bandwidth mode for debug output channels
  localparam int unsigned UcieHalfPhyWidth = NumBitsPerCycle / 2;

  // Shared by the wide fork and the cfg APB demux
  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } addr_rule_t;

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

  // SLink configuration registers.
  ucie_slink_reg_pkg::slink_reg__in_t  slink_hw2reg;
  ucie_slink_reg_pkg::slink_reg__out_t slink_reg2hw;

  // Clock/rst configuration registers.
  gw_ucie_tile_regs_pkg::gw_ucie_tile_regs__out_t hwif_out;

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
    // UCIe tile only initiates collective transactions that don't require loopback
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

  floo_gwaihir_noc_pkg::collective_axi_narrow_out_req_t axi_narrow_out_req;
  floo_gwaihir_noc_pkg::collective_axi_narrow_out_rsp_t axi_narrow_out_rsp;
  floo_gwaihir_noc_pkg::collective_axi_wide_in_req_t    axi_wide_in_req;
  floo_gwaihir_noc_pkg::collective_axi_wide_in_rsp_t    axi_wide_in_rsp;
  floo_gwaihir_noc_pkg::collective_axi_wide_out_req_t   axi_wide_out_req;
  floo_gwaihir_noc_pkg::collective_axi_wide_out_rsp_t   axi_wide_out_rsp;

  // Ingress mux output, before unalias
  floo_gwaihir_noc_pkg::collective_axi_wide_in_req_t axi_wide_in_mux_req;
  floo_gwaihir_noc_pkg::collective_axi_wide_in_rsp_t axi_wide_in_mux_rsp;

  localparam floo_pkg::axi_cfg_t AxiCfgWCollective = '{
      AddrWidth: AxiCfgW.AddrWidth,
      DataWidth: AxiCfgW.DataWidth,
      UserWidth: $bits(collective_axi_wide_out_user_t),
      InIdWidth: AxiCfgW.InIdWidth,
      OutIdWidth: AxiCfgW.OutIdWidth
  };

  // Narrow config with the narrow `user.user` field stripped, i.e. with only
  // the collective fields in the user signal, as in the wide channel
  localparam floo_pkg::axi_cfg_t AxiCfgNCollective = '{
      AddrWidth: AxiCfgN.AddrWidth,
      DataWidth: AxiCfgN.DataWidth,
      UserWidth: $bits(collective_axi_wide_out_user_t),
      InIdWidth: AxiCfgN.InIdWidth,
      OutIdWidth: AxiCfgN.OutIdWidth
  };

  // Narrow AXI with the narrow `user.user` field stripped
  `AXI_TYPEDEF_ALL_CT(collective_axi_narrow_nouser, collective_axi_narrow_nouser_req_t,
                      collective_axi_narrow_nouser_rsp_t, axi_narrow_out_addr_t,
                      axi_narrow_out_id_t, axi_narrow_out_data_t, axi_narrow_out_strb_t,
                      collective_axi_wide_out_user_t)

  // NW join AXI interface, carrying the collective fields in the user signal
  // through the serial link
  typedef logic [AxiCfgUcieJoin.OutIdWidth-1:0] axi_ucie_join_id_t;
  `AXI_TYPEDEF_ALL_CT(collective_axi_ucie_join, collective_axi_ucie_join_req_t,
                      collective_axi_ucie_join_rsp_t, axi_wide_out_addr_t, axi_ucie_join_id_t,
                      axi_wide_out_data_t, axi_wide_out_strb_t, collective_axi_wide_out_user_t)

  collective_axi_ucie_join_req_t axi_ucie_join_out_req;
  collective_axi_ucie_join_rsp_t axi_ucie_join_out_rsp;

  floo_nw_chimney #(
    .AxiCfgN             (floo_gwaihir_noc_pkg::AxiCfgN),
    .AxiCfgW             (floo_gwaihir_noc_pkg::AxiCfgW),
    .ChimneyCfgN         (floo_pkg::ChimneyDefaultCfg),
    .ChimneyCfgW         (floo_pkg::ChimneyDefaultCfg),
    .RouteCfg            (RouteCfgMcastOnly),
    .AtopSupport         (1'b1),
    .collect_op_t        (floo_gwaihir_noc_pkg::collect_op_t),
    .WideRwDecouple      (floo_gwaihir_noc_pkg::WideRwDecouple),
    .VcImpl              (VcImpl),
    .MaxAtomicTxns       (3),
    .Sam                 (floo_gwaihir_noc_pkg::CollectiveSam),
    .id_t                (floo_gwaihir_noc_pkg::id_t),
    .rob_idx_t           (floo_gwaihir_noc_pkg::rob_idx_t),
    .hdr_t               (floo_gwaihir_noc_pkg::hdr_t),
    .sam_rule_t          (floo_gwaihir_noc_pkg::collective_sam_rule_t),
    .sam_idx_t           (floo_gwaihir_noc_pkg::collective_idx_t),
    .mask_sel_t          (floo_gwaihir_noc_pkg::collective_mask_sel_t),
    .user_narrow_struct_t(floo_gwaihir_noc_pkg::collective_axi_narrow_in_user_t),
    .user_wide_struct_t  (floo_gwaihir_noc_pkg::collective_axi_wide_in_user_t),
    //CHECK PARAMS!!
    .axi_narrow_in_req_t (floo_gwaihir_noc_pkg::collective_axi_narrow_in_req_t),
    .axi_narrow_in_rsp_t (floo_gwaihir_noc_pkg::collective_axi_narrow_in_rsp_t),
    .axi_narrow_out_req_t(floo_gwaihir_noc_pkg::collective_axi_narrow_out_req_t),
    .axi_narrow_out_rsp_t(floo_gwaihir_noc_pkg::collective_axi_narrow_out_rsp_t),
    .axi_wide_in_req_t   (floo_gwaihir_noc_pkg::collective_axi_wide_in_req_t),
    .axi_wide_in_rsp_t   (floo_gwaihir_noc_pkg::collective_axi_wide_in_rsp_t),
    .axi_wide_out_req_t  (floo_gwaihir_noc_pkg::collective_axi_wide_out_req_t),
    .axi_wide_out_rsp_t  (floo_gwaihir_noc_pkg::collective_axi_wide_out_rsp_t),

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
    .axi_narrow_out_req_o(axi_narrow_out_req),
    .axi_narrow_out_rsp_i(axi_narrow_out_rsp),
    .axi_wide_in_req_i   (axi_wide_in_req),
    .axi_wide_in_rsp_o   (axi_wide_in_mux_rsp),
    .axi_wide_out_req_o  (axi_wide_out_req),
    .axi_wide_out_rsp_i  (axi_wide_out_rsp),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

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
      NoAddrRules: 4,
      default: '0
  };

  typedef struct packed {
    logic [cc_pkg::idx_width(NumUcieXbarMstPorts)-1:0] idx;
    axi_narrow_out_addr_t                              start_addr;
    axi_narrow_out_addr_t                              end_addr;
  } ucie_rule_t;

  // Sam Idx offset between UCIe base and AxiCfg
  localparam int AxiSerialCfgIdxOffset = int'(Ucie0AxiSerialCfgSamIdx) - int'(Ucie0SamIdx);
  // Sam Idx offset between UCIe base and the UCIe PCS macro APB (ucie_cfg).
  // NOTE: name generated by floogen from the "ucie_cfg" range; adjust if regen
  // emits a different symbol.
  localparam int UcieCfgIdxOffset = int'(Ucie0UcieCfgSamIdx) - int'(Ucie0SamIdx);
  localparam int TileCfgIdxOffset = int'(Ucie0TileCfgSamIdx) - int'(Ucie0SamIdx);

  ucie_rule_t [AxiSerialCfgIdxOffset:0] tile_addrmap;
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
          '{idx: JOIN, start_addr: Sam[samidx_i].start_addr, end_addr  : Sam[samidx_i].end_addr}
      };

  floo_gwaihir_noc_pkg::collective_axi_narrow_out_req_t [NumUcieXbarMstPorts-1:0]
      axi_narrow_xbar_out_req;
  floo_gwaihir_noc_pkg::collective_axi_narrow_out_rsp_t [NumUcieXbarMstPorts-1:0]
      axi_narrow_xbar_out_rsp;

  axi_xbar #(
    .Cfg          (AxiNarrowXbarCfg),
    .ATOPs        ('0),
    .Connectivity ('1),
    .slv_aw_chan_t(collective_axi_narrow_out_aw_chan_t),
    .mst_aw_chan_t(collective_axi_narrow_out_aw_chan_t),
    .w_chan_t     (collective_axi_narrow_out_w_chan_t),
    .slv_b_chan_t (collective_axi_narrow_out_b_chan_t),
    .mst_b_chan_t (collective_axi_narrow_out_b_chan_t),
    .slv_ar_chan_t(collective_axi_narrow_out_ar_chan_t),
    .mst_ar_chan_t(collective_axi_narrow_out_ar_chan_t),
    .slv_r_chan_t (collective_axi_narrow_out_r_chan_t),
    .mst_r_chan_t (collective_axi_narrow_out_r_chan_t),
    .slv_req_t    (collective_axi_narrow_out_req_t),
    .slv_resp_t   (collective_axi_narrow_out_rsp_t),
    .mst_req_t    (collective_axi_narrow_out_req_t),
    .mst_resp_t   (collective_axi_narrow_out_rsp_t),
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
    .AxiUserWidth   ($bits(collective_axi_narrow_out_user_t)),
    .AxiMaxWriteTxns(floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .AxiMaxReadTxns (floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .full_req_t     (floo_gwaihir_noc_pkg::collective_axi_narrow_out_req_t),
    .full_resp_t    (floo_gwaihir_noc_pkg::collective_axi_narrow_out_rsp_t),
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

  // SLink configuration registers.
  ucie_slink_reg i_serial_link_reg (
    .clk          (tile_clk),
    .arst_n       (tile_rst_n),
    .s_apb_psel   (cfg_apb_req[ApbSlink].psel),
    .s_apb_penable(cfg_apb_req[ApbSlink].penable),
    .s_apb_pwrite (cfg_apb_req[ApbSlink].pwrite),
    .s_apb_pprot  (cfg_apb_req[ApbSlink].pprot),
    // TODO (lleone): Check if the address bits are correct since in the type definition was 48b
    .s_apb_paddr  (cfg_apb_req[ApbSlink].paddr[UCIE_SLINK_REG_MIN_ADDR_WIDTH-1:0]),
    .s_apb_pwdata (cfg_apb_req[ApbSlink].pwdata),
    .s_apb_pstrb  (cfg_apb_req[ApbSlink].pstrb),
    .s_apb_pready (cfg_apb_rsp[ApbSlink].pready),
    .s_apb_prdata (cfg_apb_rsp[ApbSlink].prdata),
    .s_apb_pslverr(cfg_apb_rsp[ApbSlink].pslverr),
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

  // Strip the narrow `user.user` field, keeping the collective fields, so the
  // narrow user matches the wide user before joining.
  collective_axi_narrow_nouser_req_t axi_narrow_nouser_req;
  collective_axi_narrow_nouser_rsp_t axi_narrow_nouser_rsp;

  always_comb begin
    `AXI_SET_REQ_STRUCT(axi_narrow_nouser_req, axi_narrow_xbar_out_req[JOIN])
    axi_narrow_nouser_req.aw.user = '{
        collective_mask: axi_narrow_xbar_out_req[JOIN].aw.user.collective_mask,
        collective_op: axi_narrow_xbar_out_req[JOIN].aw.user.collective_op
    };
    axi_narrow_nouser_req.w.user = '{
        collective_mask: axi_narrow_xbar_out_req[JOIN].w.user.collective_mask,
        collective_op: axi_narrow_xbar_out_req[JOIN].w.user.collective_op
    };
    axi_narrow_nouser_req.ar.user = '{
        collective_mask: axi_narrow_xbar_out_req[JOIN].ar.user.collective_mask,
        collective_op: axi_narrow_xbar_out_req[JOIN].ar.user.collective_op
    };

    `AXI_SET_RESP_STRUCT(axi_narrow_xbar_out_rsp[JOIN], axi_narrow_nouser_rsp)
    axi_narrow_xbar_out_rsp[JOIN].b.user = '{
        collective_mask: axi_narrow_nouser_rsp.b.user.collective_mask,
        collective_op: axi_narrow_nouser_rsp.b.user.collective_op,
        user: '0
    };
    axi_narrow_xbar_out_rsp[JOIN].r.user = '{
        collective_mask: axi_narrow_nouser_rsp.r.user.collective_mask,
        collective_op: axi_narrow_nouser_rsp.r.user.collective_op,
        user: '0
    };
  end

  floo_nw_join #(
    .AxiCfgN          (axi_cfg_swap_iw(AxiCfgNCollective)),
    .AxiCfgW          (axi_cfg_swap_iw(AxiCfgWCollective)),
    .AxiCfgJoin       (axi_cfg_swap_iw(AxiCfgUcieJoin)),
    .EnAtopAdapter    (1'b0),
    .FilterNarrowAtops(1'b1),
    .AxiNarrowMaxTxns (32),
    .axi_narrow_req_t (collective_axi_narrow_nouser_req_t),
    .axi_narrow_rsp_t (collective_axi_narrow_nouser_rsp_t),
    .axi_wide_req_t   (collective_axi_wide_out_req_t),
    .axi_wide_rsp_t   (collective_axi_wide_out_rsp_t),
    .axi_req_t        (collective_axi_ucie_join_req_t),
    .axi_rsp_t        (collective_axi_ucie_join_rsp_t)
  ) i_floo_nw_join (
    .clk_i           (tile_clk),
    .rst_ni          (tile_rst_n),
    .test_enable_i   (test_enable_i),
    .axi_narrow_req_i(axi_narrow_nouser_req),
    .axi_narrow_rsp_o(axi_narrow_nouser_rsp),
    .axi_wide_req_i  (axi_wide_out_req),
    .axi_wide_rsp_o  (axi_wide_out_rsp),
    .axi_req_o       (axi_ucie_join_out_req),
    .axi_rsp_i       (axi_ucie_join_out_rsp)
  );

  ////////////////////
  // Multicast Fork //
  ////////////////////

  // Remote branch: own alias window -> remote ucie.
  // Local branch: peer alias window -> ingress back to the local NoC.

  typedef enum int unsigned {
    ForkRemote = 0,
    ForkLocal  = 1
  } ucie_fork_port_e;

  localparam int unsigned NumForkPorts = 2;

  // Peer UCIe tile, whose alias window selects the local branch
  sam_idx_e peer_samidx;
  assign peer_samidx = (sam_idx_e'(samidx_i) == Ucie0SamIdx) ? Ucie1SamIdx : Ucie0SamIdx;

  // Multicast rules must be power-of-2 sized and aligned
  addr_rule_t [NumForkPorts-1:0] fork_addrmap;
  always_comb begin
    fork_addrmap[ForkRemote] = '{
        idx       : ForkRemote,
        start_addr: Sam[samidx_i].start_addr,
        end_addr  : Sam[samidx_i].end_addr
    };
    fork_addrmap[ForkLocal] = '{
        idx       : ForkLocal,
        start_addr: Sam[peer_samidx].start_addr,
        end_addr  : Sam[peer_samidx].end_addr
    };
  end

  // Degenerate 1-to-NumForkPorts XBAR
  localparam axi_pkg::xbar_cfg_t AxiUcieForkXbarCfg = '{
      NoSlvPorts: 1,
      NoMstPorts: NumForkPorts,
      MaxMstTrans: 32,
      MaxSlvTrans: 32,
      FallThrough: 0,
      LatencyMode: axi_pkg::DemuxAw | axi_pkg::DemuxAr | axi_pkg::MuxAw,
      PipelineStages: 0,
      AxiIdWidthSlvPorts: AxiCfgUcieJoin.OutIdWidth,
      AxiIdUsedSlvPorts: AxiCfgUcieJoin.OutIdWidth,
      UniqueIds: 0,
      AxiAddrWidth: AxiCfgUcieJoin.AddrWidth,
      AxiDataWidth: AxiCfgUcieJoin.DataWidth,
      NoAddrRules: NumForkPorts,
      NoMulticastRules: NumForkPorts,
      NoMulticastPorts: NumForkPorts
  };

  collective_axi_ucie_join_req_t [             0:0] axi_ucie_fork_slv_req;
  collective_axi_ucie_join_rsp_t [             0:0] axi_ucie_fork_slv_rsp;
  collective_axi_ucie_join_req_t [NumForkPorts-1:0] axi_ucie_xbar_req;
  collective_axi_ucie_join_rsp_t [NumForkPorts-1:0] axi_ucie_xbar_rsp;
  collective_axi_ucie_join_req_t [NumForkPorts-1:0] axi_ucie_fork_req;
  collective_axi_ucie_join_rsp_t [NumForkPorts-1:0] axi_ucie_fork_rsp;

  assign axi_ucie_fork_slv_req[0] = axi_ucie_join_out_req;
  assign axi_ucie_join_out_rsp    = axi_ucie_fork_slv_rsp[0];

  axi_mcast_xbar #(
    .Cfg                  (AxiUcieForkXbarCfg),
    .Connectivity         ('1),
    .MulticastConnectivity('1),
    .slv_aw_chan_t        (collective_axi_ucie_join_aw_chan_t),
    .mst_aw_chan_t        (collective_axi_ucie_join_aw_chan_t),
    .w_chan_t             (collective_axi_ucie_join_w_chan_t),
    .slv_b_chan_t         (collective_axi_ucie_join_b_chan_t),
    .mst_b_chan_t         (collective_axi_ucie_join_b_chan_t),
    .slv_ar_chan_t        (collective_axi_ucie_join_ar_chan_t),
    .mst_ar_chan_t        (collective_axi_ucie_join_ar_chan_t),
    .slv_r_chan_t         (collective_axi_ucie_join_r_chan_t),
    .mst_r_chan_t         (collective_axi_ucie_join_r_chan_t),
    .slv_req_t            (collective_axi_ucie_join_req_t),
    .slv_resp_t           (collective_axi_ucie_join_rsp_t),
    .mst_req_t            (collective_axi_ucie_join_req_t),
    .mst_resp_t           (collective_axi_ucie_join_rsp_t),
    .rule_t               (addr_rule_t)
  ) i_ucie_mcast_fork (
    .clk_i                (tile_clk),
    .rst_ni               (tile_rst_n),
    .slv_ports_req_i      (axi_ucie_fork_slv_req),
    .slv_ports_resp_o     (axi_ucie_fork_slv_rsp),
    .mst_ports_req_o      (axi_ucie_xbar_req),
    .mst_ports_resp_i     (axi_ucie_xbar_rsp),
    .addr_map_i           (fork_addrmap),
    .en_default_mst_port_i(1'b0),
    .default_mst_port_i   ('{default: '0})
  );

  // Multicast transactions directed to multiple chiplets must have the
  // collective_op field set to Unicast, since they are not handled directly
  // within FlooNoC (multiple mesh-based chiplets connected together through
  // a UCIe bus do not form a mesh topology in a strict sense, and FlooNoC only
  // supports meshes at the moment).
  // However, when the forked requests exit the multicast crossbar, directed to
  // each branch's chimney, their collective_op field must be set to Multicast,
  // so that they can be handled as multicast transactions within the
  // respective chiplets.
  for (genvar i = 0; i < NumForkPorts; i++) begin : gen_fork_port
    always_comb begin
      axi_ucie_fork_req[i] = axi_ucie_xbar_req[i];
      axi_ucie_fork_req[i].aw.user.collective_op =
          (axi_ucie_xbar_req[i].aw.user.collective_mask != '0) ? floo_pkg::Multicast :
                                                                 floo_pkg::Unicast;
    end
    assign axi_ucie_xbar_rsp[i] = axi_ucie_fork_rsp[i];
  end

  /////////////////////////////////////////////////////////////
  // Mux local multicast branch and incoming path from slink //
  /////////////////////////////////////////////////////////////

  typedef enum int unsigned {
    IngressRemote = 0,
    IngressLocal  = 1
  } ucie_ingress_port_e;

  // The remote branch is driven directly by the serial link (see below)
  collective_axi_ucie_join_req_t [1:0] axi_wide_ingress_req;
  collective_axi_ucie_join_rsp_t [1:0] axi_wide_ingress_rsp;

  assign axi_wide_ingress_req[IngressLocal] = axi_ucie_fork_req[ForkLocal];
  assign axi_ucie_fork_rsp[ForkLocal]       = axi_wide_ingress_rsp[IngressLocal];

  axi_mux #(
    .SlvAxiIDWidth(AxiCfgUcieJoin.OutIdWidth),
    .slv_aw_chan_t(collective_axi_ucie_join_aw_chan_t),
    .mst_aw_chan_t(collective_axi_wide_in_aw_chan_t),
    .w_chan_t     (collective_axi_wide_in_w_chan_t),
    .slv_b_chan_t (collective_axi_ucie_join_b_chan_t),
    .mst_b_chan_t (collective_axi_wide_in_b_chan_t),
    .slv_ar_chan_t(collective_axi_ucie_join_ar_chan_t),
    .mst_ar_chan_t(collective_axi_wide_in_ar_chan_t),
    .slv_r_chan_t (collective_axi_ucie_join_r_chan_t),
    .mst_r_chan_t (collective_axi_wide_in_r_chan_t),
    .slv_req_t    (collective_axi_ucie_join_req_t),
    .slv_resp_t   (collective_axi_ucie_join_rsp_t),
    .mst_req_t    (collective_axi_wide_in_req_t),
    .mst_resp_t   (collective_axi_wide_in_rsp_t),
    .NoSlvPorts   (2),
    .MaxWTrans    (32)
  ) i_wide_ingress_mux (
    .clk_i      (tile_clk),
    .rst_ni     (tile_rst_n),
    .slv_reqs_i (axi_wide_ingress_req),
    .slv_resps_o(axi_wide_ingress_rsp),
    .mst_req_o  (axi_wide_in_mux_req),
    .mst_resp_i (axi_wide_in_mux_rsp)
  );

  // Translate chimney ingress addresses to their canonical form
  always_comb begin
    axi_wide_in_req         = axi_wide_in_mux_req;
    axi_wide_in_req.aw.addr = unalias_ucie_address(axi_wide_in_mux_req.aw.addr, ucie_id_i);
    axi_wide_in_req.ar.addr = unalias_ucie_address(axi_wide_in_mux_req.ar.addr, ucie_id_i);
  end

  //////////////////
  // AXI Streamer //
  /////////////////

  // Serializer PHY backend: the stream between the bandwidth-mode adapter and
  // the PCS wrapper (`ucie_pcs_wrap`), which owns everything PHY/PCS-specific.
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
    .axi_req_t             (collective_axi_ucie_join_req_t),
    .axi_rsp_t             (collective_axi_ucie_join_rsp_t),
    .aw_chan_t             (collective_axi_ucie_join_aw_chan_t),
    .ar_chan_t             (collective_axi_ucie_join_ar_chan_t),
    .r_chan_t              (collective_axi_ucie_join_r_chan_t),
    .w_chan_t              (collective_axi_ucie_join_w_chan_t),
    .b_chan_t              (collective_axi_ucie_join_b_chan_t),
    .hwif_in_t             (ucie_slink_reg_pkg::slink_reg__in_t),
    .hwif_out_t            (ucie_slink_reg_pkg::slink_reg__out_t)
  ) i_ucie_slink_serializer (
    .clk_i                   (tile_clk),
    .rst_ni                  (tile_rst_n),
    .clk_sl_i                (tile_clk),
    .rst_sl_ni               (tile_rst_n),
    .axi_in_req_i            (axi_ucie_fork_req[ForkRemote]),
    .axi_in_rsp_o            (axi_ucie_fork_rsp[ForkRemote]),
    .axi_out_req_o           (axi_wide_ingress_req[IngressRemote]),
    .axi_out_rsp_i           (axi_wide_ingress_rsp[IngressRemote]),
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

  /////////////////
  // PCS wrapper //
  /////////////////

  ucie_pcs_wrap #(
    .NumChannels    (NumChannels),
    .NumBitsPerCycle(NumBitsPerCycle),
    .apb_req_t      (ucie_cfg_apb_req_t),
    .apb_resp_t     (ucie_cfg_apb_resp_t)
  ) i_ucie_pcs_wrap (
    .clk_i     (tile_clk),
    .rst_ni    (tile_rst_n),
    .rst_apb_ni(tile_rst_apb_n),
    .clk_ena_i (hwif_out.clk.en.value),
    .tx_data_i (phy_out_data),
    .tx_valid_i(phy_out_valid),
    .tx_ready_o(phy_out_ready),
    .rx_data_o (phy_in_data),
    .rx_valid_o(phy_in_valid),
    .rx_ready_i(phy_in_ready),
    .phy_data_out_o,
    .phy_data_out_valid_o,
    .phy_data_out_ready_i,
    .phy_data_in_i,
    .phy_data_in_valid_i,
    .phy_data_in_ready_o,
    .apb_req_i (cfg_apb_req[ApbUcie]),
    .apb_rsp_o (cfg_apb_rsp[ApbUcie])
  );

endmodule : ucie_tile
