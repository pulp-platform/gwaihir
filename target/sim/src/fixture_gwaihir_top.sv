// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

module fixture_gwaihir_top;

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;
  import gwaihir_pkg::*;

  `CHESHIRE_TYPEDEF_ALL(, CheshireCfg)

  ///////////
  //  DUT  //
  ///////////

  // verilog_format: off
  logic       clk;
  logic       rst_n;
  logic       test_mode;
  logic [1:0] boot_mode;
  logic       rtc;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_tx;
  logic uart_rx;

  logic i2c_sda_o;
  logic i2c_sda_i;
  logic i2c_sda_en;
  logic i2c_scl_o;
  logic i2c_scl_i;
  logic i2c_scl_en;

  logic                 spih_sck_o;
  logic                 spih_sck_en;
  logic [SpihNumCs-1:0] spih_csb_o;
  logic [SpihNumCs-1:0] spih_csb_en;
  logic [ 3:0]          spih_sd_o;
  logic [ 3:0]          spih_sd_i;
  logic [ 3:0]          spih_sd_en;

  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i;
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  // Set to 1 to bypass tile-specific clock gating and reset (use global signals instead)
  logic   clk_rst_bypass;
  assign  clk_rst_bypass = 1'b0;

  // HyperBus pad wires
  wire                                              hyper_tc_pad_int_0;
  wire [HyperbusNumPhys-1:0][HyperbusNumChips-1:0] hyper_csn;
  wire [HyperbusNumPhys-1:0]                        hyper_ck;
  wire [HyperbusNumPhys-1:0]                        hyper_ckn;
  wire [HyperbusNumPhys-1:0]                        hyper_rwds;
  wire [HyperbusNumPhys-1:0][7:0]                   hyper_dq;
  wire [HyperbusNumPhys-1:0]                        hyper_resetn;
  // verilog_format: on

  gwaihir_top dut (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    .test_mode_i           (test_mode),
    .boot_mode_i           (boot_mode),
    .rtc_i                 (rtc),
    .clk_rst_bypass_i      (clk_rst_bypass),
    .jtag_tck_i            (jtag_tck),
    .jtag_trst_ni          (jtag_trst_n),
    .jtag_tms_i            (jtag_tms),
    .jtag_tdi_i            (jtag_tdi),
    .jtag_tdo_o            (jtag_tdo),
    .jtag_tdo_oe_o         (),
    .uart_tx_o             (uart_tx),
    .uart_rx_i             (uart_rx),
    .uart_rts_no           (),
    .uart_dtr_no           (),
    .uart_cts_ni           (1'b0),
    .uart_dsr_ni           (1'b0),
    .uart_dcd_ni           (1'b0),
    .uart_rin_ni           (1'b0),
    .i2c_sda_o             (i2c_sda_o),
    .i2c_sda_i             (i2c_sda_i),
    .i2c_sda_en_o          (i2c_sda_en),
    .i2c_scl_o             (i2c_scl_o),
    .i2c_scl_i             (i2c_scl_i),
    .i2c_scl_en_o          (i2c_scl_en),
    .spih_sck_o            (spih_sck_o),
    .spih_sck_en_o         (spih_sck_en),
    .spih_csb_o            (spih_csb_o),
    .spih_csb_en_o         (spih_csb_en),
    .spih_sd_o             (spih_sd_o),
    .spih_sd_en_o          (spih_sd_en),
    .spih_sd_i             (spih_sd_i),
    .gpio_i                ('0),
    .gpio_o                (),
    .gpio_en_o             (),
    .apb_req_o             (),
    .apb_rsp_i             ('0),
    .slink_rcv_clk_i       (slink_rcv_clk_i),
    .slink_rcv_clk_o       (slink_rcv_clk_o),
    .slink_i               (slink_i),
    .slink_o               (slink_o),
    .pcie_refclk_n         (),
    .pcie_refclk_p         (),
    .pcie_button_rst_ni    (1'b1),
    .pcie_rx_p             (),
    .pcie_rx_n             (),
    .pcie_tx_p             (),
    .pcie_tx_n             (),
    .pcie_test_clk_en_i    (1'b0),
    .pcie_test_coreclk_i   (1'b0),
    .pcie_test_rst_en_i    (1'b0),
    .pcie_test_rst_n_i     (1'b1),
    .pcie_test_phy_rst_n_i (1'b1),
    .pcie_jtag_phys_tdi_i  (1'b0),
    .pcie_jtag_phys_tck_i  (1'b0),
    .pcie_jtag_phys_tms_i  (1'b0),
    .pcie_jtag_phys_trst_ni(1'b1),
    .pcie_jtag_phys_tdo_o  (),
    // HyperBus pads
    .pad_config_tc_pad_internal_signals_0 (hyper_tc_pad_int_0),
    .pad_hyper_phy0_cs_n_0_pad  (hyper_csn[0][0]),
    .pad_hyper_phy0_cs_n_1_pad  (hyper_csn[0][1]),
    .pad_hyper_phy0_ck_pad      (hyper_ck[0]),
    .pad_hyper_phy0_ck_n_pad    (hyper_ckn[0]),
    .pad_hyper_phy0_rwds_pad    (hyper_rwds[0]),
    .pad_hyper_phy0_dq_b0_pad   (hyper_dq[0][0]),
    .pad_hyper_phy0_dq_b1_pad   (hyper_dq[0][1]),
    .pad_hyper_phy0_dq_b2_pad   (hyper_dq[0][2]),
    .pad_hyper_phy0_dq_b3_pad   (hyper_dq[0][3]),
    .pad_hyper_phy0_dq_b4_pad   (hyper_dq[0][4]),
    .pad_hyper_phy0_dq_b5_pad   (hyper_dq[0][5]),
    .pad_hyper_phy0_dq_b6_pad   (hyper_dq[0][6]),
    .pad_hyper_phy0_dq_b7_pad   (hyper_dq[0][7]),
    .pad_hyper_phy0_reset_n_pad (hyper_resetn[0]),
    .pad_hyper_phy1_cs_n_0_pad  (hyper_csn[1][0]),
    .pad_hyper_phy1_cs_n_1_pad  (hyper_csn[1][1]),
    .pad_hyper_phy1_ck_pad      (hyper_ck[1]),
    .pad_hyper_phy1_ck_n_pad    (hyper_ckn[1]),
    .pad_hyper_phy1_rwds_pad    (hyper_rwds[1]),
    .pad_hyper_phy1_dq_b0_pad   (hyper_dq[1][0]),
    .pad_hyper_phy1_dq_b1_pad   (hyper_dq[1][1]),
    .pad_hyper_phy1_dq_b2_pad   (hyper_dq[1][2]),
    .pad_hyper_phy1_dq_b3_pad   (hyper_dq[1][3]),
    .pad_hyper_phy1_dq_b4_pad   (hyper_dq[1][4]),
    .pad_hyper_phy1_dq_b5_pad   (hyper_dq[1][5]),
    .pad_hyper_phy1_dq_b6_pad   (hyper_dq[1][6]),
    .pad_hyper_phy1_dq_b7_pad   (hyper_dq[1][7]),
    .pad_hyper_phy1_reset_n_pad (hyper_resetn[1])
  );

  //////////////
  // HyperRAM //
  //////////////

  for (genvar i = 0; i < HyperbusNumPhys; i++) begin : gen_hyper_phy
    pullup (hyper_rwds[i]);
    for (genvar j = 0; j < HyperbusNumChips; j++) begin : gen_hyper_chip
      s27ks0641 #(
        .TimingModel ("S27KS0641DPBHI020")
      ) dut ( // `dut` instance name derives from the available SDF hierarchy
        .DQ7      (hyper_dq[i][7]),
        .DQ6      (hyper_dq[i][6]),
        .DQ5      (hyper_dq[i][5]),
        .DQ4      (hyper_dq[i][4]),
        .DQ3      (hyper_dq[i][3]),
        .DQ2      (hyper_dq[i][2]),
        .DQ1      (hyper_dq[i][1]),
        .DQ0      (hyper_dq[i][0]),
        .RWDS     (hyper_rwds[i]),
        .CSNeg    (hyper_csn[i][j]),
        .CK       (hyper_ck[i]),
        .CKNeg    (hyper_ckn[i]),
        .RESETNeg (hyper_resetn[i])
      );
    end
  end

  ////////////////////////
  //  Tristate Adapter  //
  ////////////////////////

  wire                 i2c_sda;
  wire                 i2c_scl;

  wire                 spih_sck;
  wire [SpihNumCs-1:0] spih_csb;
  wire [          3:0] spih_sd;

  vip_cheshire_soc_tristate vip_tristate (.*);

  ///////////
  //  VIP  //
  ///////////

  axi_mst_req_t axi_slink_mst_req;
  axi_mst_rsp_t axi_slink_mst_rsp;

  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

  assign axi_slink_mst_req = '0;

  vip_cheshire_soc #(
    .DutCfg           (CheshireCfg),
    .UseDramSys       (1'b0),
    .axi_ext_llc_req_t(axi_llc_req_t),
    .axi_ext_llc_rsp_t(axi_llc_rsp_t),
    .axi_ext_mst_req_t(axi_mst_req_t),
    .axi_ext_mst_rsp_t(axi_mst_rsp_t)
  ) vip (
    .*
  );

endmodule
