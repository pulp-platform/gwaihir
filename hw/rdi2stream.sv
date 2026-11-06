// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module rdi2stream #(
  parameter int unsigned DataWidth = 256,
  /// Register the RDI inputs
  parameter bit          CutRdi    = 1'b1
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

  logic [DataWidth-1:0] rdi_data;
  logic                 rdi_valid;

  if (CutRdi) begin : gen_cut
    logic [DataWidth-1:0] rdi_data_q;
    logic                 rdi_valid_q;

    // The data is taken every cycle, with no enable: `rdi_valid_q` says which
    // words count, so `pl_valid` drives one flop instead of a word's load
    // enable
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rdi_valid_q <= 1'b0;
        rdi_data_q  <= '0;
      end else begin
        rdi_valid_q <= pl_valid_i;
        rdi_data_q  <= pl_data_i;
      end
    end

    assign rdi_data  = rdi_data_q;
    assign rdi_valid = rdi_valid_q;
  end else begin : gen_no_cut
    assign rdi_data  = pl_data_i;
    assign rdi_valid = pl_valid_i;
  end

  logic [DataWidth-1:0] data_q;
  logic pend_d, pend_q;
  logic drained, rx_in, capture, drop;

  assign drained = pend_q & oup_ready_i;
  assign rx_in   = rdi_valid & link_active_i;
  assign capture = rx_in & (~pend_q | drained);
  assign drop    = rx_in & pend_q & ~drained;

  always_comb begin
    pend_d = pend_q;
    if (capture) pend_d = 1'b1;
    else if (drained) pend_d = 1'b0;
  end

  `FF(pend_q, pend_d, 1'b0, clk_i, rst_ni)
  `FFL(data_q, rdi_data, capture, '0, clk_i, rst_ni)

  assign oup_data_o  = data_q;
  assign oup_valid_o = pend_q;

  logic drop_err_d, drop_err_q;
  logic [15:0] drop_cnt_d, drop_cnt_q;

  // The error flag is sticky and the count saturates
  always_comb begin
    drop_err_d = drop_err_q;
    drop_cnt_d = drop_cnt_q;
    if (drop) begin
      drop_err_d = 1'b1;
      if (drop_cnt_q != '1) drop_cnt_d = drop_cnt_q + 16'd1;
    end
  end

  `FF(drop_err_q, drop_err_d, 1'b0, clk_i, rst_ni)
  `FF(drop_cnt_q, drop_cnt_d, '0, clk_i, rst_ni)

  assign rx_drop_err_o   = drop_err_q;
  assign rx_drop_count_o = drop_cnt_q;

endmodule : rdi2stream
