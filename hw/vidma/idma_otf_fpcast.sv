// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// OTF FP Cast — three-mode streaming conversion.
// Direction B RTL — written from the Rust golden model:
//   crates/vidma_new/src/backend/transport/alcu/otf_fpcast/detailed.rs
//
// Three modes based on element size ratio:
//   - Compression (in > out, e.g. FP32→I8): packing buffer with drain
//   - Expansion   (in < out, e.g. BF16→FP32): hold register for 2nd beat
//   - Identity    (in == out, e.g. BF16→I16): combinational passthrough

module idma_otf_fpcast
  import vidma_alcu_pkg::*;
#(
  parameter int unsigned StrbWidth = 128
) (
  input logic clk_i,
  input logic rst_ni,

  // Input stream (byte-granular)
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      valid_i,
  output logic [StrbWidth-1:0]      ready_o,

  // Output stream (byte-granular)
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      valid_o,
  input  logic [StrbWidth-1:0]      ready_i,

  // Control
  input logic [7:0] opcode_i,
  input logic       drain_i,
  input logic       consumed_i
);

  localparam int unsigned BufSize = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;

  // ── Compression: packing buffer registers ────────────────────────
  logic [            7:0] pack_buf_q               [  BufSize];
  logic [OffsetWidth-1:0] pack_offset_q;
  logic [            7:0] pack_buf_d               [  BufSize];
  logic [OffsetWidth-1:0] pack_offset_d;

  // ── Expansion: hold register ─────────────────────────────────────
  logic [            7:0] expand_hold_q            [StrbWidth];
  logic                   expand_hold_valid_q;
  logic [OffsetWidth-1:0] expand_hold_len_q;
  // Tracks whether last cycle's output came from hold (gates consumed pre-clear)
  logic                   expand_hold_was_output_q;

  logic [            7:0] pending_hold             [StrbWidth];
  logic                   pending_hold_valid;
  logic [OffsetWidth-1:0] pending_hold_len;

  // ── Mode detection ───────────────────────────────────────────────
  int unsigned in_elem_size, out_elem_size;
  assign in_elem_size  = fpcast_in_elem_bytes(opcode_i);
  assign out_elem_size = fpcast_out_elem_bytes(opcode_i);

  logic is_compression, is_expansion, is_identity;
  assign is_compression = (in_elem_size > out_elem_size);
  assign is_expansion   = (in_elem_size < out_elem_size);
  assign is_identity    = (in_elem_size == out_elem_size);

  // Max compressed output bytes per input beat = (StrbWidth / in_size) * out_size.
  // Avoid runtime division (Jasper black-boxes it): use case-based lookup.
  int unsigned max_out_per_beat;
  always_comb begin
    case ({
      in_elem_size[2:0], out_elem_size[2:0]
    })
      {3'd4, 3'd1} : max_out_per_beat = (StrbWidth / 4) * 1;  // FP32→I8
      {3'd4, 3'd2} : max_out_per_beat = (StrbWidth / 4) * 2;  // FP32→BF16/I16
      {3'd2, 3'd1} : max_out_per_beat = (StrbWidth / 2) * 1;  // BF16→I8
      {3'd2, 3'd2} : max_out_per_beat = (StrbWidth / 2) * 2;  // BF16→I16 (identity)
      default:       max_out_per_beat = StrbWidth;  // safe upper bound
    endcase
  end

  // Can accept input (computed after consumed pre-shift/pre-clear)
  logic                        can_accept;

  // ── Expansion: working copies after consumed pre-clear ──────────
  logic                        hold_valid_work;
  logic [OffsetWidth-1:0]      hold_len_work;
  logic                        expand_hold_was_output_d;

  // ── Scratch buffer for expansion ─────────────────────────────────
  logic [            7:0]      expand_scratch           [BufSize];

  // ── Combinational next-state for output registers ───────────────
  logic [  StrbWidth-1:0][7:0] data_o_d;
  logic [  StrbWidth-1:0]      valid_o_d;

  // ── Main combinational logic ─────────────────────────────────────
  // Temporaries declared at block top
  int valid_bytes_c, offset_c, total_out_c, remainder_c;
  logic [31:0] in_word_c, out_word_c;
  int n_hold;

  always_comb begin
    data_o_d           = '0;
    valid_o_d          = '0;
    pending_hold_valid = 1'b0;
    pending_hold_len   = '0;
    for (int i = 0; i < StrbWidth; i++) pending_hold[i] = '0;
    for (int i = 0; i < BufSize; i++) expand_scratch[i] = '0;

    // Compression: init next-state from registered state
    for (int i = 0; i < BufSize; i++) pack_buf_d[i] = pack_buf_q[i];
    pack_offset_d            = pack_offset_q;

    // Expansion: init working copies from registered state
    hold_valid_work          = expand_hold_valid_q;
    hold_len_work            = expand_hold_len_q;
    expand_hold_was_output_d = 1'b0;

    valid_bytes_c            = 0;
    offset_c                 = 0;
    total_out_c              = 0;
    remainder_c              = 0;
    in_word_c                = '0;
    out_word_c               = '0;
    n_hold                   = 0;
    can_accept               = 1'b1;

    if (is_compression) begin
      // ── Compression mode ─────────────────────────────────

      // Consumed pre-shift: remove output beat from buffer head (combinational).
      // Handles both full beats (pack_offset >= StrbWidth) and drain partial
      // beats (0 < pack_offset < StrbWidth). Without the partial-beat case,
      // drain residuals are never cleared (deadlock).
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

      // Can accept (after consumed pre-shift)
      can_accept = (pack_offset_d + max_out_per_beat) <= BufSize;

      if ((valid_i != '0) && can_accept) begin
        if (valid_i == '1) valid_bytes_c = StrbWidth;
        else begin
          valid_bytes_c = 0;
          for (int i = 0; i < StrbWidth; i++) begin
            if (valid_i[i]) valid_bytes_c = i + 1;
            else break;
          end
        end

        offset_c = 0;
        for (int elem = 0; elem < StrbWidth; elem++) begin
          if ((offset_c + int'(in_elem_size)) > valid_bytes_c) break;
          in_word_c = '0;
          for (int b = 0; b < 4; b++) begin
            if (b < int'(in_elem_size)) in_word_c[b*8+:8] = data_i[$clog2(StrbWidth)'(offset_c+b)];
          end

          fpcast_convert_element(opcode_i, in_word_c, out_word_c);

          for (int b = 0; b < 4; b++) begin
            if (b < int'(out_elem_size))
              pack_buf_d[(OffsetWidth-1)'(pack_offset_d+b)] = out_word_c[b*8+:8];
          end
          pack_offset_d = OffsetWidth'(pack_offset_d + out_elem_size);
          offset_c      = offset_c + int'(in_elem_size);
        end
      end

      // Present output from pack buffer
      if (pack_offset_d >= StrbWidth) begin
        for (int i = 0; i < StrbWidth; i++) data_o_d[i] = pack_buf_d[i];
        valid_o_d = '1;
      end else if (drain_i && (pack_offset_d > 0)) begin
        for (int i = 0; i < StrbWidth; i++) begin
          if (i < pack_offset_d) data_o_d[i] = pack_buf_d[i];
          else data_o_d[i] = 8'd0;
        end
        for (int i = 0; i < StrbWidth; i++) valid_o_d[i] = (i < pack_offset_d) ? 1'b1 : 1'b0;
      end

    end else if (is_expansion) begin
      // ── Expansion mode ───────────────────────────────────

      // Consumed pre-clear: clear hold only when hold was the PREVIOUS cycle's output.
      if (consumed_i && expand_hold_was_output_q) begin
        hold_valid_work = 1'b0;
        hold_len_work   = '0;
      end

      // Can accept (after consumed pre-clear)
      can_accept = !hold_valid_work;

      if (hold_valid_work) begin
        // Emit held data. Record hold as output source this cycle.
        expand_hold_was_output_d = 1'b1;
        n_hold                   = hold_len_work;
        for (int i = 0; i < StrbWidth; i++) begin
          if (i < n_hold) data_o_d[i] = expand_hold_q[i];
          else data_o_d[i] = 8'd0;
        end
        for (int i = 0; i < StrbWidth; i++) valid_o_d[i] = (i < n_hold) ? 1'b1 : 1'b0;
      end else if (valid_i != '0) begin
        // Convert input — output does NOT come from hold.
        expand_hold_was_output_d = 1'b0;

        if (valid_i == '1) valid_bytes_c = StrbWidth;
        else begin
          valid_bytes_c = 0;
          for (int i = 0; i < StrbWidth; i++) begin
            if (valid_i[i]) valid_bytes_c = i + 1;
            else break;
          end
        end

        total_out_c = 0;
        offset_c    = 0;
        for (int elem = 0; elem < StrbWidth; elem++) begin
          if ((offset_c + int'(in_elem_size)) > valid_bytes_c) break;
          in_word_c = '0;
          for (int b = 0; b < 4; b++) begin
            if (b < int'(in_elem_size)) in_word_c[b*8+:8] = data_i[$clog2(StrbWidth)'(offset_c+b)];
          end

          fpcast_convert_element(opcode_i, in_word_c, out_word_c);

          for (int b = 0; b < 4; b++) begin
            if (b < int'(out_elem_size))
              expand_scratch[$clog2(2*StrbWidth)'(total_out_c+b)] = out_word_c[b*8+:8];
          end
          total_out_c = total_out_c + int'(out_elem_size);
          offset_c    = offset_c + int'(in_elem_size);
        end

        if (total_out_c <= StrbWidth) begin
          for (int i = 0; i < StrbWidth; i++) begin
            if (i < total_out_c) data_o_d[i] = expand_scratch[i];
            else data_o_d[i] = 8'd0;
          end
          for (int i = 0; i < StrbWidth; i++) valid_o_d[i] = (i < total_out_c) ? 1'b1 : 1'b0;
        end else begin
          for (int i = 0; i < StrbWidth; i++) data_o_d[i] = expand_scratch[i];
          valid_o_d   = '1;
          remainder_c = total_out_c - StrbWidth;
          for (int i = 0; i < StrbWidth; i++) begin
            if (i < remainder_c) pending_hold[i] = expand_scratch[StrbWidth+i];
            else pending_hold[i] = 8'd0;
          end
          pending_hold_valid = 1'b1;
          pending_hold_len   = OffsetWidth'(remainder_c);
        end
      end else begin
        // No output — hold was not emitted.
        expand_hold_was_output_d = 1'b0;
      end

    end else begin
      // ── Identity mode (1:1 conversion) ───────────────────
      can_accept = 1'b1;
      if (valid_i != '0) begin
        if (valid_i == '1) valid_bytes_c = StrbWidth;
        else begin
          valid_bytes_c = 0;
          for (int i = 0; i < StrbWidth; i++) begin
            if (valid_i[i]) valid_bytes_c = i + 1;
            else break;
          end
        end

        offset_c = 0;
        for (int elem = 0; elem < StrbWidth; elem++) begin
          if ((offset_c + int'(in_elem_size)) > valid_bytes_c) break;
          in_word_c = '0;
          for (int b = 0; b < 4; b++) begin
            if (b < int'(in_elem_size)) in_word_c[b*8+:8] = data_i[$clog2(StrbWidth)'(offset_c+b)];
          end

          fpcast_convert_element(opcode_i, in_word_c, out_word_c);

          for (int b = 0; b < 4; b++) begin
            if (b < int'(in_elem_size))
              data_o_d[$clog2(StrbWidth)'(offset_c+b)] = out_word_c[b*8+:8];
          end
          offset_c = offset_c + int'(in_elem_size);
        end
        valid_o_d = valid_i;
      end
    end

    // Ready output
    ready_o = can_accept ? '1 : '0;
  end

  // ── Sequential: commit state, register outputs ─────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pack_offset_q            <= '0;
      expand_hold_valid_q      <= 1'b0;
      expand_hold_len_q        <= '0;
      expand_hold_was_output_q <= 1'b0;
      for (int i = 0; i < BufSize; i++) pack_buf_q[i] <= '0;
      for (int i = 0; i < StrbWidth; i++) expand_hold_q[i] <= '0;
      data_o  <= '0;
      valid_o <= '0;
    end else begin
      // Register outputs
      data_o  <= data_o_d;
      valid_o <= valid_o_d;

      // Compression: commit next-state (consumed pre-shift already applied in comb)
      for (int i = 0; i < BufSize; i++) pack_buf_q[i] <= pack_buf_d[i];
      pack_offset_q <= pack_offset_d;

      // Expansion: consumed pre-clear applied in comb via hold_valid_work;
      // here we commit the clear and/or pending hold.
      if (consumed_i && expand_hold_was_output_q) begin
        expand_hold_valid_q <= 1'b0;
        expand_hold_len_q   <= '0;
      end
      // Pending hold overrides consumed clear (last assignment wins)
      if (pending_hold_valid) begin
        for (int i = 0; i < StrbWidth; i++) expand_hold_q[i] <= pending_hold[i];
        expand_hold_valid_q <= 1'b1;
        expand_hold_len_q   <= pending_hold_len;
      end
      expand_hold_was_output_q <= expand_hold_was_output_d;
    end
  end

endmodule : idma_otf_fpcast
