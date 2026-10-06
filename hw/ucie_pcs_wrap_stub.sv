// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Gabriele Lodi <galodi@ethz.ch>

module ucie_pcs_wrap_stub #(
  parameter int unsigned NumChannels     = 1,
  parameter int unsigned NumBitsPerCycle = 1,
  parameter int unsigned RdiDataWidth    = 256,
  parameter int unsigned RxFifoDepth     = 2,
  parameter type         apb_req_t       = logic,
  parameter type         apb_resp_t      = logic
) (
  input  logic                                             clk_i,
  input  logic                                             rst_ni,
  input  logic                                             rst_apb_ni,
  input  logic                                             clk_ena_i,
  // Serializer-side stream (after the bandwidth-mode adapter)
  input  logic      [NumChannels-1:0][NumBitsPerCycle-1:0] tx_data_i,
  input  logic      [NumChannels-1:0]                      tx_valid_i,
  output logic      [NumChannels-1:0]                      tx_ready_o,
  output logic      [NumChannels-1:0][NumBitsPerCycle-1:0] rx_data_o,
  output logic      [NumChannels-1:0]                      rx_valid_o,
  input  logic      [NumChannels-1:0]                      rx_ready_i,
  // Link control / status
  input  logic                                             link_en_i,
  output logic                                             link_active_o,
  output logic      [            3:0]                      link_state_o,
  output logic                                             link_error_o,
  output logic                                             rx_drop_err_o,
  output logic      [           15:0]                      rx_drop_count_o,
  // PHY reference clock
  input  logic                                             refclk_i,
  // Mainband bumps
  output logic                                             txckp_o,
  output logic                                             txckn_o,
  output logic      [            7:0]                      txdata_o,
  output logic                                             txtrk_o,
  output logic                                             txvld_o,
  input  logic                                             rxckp_i,
  input  logic                                             rxckn_i,
  input  logic      [            7:0]                      rxdata_i,
  input  logic                                             rxtrk_i,
  input  logic                                             rxvld_i,
  // Sideband bumps
  output logic                                             txclksb_o,
  output logic                                             txdatasb_o,
  input  logic                                             rxclksb_i,
  input  logic                                             rxdatasb_i,
  // Analog / I3C bumps
  inout  wire                                              atest0_io,
  inout  wire                                              rref_io,
  inout  wire                                              scl_io,
  inout  wire                                              sda_io,
  // PCS CSRs (ucie_cfg SAM range)
  input  apb_req_t                                         apb_req_i,
  output apb_resp_t                                        apb_rsp_o,
  // Interrupts
  output logic      [            1:0]                      irq_o
);

  assign tx_ready_o = '0;
  assign rx_data_o  = '0;
  assign rx_valid_o = '0;

  assign link_active_o   = 1'b0;
  assign link_state_o    = '0;
  assign link_error_o    = 1'b0;
  assign rx_drop_err_o   = 1'b0;
  assign rx_drop_count_o = '0;

  assign txckp_o    = 1'b0;
  assign txckn_o    = 1'b0;
  assign txdata_o   = '0;
  assign txtrk_o    = 1'b0;
  assign txvld_o    = 1'b0;
  assign txclksb_o  = 1'b0;
  assign txdatasb_o = 1'b0;

  assign apb_rsp_o.pready  = 1'b1;
  assign apb_rsp_o.prdata  = '0;
  assign apb_rsp_o.pslverr = 1'b0;

  assign irq_o = '0;

endmodule : ucie_pcs_wrap_stub
