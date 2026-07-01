// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch> (upstream iDMA transport layer)
// - Tobias Senti <tsenti@ethz.ch>
// - Daniel Keller <dankeller@iis.ee.ethz.ch> (viDMA OTF extensions)
//
// Transport layer for AXI read/write protocol with OTF transform support.
// Direction B RTL — OTF extensions written from Rust golden model:
//   crates/vidma_new/src/backend/transport/layer/detailed.rs
//
// When EnableOtfTransform=0, this module is functionally identical to the
// upstream vidma_transport_layer_rw_axi.sv (purely structural wiring).
//
// OTF extensions (gated by EnableOtfTransform generate block):
//   - ALCU between dataflow element and write barrel shift
//   - MxQuant + FpCast compression drain FSMs (registered)
//   - MxDequant + FpCast expansion bypass (route around dataflow)
//   - Write shift override (w_shift=0 for compression transforms)
//   - Opcode priority mux, consumed signal, latched payloads
//   - Burst initialization on first data arrival (R byte counting)

`include "common_cells/registers.svh"

module vidma_transport_layer_rw_axi
  import vidma_otf_pkg::*;
#(
  parameter int unsigned NumAxInFlight        = 32'd2,
  parameter int unsigned DataWidth            = 32'd16,
  parameter int unsigned BufferDepth          = 32'd3,
  parameter bit          MaskInvalidData      = 1'b1,
  parameter bit          EnableOtfTransform   = 1'b0,
  parameter int unsigned NumSimdLanes         = 1,
  parameter bit          EnableMultiply       = 1'b0,
  parameter bit          EnableFpCast         = 1'b1,
  parameter bit          PrintFifoInfo        = 1'b0,
  parameter type         r_dp_req_t           = logic,
  parameter type         w_dp_req_t           = logic,
  parameter type         r_dp_rsp_t           = logic,
  parameter type         w_dp_rsp_t           = logic,
  parameter type         write_meta_channel_t = logic,
  parameter type         read_meta_channel_t  = logic,
  parameter type         axi_req_t            = logic,
  parameter type         axi_rsp_t            = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,

  output axi_req_t axi_read_req_o,
  input  axi_rsp_t axi_read_rsp_i,
  output axi_req_t axi_write_req_o,
  input  axi_rsp_t axi_write_rsp_i,

  input  r_dp_req_t r_dp_req_i,
  input  logic      r_dp_valid_i,
  output logic      r_dp_ready_o,
  output r_dp_rsp_t r_dp_rsp_o,
  output logic      r_dp_valid_o,
  input  logic      r_dp_ready_i,

  input  w_dp_req_t w_dp_req_i,
  input  logic      w_dp_valid_i,
  output logic      w_dp_ready_o,
  output w_dp_rsp_t w_dp_rsp_o,
  output logic      w_dp_valid_o,
  input  logic      w_dp_ready_i,

  input  read_meta_channel_t  ar_req_i,
  input  logic                ar_valid_i,
  output logic                ar_ready_o,
  input  write_meta_channel_t aw_req_i,
  input  logic                aw_valid_i,
  output logic                aw_ready_o,

  input logic dp_poison_i,

  output logic r_chan_ready_o,
  output logic r_chan_valid_o,
  output logic r_dp_busy_o,
  output logic w_dp_busy_o,
  output logic buffer_busy_o
);

  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned OffsetWidth = $clog2(StrbWidth);

  typedef logic [DataWidth-1:0] data_t;
  typedef logic [StrbWidth-1:0] strb_t;
  typedef logic [7:0] byte_t;

  // ── Internal signals ─────────────────────────────────────────
  // Read side
  strb_t                   buffer_in_valid;
  strb_t                   buffer_in_ready;  // muxed: dataflow or bypass
  strb_t                   dataflow_ready_to_read;  // raw dataflow ready_o
  byte_t [2*StrbWidth-1:0] buffer_in_tmp;
  byte_t [StrbWidth-1:0] buffer_in, buffer_in_shifted;

  // Dataflow element
  strb_t                   buffer_out_valid;
  byte_t [  StrbWidth-1:0] buffer_out;
  // Expansion bypass: zero dataflow valid_i to prevent stale data accumulation.
  // Set by gen_otf when expansion_bypass_active. Matches Rust model line 513.
  logic                    dataflow_bypass_gate;
  strb_t                   dataflow_ready_in;  // ready driven into dataflow

  // Write side — muxed signals (OTF overrides these)
  byte_t [  StrbWidth-1:0] write_data_in;  // data to axi_write
  strb_t                   write_valid_in;  // valid to axi_write
  strb_t                   write_ready_out;  // ready from axi_write

  // Write barrel shift intermediates
  byte_t [2*StrbWidth-1:0] write_data_tmp;
  byte_t [  StrbWidth-1:0] write_data_shifted;
  strb_t                   write_valid_shifted;
  strb_t                   write_ready_shifted;

  // ── Read Ports ───────────────────────────────────────────────
  idma_axi_read #(
    .StrbWidth (StrbWidth),
    .byte_t    (byte_t),
    .strb_t    (strb_t),
    .r_dp_req_t(r_dp_req_t),
    .r_dp_rsp_t(r_dp_rsp_t),
    .ar_chan_t (read_meta_channel_t),
    .read_req_t(axi_req_t),
    .read_rsp_t(axi_rsp_t)
  ) i_idma_axi_read (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .r_dp_req_i       (r_dp_req_i),
    .r_dp_valid_i     (r_dp_valid_i),
    .r_dp_ready_o     (r_dp_ready_o),
    .r_dp_rsp_o       (r_dp_rsp_o),
    .r_dp_valid_o     (r_dp_valid_o),
    .r_dp_ready_i     (r_dp_ready_i),
    .ar_req_i         (ar_req_i),
    .ar_valid_i       (ar_valid_i),
    .ar_ready_o       (ar_ready_o),
    .read_req_o       (axi_read_req_o),
    .read_rsp_i       (axi_read_rsp_i),
    .r_chan_valid_o   (r_chan_valid_o),
    .r_chan_ready_o   (r_chan_ready_o),
    .buffer_in_o      (buffer_in),
    .buffer_in_valid_o(buffer_in_valid),
    .buffer_in_ready_i(buffer_in_ready)
  );

  // ── Read Barrel Shifter ──────────────────────────────────────
  assign buffer_in_tmp     = {buffer_in, buffer_in} >> (r_dp_req_i.shift * 8);
  assign buffer_in_shifted = buffer_in_tmp[$bits(buffer_in_shifted)/8-1:0];

  // ── Buffer (Dataflow Element) ────────────────────────────────
  idma_dataflow_element #(
    .BufferDepth  (BufferDepth),
    .StrbWidth    (StrbWidth),
    .PrintFifoInfo(PrintFifoInfo),
    .strb_t       (strb_t),
    .byte_t       (byte_t)
  ) i_dataflow_element (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .testmode_i(testmode_i),
    .data_i    (buffer_in_shifted),
    .valid_i   (dataflow_bypass_gate ? '0 : buffer_in_valid),
    .ready_o   (dataflow_ready_to_read),
    .data_o    (buffer_out),
    .valid_o   (buffer_out_valid),
    .ready_i   (dataflow_ready_in)
  );

  // ── Write Barrel Shifter ─────────────────────────────────────
  // Operates on muxed write_data_in / write_valid_in, not
  // raw dataflow output. OTF block overrides these signals.
  assign write_data_tmp      = {write_data_in, write_data_in} >> (w_dp_req_i.shift * 8);
  assign write_data_shifted  = write_data_tmp[$bits(write_data_shifted)/8-1:0];
  assign write_valid_shifted = strb_t'({write_valid_in, write_valid_in} >> w_dp_req_i.shift);
  assign write_ready_shifted = strb_t'({write_ready_out, write_ready_out} >> (-w_dp_req_i.shift));

  // ── Write Ports ──────────────────────────────────────────────
  idma_axi_write #(
    .StrbWidth      (StrbWidth),
    .MaskInvalidData(MaskInvalidData),
    .byte_t         (byte_t),
    .data_t         (data_t),
    .strb_t         (strb_t),
    .w_dp_req_t     (w_dp_req_t),
    .w_dp_rsp_t     (w_dp_rsp_t),
    .aw_chan_t      (write_meta_channel_t),
    .write_req_t    (axi_req_t),
    .write_rsp_t    (axi_rsp_t)
  ) i_idma_axi_write (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .w_dp_req_i        (w_dp_req_i),
    .w_dp_valid_i      (w_dp_valid_i),
    .w_dp_ready_o      (w_dp_ready_o),
    .dp_poison_i       (dp_poison_i),
    .w_dp_rsp_o        (w_dp_rsp_o),
    .w_dp_valid_o      (w_dp_valid_o),
    .w_dp_ready_i      (w_dp_ready_i),
    .aw_req_i          (aw_req_i),
    .aw_valid_i        (aw_valid_i),
    .aw_ready_o        (aw_ready_o),
    .write_req_o       (axi_write_req_o),
    .write_rsp_i       (axi_write_rsp_i),
    .buffer_out_i      (write_data_shifted),
    .buffer_out_valid_i(write_valid_shifted),
    .buffer_out_ready_o(write_ready_out)
  );

  // ══════════════════════════════════════════════════════════════
  // Signal mux: passthrough vs OTF
  // ══════════════════════════════════════════════════════════════

  generate
    if (!EnableOtfTransform) begin : gen_passthrough
      // ── Passthrough: direct dataflow → write ─────────────────
      assign write_data_in        = buffer_out;
      assign write_valid_in       = buffer_out_valid;
      assign dataflow_ready_in    = write_ready_shifted;
      assign buffer_in_ready      = dataflow_ready_to_read;
      assign dataflow_bypass_gate = 1'b0;
    end else begin : gen_otf
      // ── OTF: ALCU + drain FSMs + bypass ──────────────────────

      // ── OTF opcode decode from latched w_dp ──────────────────
      logic [7:0] latched_otf_opcode_q;
      logic is_mx_quant, is_mx_dequant, is_fpcast_compress;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) latched_otf_opcode_q <= 8'h08;
        else if (w_dp_valid_i) latched_otf_opcode_q <= w_dp_req_i.otf_opcode;
      end

      // Effective opcode: bypass register on first beat. Use
      // w_dp_req_i.otf_opcode directly when w_dp_valid_i is asserted
      // (the register update happens on the next posedge, but the
      // ALCU needs the correct opcode combinationally on the same cycle).
      logic [7:0] effective_otf_opcode;
      assign effective_otf_opcode = w_dp_valid_i ? w_dp_req_i.otf_opcode : latched_otf_opcode_q;

      assign is_mx_quant          = is_otf_mx_quant(effective_otf_opcode);
      assign is_mx_dequant        = is_otf_mx_dequant(effective_otf_opcode);
      assign is_fpcast_compress   = is_otf_compression(effective_otf_opcode);

      // R-side opcode decode (for expansion bypass detection)
      logic is_r_expansion;
      assign is_r_expansion = r_dp_valid_i && (is_otf_mx_dequant(
          r_dp_req_i.otf_opcode
      ) || (is_otf_fpcast(
          r_dp_req_i.otf_opcode
      ) && !is_otf_compression(
          r_dp_req_i.otf_opcode
      )));
      // Latch expansion bypass across multi-page R transfers. Without the
      // latch, r_dp_valid_i drops between legalized R pages, deactivating
      // the bypass and allowing stale dataflow accumulation. Set on the
      // first expansion R burst; clear on the last R beat of the last R
      // burst (r_dp_valid_o && eff_r_last). Uses r_last from the legalizer
      // which marks the final burst of the 1D transfer.
      logic expansion_bypass_active;
      assign expansion_bypass_active = is_r_expansion && !is_mx_quant;
      // During expansion bypass, prevent data from entering the dataflow
      // per-lane FIFOs. The dataflow mixes data from different R beats into
      // per-lane queues, losing per-beat valid mask granularity. Partial
      // last beats appear as full beats to the ALCU because stale lanes
      // retain entries from previous beats. Gate the dataflow and use
      // buffer_out directly (which still carries the current beat from the
      // dataflow's passthrough when the FIFO is empty).
      // Matches Rust model line 512-514 in layer/detailed.rs.
      assign dataflow_bypass_gate    = expansion_bypass_active;

      // ── Drain FSM registers ──────────────────────────────────
      logic mx_draining_q, mx_drain_pending;
      logic fp_draining_q, fp_drain_pending;
      logic [31:0] mx_r_expected_q, mx_r_received_q;
      logic mx_r_last_q;
      logic [31:0] fp_r_expected_q, fp_r_received_q;
      logic                   fp_r_last_q;
      // Consumed: combinational W beat fire → ALCU same-cycle shift.
      // The ALCU sub-units (FpCast, MxQuant) apply consumed as a
      // combinational pre-shift in their always_comb blocks. Since
      // their outputs (data_o, valid_o) are REGISTERED, there is no
      // combinational loop through the write path.
      logic                   consumed_w;

      // ── Latched r_dp_req for burst init ──────────────────────
      logic [OffsetWidth-1:0] latched_r_offset_q;
      logic [OffsetWidth-1:0] latched_r_tailer_q;
      logic [            7:0] latched_r_num_beats_q;
      logic                   latched_r_last_q;
      logic [OffsetWidth-1:0] latched_r_dst_offset_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          latched_r_offset_q     <= '0;
          latched_r_tailer_q     <= '0;
          latched_r_num_beats_q  <= '0;
          latched_r_last_q       <= '0;
          latched_r_dst_offset_q <= '0;
        end else if (r_dp_valid_i) begin
          latched_r_offset_q     <= r_dp_req_i.offset;
          latched_r_tailer_q     <= r_dp_req_i.tailer;
          latched_r_num_beats_q  <= r_dp_req_i.num_beats;
          latched_r_last_q       <= r_dp_req_i.r_last;
          latched_r_dst_offset_q <= r_dp_req_i.dst_offset;
        end
      end

      // Effective r_dp fields: bypass register when r_dp_valid_i is
      // asserted so the burst-init and drain logic see correct values
      // on the same cycle (same pattern as effective_otf_opcode).
      logic [OffsetWidth-1:0] eff_r_offset, eff_r_tailer, eff_r_dst_offset;
      logic [7:0] eff_r_num_beats;
      logic       eff_r_last;
      assign eff_r_offset     = r_dp_valid_i ? r_dp_req_i.offset : latched_r_offset_q;
      assign eff_r_tailer     = r_dp_valid_i ? r_dp_req_i.tailer : latched_r_tailer_q;
      assign eff_r_num_beats  = r_dp_valid_i ? r_dp_req_i.num_beats : latched_r_num_beats_q;
      assign eff_r_last       = r_dp_valid_i ? r_dp_req_i.r_last : latched_r_last_q;
      assign eff_r_dst_offset = r_dp_valid_i ? r_dp_req_i.dst_offset : latched_r_dst_offset_q;

      // ── Opcode mux ───────────────────────────────────────────
      // Priority: drain → bypass → effective
      logic [7:0] otf_opcode_muxed;
      always_comb begin
        if (mx_draining_q) otf_opcode_muxed = 8'h20;
        else if (fp_draining_q) otf_opcode_muxed = effective_otf_opcode;
        else if (expansion_bypass_active) otf_opcode_muxed = r_dp_req_i.otf_opcode;
        else otf_opcode_muxed = effective_otf_opcode;
      end

      // ── Gated dataflow valid (zero during drain) ─────────────
      strb_t gated_valid;
      assign gated_valid = (mx_draining_q || fp_draining_q) ? '0 : buffer_out_valid;

      // ── Expansion bypass data/valid mux ─────────────────────
      // During expansion bypass (MxDequant, FpCast expansion), the
      // dataflow per-lane FIFOs are gated (dataflow_bypass_gate=1)
      // to prevent stale data accumulation. Instead, feed the ALCU
      // directly from the read barrel shifter output (buffer_in_shifted
      // + buffer_in_valid). This preserves correct per-beat valid masks.
      // Matches Rust model line 510-531 in layer/detailed.rs.
      byte_t [StrbWidth-1:0] alcu_data_muxed;
      strb_t                 alcu_valid_muxed;

      assign alcu_data_muxed  = expansion_bypass_active ? buffer_in_shifted : buffer_out;
      assign alcu_valid_muxed = expansion_bypass_active ? buffer_in_valid : gated_valid;

      // ── ALCU instantiation ───────────────────────────────────
      byte_t [StrbWidth-1:0] alcu_data_o;
      strb_t                 alcu_valid_o;
      strb_t                 alcu_ready_o;

      idma_alcu #(
        .StrbWidth     (StrbWidth),
        .NumSimdLanes  (NumSimdLanes),
        .EnableMultiply(EnableMultiply),
        .EnableFpCast  (EnableFpCast)
      ) i_alcu (
        .clk_i,
        .rst_ni,
        .data_a_i          (alcu_data_muxed),
        .valid_a_i         (alcu_valid_muxed),
        .ready_a_o         (alcu_ready_o),
        .data_b_i          ('0),
        .valid_b_i         ('0),
        .ready_b_o         (),
        .data_o            (alcu_data_o),
        .valid_o           (alcu_valid_o),
        .ready_i           (write_ready_shifted),
        .opcode_i          (otf_opcode_muxed),
        .single_head_mode_i(1'b1),
        .mx_quant_drain_i  (mx_draining_q),
        .fpcast_drain_i    (fp_draining_q),
        .consumed_i        (consumed_w)
      );

      // ── Expansion bypass: R-ready override ────────────────────
      // During bypass, route ALCU dequant/expansion ready to
      // axi_read instead of stalling via dataflow. During R/W
      // overlap (R=dequant, W=quant), stall R entirely.
      logic is_r_overlap_stall;
      assign is_r_overlap_stall = (is_otf_mx_dequant(
          r_dp_req_i.otf_opcode
      ) || (is_otf_fpcast(
          r_dp_req_i.otf_opcode
      ) && !is_otf_compression(
          r_dp_req_i.otf_opcode
      ))) && r_dp_valid_i && is_mx_quant;

      always_comb begin
        if (expansion_bypass_active) buffer_in_ready = alcu_ready_o;
        else if (is_r_overlap_stall) buffer_in_ready = '0;
        else buffer_in_ready = dataflow_ready_to_read;
      end

      // ── Dataflow ready: ALCU ready masked with valid ─────────
      // Mask prevents popping empty dataflow entries during drain.
      // Zero during expansion bypass (dataflow is stalled).
      // Mask prevents popping empty dataflow entries during drain.
      // Zero during expansion bypass (dataflow is stalled).
      // ── Pure-passthrough fast path ───────────────────────────
      // Opcode 0x08 performs no transform, yet routing it through the
      // ALCU + registered write latch adds a pipeline stage whose draining
      // is NOT lock-stepped with the per-transfer w_dp write metadata. When
      // transfers are issued back-to-back (pipelined, no wait between them),
      // the last beat of transfer N can remain buffered/latched after
      // transfer N's write legalizer has retired its w_dp -> the beat has no
      // write request to drain it -> buffer_busy stays high forever -> the
      // backend's busy_o never clears -> snrt_dma_wait_all spins (hang).
      // Single/serialized transfers flush the latch fine, which is why it
      // only bites pipelined passthrough (e.g. the MXCore GEMM operand load).
      // Fix: drain the buffer in lock-step with the write datapath exactly
      // like gen_passthrough (EnableOtfTransform=0), bypassing the ALCU+latch
      // for opcode 0x08 only. MX/FpCast transforms and ALU ops are untouched
      // (they legitimately need the ALCU), so the cosim-verified transform
      // datapath is unaffected. 0x08 == vidma_alcu_pkg::OpPassthrough.
      logic is_pure_passthrough;
      assign is_pure_passthrough = (effective_otf_opcode == 8'h08)
          && !mx_draining_q && !fp_draining_q && !expansion_bypass_active;

      // During a residual drain (mx_draining_q / fp_draining_q) the ALCU flushes
      // its INTERNAL pack buffer and does NOT consume from the dataflow — its
      // input valid is gated to 0 (see `gated_valid`). But alcu_ready_o
      // (= the pack buffer's can_accept) stays high while it drains, so without
      // this guard `dataflow_ready_in` would keep POPPING the per-lane dataflow
      // FIFO and DISCARD whatever it holds. With force-decoupled R/W and
      // back-to-back (pipelined) transfers, the NEXT transfer's first read beat
      // can already be sitting in the dataflow while the current transfer is
      // still draining -> it gets popped-and-dropped, never reaching the ALCU.
      // That lost beat shifts the next transfer's MX-block phase by one beat, so
      // its final block ends up half-built (fill_q != 0) and its residual drain
      // can never complete the final 33B block -> the write legalizer's last
      // w_dp is never satisfied -> backend stays busy -> snrt_dma_wait_all hangs.
      // Holding dataflow_ready_in low during drain keeps the next transfer's
      // beats buffered until the drain finishes; the dataflow then resumes
      // feeding them intact. Single / serialized transfers never overlap a drain
      // with the next transfer's data, so this is a no-op for them (the cosim-
      // verified streaming datapath is unchanged).
      assign dataflow_ready_in = is_pure_passthrough ? write_ready_shifted
          : (expansion_bypass_active || mx_draining_q || fp_draining_q) ? '0
          : (alcu_ready_o & buffer_out_valid);

      // ── Write buffer latch ───────────────────────────────────
      // Preserves ALCU output across multiple W beats for
      // barrel-shifted passthrough/ALU. Streaming transforms
      // bypass the latch (pack/unpack buffer holds output).
      byte_t [StrbWidth-1:0] latch_data_q;
      strb_t                 latch_valid_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          latch_valid_q <= '0;
        end else begin
          if (alcu_valid_o != '0) begin
            latch_data_q  <= alcu_data_o;
            latch_valid_q <= alcu_valid_o;
          end else if (!is_mx_quant && !is_mx_dequant && !is_fpcast_compress) begin
            latch_valid_q <= '0;
          end
        end
      end

      // Signal mux: ALCU output or latch
      // Streaming transforms use ALCU directly; passthrough/ALU
      // with barrel shift falls back to latch between W beats.
      logic use_alcu_direct;
      assign use_alcu_direct = is_mx_quant || is_mx_dequant
          || is_fpcast_compress || (alcu_valid_o != '0);

      // Pure passthrough drains the read buffer directly (lock-step with the
      // write datapath, exactly like gen_passthrough); transforms/ALU use the
      // ALCU output or its latch as before.
      assign write_data_in  = is_pure_passthrough ? buffer_out
          : use_alcu_direct ? alcu_data_o : latch_data_q;
      assign write_valid_in = is_pure_passthrough ? buffer_out_valid
          : use_alcu_direct ? alcu_valid_o : latch_valid_q;

      // ── Drain FSM combinational ──────────────────────────────
      // Burst init: compute expected R bytes on first data arrival
      logic [31:0] mx_r_expected_d, mx_r_received_d;
      logic [31:0] fp_r_expected_d, fp_r_received_d;
      logic mx_r_last_d, fp_r_last_d;
      logic [31:0] burst_last_end, burst_expected;

      always_comb begin
        mx_r_expected_d  = mx_r_expected_q;
        mx_r_received_d  = mx_r_received_q;
        mx_r_last_d      = mx_r_last_q;
        fp_r_expected_d  = fp_r_expected_q;
        fp_r_received_d  = fp_r_received_q;
        fp_r_last_d      = fp_r_last_q;
        mx_drain_pending = 1'b0;
        fp_drain_pending = 1'b0;

        // Pre-compute burst-init expected bytes.
        if (eff_r_tailer == '0) burst_last_end = StrbWidth;
        else burst_last_end = 32'(eff_r_tailer);

        if (eff_r_num_beats == '0) burst_expected = burst_last_end - 32'(eff_r_offset);
        else
          burst_expected = (StrbWidth - 32'(eff_r_offset))
              + (32'(eff_r_num_beats) - 1) * StrbWidth
              + burst_last_end;

        // MxQuant burst init on first gated data
        if (is_mx_quant && gated_valid != '0 && mx_r_expected_q == '0) begin
          mx_r_expected_d = burst_expected;
          mx_r_received_d = '0;
          mx_r_last_d     = eff_r_last;
        end

        // FpCast compression burst init
        if (is_fpcast_compress && !is_r_expansion
            && gated_valid != '0
            && fp_r_expected_q == '0) begin
          fp_r_expected_d = burst_expected;
          fp_r_received_d = '0;
          fp_r_last_d     = eff_r_last;
        end

        // Count received R bytes (use registered snapshot)
        if (is_mx_quant && gated_valid != '0)
          mx_r_received_d = mx_r_received_q + $countones(gated_valid);
        if (is_fpcast_compress && gated_valid != '0)
          fp_r_received_d = fp_r_received_q + $countones(gated_valid);

        // Drain pending: all R bytes received for this burst
        if (is_mx_quant && mx_r_expected_q > 0 && mx_r_received_d >= mx_r_expected_q) begin
          if (mx_r_last_q) mx_drain_pending = 1'b1;
          else begin
            // Intermediate burst: reset counters
            mx_r_expected_d = '0;
            mx_r_received_d = '0;
          end
        end
        if (is_fpcast_compress && fp_r_expected_q > 0 && fp_r_received_d >= fp_r_expected_q) begin
          if (fp_r_last_q) fp_drain_pending = 1'b1;
          else begin
            fp_r_expected_d = '0;
            fp_r_received_d = '0;
          end
        end
      end

      // ── Drain FSM sequential ─────────────────────────────────
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          mx_draining_q   <= 1'b0;
          fp_draining_q   <= 1'b0;
          mx_r_expected_q <= '0;
          mx_r_received_q <= '0;
          mx_r_last_q     <= 1'b0;
          fp_r_expected_q <= '0;
          fp_r_received_q <= '0;
          fp_r_last_q     <= 1'b0;
        end else begin
          mx_r_expected_q <= mx_r_expected_d;
          mx_r_received_q <= mx_r_received_d;
          mx_r_last_q     <= mx_r_last_d;
          fp_r_expected_q <= fp_r_expected_d;
          fp_r_received_q <= fp_r_received_d;
          fp_r_last_q     <= fp_r_last_d;

          // Drain entry: registered for timing closure
          if (mx_drain_pending && !mx_draining_q) mx_draining_q <= 1'b1;
          // Drain exit: ALCU pack buffer empty
          // (ALCU reports empty via valid_o == 0 during drain)
          if (mx_draining_q && alcu_valid_o == '0) begin
            mx_draining_q   <= 1'b0;
            mx_r_expected_q <= '0;
            mx_r_received_q <= '0;
          end

          if (fp_drain_pending && !fp_draining_q) fp_draining_q <= 1'b1;
          if (fp_draining_q && alcu_valid_o == '0) begin
            fp_draining_q   <= 1'b0;
            fp_r_expected_q <= '0;
            fp_r_received_q <= '0;
          end

        end
      end

      assign consumed_w = axi_write_req_o.w_valid && axi_write_rsp_i.w_ready;

    end
  endgenerate

  // ── Module Control ───────────────────────────────────────────
  assign r_dp_busy_o   = r_dp_valid_i;
  assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
  assign buffer_busy_o = |buffer_out_valid;

endmodule : vidma_transport_layer_rw_axi
