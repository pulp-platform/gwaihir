// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "hci_helpers.svh"

module surya_hwpe_subsystem
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import lsu_pkg::amo_op_e;
#(
  parameter type tcdm_req_t   = logic,
  parameter type tcdm_rsp_t   = logic,
  parameter type periph_req_t = logic,
  parameter type periph_rsp_t = logic,

  parameter int unsigned HwpeDataWidth = 256,
  parameter int unsigned IdWidth       = 8,
  parameter int unsigned NrCores       = 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic test_mode_i,

  // TCDM interface (Master)
  output tcdm_req_t tcdm_req_o,
  input  tcdm_rsp_t tcdm_rsp_i,

  // HWPE control interface (Slave)
  input  periph_req_t hwpe_ctrl_req_i,
  output periph_rsp_t hwpe_ctrl_rsp_o,

  output logic [NrCores-1:0] hwpe_evt_o
);

  // verilog_format: off
  localparam hci_size_parameter_t HCISizeTcdm = '{
    DW:  HwpeDataWidth,
    AW:  DEFAULT_AW,
    BW:  DEFAULT_BW,
    UW:  0,
    IW:  1,
    EW:  0,
    EHW: 0
  };
  // verilog_format: on

  logic [1:0] hwpe_clk;
  logic [1:0] clk_en;
  logic       mux_sel;

  logic [        1:0][NrCores-1:0][1:0] evt;
  logic [NrCores-1:0]                   hwpe_evt_q;

  hwpe_ctrl_intf_periph #(.ID_WIDTH(IdWidth)) periph[0:1] (.clk(clk_i));

  hci_core_intf #(
`ifndef SYNTHESIS
    .WAIVE_RSP3_ASSERT(1'b1),
`endif
    .DW               (HwpeDataWidth),
    .UW               (0),
    .IW               (1),
    .EW               (0),
    .EHW              (0)
  ) tcdm (
    .clk(clk_i)
  );

  hci_core_intf #(
`ifndef SYNTHESIS
    .WAIVE_RSP3_ASSERT(1'b1),
`endif
    .DW               (HwpeDataWidth),
    .UW               (0),
    .IW               (1),
    .EW               (0),
    .EHW              (0)
  ) tcdm_to_mux[0:1] (
    .clk(clk_i)
  );

  // request channel
  assign tcdm_req_o.q_valid = tcdm.req;
  assign tcdm_req_o.q.addr  = tcdm.add;
  assign tcdm_req_o.q.write = ~tcdm.wen;
  assign tcdm_req_o.q.strb  = tcdm.be;
  assign tcdm_req_o.q.data  = tcdm.data;
  assign tcdm_req_o.q.amo   = lsu_pkg::AMONone;
  assign tcdm_req_o.q.user  = '0;
  // response channel
  assign tcdm.gnt           = tcdm_rsp_i.q_ready;
  assign tcdm.r_valid       = tcdm_rsp_i.p_valid;
  assign tcdm.r_data        = tcdm_rsp_i.p.data;
  assign tcdm.r_opc         = '0;
  assign tcdm.r_user        = '0;

  // Surya matches a response to a request by `r_id`, and the Snitch TCDM returns none.
  assign tcdm.r_id = tcdm.id;

  localparam int unsigned AccAddrWidth = $clog2(surya_regif_pkg::SURYA_REGIF_SIZE);

  localparam logic [1:0] CtrlEvtClr = 2'd0;  // +0x0
  localparam logic [1:0] CtrlMuxSel = 2'd1;  // +0x4
  localparam logic [1:0] CtrlClkEn = 2'd2;  // +0x8

  logic       ctrl_blk_sel;
  logic [1:0] ctrl_blk_idx;
  logic periph_sel_q, periph_sel_d;
  assign ctrl_blk_sel = hwpe_ctrl_req_i.q.addr[AccAddrWidth+1];
  assign ctrl_blk_idx = hwpe_ctrl_req_i.q.addr[3:2];
  assign periph_sel_d = hwpe_ctrl_req_i.q.addr[AccAddrWidth];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      periph_sel_q <= 1'b0;
    end else begin
      periph_sel_q <= periph_sel_d;
    end
  end

  always_comb begin
    // defaults overridden below
    periph[0].req           = '0;
    periph[1].req           = '0;
    hwpe_ctrl_rsp_o.q_ready = '0;
    hwpe_ctrl_rsp_o.p.data  = '0;
    hwpe_ctrl_rsp_o.p_valid = '0;

    // independent of selector
    periph[0].add  = AccAddrWidth'(hwpe_ctrl_req_i.q.addr);
    periph[0].wen  = ~hwpe_ctrl_req_i.q.write;
    periph[0].be   = hwpe_ctrl_req_i.q.strb;
    periph[0].data = hwpe_ctrl_req_i.q.data;
    periph[0].id   = hwpe_ctrl_req_i.q.user;
    periph[1].add  = AccAddrWidth'(hwpe_ctrl_req_i.q.addr);
    periph[1].wen  = ~hwpe_ctrl_req_i.q.write;
    periph[1].be   = hwpe_ctrl_req_i.q.strb;
    periph[1].data = hwpe_ctrl_req_i.q.data;
    periph[1].id   = hwpe_ctrl_req_i.q.user;

    if (ctrl_blk_sel) begin
      hwpe_ctrl_rsp_o.q_ready = hwpe_ctrl_req_i.q_valid;
      hwpe_ctrl_rsp_o.p_valid = '1;
    end else begin
      // request channel
      if (periph_sel_d == 1'b0) begin
        periph[0].req           = hwpe_ctrl_req_i.q_valid;
        hwpe_ctrl_rsp_o.q_ready = periph[0].gnt;
      end else begin
        periph[1].req           = hwpe_ctrl_req_i.q_valid;
        hwpe_ctrl_rsp_o.q_ready = periph[1].gnt;
      end
      // response channel
      if (periph_sel_q == 1'b0) begin
        hwpe_ctrl_rsp_o.p.data  = periph[0].r_data;
        hwpe_ctrl_rsp_o.p_valid = periph[0].r_valid;
      end else begin
        hwpe_ctrl_rsp_o.p.data  = periph[1].r_data;
        hwpe_ctrl_rsp_o.p_valid = periph[1].r_valid;
      end
    end

  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      clk_en <= '0;
    end else begin
      if (ctrl_blk_sel && (ctrl_blk_idx == CtrlClkEn) && hwpe_ctrl_req_i.q_valid &&
          hwpe_ctrl_req_i.q.write) begin
        clk_en <= hwpe_ctrl_req_i.q.data[1:0];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mux_sel <= '0;
    end else begin
      if (ctrl_blk_sel && (ctrl_blk_idx == CtrlMuxSel) && hwpe_ctrl_req_i.q_valid &&
          hwpe_ctrl_req_i.q.write) begin
        mux_sel <= hwpe_ctrl_req_i.q.data[0];
      end
    end
  end


  for (genvar ii = 0; ii < NrCores; ii++) begin : gen_hwpe_evt
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        hwpe_evt_q[ii] <= '0;
      end else begin
        if (evt[mux_sel][ii]) begin
          hwpe_evt_q[ii] <= 1'b1;
        end
        else if (ctrl_blk_sel && (ctrl_blk_idx == CtrlEvtClr) &&
                 hwpe_ctrl_req_i.q_valid && hwpe_ctrl_req_i.q.write &&
                 hwpe_ctrl_req_i.q.data == (1 << ii)) begin
          hwpe_evt_q[ii] <= 1'b0;
        end
      end
    end
  end
  assign hwpe_evt_o = hwpe_evt_q;

  tc_clk_gating i_surya_clk_gate (
    .clk_i    (clk_i),
    .en_i     (clk_en[0]),
    .test_en_i('0),
    .clk_o    (hwpe_clk[0])
  );

  tc_clk_gating i_datamover_clk_gate (
    .clk_i    (clk_i),
    .en_i     (clk_en[1]),
    .test_en_i('0),
    .clk_o    (hwpe_clk[1])
  );

  surya_hwpe_top #(
    .HCI_SIZE_tcdm(HCISizeTcdm),
    .NumCores     (NrCores),
    .IdWidth      (IdWidth)
  ) i_surya_top (
    .clk_i (hwpe_clk[0]),
    .rst_ni(rst_ni),
    .busy_o(),
    .evt_o (evt[0]),
    .tcdm  (tcdm_to_mux[0]),
    .periph(periph[0])
  );

  datamover_top #(
    .ID           (IdWidth),
    .N_CORES      (NrCores),
    .BW           (HwpeDataWidth),
    .HCI_SIZE_tcdm(HCISizeTcdm)
  ) i_datamover_top (
    .clk_i      (hwpe_clk[1]),
    .rst_ni     (rst_ni),
    .test_mode_i(test_mode_i),
    .evt_o      (evt[1]),
    .tcdm       (tcdm_to_mux[1]),
    .periph     (periph[1])
  );

  hci_core_mux_static #(
    .NB_CHAN    (2),
    .HCI_SIZE_in(HCISizeTcdm)
  ) i_static_mux (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .clear_i(1'b0),
    .sel_i  (mux_sel),
    .in     (tcdm_to_mux),
    .out    (tcdm)
  );

endmodule : surya_hwpe_subsystem
