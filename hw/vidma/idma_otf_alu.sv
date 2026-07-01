// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// Byte-granular on-the-fly ALU for the viDMA datapath.
// Direction B RTL — written from the Rust golden model:
//   crates/vidma_new/src/backend/transport/alcu/otf_alu/detailed.rs
//
// All computation is combinational. The only sequential state is the
// accumulator register (acc_q). Reductions use byte-level wrapping
// arithmetic (NOT $bitstoshortreal).

module idma_otf_alu
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth      = 128,
  /// Gate off OpMul/OpAxpy multipliers to save area when not needed.
  /// Default 0: multipliers removed, OpMul/OpAxpy produce passthrough.
  parameter bit          EnableMultiply = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,

  // Input stream A (byte-granular)
  input  logic [StrbWidth-1:0][7:0] data_a_i,
  input  logic [StrbWidth-1:0]      valid_a_i,
  output logic [StrbWidth-1:0]      ready_a_o,

  // Input stream B (byte-granular)
  input  logic [StrbWidth-1:0][7:0] data_b_i,
  input  logic [StrbWidth-1:0]      valid_b_i,
  output logic [StrbWidth-1:0]      ready_b_o,

  // Output stream (byte-granular)
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,

  // Control
  input logic [7:0] opcode_i,
  input logic       single_head_mode_i
);

  // ── Internal signals ─────────────────────────────────────────────
  logic [4:0] opcode_core;
  assign opcode_core = opcode_i[4:0];

  // Accumulator register
  logic [StrbWidth-1:0][7:0] acc_d, acc_q;

  // IO class from opcode bits [4:3]
  logic [1:0] io_class;
  assign io_class = opcode_core[4:3];

  // Binary op detection (matches Rust AluOp::is_binary())
  logic is_binary;
  assign is_binary = (opcode_core == OpAdd)  ||
                        (opcode_core == OpSub)  ||
                        (opcode_core == OpMul)  ||
                        (opcode_core == OpAxpy) ||
                        (opcode_core == OpAnd)  ||
                        (opcode_core == OpOr)   ||
                        (opcode_core == OpXor);

  // Dual-head mode: binary ops in dual-head mode use data_a and data_b
  logic dual_head_active;
  assign dual_head_active = !single_head_mode_i && is_binary;

  logic both_valid;
  assign both_valid = (valid_a_i != '0) && (valid_b_i != '0);

  // ── Combinational datapath ───────────────────────────────────────
  always_comb begin
    // Default: retain accumulator, clear output
    acc_d   = acc_q;
    data_o  = '0;
    valid_o = '0;

    if (dual_head_active) begin
      // Dual-head path: binary ops with two input streams
      if (both_valid) begin
        unique case (opcode_core)
          OpAdd: for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] + data_b_i[j];
          OpSub: for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] - data_b_i[j];
          OpMul:
          if (EnableMultiply)
            for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] * data_b_i[j];
          else data_o = data_a_i;  // passthrough when multiply disabled
          OpAxpy:
          if (EnableMultiply)
            for (int j = 0; j < StrbWidth; j++) data_o[j] = (acc_q[j] * data_a_i[j]) + data_b_i[j];
          else for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] + data_b_i[j];
          OpAnd: for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] & data_b_i[j];
          OpOr: for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] | data_b_i[j];
          OpXor: for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] ^ data_b_i[j];
          default: data_o = data_a_i;
        endcase
        valid_o = valid_a_i;
        // acc_d unchanged for dual-head
      end
      // If not both_valid, valid_o stays 0 (stall)
    end else begin
      // Single-head path
      unique case (opcode_core)
        // ── Generators (0->N) ────────────────────────────
        // Generators replace data but still flow through the dataflow
        // handshake — valid_o tracks valid_a_i so the ALCU doesn't claim
        // output before input arrives (prevents R/AW credit deadlock).
        OpZeroGen: begin
          data_o  = '0;
          valid_o = valid_a_i;
        end
        OpOnesGen: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = 8'hFF;
          valid_o = valid_a_i;
        end
        OpPrngGen: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = 8'hA5;
          valid_o = valid_a_i;
        end
        OpAccGen: begin
          data_o  = acc_q;
          valid_o = valid_a_i;
        end

        // ── N->N unary/binary-with-acc ───────────────────
        OpPassthrough: begin
          data_o  = data_a_i;
          valid_o = valid_a_i;
        end
        OpNot: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = ~data_a_i[j];
          valid_o = valid_a_i;
        end
        OpAdd: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] + acc_q[j];
          valid_o = valid_a_i;
        end
        OpSub: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] - acc_q[j];
          valid_o = valid_a_i;
        end
        OpMul: begin
          if (EnableMultiply)
            for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] * acc_q[j];
          else data_o = data_a_i;  // passthrough when multiply disabled
          valid_o = valid_a_i;
        end
        OpAxpy: begin
          if (EnableMultiply)
            for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] + (data_a_i[j] * acc_q[j]);
          else for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] + acc_q[j];
          valid_o = valid_a_i;
        end
        OpAnd: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] & acc_q[j];
          valid_o = valid_a_i;
        end
        OpOr: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] | acc_q[j];
          valid_o = valid_a_i;
        end
        OpXor: begin
          for (int j = 0; j < StrbWidth; j++) data_o[j] = data_a_i[j] ^ acc_q[j];
          valid_o = valid_a_i;
        end

        // ── Load accumulator ─────────────────────────────
        OpLoadAcc: begin
          data_o  = data_a_i;
          acc_d   = data_a_i;
          valid_o = valid_a_i;
        end

        // ── Reductions (N->0) — byte-level wrapping ──────
        OpSumReduce: begin
          valid_o = '0;
          for (int j = 0; j < StrbWidth; j++) acc_d[j] = acc_q[j] + data_a_i[j];
        end
        OpMaxReduce: begin
          valid_o = '0;
          for (int j = 0; j < StrbWidth; j++) begin
            if (data_a_i[j] > acc_q[j]) acc_d[j] = data_a_i[j];
            else acc_d[j] = acc_q[j];
          end
        end
        OpMinReduce: begin
          valid_o = '0;
          for (int j = 0; j < StrbWidth; j++) begin
            if (data_a_i[j] < acc_q[j]) acc_d[j] = data_a_i[j];
            else acc_d[j] = acc_q[j];
          end
        end

        default: begin
          data_o  = data_a_i;
          valid_o = valid_a_i;
        end
      endcase
    end
  end

  // ── Ready logic ──────────────────────────────────────────────────
  // Matches Rust eval_ready_only() in detailed.rs
  always_comb begin
    if (dual_head_active) begin
      // Dual-head: both ports ready only when both valid AND downstream ready
      if (both_valid) begin
        ready_a_o = ready_i;
        ready_b_o = ready_i;
      end else begin
        ready_a_o = '0;
        ready_b_o = '0;
      end
    end else begin
      // Single-head: ready depends on IO class
      unique case (io_class)
        2'b00: begin  // Generators: no input needed
          ready_a_o = ready_i;
          ready_b_o = '0;
        end
        2'b01: begin  // N->N maps
          ready_a_o = ready_i;
          ready_b_o = '0;
        end
        2'b10: begin  // Reductions: always consume
          // Binary ops (Or, Xor) in single-head mode: override to N->N
          if (is_binary) begin
            ready_a_o = ready_i;
          end else begin
            ready_a_o = '1;
          end
          ready_b_o = '0;
        end
        default: begin  // 0->0
          ready_a_o = '0;
          ready_b_o = '0;
        end
      endcase
    end
  end

  // ── Accumulator register ─────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc_q <= '0;
    end else begin
      acc_q <= acc_d;
    end
  end

endmodule : idma_otf_alu
