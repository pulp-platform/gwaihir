// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// ALCU (Arithmetic, Logic, and Conversion Unit) — top dispatcher.
// Direction B RTL — written from the Rust golden model:
//   crates/vidma_new/src/backend/transport/alcu/detailed.rs
//
// Mux controller: owns all four sub-units (ALU, MxQuant, MxDequant, FpCast),
// dispatches based on opcode, routes ready/valid/data.
//
// NumSimdLanes partitions ALU and FpCast into independent lanes for faster
// synthesis. MxQuant/MxDequant stay monolithic (block-scale is cross-element).
// Default NumSimdLanes=1 preserves monolithic behavior for cosim.

module idma_alcu
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth      = 128,
  parameter int unsigned NumSimdLanes   = 1,
  parameter bit          EnableMultiply = 1'b0,
  parameter bit          EnableFpCast   = 1'b1
) (
  input logic clk_i,
  input logic rst_ni,

  // Port A (head 0)
  input  logic [StrbWidth-1:0][7:0] data_a_i,
  input  logic [StrbWidth-1:0]      valid_a_i,
  output logic [StrbWidth-1:0]      ready_a_o,

  // Port B (head 1)
  input  logic [StrbWidth-1:0][7:0] data_b_i,
  input  logic [StrbWidth-1:0]      valid_b_i,
  output logic [StrbWidth-1:0]      ready_b_o,

  // Output
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,

  // Control
  input logic [7:0] opcode_i,
  input logic       single_head_mode_i,
  input logic       mx_quant_drain_i,
  input logic       fpcast_drain_i,
  input logic       consumed_i
);

  localparam int unsigned LaneWidth = StrbWidth / NumSimdLanes;

  // ── Opcode decode ────────────────────────────────────────────────
  logic is_mx, is_fpcast, is_alu;
  logic is_mx_quant, is_mx_dequant;

  assign is_fpcast     = (opcode_i & OpcodeFpcastMask) != '0;
  assign is_mx         = !is_fpcast && ((opcode_i & OpcodeMxMask) != '0);
  assign is_mx_quant   = is_mx && (opcode_i[0] == 1'b0);
  assign is_mx_dequant = is_mx && (opcode_i[0] == 1'b1);
  assign is_alu        = !is_fpcast && !is_mx;

  // ── Sub-unit output signals ──────────────────────────────────────
  logic [StrbWidth-1:0][7:0] data_alu, data_mxq, data_mxdq, data_fpc;
  logic [StrbWidth-1:0] valid_alu, valid_mxq, valid_mxdq, valid_fpc;
  logic [StrbWidth-1:0] ready_alu_a, ready_alu_b;
  logic [StrbWidth-1:0] ready_mxq, ready_mxdq, ready_fpc;

  // ── ALU: SIMD-partitioned into NumSimdLanes lanes ──────────────
  for (genvar lane = 0; lane < NumSimdLanes; lane++) begin : gen_alu_lane
    idma_otf_alu #(
      .StrbWidth     (LaneWidth),
      .EnableMultiply(EnableMultiply)
    ) i_alu (
      .clk_i,
      .rst_ni,
      .data_a_i          (data_a_i[lane*LaneWidth+:LaneWidth]),
      .valid_a_i         (is_alu ? valid_a_i[lane*LaneWidth+:LaneWidth] : '0),
      .ready_a_o         (ready_alu_a[lane*LaneWidth+:LaneWidth]),
      .data_b_i          (data_b_i[lane*LaneWidth+:LaneWidth]),
      .valid_b_i         (is_alu ? valid_b_i[lane*LaneWidth+:LaneWidth] : '0),
      .ready_b_o         (ready_alu_b[lane*LaneWidth+:LaneWidth]),
      .data_o            (data_alu[lane*LaneWidth+:LaneWidth]),
      .valid_o           (valid_alu[lane*LaneWidth+:LaneWidth]),
      .ready_i           (is_alu ? ready_i[lane*LaneWidth+:LaneWidth] : '0),
      .opcode_i          (opcode_i),
      .single_head_mode_i(single_head_mode_i)
    );
  end

  // ── MX Quant: monolithic (block-scale is cross-element) ─────────
  idma_otf_mxquant #(
    .StrbWidth(StrbWidth)
  ) i_mxquant (
    .clk_i,
    .rst_ni,
    .data_i    (data_a_i),
    .valid_i   (is_mx_quant ? valid_a_i : '0),
    .ready_o   (ready_mxq),
    .data_o    (data_mxq),
    .valid_o   (valid_mxq),
    .ready_i   (is_mx_quant ? ready_i : '0),
    .drain_i   (mx_quant_drain_i),
    .consumed_i(is_mx_quant ? consumed_i : 1'b0)
  );

  // ── MX Dequant: monolithic (sequential unpacking buffer) ────────
  idma_otf_mxdequant #(
    .StrbWidth(StrbWidth)
  ) i_mxdequant (
    .clk_i,
    .rst_ni,
    .data_i    (data_a_i),
    .valid_i   (is_mx_dequant ? valid_a_i : '0),
    .ready_o   (ready_mxdq),
    .data_o    (data_mxdq),
    .valid_o   (valid_mxdq),
    .ready_i   (is_mx_dequant ? ready_i : '0),
    .consumed_i(is_mx_dequant ? consumed_i : 1'b0)
  );

  // ── FP Cast: gated by EnableFpCast to save area when not needed ────
  if (EnableFpCast) begin : gen_fpcast
    idma_otf_fpcast #(
      .StrbWidth(StrbWidth)
    ) i_fpcast (
      .clk_i,
      .rst_ni,
      .data_i    (data_a_i),
      .valid_i   (is_fpcast ? valid_a_i : '0),
      .ready_o   (ready_fpc),
      .data_o    (data_fpc),
      .valid_o   (valid_fpc),
      .ready_i   (is_fpcast ? ready_i : '0),
      .opcode_i  (opcode_i),
      .drain_i   (fpcast_drain_i),
      .consumed_i(is_fpcast ? consumed_i : 1'b0)
    );
  end else begin : gen_no_fpcast
    // Passthrough when FpCast disabled — fpcast opcodes produce input data.
    assign data_fpc  = data_a_i;
    assign valid_fpc = is_fpcast ? valid_a_i : '0;
    assign ready_fpc = is_fpcast ? ready_i : '0;
  end

  // ── Output mux ───────────────────────────────────────────────────
  always_comb begin
    if (is_mx_quant) begin
      data_o    = data_mxq;
      valid_o   = valid_mxq;
      ready_a_o = ready_mxq;
      ready_b_o = '0;
    end else if (is_mx_dequant) begin
      data_o    = data_mxdq;
      valid_o   = valid_mxdq;
      ready_a_o = ready_mxdq;
      ready_b_o = '0;
    end else if (is_fpcast) begin
      data_o    = data_fpc;
      valid_o   = valid_fpc;
      ready_a_o = ready_fpc;
      ready_b_o = '0;
    end else begin
      data_o    = data_alu;
      valid_o   = valid_alu;
      ready_a_o = ready_alu_a;
      ready_b_o = ready_alu_b;
    end
  end

endmodule : idma_alcu
