// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// OTF opcode decode and transform helper functions for the viDMA
// legalizer and transport layer. Extends vidma_alcu_pkg with
// transport-level queries.
//
// Golden spec: crates/vidma_new/src/types/otf.rs

package vidma_otf_pkg;
  import vidma_alcu_pkg::*;

  // ── MX block geometry ──────────────────────────────────────────
  localparam int unsigned MxBlockSize = 32;  // elements per MX block
  localparam int unsigned MxFp32BlockBytes = MxBlockSize * 4;  // 128B uncompressed
  localparam int unsigned MxCompressedBlockBytes = MxBlockSize + 1;  // 33B (1 scale + 32 data)

  // ── Opcode classification ──────────────────────────────────────

  /// Is the opcode a streaming transform (MxQuant/MxDequant/FpCast)?
  function automatic logic is_otf_transform(input logic [7:0] opcode);
    return is_otf_mx(opcode) || is_otf_fpcast(opcode);
  endfunction

  /// Is the opcode an MX operation (quant or dequant)?
  function automatic logic is_otf_mx(input logic [7:0] opcode);
    return ((opcode & OpcodeFpcastMask) == '0) && ((opcode & OpcodeMxMask) != '0);
  endfunction

  /// Is the opcode MX quantization (FP32→MXFP8)?
  function automatic logic is_otf_mx_quant(input logic [7:0] opcode);
    return is_otf_mx(opcode) && (opcode[0] == 1'b0);
  endfunction

  /// Is the opcode MX dequantization (MXFP8→FP32)?
  function automatic logic is_otf_mx_dequant(input logic [7:0] opcode);
    return is_otf_mx(opcode) && (opcode[0] == 1'b1);
  endfunction

  /// Is the opcode a FpCast operation?
  function automatic logic is_otf_fpcast(input logic [7:0] opcode);
    return (opcode & OpcodeFpcastMask) != '0;
  endfunction

  /// Is the opcode a compression transform (output < input)?
  function automatic logic is_otf_compression(input logic [7:0] opcode);
    if (is_otf_mx_quant(opcode)) return 1'b1;
    if (is_otf_fpcast(opcode)) begin
      return fpcast_in_elem_bytes(opcode) > fpcast_out_elem_bytes(opcode);
    end
    return 1'b0;
  endfunction

  // ── Element sizes ──────────────────────────────────────────────

  /// Input and output element sizes in bytes for a transform opcode.
  /// Returns {in_size, out_size} packed as two 32-bit values.
  function automatic logic [63:0] otf_element_sizes(input logic [7:0] opcode);
    int unsigned in_size, out_size;
    if (is_otf_mx_quant(opcode)) begin
      // opcode[1] selects FP16-source quant: a block is 32*2=64B (FP16) vs 128B (FP32).
      in_size  = opcode[1] ? (MxFp32BlockBytes/2) : MxFp32BlockBytes;
      out_size = MxCompressedBlockBytes;
    end else if (is_otf_mx_dequant(opcode)) begin
      in_size  = MxCompressedBlockBytes;
      out_size = MxFp32BlockBytes;
    end else if (is_otf_fpcast(opcode)) begin
      in_size  = fpcast_in_elem_bytes(opcode);
      out_size = fpcast_out_elem_bytes(opcode);
    end else begin
      in_size  = 1;
      out_size = 1;
    end
    return {in_size[31:0], out_size[31:0]};
  endfunction

  // ── Write length computation ───────────────────────────────────

  /// Compute the write-side transfer length from a read-side length.
  /// For transforms: w_length = (r_length / in_size) * out_size.
  /// For non-transforms: w_length = r_length (passthrough).
  function automatic int unsigned otf_write_length(input logic [7:0] opcode,
                                                   input int unsigned r_length);
    logic [63:0] sizes;
    int unsigned in_size, out_size;

    if (!is_otf_transform(opcode)) return r_length;

    sizes    = otf_element_sizes(opcode);
    in_size  = sizes[63:32];
    out_size = sizes[31:0];

    if (in_size == 0) return r_length;  // safety
    return (r_length / in_size) * out_size;
  endfunction

  /// Compute coordinated R bytes for coupled transform splitting.
  /// Returns the maximum R bytes that respect both R and W page boundaries,
  /// rounded down to element boundary. Returns 0 if fewer bytes remain
  /// than one input element.
  function automatic int unsigned otf_coordinated_r_bytes(
      input logic [7:0] opcode, input int unsigned r_page_bytes, input int unsigned w_page_bytes);
    logic [63:0] sizes;
    int unsigned in_size, out_size;
    int unsigned r_from_w_page, r_max, r_coordinated;

    sizes    = otf_element_sizes(opcode);
    in_size  = sizes[63:32];
    out_size = sizes[31:0];

    if (in_size == 0 || out_size == 0) return r_page_bytes;

    r_from_w_page = (w_page_bytes / out_size) * in_size;
    r_max         = (r_page_bytes < r_from_w_page) ? r_page_bytes : r_from_w_page;
    r_coordinated = (r_max / in_size) * in_size;

    return r_coordinated;
  endfunction

  /// Does this transform require force-decoupled R/W?
  /// Force decouple_rw for all streaming transforms:
  /// - MxQuant/MxDequant: 33-byte blocks don't divide 4K pages.
  /// - FpCast compression: the w_dp_req must arrive before R data so the
  ///   drain FSM's is_fpcast_compress classification is active when the
  ///   first data beat enters the ALCU. With coupled R/W, the w_dp_req
  ///   and R data arrive on the same cycle from the legalizer but the
  ///   idma_axi_read pipeline adds latency, causing the data to arrive
  ///   one cycle AFTER the opcode latch — too late for burst-init.
  function automatic logic needs_force_decouple_rw(input logic [7:0] opcode);
    return is_otf_mx(opcode) || is_otf_compression(opcode);
  endfunction

endpackage : vidma_otf_pkg
