// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module stream2rdi #(
  parameter int unsigned DataWidth = 256
) (
  input  logic [DataWidth-1:0] inp_data_i,
  input  logic                 inp_valid_i,
  output logic                 inp_ready_o,
  output logic [DataWidth-1:0] lp_data_o,
  output logic                 lp_valid_o,
  output logic                 lp_irdy_o,
  input  logic                 pl_trdy_i,
  input  logic                 link_active_i
);

  assign lp_data_o   = inp_data_i;
  assign lp_valid_o  = inp_valid_i & link_active_i;
  assign lp_irdy_o   = link_active_i;
  assign inp_ready_o = pl_trdy_i & link_active_i;

endmodule : stream2rdi
