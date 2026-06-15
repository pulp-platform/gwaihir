// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

`include "axi/assign.svh"

module cluster_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import snitch_cluster_pkg::*;
  import gwaihir_pkg::*;
(
  input  logic                                    clk_i,
  input  logic                                    rst_ni,
  input  logic                                    test_enable_i,
  input  logic                                    clk_rst_bypass_i,
  // Cluster ports
  input  logic                      [NrCores-1:0] debug_req_i,
  input  logic                      [NrCores-1:0] meip_i,
  input  logic                      [NrCores-1:0] mtip_i,
  input  logic                      [NrCores-1:0] msip_i,
  input  logic                      [        9:0] hart_base_id_i,
  input  snitch_cluster_pkg::addr_t               cluster_base_addr_i,
  input  snitch_cluster_pkg::addr_t               cluster_base_offset_i,
  // Chimney ports
  input  id_t                                     id_i,
  // Router ports
  output floo_req_t                 [ West:North] floo_req_o,
  input  floo_rsp_t                 [ West:North] floo_rsp_i,
  output floo_wide_t                [ West:North] floo_wide_o,
  input  floo_req_t                 [ West:North] floo_req_i,
  output floo_rsp_t                 [ West:North] floo_rsp_o,
  input  floo_wide_t                [ West:North] floo_wide_i
);

  // Tile-specific reset and clock signals
  logic tile_clk;
  logic tile_rst_n;

  typedef enum int unsigned {
    Cluster       = 'd0,
    TileCfg       = 'd1,
    NumDemuxPorts = 'd2
  } axi_demux_sel_e;

  typedef logic [AxiCfgN.AddrWidth-1:0] addr_t;
  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } addr_rule_t;

  // NOTE(fischeti): This is approximate since it does not include the
  // actual address range for this exact tile, but it is sufficient since
  // the NoC will take care of routing the request to the correct tile.
  localparam int unsigned NumTileAddrMapRules = 1;
  addr_rule_t [NumTileAddrMapRules-1:0] TileAddrMap = '{
      '{
          idx: TileCfg,
          start_addr: Sam[ClusterConfigX0Y0SamIdx].start_addr,
          end_addr: Sam[ClusterConfigX3Y3SamIdx].end_addr
      }
  };
  localparam int unsigned NumTileApbAddrMapRules = 1;
  addr_rule_t [NumTileApbAddrMapRules-1:0] TileApbAddrMap = '{
      '{idx: 0, start_addr: '0, end_addr: '1}
  };

  logic aw_select, ar_select;

  snitch_cluster_pkg::narrow_in_req_t              chimney_narrow_out_req;
  snitch_cluster_pkg::narrow_in_resp_t             chimney_narrow_out_rsp;
  snitch_cluster_pkg::narrow_in_req_t        [1:0] axi_demux_out_req;
  snitch_cluster_pkg::narrow_in_resp_t       [1:0] axi_demux_out_rsp;

  gw_tile_regs_pkg::gw_tile_regs__out_t            hwif_out;

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t       tile_cfg_demux_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t       tile_cfg_demux_rsp;
  tile_cfg_axi_lite_req_t                          tile_cfg_axi_lite_req;
  tile_cfg_axi_lite_resp_t                         tile_cfg_axi_lite_rsp;
  tile_cfg_axi_lite_32_req_t                       tile_cfg_axi_lite_32_req;
  tile_cfg_axi_lite_32_resp_t                      tile_cfg_axi_lite_32_rsp;
  tile_cfg_apb_req_t                               tile_cfg_apb_req;
  tile_cfg_apb_resp_t                              tile_cfg_apb_rsp;

  ////////////////////
  // Snitch Cluster //
  ////////////////////

  snitch_cluster_pkg::narrow_in_req_t              cluster_narrow_in_req;
  snitch_cluster_pkg::narrow_in_resp_t             cluster_narrow_in_rsp;
  snitch_cluster_pkg::narrow_out_req_t             cluster_narrow_out_req;
  snitch_cluster_pkg::narrow_out_resp_t            cluster_narrow_out_rsp;
  snitch_cluster_pkg::wide_out_req_t               cluster_wide_out_req;
  snitch_cluster_pkg::wide_out_resp_t              cluster_wide_out_rsp;
  snitch_cluster_pkg::wide_in_req_t                cluster_wide_in_req;
  snitch_cluster_pkg::wide_in_resp_t               cluster_wide_in_rsp;

  snitch_cluster_pkg::narrow_out_req_t             cluster_narrow_ext_req;
  snitch_cluster_pkg::narrow_out_resp_t            cluster_narrow_ext_rsp;
  snitch_cluster_pkg::tcdm_dma_req_t               cluster_tcdm_ext_req_aligned;
  snitch_cluster_pkg::tcdm_dma_req_t               cluster_tcdm_ext_req_misaligned;
  snitch_cluster_pkg::tcdm_dma_rsp_t               cluster_tcdm_ext_rsp_aligned;
  snitch_cluster_pkg::tcdm_dma_rsp_t               cluster_tcdm_ext_rsp_misaligned;

  cluster_narrow_out_dw_conv_req_t cluster_narrow_out_dw_conv_req, cluster_narrow_out_cut_req;
  cluster_narrow_out_dw_conv_resp_t cluster_narrow_out_dw_conv_rsp, cluster_narrow_out_cut_rsp;

  hwpectrl_req_t               hwpectrl_req;
  hwpectrl_rsp_t               hwpectrl_rsp;

  logic          [NrCores-1:0] mxip;


  ////////////////////////
  // Wide FPU Reduction //
  ////////////////////////

  // Snitch cluster DCA interface
  snitch_cluster_pkg::dca_req_t offload_dca_req, offload_dca_req_cut;
  snitch_cluster_pkg::dca_rsp_t offload_dca_rsp, offload_dca_rsp_cut;

  // Signals to connect the NW router to the wide parser
  red_wide_req_t offload_wide_req;
  red_wide_rsp_t offload_wide_rsp;

  // Parse the Wide request from the reouter to the one from the snitch cluster!
  // TODO(raroth): possible to remove this decode from the gwaihir repo and move it inside the
  //       FlooNoC repo. Currently the Decode used for the ALU is directly inside the floo_alu.sv
  //       file. Maybe do the same for the FPU
  if (en_wide_reduction(RouteCfg.CollectiveCfg.OpCfg)) begin : gen_wide_offload_reduction
    // Connect the DCA Request
    assign offload_dca_req.q_valid = offload_wide_req.valid;
    assign offload_wide_rsp.ready  = offload_dca_rsp.q_ready;

    // Parse the FPU Request
    always_comb begin
      // Init default values
      offload_dca_req.q.operands     = '0;

      // Set default Values
      offload_dca_req.q.src_fmt      = fpnew_pkg::FP64;
      offload_dca_req.q.dst_fmt      = fpnew_pkg::FP64;
      offload_dca_req.q.int_fmt      = fpnew_pkg::INT64;
      offload_dca_req.q.vectorial_op = 1'b0;
      offload_dca_req.q.op_mod       = 1'b0;
      offload_dca_req.q.rnd_mode     = fpnew_pkg::RNE;
      offload_dca_req.q.op           = fpnew_pkg::ADD;

      // Define the operation we want to execute on the FPU
      unique casez (offload_wide_req.req.op)
        (floo_pkg::FpAdd): begin
          offload_dca_req.q.op          = fpnew_pkg::ADD;
          offload_dca_req.q.operands[0] = '0;
          offload_dca_req.q.operands[1] = offload_wide_req.req.operand1;
          offload_dca_req.q.operands[2] = offload_wide_req.req.operand2;
        end
        (floo_pkg::FpMul): begin
          offload_dca_req.q.op          = fpnew_pkg::MUL;
          offload_dca_req.q.operands[0] = offload_wide_req.req.operand1;
          offload_dca_req.q.operands[1] = offload_wide_req.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        (floo_pkg::FpMax): begin
          offload_dca_req.q.op          = fpnew_pkg::MINMAX;
          offload_dca_req.q.rnd_mode    = fpnew_pkg::RNE;
          offload_dca_req.q.operands[0] = offload_wide_req.req.operand1;
          offload_dca_req.q.operands[1] = offload_wide_req.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        (floo_pkg::FpMin): begin
          offload_dca_req.q.op          = fpnew_pkg::MINMAX;
          offload_dca_req.q.rnd_mode    = fpnew_pkg::RTZ;
          offload_dca_req.q.operands[0] = offload_wide_req.req.operand1;
          offload_dca_req.q.operands[1] = offload_wide_req.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        default: begin
          offload_dca_req.q.op          = fpnew_pkg::ADD;
          offload_dca_req.q.operands[0] = '0;
          offload_dca_req.q.operands[1] = '0;
          offload_dca_req.q.operands[2] = '0;
        end
      endcase
    end

    // TODO(raroth): move these spill register inside FlooNoC and make them configurable.
    // Insert a reqrsp-cut to avoid timing violations
    //If teh CutOffloadIntf is enabled, the cut is already in the offload controller, you can bypass teh one below
    generic_reqrsp_cut #(
      .req_chan_t(snitch_cluster_pkg::dca_req_chan_t),
      .rsp_chan_t(snitch_cluster_pkg::dca_rsp_chan_t),
      .BypassReq (RouteCfg.CollectiveCfg.WideRedCfg.CutOffloadIntf),
      .BypassRsp (RouteCfg.CollectiveCfg.WideRedCfg.CutOffloadIntf)
    ) i_dca_router_cut (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .slv_req_i(offload_dca_req),
      .slv_rsp_o(offload_dca_rsp),
      .mst_req_o(offload_dca_req_cut),
      .mst_rsp_i(offload_dca_rsp_cut)
    );
    // Connect the Response
    assign offload_wide_rsp.valid      = offload_dca_rsp.p_valid;
    assign offload_dca_req.p_ready     = offload_wide_req.ready;
    assign offload_wide_rsp.rsp.result = offload_dca_rsp.p.result;

    // No Wide Reduction supported
  end else begin : gen_no_wide_reduction
    assign offload_dca_req_cut         = '0;
    assign offload_dca_rsp             = '0;
    assign offload_wide_rsp.ready      = '0;
    assign offload_wide_rsp.rsp.result = '0;
    assign offload_wide_rsp.valid      = '0;
  end

  // TODO(lleone): Add teh narrow ALU reduction unit and connections here


  snitch_cluster_wrapper i_cluster (
    .clk_i             (tile_clk),
    .rst_ni            (tile_rst_n),
    .debug_req_i,
    .meip_i,
    .mtip_i,
    .msip_i,
    .hart_base_id_i,
    .cluster_base_addr_i,
    .cluster_base_offset_i,
    .mxip_i            (mxip),
    .clk_d2_bypass_i   ('0),
    .sram_cfgs_i       ('0),
    .narrow_in_req_i   (cluster_narrow_in_req),
    .narrow_in_resp_o  (cluster_narrow_in_rsp),
    .narrow_out_req_o  (cluster_narrow_out_req),
    .narrow_out_resp_i (cluster_narrow_out_rsp),
    .wide_out_req_o    (cluster_wide_out_req),
    .wide_out_resp_i   (cluster_wide_out_rsp),
    .wide_in_req_i     (cluster_wide_in_req),
    .wide_in_resp_o    (cluster_wide_in_rsp),
    .narrow_ext_req_o  (cluster_narrow_ext_req),
    .narrow_ext_resp_i (cluster_narrow_ext_rsp),
    .tcdm_ext_req_i    (cluster_tcdm_ext_req_aligned),
    .tcdm_ext_resp_o   (cluster_tcdm_ext_rsp_aligned),
    .dca_req_i         (offload_dca_req_cut),
    .dca_rsp_o         (offload_dca_rsp_cut),
    .x_issue_req_o     (),
    .x_issue_resp_i    ('0),
    .x_issue_valid_o   (),
    .x_issue_ready_i   ('0),
    .x_register_o      (),
    .x_register_valid_o(),
    .x_register_ready_i('0),
    .x_commit_o        (),
    .x_commit_valid_o  (),
    .x_result_i        ('0),
    .x_result_valid_i  ('0),
    .x_result_ready_o  ()
  );

  if (UseHWPE) begin : gen_hwpe

    // Convert narrow AXI's 64 bit DW down to 32
    axi_dw_converter #(
      .AxiMaxReads        (1),
      .AxiSlvPortDataWidth(snitch_cluster_pkg::NarrowDataWidth),
      .AxiMstPortDataWidth(HWPECtrlDataWidth),
      .AxiAddrWidth       (snitch_cluster_pkg::AddrWidth),
      .AxiIdWidth         (snitch_cluster_pkg::NarrowIdWidthOut),
      .aw_chan_t          (snitch_cluster_pkg::narrow_out_aw_chan_t),
      .mst_w_chan_t       (cluster_narrow_out_dw_conv_w_chan_t),
      .slv_w_chan_t       (snitch_cluster_pkg::narrow_out_w_chan_t),
      .b_chan_t           (snitch_cluster_pkg::narrow_out_b_chan_t),
      .ar_chan_t          (snitch_cluster_pkg::narrow_out_ar_chan_t),
      .mst_r_chan_t       (cluster_narrow_out_dw_conv_r_chan_t),
      .slv_r_chan_t       (snitch_cluster_pkg::narrow_out_r_chan_t),
      .axi_mst_req_t      (cluster_narrow_out_dw_conv_req_t),
      .axi_mst_resp_t     (cluster_narrow_out_dw_conv_resp_t),
      .axi_slv_req_t      (snitch_cluster_pkg::narrow_out_req_t),
      .axi_slv_resp_t     (snitch_cluster_pkg::narrow_out_resp_t)
    ) i_axi_dw_hwpe (
      .clk_i     (tile_clk),
      .rst_ni    (tile_rst_n),
      .slv_req_i (cluster_narrow_ext_req),
      .slv_resp_o(cluster_narrow_ext_rsp),
      .mst_req_o (cluster_narrow_out_dw_conv_req),
      .mst_resp_i(cluster_narrow_out_dw_conv_rsp)
    );

    axi_cut #(
      .Bypass    (0),
      .aw_chan_t (snitch_cluster_pkg::narrow_out_aw_chan_t),
      .w_chan_t  (cluster_narrow_out_dw_conv_w_chan_t),
      .b_chan_t  (snitch_cluster_pkg::narrow_out_b_chan_t),
      .ar_chan_t (snitch_cluster_pkg::narrow_out_ar_chan_t),
      .r_chan_t  (cluster_narrow_out_dw_conv_r_chan_t),
      .axi_req_t (cluster_narrow_out_dw_conv_req_t),
      .axi_resp_t(cluster_narrow_out_dw_conv_resp_t)
    ) i_cut_ext_narrow_slv (
      .clk_i     (tile_clk),
      .rst_ni    (tile_rst_n),
      .slv_req_i (cluster_narrow_out_dw_conv_req),
      .slv_resp_o(cluster_narrow_out_dw_conv_rsp),
      .mst_req_o (cluster_narrow_out_cut_req),
      .mst_resp_i(cluster_narrow_out_cut_rsp)
    );

    axi_to_tcdm #(
      .axi_req_t (cluster_narrow_out_dw_conv_req_t),
      .axi_rsp_t (cluster_narrow_out_dw_conv_resp_t),
      .tcdm_req_t(hwpectrl_req_t),
      .tcdm_rsp_t(hwpectrl_rsp_t),
      .IdWidth   (snitch_cluster_pkg::NarrowIdWidthOut),
      .AddrWidth (HWPECtrlAddrWidth),
      .DataWidth (HWPECtrlDataWidth)
    ) i_axi_to_hwpe_ctrl (
      .clk_i     (tile_clk),
      .rst_ni    (tile_rst_n),
      .axi_req_i (cluster_narrow_out_cut_req),
      .axi_rsp_o (cluster_narrow_out_cut_rsp),
      .tcdm_req_o(hwpectrl_req),
      .tcdm_rsp_i(hwpectrl_rsp)
    );

    snitch_tcdm_aligner #(
      .tcdm_req_t   (snitch_cluster_pkg::tcdm_dma_req_t),
      .tcdm_rsp_t   (snitch_cluster_pkg::tcdm_dma_rsp_t),
      .DataWidth    (snitch_cluster_pkg::WideDataWidth),
      .TCDMDataWidth(snitch_cluster_pkg::NarrowDataWidth),
      .AddrWidth    (snitch_cluster_pkg::TcdmAddrWidth)
    ) i_snitch_tcdm_aligner (
      .clk_i                (tile_clk),
      .rst_ni               (tile_rst_n),
      .tcdm_req_misaligned_i(cluster_tcdm_ext_req_misaligned),
      .tcdm_req_aligned_o   (cluster_tcdm_ext_req_aligned),
      .tcdm_rsp_aligned_i   (cluster_tcdm_ext_rsp_aligned),
      .tcdm_rsp_misaligned_o(cluster_tcdm_ext_rsp_misaligned)
    );

    snitch_hwpe_subsystem #(
      .tcdm_req_t   (snitch_cluster_pkg::tcdm_dma_req_t),
      .tcdm_rsp_t   (snitch_cluster_pkg::tcdm_dma_rsp_t),
      .periph_req_t (hwpectrl_req_t),
      .periph_rsp_t (hwpectrl_rsp_t),
      .HwpeDataWidth(snitch_cluster_pkg::WideDataWidth),
      .IdWidth      (snitch_cluster_pkg::NarrowIdWidthOut),
      .NrCores      (NrCores),
      .TCDMDataWidth(snitch_cluster_pkg::NarrowDataWidth)
    ) i_snitch_hwpe_subsystem (
      .clk_i          (tile_clk),
      .rst_ni         (tile_rst_n),
      .test_mode_i    (1'b0),
      .tcdm_req_o     (cluster_tcdm_ext_req_misaligned),
      .tcdm_rsp_i     (cluster_tcdm_ext_rsp_misaligned),
      .hwpe_ctrl_req_i(hwpectrl_req),
      .hwpe_ctrl_rsp_o(hwpectrl_rsp),
      .hwpe_evt_o     (mxip)
    );
  end else begin : gen_no_redmul_e
    assign mxip                         = '0;
    assign cluster_tcdm_ext_req_aligned = '0;
    assign cluster_narrow_ext_rsp       = '0;
  end

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
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl),
    .NoLoopback    (1'b0),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .red_wide_req_t(red_wide_req_t),
    .red_wide_rsp_t(red_wide_rsp_t),
    .CollectiveCfg (RouteCfg.CollectiveCfg)
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
    .offload_wide_req_o  (offload_wide_req),
    .offload_wide_rsp_i  (offload_wide_rsp),
    // Narrow Reduction offload port
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  assign floo_req_o                      = router_floo_req_out[West:North];
  assign router_floo_req_in[West:North]  = floo_req_i;
  assign floo_rsp_o                      = router_floo_rsp_out[West:North];
  assign router_floo_rsp_in[West:North]  = floo_rsp_i;
  assign router_floo_wide_in[West:North] = floo_wide_i;
  assign floo_wide_o[West:North]         = router_floo_wide_out[West:North];

  /////////////
  // Chimney //
  /////////////


  floo_nw_chimney #(
    .AxiCfgN             (floo_gwaihir_noc_pkg::AxiCfgN),
    .AxiCfgW             (floo_gwaihir_noc_pkg::AxiCfgW),
    .ChimneyCfgN         (floo_pkg::ChimneyDefaultCfg),
    .ChimneyCfgW         (floo_pkg::ChimneyDefaultCfg),
    .RouteCfg            (floo_gwaihir_noc_pkg::RouteCfg),
    .AtopSupport         (1'b1),
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
    .axi_narrow_in_req_t (snitch_cluster_pkg::narrow_out_req_t),
    .axi_narrow_in_rsp_t (snitch_cluster_pkg::narrow_out_resp_t),
    .axi_narrow_out_req_t(snitch_cluster_pkg::narrow_in_req_t),
    .axi_narrow_out_rsp_t(snitch_cluster_pkg::narrow_in_resp_t),
    .axi_wide_in_req_t   (snitch_cluster_pkg::wide_out_req_t),
    .axi_wide_in_rsp_t   (snitch_cluster_pkg::wide_out_resp_t),
    .axi_wide_out_req_t  (snitch_cluster_pkg::wide_in_req_t),
    .axi_wide_out_rsp_t  (snitch_cluster_pkg::wide_in_resp_t),
    .floo_req_t          (floo_gwaihir_noc_pkg::floo_req_t),
    .floo_rsp_t          (floo_gwaihir_noc_pkg::floo_rsp_t),
    .floo_wide_t         (floo_gwaihir_noc_pkg::floo_wide_t),
    .sram_cfg_t          (snitch_cluster_pkg::sram_cfg_t),
    .user_narrow_struct_t(floo_gwaihir_noc_pkg::collective_axi_narrow_in_user_t),
    .user_wide_struct_t  (floo_gwaihir_noc_pkg::collective_axi_wide_in_user_t)
  ) i_chimney (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .test_enable_i,
    .id_i,
    .route_table_i       ('0),
    .sram_cfg_i          ('0),
    .axi_narrow_in_req_i (cluster_narrow_out_req),
    .axi_narrow_in_rsp_o (cluster_narrow_out_rsp),
    .axi_narrow_out_req_o(chimney_narrow_out_req),
    .axi_narrow_out_rsp_i(chimney_narrow_out_rsp),
    .axi_wide_in_req_i   (cluster_wide_out_req),
    .axi_wide_in_rsp_o   (cluster_wide_out_rsp),
    .axi_wide_out_req_o  (cluster_wide_in_req),
    .axi_wide_out_rsp_i  (cluster_wide_in_rsp),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  addr_decode #(
    .NoIndices(NumDemuxPorts),
    .NoRules  (NumTileAddrMapRules),
    .addr_t   (addr_t),
    .rule_t   (addr_rule_t)
  ) i_addr_decode_aw (
    .addr_i          (chimney_narrow_out_req.aw.addr),
    .addr_map_i      (TileAddrMap),
    .idx_o           (aw_select),
    .dec_valid_o     (),
    .dec_error_o     (),
    .en_default_idx_i(1'b1),
    .default_idx_i   ('0)
  );

  addr_decode #(
    .NoIndices(NumDemuxPorts),
    .NoRules  (NumTileAddrMapRules),
    .addr_t   (addr_t),
    .rule_t   (addr_rule_t)
  ) i_addr_decode_ar (
    .addr_i          (chimney_narrow_out_req.ar.addr),
    .addr_map_i      (TileAddrMap),
    .idx_o           (ar_select),
    .dec_valid_o     (),
    .dec_error_o     (),
    .en_default_idx_i(1'b1),
    .default_idx_i   ('0)
  );

  axi_demux #(
    .AxiIdWidth (AxiCfgN.OutIdWidth),
    .AtopSupport(1'b1),
    .aw_chan_t  (snitch_cluster_pkg::narrow_in_aw_chan_t),
    .w_chan_t   (snitch_cluster_pkg::narrow_in_w_chan_t),
    .b_chan_t   (snitch_cluster_pkg::narrow_in_b_chan_t),
    .ar_chan_t  (snitch_cluster_pkg::narrow_in_ar_chan_t),
    .r_chan_t   (snitch_cluster_pkg::narrow_in_r_chan_t),
    .axi_req_t  (snitch_cluster_pkg::narrow_in_req_t),
    .axi_resp_t (snitch_cluster_pkg::narrow_in_resp_t),
    .NoMstPorts (NumDemuxPorts),
    .MaxTrans   (floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .AxiLookBits(AxiCfgN.OutIdWidth),
    .SpillAr    (1'b0),
    .SpillAw    (1'b0)
  ) i_axi_demux (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .test_i         (test_enable_i),
    .slv_req_i      (chimney_narrow_out_req),
    .slv_aw_select_i(aw_select),
    .slv_ar_select_i(ar_select),
    .slv_resp_o     (chimney_narrow_out_rsp),
    .mst_reqs_o     (axi_demux_out_req),
    .mst_resps_i    (axi_demux_out_rsp)
  );

  assign cluster_narrow_in_req      = axi_demux_out_req[Cluster];
  assign axi_demux_out_rsp[Cluster] = cluster_narrow_in_rsp;

  // The configuration register path does not make use of the wide collective
  // `user` field (it is only relevant for the collective/multicast path into
  // the cluster). Down-convert the demuxed request to the plain narrow AXI
  // type before the AXI-Lite conversion; the struct assign truncates the
  // collective `user` payload down to the plain AXI user width.
  `AXI_ASSIGN_REQ_STRUCT(tile_cfg_demux_req, axi_demux_out_req[TileCfg])
  `AXI_ASSIGN_RESP_STRUCT(axi_demux_out_rsp[TileCfg], tile_cfg_demux_rsp)

  axi_to_axi_lite #(
    .AxiAddrWidth   (AxiCfgN.AddrWidth),
    .AxiDataWidth   (AxiCfgN.DataWidth),
    .AxiIdWidth     (AxiCfgN.OutIdWidth),
    .AxiUserWidth   (AxiCfgN.UserWidth),
    .AxiMaxWriteTxns(floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .AxiMaxReadTxns (floo_pkg::ChimneyDefaultCfg.MaxTxns),
    .full_req_t     (floo_gwaihir_noc_pkg::axi_narrow_out_req_t),
    .full_resp_t    (floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t),
    .lite_req_t     (tile_cfg_axi_lite_req_t),
    .lite_resp_t    (tile_cfg_axi_lite_resp_t)
  ) i_axi_to_axi_lite_tile_cfg (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .test_i    (test_enable_i),
    .slv_req_i (tile_cfg_demux_req),
    .slv_resp_o(tile_cfg_demux_rsp),
    .mst_req_o (tile_cfg_axi_lite_req),
    .mst_resp_i(tile_cfg_axi_lite_rsp)
  );

  axi_lite_dw_converter #(
    .AxiAddrWidth       (AxiCfgN.AddrWidth),
    .AxiSlvPortDataWidth(AxiCfgN.DataWidth),
    .AxiMstPortDataWidth(gw_tile_regs_pkg::GW_TILE_REGS_DATA_WIDTH),
    .axi_lite_aw_t      (tile_cfg_axi_lite_aw_chan_t),
    .axi_lite_slv_w_t   (tile_cfg_axi_lite_w_chan_t),
    .axi_lite_mst_w_t   (tile_cfg_axi_lite_32_w_chan_t),
    .axi_lite_b_t       (tile_cfg_axi_lite_b_chan_t),
    .axi_lite_ar_t      (tile_cfg_axi_lite_ar_chan_t),
    .axi_lite_slv_r_t   (tile_cfg_axi_lite_r_chan_t),
    .axi_lite_mst_r_t   (tile_cfg_axi_lite_32_r_chan_t),
    .axi_lite_slv_req_t (tile_cfg_axi_lite_req_t),
    .axi_lite_slv_res_t (tile_cfg_axi_lite_resp_t),
    .axi_lite_mst_req_t (tile_cfg_axi_lite_32_req_t),
    .axi_lite_mst_res_t (tile_cfg_axi_lite_32_resp_t)
  ) i_axi_lite_dw_converter_tile_cfg (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .slv_req_i(tile_cfg_axi_lite_req),
    .slv_res_o(tile_cfg_axi_lite_rsp),
    .mst_req_o(tile_cfg_axi_lite_32_req),
    .mst_res_i(tile_cfg_axi_lite_32_rsp)
  );

  axi_lite_to_apb #(
    .NoApbSlaves    (1),
    .NoRules        (NumTileApbAddrMapRules),
    .AddrWidth      (AxiCfgN.AddrWidth),
    .DataWidth      (gw_tile_regs_pkg::GW_TILE_REGS_DATA_WIDTH),
    .axi_lite_req_t (tile_cfg_axi_lite_32_req_t),
    .axi_lite_resp_t(tile_cfg_axi_lite_32_resp_t),
    .apb_req_t      (tile_cfg_apb_req_t),
    .apb_resp_t     (tile_cfg_apb_resp_t),
    .rule_t         (addr_rule_t)
  ) i_axi_lite_to_apb_tile_cfg (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .axi_lite_req_i (tile_cfg_axi_lite_32_req),
    .axi_lite_resp_o(tile_cfg_axi_lite_32_rsp),
    .apb_req_o      (tile_cfg_apb_req),
    .apb_resp_i     (tile_cfg_apb_rsp),
    .addr_map_i     (TileApbAddrMap)
  );

  gw_tile_regs i_gw_tile_regs (
    .clk          (clk_i),
    .arst_n       (rst_ni),
    .s_apb_paddr  (tile_cfg_apb_req.paddr[gw_tile_regs_pkg::GW_TILE_REGS_MIN_ADDR_WIDTH-1:0]),
    .s_apb_penable(tile_cfg_apb_req.penable),
    .s_apb_psel   (tile_cfg_apb_req.psel),
    .s_apb_pwrite (tile_cfg_apb_req.pwrite),
    .s_apb_pprot  (tile_cfg_apb_req.pprot),
    .s_apb_pwdata (tile_cfg_apb_req.pwdata),
    .s_apb_pstrb  (tile_cfg_apb_req.pstrb),
    .s_apb_prdata (tile_cfg_apb_rsp.prdata),
    .s_apb_pready (tile_cfg_apb_rsp.pready),
    .s_apb_pslverr(tile_cfg_apb_rsp.pslverr),
    .hwif_out     (hwif_out)
  );

  //////////////////////////
  // Clock Gating & Reset //
  //////////////////////////

  tc_clk_gating i_tc_clk_gating_cluster (
    .clk_i,
    .en_i     (hwif_out.clk.en.value),
    .test_en_i(clk_rst_bypass_i),
    .clk_o    (tile_clk)
  );

`ifdef TARGET_XILINX
  // Using clk cells makes Vivado flag the reset as a clock tree
  assign tile_rst_n = (clk_rst_bypass_i) ? rst_ni : tile_rst_ni;
`else
  tc_clk_mux2 i_tc_reset_mux (
    .clk0_i   (hwif_out.rst.n.value),
    .clk1_i   (rst_ni),
    .clk_sel_i(clk_rst_bypass_i),
    .clk_o    (tile_rst_n)
  );
`endif



endmodule
