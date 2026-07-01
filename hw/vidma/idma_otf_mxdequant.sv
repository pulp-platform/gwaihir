// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// OTF MX Dequantization — streaming unpacking buffer.
// Direction B RTL — written from the Rust golden model:
//   crates/vidma_new/src/backend/transport/alcu/otf_mxdequant/detailed.rs
//
// Architecture: 2×StrbWidth shift-register unpacking buffer. Input MX-compressed
// bytes are staged, then appended on tick. Output FP32 beats are produced
// when ≥33B are available in the registered buffer (no read-through of
// pending input — output reads from registered state only).

module idma_otf_mxdequant
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth = 128
) (
  input logic clk_i,
  input logic rst_ni,

  // Input stream (byte-granular): MX-compressed data
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      valid_i,
  output logic [StrbWidth-1:0]      ready_o,

  // Output stream (byte-granular): FP32 data
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,

  // Consumed signal: downstream consumed this beat
  input logic consumed_i
);

  localparam int unsigned BufSize = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;

  // ── Registers ────────────────────────────────────────────────────
  logic [            7:0]      unpack_buf_q     [    BufSize];
  logic [OffsetWidth-1:0]      unpack_offset_q;

  // ── Input byte count (contiguous valid from bit 0) ──────────────
  logic [OffsetWidth-1:0]      input_byte_count;

  // Can accept input (checked after consumed pre-shift)
  logic                        can_accept;

  // ── Combinational next-state for output registers ───────────────
  logic [  StrbWidth-1:0][7:0] data_o_d;
  logic [  StrbWidth-1:0]      valid_o_d;

  // Working copy of buffer after consumed pre-shift
  logic [            7:0]      shifted_buf      [    BufSize];
  logic [OffsetWidth-1:0]      shifted_offset;

  // ── Combinational: consumed pre-shift, stage input, produce output
  logic [            7:0]      dequant_scale;
  logic [           31:0]      dequant_fp32     [MxBlockSize];

  always_comb begin
    // Consumed pre-shift: remove consumed block from buffer head
    for (int i = 0; i < BufSize; i++) shifted_buf[i] = unpack_buf_q[i];
    shifted_offset = unpack_offset_q;

    if (consumed_i && (shifted_offset >= MxCompressedBlockBytes)) begin
      for (int i = 0; i < BufSize; i++) begin
        if ((i + MxCompressedBlockBytes) < BufSize)
          shifted_buf[i] = unpack_buf_q[MxCompressedBlockBytes+i];
        else shifted_buf[i] = '0;
      end
      shifted_offset = OffsetWidth'(shifted_offset - MxCompressedBlockBytes);
    end

    // Can accept input (checked after consumed pre-shift)
    can_accept    = (shifted_offset + StrbWidth) <= BufSize;

    // Pre-compute decompressed output from shifted buffer.
    // Decode scale once and reuse for all 32 elements (explicit CSE).
    dequant_scale = shifted_buf[0];
    for (int i = 0; i < MxBlockSize; i++) begin
      dequant_fp32[i] =
          mxfp8_byte_to_fp32_prescaled(shifted_buf[1+i], decode_signed_scale(dequant_scale));
    end

    // Count contiguous valid input bytes (valid_i is always contiguous
    // from bit 0 in the DMA datapath — full beats or trailing partial).
    input_byte_count = '0;
    if ((valid_i != '0) && can_accept) begin
      for (int i = 0; i < StrbWidth; i++) begin
        input_byte_count = input_byte_count + OffsetWidth'(valid_i[i]);
      end
    end

    // Produce output (drives registered outputs)
    data_o_d  = '0;
    valid_o_d = '0;

    if (shifted_offset >= MxCompressedBlockBytes) begin
      for (int i = 0; i < MxBlockSize; i++) begin
        data_o_d[i*4]   = dequant_fp32[i][7:0];
        data_o_d[i*4+1] = dequant_fp32[i][15:8];
        data_o_d[i*4+2] = dequant_fp32[i][23:16];
        data_o_d[i*4+3] = dequant_fp32[i][31:24];
      end
      for (int i = MxFp32BlockBytes; i < StrbWidth; i++) begin
        data_o_d[i] = 8'd0;
      end
      valid_o_d = '1;
    end

    // Ready (combinational, not registered)
    ready_o = can_accept ? '1 : '0;
  end

  // ── Next-state: shifted buffer + pending input append ─────────────
  logic [            7:0] unpack_buf_d    [BufSize];
  logic [OffsetWidth-1:0] unpack_offset_d;

  always_comb begin
    for (int i = 0; i < BufSize; i++) unpack_buf_d[i] = shifted_buf[i];
    unpack_offset_d = shifted_offset;

    // Append input data directly at shifted_offset (skip pending_input
    // indirection — valid_i is contiguous so data_i[0..count-1] are the bytes).
    if (input_byte_count > 0) begin
      for (int i = 0; i < StrbWidth; i++) begin
        if (i < input_byte_count) unpack_buf_d[(OffsetWidth-1)'(unpack_offset_d+i)] = data_i[i];
      end
      unpack_offset_d = unpack_offset_d + input_byte_count;
    end
  end

  // ── Sequential: commit next-state, register outputs ─────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      unpack_offset_q <= '0;
      for (int i = 0; i < BufSize; i++) unpack_buf_q[i] <= '0;
      data_o  <= '0;
      valid_o <= '0;
    end else begin
      data_o  <= data_o_d;
      valid_o <= valid_o_d;
      for (int i = 0; i < BufSize; i++) unpack_buf_q[i] <= unpack_buf_d[i];
      unpack_offset_q <= unpack_offset_d;
    end
  end

endmodule : idma_otf_mxdequant
