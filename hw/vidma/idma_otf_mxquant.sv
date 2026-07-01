// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// OTF MX Quantization — StrbWidth-parametric, FP32 + FP16 input.
//
// Collects a 32-element block over BeatsPerBlock input beats (FP32: 4B/elem,
// FP16: 2B/elem, widened to FP32 via fp16_bits_to_fp32), quantizes to one 33B MX
// block ([1B E8M0 scale][32B E5M2]), and packs into StrbWidth-wide output beats via
// a 2*StrbWidth pack buffer (inline-33B layout). Read-bound: accepts a full input
// beat every cycle as long as the pack buffer has room (it drains fast: 33B out vs
// 128B/64B in per block).
module idma_otf_mxquant
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth = 128
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      valid_i,
  output logic [StrbWidth-1:0]      ready_o,
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,
  input  logic                      drain_i,
  input  logic                      consumed_i,
  input  logic                      src_fp16_i   // 1: FP16 input, 0: FP32 input
);

  localparam int unsigned BufSize     = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;
  localparam int unsigned ElemsFP32   = StrbWidth / 4;            // FP32 elems / beat
  localparam int unsigned ElemsFP16   = StrbWidth / 2;            // FP16 elems / beat
  localparam int unsigned FillW       = $clog2(MxBlockSize) + 1;

  // ── Block element collection (in the FP32 domain) ─────────────────
  logic [31:0]      elem_q [MxBlockSize];
  logic [FillW-1:0] fill_q;
  logic [31:0]      elem_d [MxBlockSize];
  logic [FillW-1:0] fill_d;

  // ── Output pack buffer (inline 33B) ───────────────────────────────
  logic [            7:0] pack_q [BufSize];
  logic [OffsetWidth-1:0] pack_off_q;
  logic [            7:0] pack_d [BufSize];
  logic [OffsetWidth-1:0] pack_off_d;
  logic [StrbWidth-1:0][7:0] data_o_d;
  logic [StrbWidth-1:0]      valid_o_d;

  // Widen this beat's elements to FP32 (FP16 path uses the exact widen) and mark each
  // element valid iff ALL its source bytes are valid — so partial / non-contiguous /
  // misaligned beats only ever contribute whole, valid elements (matches the golden's
  // valid-lane compaction; using fixed lane positions would ingest garbage).
  logic [31:0] in_elem [ElemsFP16];
  logic [ElemsFP16-1:0] elem_valid;
  always_comb begin
    for (int e = 0; e < ElemsFP16; e++) begin
      if (src_fp16_i) begin
        in_elem[e]    = fp16_bits_to_fp32({data_i[e*2+1], data_i[e*2]});
        elem_valid[e] = valid_i[e*2] & valid_i[e*2+1];
      end else if (e < ElemsFP32) begin
        in_elem[e]    = {data_i[e*4+3], data_i[e*4+2], data_i[e*4+1], data_i[e*4]};
        elem_valid[e] = valid_i[e*4] & valid_i[e*4+1] & valid_i[e*4+2] & valid_i[e*4+3];
      end else begin
        in_elem[e]    = 32'd0;
        elem_valid[e] = 1'b0;
      end
    end
  end

  logic can_accept;
  logic [7:0] blk_scale;

  always_comb begin
    for (int i = 0; i < MxBlockSize; i++) elem_d[i] = elem_q[i];
    fill_d = fill_q;
    for (int i = 0; i < BufSize; i++) pack_d[i] = pack_q[i];
    pack_off_d = pack_off_q;
    blk_scale  = '0;

    // Output consume pre-shift (remove an emitted beat / drain partial)
    if (consumed_i && (pack_off_d > 0)) begin
      if (pack_off_d >= OffsetWidth'(StrbWidth)) begin
        for (int i = 0; i < BufSize; i++)
          pack_d[i] = ((i + StrbWidth) < BufSize) ? pack_q[i+StrbWidth] : 8'd0;
        pack_off_d = OffsetWidth'(pack_off_d - StrbWidth);
      end else begin
        pack_off_d = '0;
        for (int i = 0; i < BufSize; i++) pack_d[i] = 8'd0;
      end
    end

    // Accept input: compact valid elements into the block buffer, and complete +
    // quantize + pack each 32-element block RE-ENTRANTLY — the moment it fills, mid-beat
    // — then keep draining the beat's remaining valid elements into the next block. This
    // is what prevents tail-drop when a beat crosses a block boundary (misaligned/partial
    // input). At StrbWidth<=64 (512b) a beat carries <=MxBlockSize elements so it
    // completes AT MOST 1 block — reserve 1 block (33B). Reserving 2 here would create a
    // deadlock window (pack_off in (BufSize-2*33, StrbWidth) can neither accept nor emit).
    // (FP16 at StrbWidth>64 would complete >1 block/beat and is out of scope; the
    // overflow assertion below guards it in sim.)
    can_accept = (pack_off_d + OffsetWidth'(MxCompressedBlockBytes)) <= OffsetWidth'(BufSize);
    if ((valid_i != '0) && can_accept) begin
      for (int e = 0; e < ElemsFP16; e++) begin
        if (elem_valid[e]) begin
          elem_d[fill_d[$clog2(MxBlockSize)-1:0]] = in_elem[e];
          if (fill_d == FillW'(MxBlockSize-1)) begin
            // this element completes the block -> quantize + pack 33B, then carry on
            blk_scale = compute_block_scale_with_bias(elem_d, E5m2Bias);
            pack_d[pack_off_d[OffsetWidth-2:0]] = blk_scale;
            pack_off_d = OffsetWidth'(pack_off_d + 1);
            for (int i = 0; i < MxBlockSize; i++) begin
              pack_d[pack_off_d[OffsetWidth-2:0]] =
                  fp32_to_mxfp8_byte_prescaled(elem_d[i], decode_signed_scale(blk_scale));
              pack_off_d = OffsetWidth'(pack_off_d + 1);
            end
            fill_d = '0;
          end else begin
            fill_d = fill_d + FillW'(1);
          end
        end
      end
    end

    // Present output beat
    data_o_d  = '0;
    valid_o_d = '0;
    if (pack_off_d >= OffsetWidth'(StrbWidth)) begin
      for (int i = 0; i < StrbWidth; i++) data_o_d[i] = pack_d[i];
      valid_o_d = '1;
    end else if (drain_i && (pack_off_d > 0)) begin
      for (int i = 0; i < StrbWidth; i++) begin
        data_o_d[i]  = (i < pack_off_d) ? pack_d[i] : 8'd0;
        valid_o_d[i] = (i < pack_off_d) ? 1'b1 : 1'b0;
      end
    end

    ready_o = can_accept ? '1 : '0;
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (pack_off_d <= OffsetWidth'(BufSize))
      else $fatal(1, "idma_otf_mxquant: pack-buffer overflow — a beat completed >1 block (StrbWidth=%0d too large for the FP16 path?)", StrbWidth);
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_q <= '0; pack_off_q <= '0;
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= 32'd0;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= 8'd0;
      data_o <= '0; valid_o <= '0;
    end else begin
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= elem_d[i];
      fill_q <= fill_d;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= pack_d[i];
      pack_off_q <= pack_off_d;
      data_o  <= data_o_d;
      valid_o <= valid_o_d;
    end
  end

endmodule : idma_otf_mxquant
