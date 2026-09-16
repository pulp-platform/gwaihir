// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors: Sergio Mazzola <smazzola@iis.ee.ethz.ch>

`include "hci_helpers.svh"

// Splitting module: HCI-Core wide interface → NB_OUT_CHAN Snitch TCDM bus plugs.
//
// Accepts a single DW-bit HCI-Core transaction from the accelerator and splits it into
// NB_OUT_CHAN narrower (DW/NB_OUT_CHAN-bit) sub-transactions on plain Snitch TCDM bus ports.
//
// Grant semantics: the accelerator sees gnt=1 only when all sub-channel banks simultaneously
// assert q_ready. Partially-committed sub-channels are tracked and their requests suppressed
// so already-granted banks are freed for other initiators while remaining ones are pending.
//
// Response semantics: responses from early-completing sub-channels are buffered in per-channel
// registers. When the last sub-channel's p_valid arrives, it bypasses its register and is
// combined combinatorially with already-buffered data. The accelerator sees r_valid as a
// one-cycle pulse exactly one cycle after gnt, with no dependence on r_ready.
//
// Assumption: the accelerator issues at most one outstanding transaction; it must not assert
// a new req before the current r_valid pulse. Violating this corrupts per-channel tracking.

module konark_tcdm_split
  import hwpe_stream_package::*;
  import hci_package::*;
#(
  parameter int unsigned DW          = 64,
  parameter int unsigned BW          = 8,
  parameter int unsigned NB_OUT_CHAN = 2,
  parameter type         tcdm_req_t  = logic,
  parameter type         tcdm_rsp_t  = logic,
  parameter hci_size_parameter_t `HCI_SIZE_PARAM(tcdm_target) = '0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  hci_core_intf.target                  tcdm_target,
  output tcdm_req_t [NB_OUT_CHAN-1:0]   tcdm_req_o,
  input  tcdm_rsp_t [NB_OUT_CHAN-1:0]   tcdm_rsp_i
);

  localparam int unsigned DW_OUT = DW / NB_OUT_CHAN;
  localparam int unsigned BW_OUT = 8;
  localparam int unsigned EHW    = `HCI_SIZE_GET_EHW(tcdm_target);

  // ---------------------------------------------------------------------------
  // Request path
  // ---------------------------------------------------------------------------

  // sub_granted_q[ii]: bank ii was granted in a previous cycle; its request is suppressed
  // until the overall transaction commits (all banks simultaneously grant).
  logic [NB_OUT_CHAN-1:0] sub_granted_q;

  logic [NB_OUT_CHAN-1:0] chan_req;       // q_valid forwarded to each bank
  logic [NB_OUT_CHAN-1:0] chan_gnt;       // q_ready from each bank
  logic [NB_OUT_CHAN-1:0] chan_committed; // sub-channel committed this cycle

  for (genvar ii = 0; ii < NB_OUT_CHAN; ii++) begin : gen_req_binding
    assign chan_req[ii]       = tcdm_target.req & ~sub_granted_q[ii];
    assign chan_gnt[ii]       = tcdm_rsp_i[ii].q_ready;
    assign chan_committed[ii] = sub_granted_q[ii] | (chan_req[ii] & chan_gnt[ii]);

    assign tcdm_req_o[ii].q_valid = chan_req[ii];
    assign tcdm_req_o[ii].q.addr  = tcdm_target.add + ii * (DW_OUT / BW_OUT);
    assign tcdm_req_o[ii].q.write = ~tcdm_target.wen;   // HCI: wen=1 read, 0 write; TCDM: write=1 write
    assign tcdm_req_o[ii].q.strb  = tcdm_target.be  [(ii+1)*DW_OUT/BW_OUT-1 : ii*DW_OUT/BW_OUT];
    assign tcdm_req_o[ii].q.data  = tcdm_target.data [(ii+1)*DW_OUT-1        : ii*DW_OUT        ];
    assign tcdm_req_o[ii].q.amo   = lsu_pkg::AMONone;
    assign tcdm_req_o[ii].q.user  = '0;
  end

  // Grant to accelerator only when every sub-channel has been committed to its bank.
  assign tcdm_target.gnt = tcdm_target.req & (&chan_committed);

  // Accumulate partial grants; cleared when all committed or on req drop.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sub_granted_q <= '0;
    end else if (clear_i) begin
      sub_granted_q <= '0;
    end else if (tcdm_target.gnt) begin
      sub_granted_q <= '0;
    end else if (tcdm_target.req) begin
      for (int ii = 0; ii < NB_OUT_CHAN; ii++) begin
        if (chan_req[ii] & chan_gnt[ii])
          sub_granted_q[ii] <= 1'b1;
      end
    end else begin
      sub_granted_q <= '0;
    end
  end

  // ---------------------------------------------------------------------------
  // Response path with per-channel register and bypass mux
  // ---------------------------------------------------------------------------

  // sub_r_valid_q[ii] / sub_r_data_q[ii]: p_valid from bank ii buffered in a register.
  // The register holds data from early-completing channels while slower ones are still pending.
  logic [NB_OUT_CHAN-1:0]             sub_r_valid_q;
  logic [NB_OUT_CHAN-1:0][DW_OUT-1:0] sub_r_data_q;

  logic [NB_OUT_CHAN-1:0]             chan_r_valid;  // p_valid arriving from each bank this cycle
  logic [NB_OUT_CHAN-1:0]             sub_r_avail;   // response available: in reg OR arriving now
  logic [NB_OUT_CHAN-1:0][DW_OUT-1:0] mux_r_data;    // per-channel bypass mux output
  logic                               all_r_avail;
  logic                               retire;

  for (genvar ii = 0; ii < NB_OUT_CHAN; ii++) begin : gen_rsp_binding
    assign chan_r_valid[ii] = tcdm_rsp_i[ii].p_valid;

    // Available = already in register, OR arriving on this cycle (bypass path).
    assign sub_r_avail[ii] = sub_r_valid_q[ii] | chan_r_valid[ii];

    // Bypass mux: use registered data if already captured, otherwise take directly from bank.
    // For the last arriving channel (all others already buffered), this provides the full
    // response to the accelerator without an intermediate register stage.
    assign mux_r_data[ii] = sub_r_valid_q[ii] ? sub_r_data_q[ii] : tcdm_rsp_i[ii].p.data;
  end

  assign all_r_avail = &sub_r_avail;

  // r_valid is a one-cycle pulse: asserted when all sub-channel responses are available,
  // cleared the following cycle when registers are reset. No dependence on r_ready.
  assign retire              = all_r_avail;
  assign tcdm_target.r_valid = all_r_avail;

  // Reconstruction: channel 0 at LSB, channel NB_OUT_CHAN-1 at MSB.
  assign tcdm_target.r_data = { >> {mux_r_data} };

  // Sideband signals not carried by the Snitch TCDM bus.
  assign tcdm_target.r_user = '0;
  assign tcdm_target.r_id   = '0;
  assign tcdm_target.r_opc  = '0;
  assign tcdm_target.r_ecc  = '0;

  // Buffer incoming responses as they arrive from each bank.
  // retire takes priority: on the retire cycle, bypass muxes carry data combinatorially
  // to the accelerator and registers are cleared for the next transaction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sub_r_valid_q <= '0;
      sub_r_data_q  <= '0;
    end else if (clear_i) begin
      sub_r_valid_q <= '0;
      sub_r_data_q  <= '0;
    end else if (retire) begin
      sub_r_valid_q <= '0;
    end else begin
      for (int ii = 0; ii < NB_OUT_CHAN; ii++) begin
        // Capture only if the slot is empty; banks send p_valid once per request.
        if (chan_r_valid[ii] & ~sub_r_valid_q[ii]) begin
          sub_r_valid_q[ii] <= 1'b1;
          sub_r_data_q[ii]  <= tcdm_rsp_i[ii].p.data;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // ECC handshake on the HCI target side (no ECC on Snitch TCDM bus)
  // ---------------------------------------------------------------------------

  if (EHW > 0) begin : ecc_handshake_gen
    assign tcdm_target.egnt     = '{default: {tcdm_target.gnt}};
    assign tcdm_target.r_evalid = '{default: {tcdm_target.r_valid}};
  end else begin : no_ecc_handshake_gen
    assign tcdm_target.egnt     = '1;
    assign tcdm_target.r_evalid = '0;
  end

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

`ifndef SYNTHESIS
`ifndef VERILATOR
`ifndef VCS
  `HCI_SIZE_CHECK_ASSERTS(tcdm_target);

  // Verify no new grant while old response data is still buffered (without a simultaneous
  // retire clearing it). A new req in the same cycle as retire is legal: the accelerator
  // may issue the next req in the cycle r_valid fires (back-to-back transactions), and
  // bank responses for the new transaction cannot arrive until the following cycle.
  no_grant_during_pending_rsp : assert property (
    @(posedge clk_i) disable iff (!rst_ni || clear_i)
    (tcdm_target.gnt & |sub_r_valid_q) |-> retire
  ) else $error("konark_tcdm_split: new gnt while previous response still pending");
`endif
`endif
`endif

endmodule : konark_tcdm_split
