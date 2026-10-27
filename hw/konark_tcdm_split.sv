// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors: Sergio Mazzola <smazzola@iis.ee.ethz.ch>
//
// Adapted from konark-cluster cf58dce.

`include "hci_helpers.svh"

// Splits a DW-bit HCI-Core transaction into NB_OUT_CHAN Snitch TCDM bus plugs. Each plug commits
// on its own q_ready, and gnt rises once all are committed. r_valid is a one-cycle pulse one cycle
// after gnt. The accelerator must not issue a new req before r_valid.

module konark_tcdm_split
  import hci_package::*;
#(
  parameter int unsigned         DW                   = 64,
  parameter int unsigned         BW                   = 8,
  parameter int unsigned         NB_OUT_CHAN          = 2,
  parameter type                 tcdm_req_t           = logic,
  parameter type                 tcdm_rsp_t           = logic,
  // verilog_lint: waive parameter-name-style
  parameter hci_size_parameter_t HCI_SIZE_tcdm_target = '0
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  input  logic                                  clear_i,
         hci_core_intf.target                   tcdm_target,
  output tcdm_req_t           [NB_OUT_CHAN-1:0] tcdm_req_o,
  input  tcdm_rsp_t           [NB_OUT_CHAN-1:0] tcdm_rsp_i
);

  localparam int unsigned DwOut = DW / NB_OUT_CHAN;
  localparam int unsigned BwOut = BW;
  localparam int unsigned EHW = `HCI_SIZE_GET_EHW(tcdm_target);

  // ---------------------------------------------------------------------------
  // Request path
  // ---------------------------------------------------------------------------

  // Plugs granted in an earlier cycle; their requests stay off until gnt.
  logic [NB_OUT_CHAN-1:0] sub_granted_q;

  logic [NB_OUT_CHAN-1:0] chan_req;  // q_valid forwarded to each bank
  logic [NB_OUT_CHAN-1:0] chan_gnt;  // q_ready from each bank
  logic [NB_OUT_CHAN-1:0] chan_committed;  // plug committed this cycle

  for (genvar ii = 0; ii < NB_OUT_CHAN; ii++) begin : gen_req_binding
    assign chan_req[ii]       = tcdm_target.req & ~sub_granted_q[ii];
    assign chan_gnt[ii]       = tcdm_rsp_i[ii].q_ready;
    assign chan_committed[ii] = sub_granted_q[ii] | (chan_req[ii] & chan_gnt[ii]);

    assign tcdm_req_o[ii].q_valid = chan_req[ii];
    assign tcdm_req_o[ii].q.addr  = tcdm_target.add + ii * (DwOut / BwOut);
    // HCI: wen=1 read, 0 write; TCDM: write=1 write
    assign tcdm_req_o[ii].q.write = ~tcdm_target.wen;
    assign tcdm_req_o[ii].q.strb  = tcdm_target.be[(ii+1)*DwOut/BwOut-1 : ii*DwOut/BwOut];
    assign tcdm_req_o[ii].q.data  = tcdm_target.data[(ii+1)*DwOut-1 : ii*DwOut];
    assign tcdm_req_o[ii].q.amo   = lsu_pkg::AMONone;
    assign tcdm_req_o[ii].q.user  = '0;
  end

  // Grant to accelerator only when every plug has been committed to its bank.
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
        if (chan_req[ii] & chan_gnt[ii]) sub_granted_q[ii] <= 1'b1;
      end
    end else begin
      sub_granted_q <= '0;
    end
  end

  // ---------------------------------------------------------------------------
  // Response path with per-channel register and bypass mux
  // ---------------------------------------------------------------------------

  logic [NB_OUT_CHAN-1:0]            sub_r_valid_q;
  logic [NB_OUT_CHAN-1:0][DwOut-1:0] sub_r_data_q;

  logic [NB_OUT_CHAN-1:0]            chan_r_valid;  // p_valid arriving from each bank this cycle
  logic [NB_OUT_CHAN-1:0]            sub_r_avail;  // response available: in reg OR arriving now
  logic [NB_OUT_CHAN-1:0][DwOut-1:0] mux_r_data;  // per-channel bypass mux output
  logic                              all_r_avail;
  logic                              retire;
  logic                              abort;

  for (genvar ii = 0; ii < NB_OUT_CHAN; ii++) begin : gen_rsp_binding
    assign chan_r_valid[ii] = tcdm_rsp_i[ii].p_valid;

    assign sub_r_avail[ii] = sub_r_valid_q[ii] | chan_r_valid[ii];

    // Bypass mux: the registered data if already captured, otherwise the bank response.
    assign mux_r_data[ii] = sub_r_valid_q[ii] ? sub_r_data_q[ii] : tcdm_rsp_i[ii].p.data;
  end

  assign all_r_avail = &sub_r_avail;

  assign retire              = all_r_avail;
  // A soft clear in the accelerator drops req before gnt: discard the partial responses.
  assign abort               = ~tcdm_target.req & |sub_granted_q;
  assign tcdm_target.r_valid = all_r_avail;

  // Reconstruction: channel 0 at LSB, channel NB_OUT_CHAN-1 at MSB.
  assign tcdm_target.r_data = {>>{mux_r_data}};

  // Sideband signals not carried by the Snitch TCDM bus.
  assign tcdm_target.r_user = '0;
  assign tcdm_target.r_id   = '0;
  assign tcdm_target.r_opc  = '0;
  assign tcdm_target.r_ecc  = '0;

  // Buffer the responses of each bank. retire clears the registers for the next transaction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sub_r_valid_q <= '0;
      sub_r_data_q  <= '0;
    end else if (clear_i) begin
      sub_r_valid_q <= '0;
      sub_r_data_q  <= '0;
    end else if (retire | abort) begin
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

  if (EHW > 0) begin : gen_ecc_handshake
    assign tcdm_target.egnt     = '{default: {tcdm_target.gnt}};
    assign tcdm_target.r_evalid = '{default: {tcdm_target.r_valid}};
  end else begin : gen_no_ecc_handshake
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

  // A new gnt with buffered responses is legal only in the retire cycle.
  no_grant_during_pending_rsp :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni || clear_i)
    (tcdm_target.gnt & |(sub_r_valid_q & ~sub_granted_q)) |-> retire
  )
  else $error("konark_tcdm_split: new gnt while previous response still pending");
`endif
`endif
`endif

endmodule : konark_tcdm_split
