// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// OTF MX Quantization — streaming packing buffer.
// Direction B RTL — written from the Rust golden model:
//   crates/vidma_new/src/backend/transport/alcu/otf_mxquant/detailed.rs
//
// Architecture: 2×StrbWidth shift-register packing buffer. Input FP32
// beats are quantized to MX E5M2 blocks (33B each: 1B scale + 32B data)
// and appended to the buffer. Output beats are presented from the buffer
// head when enough data has accumulated (≥StrbWidth bytes).

module idma_otf_mxquant
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth = 128
) (
  input logic clk_i,
  input logic rst_ni,

  // Input stream (byte-granular): FP32 data, 128B = 32 FP32 elements
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      valid_i,
  output logic [StrbWidth-1:0]      ready_o,

  // Output stream (byte-granular): MX-compressed data
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,

  // Drain signal: emit partial beat from buffer residual
  input logic drain_i,
  // Consumed signal: downstream consumed this beat
  input logic consumed_i
);

  localparam int unsigned BufSize = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;

  // ── Registers ────────────────────────────────────────────────────
  logic [            7:0] pack_buf_q    [    BufSize];
  logic [OffsetWidth-1:0] pack_offset_q;

  // ── Combinational next-state ─────────────────────────────────────
  logic [            7:0] pack_buf_d    [    BufSize];
  logic [OffsetWidth-1:0] pack_offset_d;

  // ── Quantize one MX block ────────────────────────────────────────
  logic [           31:0] fp32_bits     [MxBlockSize];
  logic [            7:0] block_scale;
  logic [            7:0] mxfp8_bytes   [MxBlockSize];

  always_comb begin
    for (int i = 0; i < MxBlockSize; i++) begin
      fp32_bits[i] = {data_i[i*4+3], data_i[i*4+2], data_i[i*4+1], data_i[i*4]};
    end
    // Compute block scale once, decode once, reuse for all 32 elements.
    block_scale = compute_block_scale_with_bias(fp32_bits, E5m2Bias);
    for (int i = 0; i < MxBlockSize; i++) begin
      mxfp8_bytes[i] = fp32_to_mxfp8_byte_prescaled(fp32_bits[i], decode_signed_scale(block_scale));
    end
  end

  // ── Combinational next-state for output registers ───────────────
  logic [StrbWidth-1:0][7:0] data_o_d;
  logic [StrbWidth-1:0]      valid_o_d;

  // Can accept input after consumed pre-shift
  logic                      can_accept;

  // ── Main combinational logic ─────────────────────────────────────
  always_comb begin
    // Start from registered state
    for (int i = 0; i < BufSize; i++) pack_buf_d[i] = pack_buf_q[i];
    pack_offset_d = pack_offset_q;

    // Consumed pre-shift: remove output beat from buffer head (combinational).
    // Handles both full beats (pack_offset >= StrbWidth) and drain partial
    // beats (0 < pack_offset < StrbWidth). Without the partial-beat case,
    // drain residuals are never cleared, causing the drain phase to never
    // exit (deadlock). Matches Rust model: consumed_bytes = min(offset, SW).
    if (consumed_i && (pack_offset_d > 0)) begin
      if (pack_offset_d >= StrbWidth) begin
        for (int i = 0; i < BufSize; i++) begin
          if ((i + StrbWidth) < BufSize) pack_buf_d[i] = pack_buf_d[i+StrbWidth];
          else pack_buf_d[i] = '0;
        end
        pack_offset_d = OffsetWidth'(pack_offset_d - StrbWidth);
      end else begin
        // Drain partial beat: consumed < StrbWidth bytes
        pack_offset_d = 0;
        for (int i = 0; i < BufSize; i++) pack_buf_d[i] = '0;
      end
    end

    // Can accept input (checked after consumed pre-shift)
    can_accept = (pack_offset_d + MxCompressedBlockBytes) <= BufSize;

    // Quantize input beat and append to packing buffer
    if ((valid_i != '0) && can_accept) begin
      pack_buf_d[pack_offset_d[OffsetWidth-2:0]] = block_scale;
      pack_offset_d                              = OffsetWidth'(pack_offset_d + 1);
      for (int i = 0; i < MxBlockSize; i++) begin
        pack_buf_d[pack_offset_d[OffsetWidth-2:0]] = mxfp8_bytes[i];
        pack_offset_d                              = OffsetWidth'(pack_offset_d + 1);
      end
    end

    // Present output from packing buffer (drives registered outputs)
    if (pack_offset_d >= StrbWidth) begin
      for (int i = 0; i < StrbWidth; i++) data_o_d[i] = pack_buf_d[i];
      valid_o_d = '1;
    end else if (drain_i && (pack_offset_d > 0)) begin
      for (int i = 0; i < StrbWidth; i++) begin
        if (i < pack_offset_d) data_o_d[i] = pack_buf_d[i];
        else data_o_d[i] = 8'd0;
      end
      for (int i = 0; i < StrbWidth; i++) begin
        valid_o_d[i] = (i < pack_offset_d) ? 1'b1 : 1'b0;
      end
    end else begin
      data_o_d  = '0;
      valid_o_d = '0;
    end

    // Ready: accept input if buffer has room (combinational, not registered)
    ready_o = can_accept ? '1 : '0;
  end

  // ── Sequential: commit state, register outputs ─────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pack_offset_q <= '0;
      for (int i = 0; i < BufSize; i++) pack_buf_q[i] <= '0;
      data_o  <= '0;
      valid_o <= '0;
    end else begin
      data_o  <= data_o_d;
      valid_o <= valid_o_d;
      for (int i = 0; i < BufSize; i++) pack_buf_q[i] <= pack_buf_d[i];
      pack_offset_q <= pack_offset_d;
    end
  end

endmodule : idma_otf_mxquant
