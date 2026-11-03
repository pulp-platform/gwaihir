// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module stream2rdi #(
  parameter int unsigned DataWidth = 256,
  /// Cut all paths between the stream and the RDI
  parameter bit          CutRdi    = 1'b1
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic [DataWidth-1:0] inp_data_i,
  input  logic                 inp_valid_i,
  output logic                 inp_ready_o,
  output logic [DataWidth-1:0] lp_data_o,
  output logic                 lp_valid_o,
  output logic                 lp_irdy_o,
  input  logic                 pl_trdy_i,
  input  logic                 link_active_i
);

  logic [DataWidth-1:0] rdi_data;
  logic rdi_valid, rdi_ready;

  cc_spill_register #(
    .data_t(logic [DataWidth-1:0]),
    .Bypass(!CutRdi)
  ) i_cut (
    .clk_i,
    .rst_ni,
    .clr_i  (1'b0),
    .valid_i(inp_valid_i),
    .ready_o(inp_ready_o),
    .data_i (inp_data_i),
    .valid_o(rdi_valid),
    .ready_i(rdi_ready),
    .data_o (rdi_data)
  );

  // Send only while the link is ACTIVE
  assign lp_data_o  = rdi_data;
  assign lp_valid_o = rdi_valid & link_active_i;
  assign lp_irdy_o  = link_active_i;
  assign rdi_ready  = pl_trdy_i & link_active_i;

endmodule : stream2rdi
