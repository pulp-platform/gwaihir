// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// OTF MX Dequantization — streaming unpacking buffer (StrbWidth-parametric).
//
// 512b-capable rewrite: the previous version emitted a whole 128B FP32 block in a
// single output beat (assumed StrbWidth >= 128, i.e. 1024-bit). This version decodes
// one 33B MX block (1 scale + 32 E5M2) and STREAMS the 128B FP32 result over
// OutBeats = MxFp32BlockBytes/StrbWidth output beats (2 @512b, 1 @1024b, 4 @256b).
//
// Input  side: byte-granular accumulation buffer (2*StrbWidth), unchanged in spirit.
// Output side: a 128B staging register drained StrbWidth bytes per `consumed_i`.
module idma_otf_mxdequant
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth = 128
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  // Input stream (byte-granular): MX-compressed data
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      valid_i,
  output logic [StrbWidth-1:0]      ready_o,
  // Output stream (byte-granular): FP32 data
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,
  // Consumed: downstream consumed this output beat
  input  logic                      consumed_i
);

  localparam int unsigned BufSize     = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;
  localparam int unsigned OutBeats    = MxFp32BlockBytes / StrbWidth;  // 128 / StrbWidth
  localparam int unsigned BeatIdxW    = (OutBeats > 1) ? $clog2(OutBeats) : 1;

  // pragma translate_off
  initial begin
    if ((MxFp32BlockBytes % StrbWidth) != 0)
      $fatal(1, "idma_otf_mxdequant: StrbWidth (%0d) must divide %0d", StrbWidth, MxFp32BlockBytes);
  end
  // pragma translate_on

  // ── Input accumulation buffer ──────────────────────────────────────
  logic [            7:0] buf_q [BufSize];
  logic [OffsetWidth-1:0] off_q;
  logic [            7:0] buf_d [BufSize];
  logic [OffsetWidth-1:0] off_d;

  // ── Output staging (128B FP32 block) ──────────────────────────────
  logic [MxFp32BlockBytes-1:0][7:0] stage_q, stage_d;
  logic                             stage_valid_q, stage_valid_d;
  logic [BeatIdxW-1:0]              beat_q, beat_d;

  // ── Decode one block from the buffer head (combinational) ─────────
  logic [ 7:0] dq_scale;
  logic [31:0] dq_fp32 [MxBlockSize];
  always_comb begin
    dq_scale = buf_q[0];
    for (int i = 0; i < MxBlockSize; i++)
      dq_fp32[i] = mxfp8_byte_to_fp32_prescaled(buf_q[1+i], decode_signed_scale(dq_scale));
  end

  logic [OffsetWidth-1:0] in_count;
  logic                   can_accept, start_decode;

  always_comb begin
    for (int i = 0; i < BufSize; i++) buf_d[i] = buf_q[i];
    off_d         = off_q;
    stage_d       = stage_q;
    stage_valid_d = stage_valid_q;
    beat_d        = beat_q;

    // Output drain: advance beat / release block on consumed_i
    if (stage_valid_q && consumed_i) begin
      if (beat_q == BeatIdxW'(OutBeats-1)) begin
        stage_valid_d = 1'b0;
        beat_d        = '0;
      end else begin
        beat_d = beat_q + 1'b1;
      end
    end

    // Start a new block decode when the output stage is free (post-drain) and a
    // full compressed block is buffered. Pops 33B from the input buffer.
    start_decode = (!stage_valid_d) && (off_q >= OffsetWidth'(MxCompressedBlockBytes));
    if (start_decode) begin
      for (int i = 0; i < MxBlockSize; i++) begin
        stage_d[i*4]   = dq_fp32[i][7:0];
        stage_d[i*4+1] = dq_fp32[i][15:8];
        stage_d[i*4+2] = dq_fp32[i][23:16];
        stage_d[i*4+3] = dq_fp32[i][31:24];
      end
      stage_valid_d = 1'b1;
      beat_d        = '0;
      for (int i = 0; i < BufSize; i++)
        buf_d[i] = ((i + MxCompressedBlockBytes) < BufSize) ? buf_q[i+MxCompressedBlockBytes] : 8'd0;
      off_d = OffsetWidth'(off_q - MxCompressedBlockBytes);
    end

    // Input accept into the (post-pop) buffer. COMPACT the actually-valid lanes
    // (valid_i may be non-contiguous / not lane-0-anchored on misaligned or partial
    // source beats) — copy data_i[i] for each set valid_i[i], in order. This matches
    // the Rust golden (otf_mxdequant compacts valid lanes); copying the first
    // popcount lanes would ingest wrong/garbage bytes and corrupt block scales.
    in_count   = '0;
    can_accept = (off_d + StrbWidth) <= BufSize;
    if ((valid_i != '0) && can_accept) begin
      for (int i = 0; i < StrbWidth; i++)
        if (valid_i[i]) begin
          buf_d[(OffsetWidth-1)'(off_d + in_count)] = data_i[i];
          in_count = in_count + OffsetWidth'(1);
        end
      off_d = off_d + in_count;
    end
    ready_o = can_accept ? '1 : '0;
  end

  // Output beat drive: StrbWidth-byte slice of the staged 128B block
  always_comb begin
    data_o  = '0;
    valid_o = '0;
    if (stage_valid_q) begin
      for (int b = 0; b < StrbWidth; b++)
        data_o[b] = stage_q[beat_q*StrbWidth + b];
      valid_o = '1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < BufSize; i++) buf_q[i] <= 8'd0;
      off_q <= '0; stage_valid_q <= 1'b0; beat_q <= '0;
      for (int i = 0; i < MxFp32BlockBytes; i++) stage_q[i] <= 8'd0;
    end else begin
      for (int i = 0; i < BufSize; i++) buf_q[i] <= buf_d[i];
      off_q <= off_d; stage_valid_q <= stage_valid_d; beat_q <= beat_d;
      stage_q <= stage_d;
    end
  end

endmodule : idma_otf_mxdequant
