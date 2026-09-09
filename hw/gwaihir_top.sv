// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

`include "axi/assign.svh"

module gwaihir_top
  import gwaihir_pkg::*;
  import cheshire_pkg::*;
  import floo_pkg::*;
  import snitch_cluster_wrapper_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import ucie_slink_reg_pkg::*;
(
  input logic       clk_i,
  input logic       rst_ni,
  input logic       test_mode_i,
  input logic [1:0] boot_mode_i,
  input logic       rtc_i,
  input logic       clk_rst_bypass_i,

  // JTAG
  input  logic jtag_tck_i,
  input  logic jtag_trst_ni,
  input  logic jtag_tms_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,
  output logic jtag_tdo_oe_o,

  // UART interface
  output logic uart_tx_o,
  input  logic uart_rx_i,

  // UART modem flow control
  output logic uart_rts_no,
  output logic uart_dtr_no,
  input  logic uart_cts_ni,
  input  logic uart_dsr_ni,
  input  logic uart_dcd_ni,
  input  logic uart_rin_ni,

  // I2C interface
  output logic i2c_sda_o,
  input  logic i2c_sda_i,
  output logic i2c_sda_en_o,
  output logic i2c_scl_o,
  input  logic i2c_scl_i,
  output logic i2c_scl_en_o,

  // SPI host interface
  output logic                 spih_sck_o,
  output logic                 spih_sck_en_o,
  output logic [SpihNumCs-1:0] spih_csb_o,
  output logic [SpihNumCs-1:0] spih_csb_en_o,
  output logic [          3:0] spih_sd_o,
  output logic [          3:0] spih_sd_en_o,
  input  logic [          3:0] spih_sd_i,

  // GPIO interface
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_en_o,

  // APB configuration interfaces
  output csh_apb_req_t  [CshRegExtNumApbSlv-1:0] apb_req_o,
  input  csh_apb_resp_t [CshRegExtNumApbSlv-1:0] apb_rsp_i,

  // Serial link interface
  input  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i,
  output logic [SlinkNumChan-1:0]                    slink_rcv_clk_o,
  input  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i,
  output logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o,

  // PCIe interface
  inout  wire        pcie_refclk_n,
  inout  wire        pcie_refclk_p,
  input  logic       pcie_button_rst_ni,
  inout  wire  [1:0] pcie_rx_p,
  inout  wire  [1:0] pcie_rx_n,
  inout  wire  [1:0] pcie_tx_p,
  inout  wire  [1:0] pcie_tx_n,
  input  logic       pcie_test_clk_en_i,
  input  logic       pcie_test_coreclk_i,
  input  logic       pcie_test_rst_en_i,
  input  logic       pcie_test_rst_n_i,
  input  logic       pcie_test_phy_rst_n_i,
  input  logic       pcie_jtag_phys_tdi_i,
  input  logic       pcie_jtag_phys_tck_i,
  input  logic       pcie_jtag_phys_tms_i,
  input  logic       pcie_jtag_phys_trst_ni,
  output logic       pcie_jtag_phys_tdo_o,

  // AXI ports to DRAM
  output csh_axi_llc_req_t axi_llc_mst_req_o,
  input  csh_axi_llc_rsp_t axi_llc_mst_rsp_i,

  // HyperBus interface
  inout wire [HyperbusNumPadCfg-1:0]                       hyper_pad_config,
  inout wire [  HyperbusNumPhys-1:0]                       hyper_ck,
  inout wire [  HyperbusNumPhys-1:0]                       hyper_ck_n,
  inout wire [  HyperbusNumPhys-1:0][HyperbusNumChips-1:0] hyper_cs_n,
  inout wire [  HyperbusNumPhys-1:0]                       hyper_rwds,
  inout wire [  HyperbusNumPhys-1:0][                 7:0] hyper_dq,
  inout wire [  HyperbusNumPhys-1:0]                       hyper_reset_n
);

  floo_req_t [MeshDim.x-1:0][MeshDim.y-1:0][West:North] floo_req_in, floo_req_out;
  floo_rsp_t [MeshDim.x-1:0][MeshDim.y-1:0][West:North] floo_rsp_in, floo_rsp_out;
  floo_wide_t [MeshDim.x-1:0][MeshDim.y-1:0][West:North] floo_wide_in, floo_wide_out;

  ///////////////////
  // Cluster tiles //
  ///////////////////

  logic [NumClusters-1:0][NrCores-1:0] debug_req, meip, mtip, msip;

  // TODO: Connect the debug and interrupt signals
  assign debug_req = '0;
  assign meip      = '0;
  assign mtip      = '0;
  assign msip      = '0;

  for (genvar c = 0; c < NumClusters; c++) begin : gen_clusters

    localparam int ClusterSamIdx = 2 * c + ClusterX0Y0SamIdx;
    localparam id_t ClusterId = CollectiveSam[ClusterSamIdx].idx.id;
    localparam id_t ClusterPhysicalId = gwaihir_pkg::SamPhysical[ClusterSamIdx].idx;
    localparam int X = int'(ClusterPhysicalId.x);
    localparam int Y = int'(ClusterPhysicalId.y);
    localparam int unsigned HartBaseId = c * NrCores + 1;  // Cheshire is hart 0
    localparam axi_wide_in_addr_t ClusterBaseAddr = Sam[ClusterSamIdx].start_addr;
    localparam axi_wide_in_addr_t ClusterBaseOffset = Sam[ClusterSamIdx].end_addr - ClusterBaseAddr;

    cluster_tile i_cluster_tile (
      .clk_i,
      .rst_ni,
      .test_enable_i        (test_mode_i),
      .clk_rst_bypass_i     (clk_rst_bypass_i),
      .debug_req_i          (debug_req[c]),
      .meip_i               (meip[c]),
      .mtip_i               (mtip[c]),
      .msip_i               (msip[c]),
      .hart_base_id_i       (HartBaseId[9:0]),
      .cluster_base_addr_i  (ClusterBaseAddr),
      .cluster_base_offset_i(ClusterBaseOffset),
      .id_i                 (ClusterId),
      .floo_req_o           (floo_req_out[X][Y]),
      .floo_rsp_i           (floo_rsp_in[X][Y]),
      .floo_wide_o          (floo_wide_out[X][Y]),
      .floo_req_i           (floo_req_in[X][Y]),
      .floo_rsp_o           (floo_rsp_out[X][Y]),
      .floo_wide_i          (floo_wide_in[X][Y])
    );
  end

  ///////////////////
  // Cheshire tile //
  ///////////////////

  // TODO(fischeti): Connect the interrupt signals
  logic [iomsb(NumIrqCtxts*CheshireCfg.NumExtIrqHarts):0] xeip_ext;
  logic [            iomsb(CheshireCfg.NumExtIrqHarts):0] mtip_ext;
  logic [            iomsb(CheshireCfg.NumExtIrqHarts):0] msip_ext;

  localparam id_t CheshireId = CollectiveSam[CheshireInternalSamIdx].idx.id;
  localparam id_t CheshirePhysicalId = SamPhysical[CheshireInternalSamIdx].idx;

  csh_axi_llc_req_t llc_demux_req, hyper_axi_req;
  csh_axi_llc_rsp_t llc_demux_rsp, hyper_axi_rsp;
  csh_apb_req_t  hyper_plat_apb_req;
  csh_apb_resp_t hyper_plat_apb_rsp;
  csh_reg_req_t  hyper_reg_req;
  csh_reg_rsp_t  hyper_reg_rsp;

  cheshire_tile i_cheshire_tile (
    .clk_i,
    .rst_ni,
    .test_mode_i,
    .boot_mode_i,
    .rtc_i,
    .xeip_ext_o          (xeip_ext),
    .mtip_ext_o          (mtip_ext),
    .msip_ext_o          (msip_ext),
    .jtag_tck_i,
    .jtag_trst_ni,
    .jtag_tms_i,
    .jtag_tdi_i,
    .jtag_tdo_o,
    .jtag_tdo_oe_o,
    .uart_tx_o,
    .uart_rx_i,
    .uart_rts_no,
    .uart_dtr_no,
    .uart_cts_ni,
    .uart_dsr_ni,
    .uart_dcd_ni,
    .uart_rin_ni,
    .i2c_sda_o,
    .i2c_sda_i,
    .i2c_sda_en_o,
    .i2c_scl_o,
    .i2c_scl_i,
    .i2c_scl_en_o,
    .spih_sck_o,
    .spih_sck_en_o,
    .spih_csb_o,
    .spih_csb_en_o,
    .spih_sd_o,
    .spih_sd_en_o,
    .spih_sd_i,
    .gpio_i,
    .gpio_o,
    .gpio_en_o,
    .apb_req_o,
    .apb_rsp_i,
    .slink_rcv_clk_i,
    .slink_rcv_clk_o,
    .slink_i,
    .slink_o,
    .axi_llc_mst_req_o   (llc_demux_req),
    .axi_llc_mst_rsp_i   (llc_demux_rsp),
    .hyper_plat_apb_req_o(hyper_plat_apb_req),
    .hyper_plat_apb_rsp_i(hyper_plat_apb_rsp),
    .hyper_reg_req_o     (hyper_reg_req),
    .hyper_reg_rsp_i     (hyper_reg_rsp),
    .id_i                (CheshireId),
    .floo_req_west_o     (floo_req_out[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_rsp_west_i     (floo_rsp_in[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_wide_west_o    (floo_wide_out[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_req_west_i     (floo_req_in[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_rsp_west_o     (floo_rsp_out[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_wide_west_i    (floo_wide_in[CheshirePhysicalId.x][CheshirePhysicalId.y][West]),
    .floo_req_south_o    (floo_req_out[CheshirePhysicalId.x][CheshirePhysicalId.y][South]),
    .floo_rsp_south_i    (floo_rsp_in[CheshirePhysicalId.x][CheshirePhysicalId.y][South]),
    .floo_wide_south_o   (floo_wide_out[CheshirePhysicalId.x][CheshirePhysicalId.y][South]),
    .floo_req_south_i    (floo_req_in[CheshirePhysicalId.x][CheshirePhysicalId.y][South]),
    .floo_rsp_south_o    (floo_rsp_out[CheshirePhysicalId.x][CheshirePhysicalId.y][South]),
    .floo_wide_south_i   (floo_wide_in[CheshirePhysicalId.x][CheshirePhysicalId.y][South])
  );
  assign floo_req_out[CheshirePhysicalId.x][CheshirePhysicalId.y][North]  = '0;
  assign floo_rsp_out[CheshirePhysicalId.x][CheshirePhysicalId.y][North]  = '0;
  assign floo_wide_out[CheshirePhysicalId.x][CheshirePhysicalId.y][North] = '0;
  assign floo_req_out[CheshirePhysicalId.x][CheshirePhysicalId.y][East]   = '0;
  assign floo_rsp_out[CheshirePhysicalId.x][CheshirePhysicalId.y][East]   = '0;
  assign floo_wide_out[CheshirePhysicalId.x][CheshirePhysicalId.y][East]  = '0;

  ////////////////////
  // LLC out demux  //
  ////////////////////

  gw_hyperbus_regs_pkg::gw_hyperbus_regs__out_t hyper_plat_hwif;

  gw_hyperbus_regs i_gw_hyperbus_regs (
    .clk(clk_i),
    .arst_n(rst_ni),
    .s_apb_paddr  (hyper_plat_apb_req.paddr
                  [gw_hyperbus_regs_pkg::GW_HYPERBUS_REGS_MIN_ADDR_WIDTH-1:0]),
    .s_apb_penable(hyper_plat_apb_req.penable),
    .s_apb_psel(hyper_plat_apb_req.psel),
    .s_apb_pwrite(hyper_plat_apb_req.pwrite),
    .s_apb_pprot(hyper_plat_apb_req.pprot),
    .s_apb_pwdata(hyper_plat_apb_req.pwdata),
    .s_apb_pstrb(hyper_plat_apb_req.pstrb),
    .s_apb_prdata(hyper_plat_apb_rsp.prdata),
    .s_apb_pready(hyper_plat_apb_rsp.pready),
    .s_apb_pslverr(hyper_plat_apb_rsp.pslverr),
    .hwif_out(hyper_plat_hwif)
  );

  llc_addr_rule_t [LlcOutNumRules-1:0] llc_addr_map;
  logic [LlcOutSelWidth-1:0] llc_aw_select, llc_ar_select;

  assign llc_addr_map = gen_llc_addr_map(hyper_plat_hwif.shared.to_hyper.value);

  addr_decode #(
    .NoIndices(LlcOutNumMstPort),
    .NoRules  (LlcOutNumRules),
    .addr_t   (csh_addr_t),
    .rule_t   (llc_addr_rule_t)
  ) i_llc_aw_decode (
    .addr_i          (llc_demux_req.aw.addr),
    .addr_map_i      (llc_addr_map),
    .idx_o           (llc_aw_select),
    .dec_valid_o     (),
    .dec_error_o     (),
    .en_default_idx_i(1'b1),
    .default_idx_i   (LlcOutSelWidth'(LlcOutLpddr))
  );

  addr_decode #(
    .NoIndices(LlcOutNumMstPort),
    .NoRules  (LlcOutNumRules),
    .addr_t   (csh_addr_t),
    .rule_t   (llc_addr_rule_t)
  ) i_llc_ar_decode (
    .addr_i          (llc_demux_req.ar.addr),
    .addr_map_i      (llc_addr_map),
    .idx_o           (llc_ar_select),
    .dec_valid_o     (),
    .dec_error_o     (),
    .en_default_idx_i(1'b1),
    .default_idx_i   (LlcOutSelWidth'(LlcOutLpddr))
  );

  logic hyper_clk;

  cc_clk_int_div #(
    .DivValueWidth  (HyperbusClkDivWidth),
    .DefaultDivValue(HyperbusRstClkDiv)
  ) i_hyper_clk_div (
    .clk_i,
    .rst_ni,
    .en_i          (1'b1),
    .test_mode_en_i(test_mode_i),
    .div_i         (hyper_plat_hwif.clk_div.value.value),
    .div_valid_i   (hyper_plat_hwif.clk_div.valid.value),
    .div_ready_o   (),
    .clk_o         (hyper_clk),
    .cycl_count_o  ()
  );

  csh_axi_llc_req_t [LlcOutNumMstPort-1:0] llc_mst_req;
  csh_axi_llc_rsp_t [LlcOutNumMstPort-1:0] llc_mst_rsp;

  assign axi_llc_mst_req_o           = llc_mst_req[LlcOutLpddr];
  assign llc_mst_rsp[LlcOutLpddr]    = axi_llc_mst_rsp_i;
  assign llc_mst_rsp[LlcOutHyperbus] = hyper_axi_rsp;

  assign hyper_axi_req = llc_mst_req[LlcOutHyperbus];

  axi_demux #(
    .AxiIdWidth ($bits(csh_axi_llc_id_t)),
    .AtopSupport(1'b0),
    .aw_chan_t  (csh_axi_llc_aw_chan_t),
    .w_chan_t   (csh_axi_llc_w_chan_t),
    .b_chan_t   (csh_axi_llc_b_chan_t),
    .ar_chan_t  (csh_axi_llc_ar_chan_t),
    .r_chan_t   (csh_axi_llc_r_chan_t),
    .axi_req_t  (csh_axi_llc_req_t),
    .axi_resp_t (csh_axi_llc_rsp_t),
    .NoMstPorts (LlcOutNumMstPort),
    .MaxTrans   (8),
    .AxiLookBits($bits(csh_axi_llc_id_t)),
    .UniqueIds  (1'b0),
    .SpillAw    (1'b1),
    .SpillW     (1'b0),
    .SpillB     (1'b0),
    .SpillAr    (1'b1),
    .SpillR     (1'b0)
  ) i_llc_demux (
    .clk_i,
    .rst_ni,
    .slv_req_i      (llc_demux_req),
    .slv_aw_select_i(llc_aw_select),
    .slv_ar_select_i(llc_ar_select),
    .slv_resp_o     (llc_demux_rsp),
    .mst_reqs_o     (llc_mst_req),
    .mst_resps_i    (llc_mst_rsp)
  );

  //////////////
  // HyperBus //
  //////////////

  csh_axi_llc_aw_chan_t [2**HyperbusAxiLogDepth-1:0] hyper_axi_aw_data;
  csh_axi_llc_w_chan_t  [2**HyperbusAxiLogDepth-1:0] hyper_axi_w_data;
  csh_axi_llc_b_chan_t  [2**HyperbusAxiLogDepth-1:0] hyper_axi_b_data;
  csh_axi_llc_ar_chan_t [2**HyperbusAxiLogDepth-1:0] hyper_axi_ar_data;
  csh_axi_llc_r_chan_t  [2**HyperbusAxiLogDepth-1:0] hyper_axi_r_data;
  logic [HyperbusAxiLogDepth:0] hyper_axi_aw_wptr, hyper_axi_aw_rptr;
  logic [HyperbusAxiLogDepth:0] hyper_axi_w_wptr, hyper_axi_w_rptr;
  logic [HyperbusAxiLogDepth:0] hyper_axi_b_wptr, hyper_axi_b_rptr;
  logic [HyperbusAxiLogDepth:0] hyper_axi_ar_wptr, hyper_axi_ar_rptr;
  logic [HyperbusAxiLogDepth:0] hyper_axi_r_wptr, hyper_axi_r_rptr;

  logic hyper_reg_async_req, hyper_reg_async_ack;
  csh_reg_req_t hyper_reg_async_data;
  logic hyper_reg_async_rsp_req, hyper_reg_async_rsp_ack;
  csh_reg_rsp_t hyper_reg_async_rsp_data;

  axi_cdc_src #(
    .aw_chan_t (csh_axi_llc_aw_chan_t),
    .w_chan_t  (csh_axi_llc_w_chan_t),
    .b_chan_t  (csh_axi_llc_b_chan_t),
    .ar_chan_t (csh_axi_llc_ar_chan_t),
    .r_chan_t  (csh_axi_llc_r_chan_t),
    .axi_req_t (csh_axi_llc_req_t),
    .axi_resp_t(csh_axi_llc_rsp_t),
    .LogDepth  (HyperbusAxiLogDepth),
    .SyncStages(HyperbusCdcSyncStages)
  ) i_hyper_axi_cdc_src (
    .src_clk_i                  (clk_i),
    .src_rst_ni                 (rst_ni),
    .src_req_i                  (hyper_axi_req),
    .src_resp_o                 (hyper_axi_rsp),
    .async_data_master_aw_data_o(hyper_axi_aw_data),
    .async_data_master_aw_wptr_o(hyper_axi_aw_wptr),
    .async_data_master_aw_rptr_i(hyper_axi_aw_rptr),
    .async_data_master_w_data_o (hyper_axi_w_data),
    .async_data_master_w_wptr_o (hyper_axi_w_wptr),
    .async_data_master_w_rptr_i (hyper_axi_w_rptr),
    .async_data_master_b_data_i (hyper_axi_b_data),
    .async_data_master_b_wptr_i (hyper_axi_b_wptr),
    .async_data_master_b_rptr_o (hyper_axi_b_rptr),
    .async_data_master_ar_data_o(hyper_axi_ar_data),
    .async_data_master_ar_wptr_o(hyper_axi_ar_wptr),
    .async_data_master_ar_rptr_i(hyper_axi_ar_rptr),
    .async_data_master_r_data_i (hyper_axi_r_data),
    .async_data_master_r_wptr_i (hyper_axi_r_wptr),
    .async_data_master_r_rptr_o (hyper_axi_r_rptr)
  );

  reg_cdc_src #(
    .CDC_KIND("cdc_4phase"),
    .req_t   (csh_reg_req_t),
    .rsp_t   (csh_reg_rsp_t)
  ) i_hyper_reg_cdc_src (
    .src_clk_i   (clk_i),
    .src_rst_ni  (rst_ni),
    .src_req_i   (hyper_reg_req),
    .src_rsp_o   (hyper_reg_rsp),
    .async_req_o (hyper_reg_async_req),
    .async_ack_i (hyper_reg_async_ack),
    .async_data_o(hyper_reg_async_data),
    .async_req_i (hyper_reg_async_rsp_req),
    .async_ack_o (hyper_reg_async_rsp_ack),
    .async_data_i(hyper_reg_async_rsp_data)
  );

  hyperbus_wrap #(
    .NumChips        (HyperbusNumChips),
    .NumPhys         (HyperbusNumPhys),
    .AxiAddrWidth    (CheshireCfg.AddrWidth),
    .AxiDataWidth    (CheshireCfg.AxiDataWidth),
    .AxiIdWidth      ($bits(csh_axi_llc_id_t)),
    .AxiUserWidth    (CheshireCfg.AxiUserWidth),
    .AxiMaxTrans     (HyperbusAxiMaxTrans),
    .axi_req_t       (csh_axi_llc_req_t),
    .axi_rsp_t       (csh_axi_llc_rsp_t),
    .axi_w_chan_t    (csh_axi_llc_w_chan_t),
    .axi_b_chan_t    (csh_axi_llc_b_chan_t),
    .axi_ar_chan_t   (csh_axi_llc_ar_chan_t),
    .axi_r_chan_t    (csh_axi_llc_r_chan_t),
    .axi_aw_chan_t   (csh_axi_llc_aw_chan_t),
    .RegAddrWidth    (CheshireCfg.AddrWidth),
    .RegDataWidth    (32),
    .MinFreqMHz      (HyperbusMinFreqMHz),
    .reg_req_t       (csh_reg_req_t),
    .reg_rsp_t       (csh_reg_rsp_t),
    .RxFifoLogDepth  (HyperbusRxFifoLogDepth),
    .TxFifoLogDepth  (HyperbusTxFifoLogDepth),
    .RstChipBase     (HyperbusRstChipBase),
    .RstChipSpace    (HyperbusRstChipSpace),
    .RstCfg          (HyperbusRstCfg),
    .PhyStartupCycles(HyperbusPhyStartupCycles),
    .AxiLogDepth     (HyperbusAxiLogDepth),
    .AxiSlaveArWidth ($bits(csh_axi_llc_ar_chan_t) * (2 ** HyperbusAxiLogDepth)),
    .AxiSlaveAwWidth ($bits(csh_axi_llc_aw_chan_t) * (2 ** HyperbusAxiLogDepth)),
    .AxiSlaveBWidth  ($bits(csh_axi_llc_b_chan_t) * (2 ** HyperbusAxiLogDepth)),
    .AxiSlaveRWidth  ($bits(csh_axi_llc_r_chan_t) * (2 ** HyperbusAxiLogDepth)),
    .AxiSlaveWWidth  ($bits(csh_axi_llc_w_chan_t) * (2 ** HyperbusAxiLogDepth)),
    .CdcSyncStages   (HyperbusCdcSyncStages)
  ) i_hyperbus_wrap (
    .clk_i                               (hyper_clk),
    .rst_ni,
    .test_mode_i,
    .axi_slave_ar_data_i                 (hyper_axi_ar_data),
    .axi_slave_ar_wptr_i                 (hyper_axi_ar_wptr),
    .axi_slave_ar_rptr_o                 (hyper_axi_ar_rptr),
    .axi_slave_aw_data_i                 (hyper_axi_aw_data),
    .axi_slave_aw_wptr_i                 (hyper_axi_aw_wptr),
    .axi_slave_aw_rptr_o                 (hyper_axi_aw_rptr),
    .axi_slave_b_data_o                  (hyper_axi_b_data),
    .axi_slave_b_wptr_o                  (hyper_axi_b_wptr),
    .axi_slave_b_rptr_i                  (hyper_axi_b_rptr),
    .axi_slave_r_data_o                  (hyper_axi_r_data),
    .axi_slave_r_wptr_o                  (hyper_axi_r_wptr),
    .axi_slave_r_rptr_i                  (hyper_axi_r_rptr),
    .axi_slave_w_data_i                  (hyper_axi_w_data),
    .axi_slave_w_wptr_i                  (hyper_axi_w_wptr),
    .axi_slave_w_rptr_o                  (hyper_axi_w_rptr),
    .reg_async_mst_req_i                 (hyper_reg_async_req),
    .reg_async_mst_ack_o                 (hyper_reg_async_ack),
    .reg_async_mst_data_i                (hyper_reg_async_data),
    .reg_async_mst_req_o                 (hyper_reg_async_rsp_req),
    .reg_async_mst_ack_i                 (hyper_reg_async_rsp_ack),
    .reg_async_mst_data_o                (hyper_reg_async_rsp_data),
    .pad_config_tc_pad_internal_signals_0(hyper_pad_config[0]),
    .pad_hyper_phy0_cs_n_0_pad           (hyper_cs_n[0][0]),
    .pad_hyper_phy0_cs_n_1_pad           (hyper_cs_n[0][1]),
    .pad_hyper_phy0_ck_pad               (hyper_ck[0]),
    .pad_hyper_phy0_ck_n_pad             (hyper_ck_n[0]),
    .pad_hyper_phy0_rwds_pad             (hyper_rwds[0]),
    .pad_hyper_phy0_dq_b0_pad            (hyper_dq[0][0]),
    .pad_hyper_phy0_dq_b1_pad            (hyper_dq[0][1]),
    .pad_hyper_phy0_dq_b2_pad            (hyper_dq[0][2]),
    .pad_hyper_phy0_dq_b3_pad            (hyper_dq[0][3]),
    .pad_hyper_phy0_dq_b4_pad            (hyper_dq[0][4]),
    .pad_hyper_phy0_dq_b5_pad            (hyper_dq[0][5]),
    .pad_hyper_phy0_dq_b6_pad            (hyper_dq[0][6]),
    .pad_hyper_phy0_dq_b7_pad            (hyper_dq[0][7]),
    .pad_hyper_phy0_reset_n_pad          (hyper_reset_n[0]),
    .pad_hyper_phy1_cs_n_0_pad           (hyper_cs_n[1][0]),
    .pad_hyper_phy1_cs_n_1_pad           (hyper_cs_n[1][1]),
    .pad_hyper_phy1_ck_pad               (hyper_ck[1]),
    .pad_hyper_phy1_ck_n_pad             (hyper_ck_n[1]),
    .pad_hyper_phy1_rwds_pad             (hyper_rwds[1]),
    .pad_hyper_phy1_dq_b0_pad            (hyper_dq[1][0]),
    .pad_hyper_phy1_dq_b1_pad            (hyper_dq[1][1]),
    .pad_hyper_phy1_dq_b2_pad            (hyper_dq[1][2]),
    .pad_hyper_phy1_dq_b3_pad            (hyper_dq[1][3]),
    .pad_hyper_phy1_dq_b4_pad            (hyper_dq[1][4]),
    .pad_hyper_phy1_dq_b5_pad            (hyper_dq[1][5]),
    .pad_hyper_phy1_dq_b6_pad            (hyper_dq[1][6]),
    .pad_hyper_phy1_dq_b7_pad            (hyper_dq[1][7]),
    .pad_hyper_phy1_reset_n_pad          (hyper_reset_n[1])
  );

  //////////////
  // Mem tile //
  //////////////

  for (genvar m = 0; m < NumMemTiles; m++) begin : gen_memtile
    localparam logic [$bits(sam_idx_e)-1:0] MemTileSamIdx = L2SpmNumAddrRules * m + L2Spm0SamIdx;
    localparam id_t MemTileId = CollectiveSam[MemTileSamIdx].idx.id;
    localparam id_t MemTilePhysicalId = SamPhysical[MemTileSamIdx].idx;
    localparam int MemTileX = int'(MemTilePhysicalId.x);
    localparam int MemTileY = int'(MemTilePhysicalId.y);
    // Per-tile L2 SPM size
    localparam int unsigned MemTileSpmSize = mem_tile_size(m);

    if (MemTileSpmSize == MemTileSizeSmall) begin : gen_memtile_impl
      mem_tile_small #(
`ifndef TARGET_SYNTHESIS
        .MemTileId(int'(m))
`endif
      ) i_mem_tile (
        .clk_i,
        .rst_ni,
        .test_enable_i   (test_mode_i),
        .clk_rst_bypass_i(clk_rst_bypass_i),
        .id_i            (MemTileId),
        .samidx_i        (MemTileSamIdx),
        .floo_req_o      (floo_req_out[MemTileX][MemTileY]),
        .floo_rsp_i      (floo_rsp_in[MemTileX][MemTileY]),
        .floo_wide_o     (floo_wide_out[MemTileX][MemTileY]),
        .floo_req_i      (floo_req_in[MemTileX][MemTileY]),
        .floo_rsp_o      (floo_rsp_out[MemTileX][MemTileY]),
        .floo_wide_i     (floo_wide_in[MemTileX][MemTileY])
      );
    end else if (MemTileSpmSize == MemTileSizeLarge) begin : gen_memtile_impl
      mem_tile_large #(
`ifndef TARGET_SYNTHESIS
        .MemTileId(int'(m))
`endif
      ) i_mem_tile (
        .clk_i,
        .rst_ni,
        .test_enable_i   (test_mode_i),
        .clk_rst_bypass_i(clk_rst_bypass_i),
        .id_i            (MemTileId),
        .samidx_i        (MemTileSamIdx),
        .floo_req_o      (floo_req_out[MemTileX][MemTileY]),
        .floo_rsp_i      (floo_rsp_in[MemTileX][MemTileY]),
        .floo_wide_o     (floo_wide_out[MemTileX][MemTileY]),
        .floo_req_i      (floo_req_in[MemTileX][MemTileY]),
        .floo_rsp_o      (floo_rsp_out[MemTileX][MemTileY]),
        .floo_wide_i     (floo_wide_in[MemTileX][MemTileY])
      );
    end else begin : gen_memtile_impl
      // Only the two hard-coded mem tile flavours exist, so a SAM window whose
      // size matches neither has no implementation to instantiate. Fail at
      // elaboration instead of silently leaving the tile out of the NoC.
      $fatal(
          1,
          "[gwaihir_top] Mem tile %0d has unsupported SPM size 0x%0h (expected 0x%0h or 0x%0h).",
          m,
          MemTileSpmSize,
          MemTileSizeSmall,
          MemTileSizeLarge
      );
    end
  end

  ////////////////
  // UCIe tiles //
  ////////////////

  logic [NumUcieTiles-1:0][NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_out;
  logic [NumUcieTiles-1:0][NumChannels-1:0]                      phy_data_out_valid;
  logic [NumUcieTiles-1:0][NumChannels-1:0]                      phy_data_out_ready;
  logic [NumUcieTiles-1:0][NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_in;
  logic [NumUcieTiles-1:0][NumChannels-1:0]                      phy_data_in_valid;
  logic [NumUcieTiles-1:0][NumChannels-1:0]                      phy_data_in_ready;

  localparam int Ucie0X = int'(SamPhysical[Ucie0SamIdx].idx.x);
  localparam int Ucie0Y = int'(SamPhysical[Ucie0SamIdx].idx.y);
  localparam int Ucie1X = int'(SamPhysical[Ucie1SamIdx].idx.x);
  localparam int Ucie1Y = int'(SamPhysical[Ucie1SamIdx].idx.y);

  ucie_tile i_ucie_tile0 (
    .clk_i,
    .rst_ni,
    .test_enable_i       (test_mode_i),
    .id_i                (Sam[Ucie0SamIdx].idx),
    .samidx_i            (Ucie0SamIdx),
    // ucie0 (chiplet0) ingress is pass-through.
    .ucie_id_i           (1'b0),
    .floo_req_o          (floo_req_out[Ucie0X][Ucie0Y]),
    .floo_rsp_i          (floo_rsp_in[Ucie0X][Ucie0Y]),
    .floo_wide_o         (floo_wide_out[Ucie0X][Ucie0Y]),
    .floo_req_i          (floo_req_in[Ucie0X][Ucie0Y]),
    .floo_rsp_o          (floo_rsp_out[Ucie0X][Ucie0Y]),
    .floo_wide_i         (floo_wide_in[Ucie0X][Ucie0Y]),
    // loopback
    .phy_data_out_o      (phy_data_out[0]),
    .phy_data_out_valid_o(phy_data_out_valid[0]),
    .phy_data_out_ready_i(phy_data_out_ready[0]),
    .phy_data_in_i       (phy_data_in[0]),
    .phy_data_in_valid_i (phy_data_in_valid[0]),
    .phy_data_in_ready_o (phy_data_in_ready[0])
  );

  ucie_tile i_ucie_tile1 (
    .clk_i,
    .rst_ni,
    .test_enable_i       (test_mode_i),
    .id_i                (Sam[Ucie1SamIdx].idx),
    .samidx_i            (Ucie1SamIdx),
    // ucie1 (chiplet1) ingress applies the half-shift.
    .ucie_id_i           (1'b1),
    .floo_req_o          (floo_req_out[Ucie1X][Ucie1Y]),
    .floo_rsp_i          (floo_rsp_in[Ucie1X][Ucie1Y]),
    .floo_wide_o         (floo_wide_out[Ucie1X][Ucie1Y]),
    .floo_req_i          (floo_req_in[Ucie1X][Ucie1Y]),
    .floo_rsp_o          (floo_rsp_out[Ucie1X][Ucie1Y]),
    .floo_wide_i         (floo_wide_in[Ucie1X][Ucie1Y]),
    // loopback
    .phy_data_out_o      (phy_data_out[1]),
    .phy_data_out_valid_o(phy_data_out_valid[1]),
    .phy_data_out_ready_i(phy_data_out_ready[1]),
    .phy_data_in_i       (phy_data_in[1]),
    .phy_data_in_valid_i (phy_data_in_valid[1]),
    .phy_data_in_ready_o (phy_data_in_ready[1])
  );

  // loopback UCIe[0] -> UCIe[1]: connect TX0 -> RX1
  assign phy_data_in[1]        = phy_data_out[0];
  assign phy_data_in_valid[1]  = phy_data_out_valid[0];
  assign phy_data_out_ready[0] = phy_data_in_ready[1];

  // loopback UCIe[1] -> UCIe[0]: connect TX1 -> RX0
  assign phy_data_in[0]        = phy_data_out[1];
  assign phy_data_in_valid[0]  = phy_data_out_valid[1];
  assign phy_data_out_ready[1] = phy_data_in_ready[0];

  ////////////////
  // PCIe tile  //
  ////////////////

  localparam id_t PCIeId = Sam[PcieSamIdx].idx;
  localparam id_t PCIeTilePhysicalId = SamPhysical[PcieSamIdx].idx;
  localparam int PCIeTileX = int'(PCIeTilePhysicalId.x);
  localparam int PCIeTileY = int'(PCIeTilePhysicalId.y);

  pcie_tile i_pcie_tile (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .test_enable_i    (test_mode_i),
    .pcie_refclk_n,
    .pcie_refclk_p,
    .pcie_button_rst_ni,
    .pcie_rx_p,
    .pcie_rx_n,
    .pcie_tx_p,
    .pcie_tx_n,
    .test_clk_en_i    (pcie_test_clk_en_i),
    .test_coreclk_i   (pcie_test_coreclk_i),
    .test_rst_en_i    (pcie_test_rst_en_i),
    .test_rst_n_i     (pcie_test_rst_n_i),
    .test_phy_rst_n_i (pcie_test_phy_rst_n_i),
    .jtag_phys_tdi_i  (pcie_jtag_phys_tdi_i),
    .jtag_phys_tck_i  (pcie_jtag_phys_tck_i),
    .jtag_phys_tms_i  (pcie_jtag_phys_tms_i),
    .jtag_phys_trst_ni(pcie_jtag_phys_trst_ni),
    .jtag_phys_tdo_o  (pcie_jtag_phys_tdo_o),
    .id_i             (PCIeId),
    .floo_req_east_o  (floo_req_out[PCIeTileX][PCIeTileY][East]),
    .floo_rsp_east_i  (floo_rsp_in[PCIeTileX][PCIeTileY][East]),
    .floo_wide_east_o (floo_wide_out[PCIeTileX][PCIeTileY][East]),
    .floo_req_east_i  (floo_req_in[PCIeTileX][PCIeTileY][East]),
    .floo_rsp_east_o  (floo_rsp_out[PCIeTileX][PCIeTileY][East]),
    .floo_wide_east_i (floo_wide_in[PCIeTileX][PCIeTileY][East]),
    .floo_req_south_o (floo_req_out[PCIeTileX][PCIeTileY][South]),
    .floo_rsp_south_i (floo_rsp_in[PCIeTileX][PCIeTileY][South]),
    .floo_wide_south_o(floo_wide_out[PCIeTileX][PCIeTileY][South]),
    .floo_req_south_i (floo_req_in[PCIeTileX][PCIeTileY][South]),
    .floo_rsp_south_o (floo_rsp_out[PCIeTileX][PCIeTileY][South]),
    .floo_wide_south_i(floo_wide_in[PCIeTileX][PCIeTileY][South])
  );
  assign floo_req_out[PCIeTileX][PCIeTileY][West]   = '0;
  assign floo_rsp_out[PCIeTileX][PCIeTileY][West]   = '0;
  assign floo_wide_out[PCIeTileX][PCIeTileY][West]  = '0;
  assign floo_req_out[PCIeTileX][PCIeTileY][North]  = '0;
  assign floo_rsp_out[PCIeTileX][PCIeTileY][North]  = '0;
  assign floo_wide_out[PCIeTileX][PCIeTileY][North] = '0;

  ////////////////
  // Dummy tile //
  ////////////////

  for (genvar d = 0; d < NumDummyTiles; d++) begin : gen_dummytiles

    localparam id_t DummyTileId = DummyIdx[d];
    localparam int DummyTileX = int'(DummyPhysicalIdx[d].x);
    localparam int DummyTileY = int'(DummyPhysicalIdx[d].y);

    dummy_tile i_dummy_tile (
      .clk_i,
      .rst_ni,
      .test_enable_i(test_mode_i),
      .id_i         (DummyTileId),
      .floo_req_o   (floo_req_out[DummyTileX][DummyTileY]),
      .floo_rsp_i   (floo_rsp_in[DummyTileX][DummyTileY]),
      .floo_wide_o  (floo_wide_out[DummyTileX][DummyTileY]),
      .floo_req_i   (floo_req_in[DummyTileX][DummyTileY]),
      .floo_rsp_o   (floo_rsp_out[DummyTileX][DummyTileY]),
      .floo_wide_i  (floo_wide_in[DummyTileX][DummyTileY])
    );
  end

  /////////////////////
  // NoC Connections //
  /////////////////////

  for (genvar x = 0; x < MeshDim.x; x++) begin : gen_x
    for (genvar y = 0; y < MeshDim.y; y++) begin : gen_y
      for (genvar d = int'(North); d <= int'(West); d++) begin : gen_dir
        localparam route_direction_e Dir = route_direction_e'(d);
        if (is_tie_off(x, y, Dir)) begin : gen_tie_off
          assign floo_req_in[x][y][Dir]  = '0;
          assign floo_rsp_in[x][y][Dir]  = '0;
          assign floo_wide_in[x][y][Dir] = '0;
        end else begin : gen_con
          localparam int Xn = neighbor_x(x, Dir);
          localparam int Yn = neighbor_y(y, Dir);
          localparam route_direction_e Dirn = opposite_dir(Dir);
          assign floo_req_in[x][y][Dir]  = floo_req_out[Xn][Yn][Dirn];
          assign floo_rsp_in[x][y][Dir]  = floo_rsp_out[Xn][Yn][Dirn];
          assign floo_wide_in[x][y][Dir] = floo_wide_out[Xn][Yn][Dirn];
        end
      end
    end
  end

endmodule
