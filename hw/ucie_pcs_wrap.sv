// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Gabriele Lodi <galodi@ethz.ch>

/// Open-source stand-in for the UCIe PCS macro.
///
/// `ucie_tile` is identical for the open-source and closed-source builds; the
/// bender target `ucie` swaps this module for the one in the closed-source
/// repository, which wraps the real PCS macro. This version has no PCS: the
/// serializer stream is wired straight to the tile's PHY pins, so two tiles
/// connected back to back form a plain loopback.
///
/// The PCS CSR window is still decoded so that software can probe for the
/// macro instead of guessing from the build: every APB access completes
/// immediately with `prdata = 0`, which never matches the macro's ID register.
module ucie_pcs_wrap #(
  parameter int unsigned NumChannels     = 1,
  parameter int unsigned NumBitsPerCycle = 1,
  parameter type         apb_req_t       = logic,
  parameter type         apb_resp_t      = logic
) (
  input  logic                                             clk_i,
  input  logic                                             rst_ni,
  input  logic                                             rst_apb_ni,
  /// Serializer clock enable (slink `ctrl.clk_ena`). Unused here: there is no
  /// PHY clock gate to emulate.
  input  logic                                             clk_ena_i,
  // Serializer-side stream (after the bandwidth-mode adapter)
  input  logic      [NumChannels-1:0][NumBitsPerCycle-1:0] tx_data_i,
  input  logic      [NumChannels-1:0]                      tx_valid_i,
  output logic      [NumChannels-1:0]                      tx_ready_o,
  output logic      [NumChannels-1:0][NumBitsPerCycle-1:0] rx_data_o,
  output logic      [NumChannels-1:0]                      rx_valid_o,
  input  logic      [NumChannels-1:0]                      rx_ready_i,
  // Tile PHY pins (to/from the peer tile)
  output logic      [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_out_o,
  output logic      [NumChannels-1:0]                      phy_data_out_valid_o,
  input  logic      [NumChannels-1:0]                      phy_data_out_ready_i,
  input  logic      [NumChannels-1:0][NumBitsPerCycle-1:0] phy_data_in_i,
  input  logic      [NumChannels-1:0]                      phy_data_in_valid_i,
  output logic      [NumChannels-1:0]                      phy_data_in_ready_o,
  // PCS CSRs (ucie_cfg SAM range)
  input  apb_req_t                                         apb_req_i,
  output apb_resp_t                                        apb_rsp_o
);

  // Passthrough: the serializer drives the PHY pins directly.
  assign phy_data_out_o       = tx_data_i;
  assign phy_data_out_valid_o = tx_valid_i;
  assign tx_ready_o           = phy_data_out_ready_i;
  assign rx_data_o            = phy_data_in_i;
  assign rx_valid_o           = phy_data_in_valid_i;
  assign phy_data_in_ready_o  = rx_ready_i;

  // No CSRs: complete every access at once, reading as zero.
  assign apb_rsp_o.pready  = 1'b1;
  assign apb_rsp_o.prdata  = '0;
  assign apb_rsp_o.pslverr = 1'b0;

endmodule : ucie_pcs_wrap
