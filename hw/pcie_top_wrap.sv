// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Open-source stand-in for the PCIe controller and PHY.
///
/// `pcie_tile` is identical for the open-source and closed-source builds; the
/// bender target `pcie` swaps this module for the one in the closed-source
/// repository, which wraps the real controller. This version has no
/// controller: the subordinate port answers every request with a decode error
/// so that an access to the PCIe window fails fast instead of hanging the NoC,
/// and the manager port stays idle.
///
/// The port list must stay in step with the closed-source `pcie_top_wrap`. The
/// AXI types come from `gwaihir_pkg` rather than from the controller's own
/// package, so that this build needs nothing from the closed-source
/// repository; they are sized to match the controller's ports.
module pcie_top_wrap
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
#(
  /// Implementation specific SRAM signals. Unused here: there are no SRAMs.
  parameter type impl_in_t = logic [14:0]
) (
  // Clk resets
  input logic host_clk_i,
  input logic rst_ni,

  inout wire  pcie_refclk_n,
  inout wire  pcie_refclk_p,
  input logic pcie_button_rst_ni,

  // Serdes
  inout wire [1:0] pcie_rx_p,
  inout wire [1:0] pcie_rx_n,
  inout wire [1:0] pcie_tx_p,
  inout wire [1:0] pcie_tx_n,

  // Test
  input logic test_clk_en_i,
  input logic test_coreclk_i,
  input logic test_rst_en_i,
  input logic test_rst_n_i,
  input logic test_phy_rst_n_i,

  // JTAG
  input  logic jtag_phys_tdi_i,
  input  logic jtag_phys_tck_i,
  input  logic jtag_phys_tms_i,
  input  logic jtag_phys_trst_ni,
  output logic jtag_phys_tdo_o,

  // AXI
  input  pcie_axi_slv_req_t pcie_req_i,
  output pcie_axi_slv_rsp_t pcie_rsp_o,

  output pcie_axi_mst_req_t pcie_req_o,
  input  pcie_axi_mst_rsp_t pcie_rsp_i
);

  // The chimney in front of this port supports ATOPs, so the error slave has to as well.
  axi_err_slv #(
    .AxiIdWidth(AxiCfgN.OutIdWidth),
    .axi_req_t (pcie_axi_slv_req_t),
    .axi_resp_t(pcie_axi_slv_rsp_t),
    .Resp      (axi_pkg::RESP_DECERR),
    .ATOPs     (1'b1)
  ) i_axi_err_slv (
    .clk_i     (host_clk_i),
    .rst_ni    (rst_ni),
    .slv_req_i (pcie_req_i),
    .slv_resp_o(pcie_rsp_o)
  );

  // No controller: the manager port never issues a transaction.
  assign pcie_req_o      = '0;
  assign jtag_phys_tdo_o = 1'b0;

endmodule : pcie_top_wrap
