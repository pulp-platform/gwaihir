// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module rdi2stream #(
  parameter int unsigned DataWidth = 256
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic [DataWidth-1:0] pl_data_i,
  input  logic                 pl_valid_i,
  output logic [DataWidth-1:0] oup_data_o,
  output logic                 oup_valid_o,
  input  logic                 oup_ready_i,
  input  logic                 link_active_i,
  output logic                 rx_drop_err_o,
  output logic [         15:0] rx_drop_count_o
);

  logic [DataWidth-1:0] data_q;
  logic                 pend_q;

  wire drained = pend_q & oup_ready_i;
  wire rx_in = pl_valid_i & link_active_i;
  wire capture = rx_in & (~pend_q | drained);
  wire drop = rx_in & pend_q & ~drained;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_q <= '0;
      pend_q <= 1'b0;
    end else if (capture) begin
      data_q <= pl_data_i;
      pend_q <= 1'b1;
    end else if (drained) begin
      pend_q <= 1'b0;
    end
  end

  assign oup_data_o  = data_q;
  assign oup_valid_o = pend_q;

  logic        drop_err_q;
  logic [15:0] drop_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      drop_err_q <= 1'b0;
      drop_cnt_q <= 16'd0;
    end else if (drop) begin
      drop_err_q <= 1'b1;
      if (drop_cnt_q != 16'hFFFF) drop_cnt_q <= drop_cnt_q + 16'd1;
    end
  end

  assign rx_drop_err_o   = drop_err_q;
  assign rx_drop_count_o = drop_cnt_q;

endmodule : rdi2stream
