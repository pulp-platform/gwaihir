// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

module snitch_hwpe_subsystem
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import lsu_pkg::amo_op_e;
  import gwaihir_pkg::hwpe_acc_e;
#(
  parameter type tcdm_req_t   = logic,
  parameter type tcdm_rsp_t   = logic,
  parameter type periph_req_t = logic,
  parameter type periph_rsp_t = logic,

  parameter int unsigned HwpeDataWidth = 256,
  parameter int unsigned IdWidth       = 8,
  parameter int unsigned CtrlDataWidth = 32,
  parameter int unsigned NrCores       = 8,
  parameter hwpe_acc_e   Accelerator   = gwaihir_pkg::HwpeMxCore
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

  localparam bit IsSurya = (Accelerator == gwaihir_pkg::HwpeSurya);

  // Address frame: one window per HWPE, the accelerator first, then the datamover,
  // and the control block after the windows. `gw_hwpe_subsystem_addrmap.h` mirrors it.
  localparam int unsigned NumHwpe = 2;
  localparam int unsigned AccPort = 0;
  localparam int unsigned DmaPort = 1;
  localparam int unsigned HwpeSelWidth = $clog2(NumHwpe);
  localparam int unsigned AccWindowWidth = 9;
  localparam int unsigned NumCtrlRegs = 3;
  localparam int unsigned CtrlIdxWidth = $clog2(NumCtrlRegs);
  localparam int unsigned CtrlIdxOffset = $clog2(CtrlDataWidth / 8);

  localparam logic [CtrlIdxWidth-1:0] CtrlEvtClr = 0;
  localparam logic [CtrlIdxWidth-1:0] CtrlMuxSel = 1;
  localparam logic [CtrlIdxWidth-1:0] CtrlClkEn = 2;

  // MXCore sizes its HCI ports with the hci defaults and its id filter asserts that
  // the port matches. Surya sizes its ports from the port.
  // verilog_format: off
  localparam hci_size_parameter_t HCISizeTcdm = '{
    DW:  HwpeDataWidth,
    AW:  DEFAULT_AW,
    BW:  DEFAULT_BW,
    UW:  DEFAULT_UW,
    IW:  DEFAULT_IW,
    EW:  DEFAULT_EW,
    EHW: DEFAULT_EHW
  };
  // verilog_format: on

  logic [     NumHwpe-1:0] hwpe_clk;
  logic [     NumHwpe-1:0] clk_en;
  logic [HwpeSelWidth-1:0] mux_sel;

  logic [NumHwpe-1:0][NrCores-1:0][REGFILE_N_EVT-1:0] evt;
  logic                                               busy;
  logic [NrCores-1:0]                                 hwpe_evt_q;

  hwpe_ctrl_intf_periph #(.ID_WIDTH(IdWidth)) periph[0:NumHwpe-1] (.clk(clk_i));

  hci_core_intf #(
`ifndef SYNTHESIS
    .WAIVE_RSP3_ASSERT(1'b1),
`endif
    .DW               (HwpeDataWidth),
    .EW               (DEFAULT_EW),
    .EHW              (DEFAULT_EHW)
  ) tcdm (
    .clk(clk_i)
  );

  hci_core_intf #(
`ifndef SYNTHESIS
    .WAIVE_RSP3_ASSERT(1'b1),
`endif
    .DW               (HwpeDataWidth),
    .EW               (DEFAULT_EW),
    .EHW              (DEFAULT_EHW)
  ) tcdm_to_mux[0:NumHwpe-1] (
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
  // The accelerators rebuild `r_id` themselves and carry no ECC.
  assign tcdm.r_id          = tcdm.id;
  assign tcdm.r_ecc         = '0;
  assign tcdm.egnt          = '0;
  assign tcdm.r_evalid      = '0;

  logic                    ctrl_blk_sel;
  logic [CtrlIdxWidth-1:0] ctrl_blk_idx;
  logic [HwpeSelWidth-1:0] periph_sel_q, periph_sel_d;
  assign ctrl_blk_sel = hwpe_ctrl_req_i.q.addr[AccWindowWidth+HwpeSelWidth];
  assign ctrl_blk_idx = hwpe_ctrl_req_i.q.addr[CtrlIdxOffset+:CtrlIdxWidth];
  assign periph_sel_d = hwpe_ctrl_req_i.q.addr[AccWindowWidth+:HwpeSelWidth];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      periph_sel_q <= 1'b0;
    end else begin
      periph_sel_q <= periph_sel_d;
    end
  end

  always_comb begin
    // defaults overridden below
    periph[AccPort].req     = '0;
    periph[DmaPort].req     = '0;
    hwpe_ctrl_rsp_o.q_ready = '0;
    hwpe_ctrl_rsp_o.p.data  = '0;
    hwpe_ctrl_rsp_o.p_valid = '0;

    // independent of selector
    periph[AccPort].add  = AccWindowWidth'(hwpe_ctrl_req_i.q.addr);
    periph[AccPort].wen  = ~hwpe_ctrl_req_i.q.write;
    periph[AccPort].be   = hwpe_ctrl_req_i.q.strb;
    periph[AccPort].data = hwpe_ctrl_req_i.q.data;
    periph[AccPort].id   = hwpe_ctrl_req_i.q.user;
    periph[DmaPort].add  = AccWindowWidth'(hwpe_ctrl_req_i.q.addr);
    periph[DmaPort].wen  = ~hwpe_ctrl_req_i.q.write;
    periph[DmaPort].be   = hwpe_ctrl_req_i.q.strb;
    periph[DmaPort].data = hwpe_ctrl_req_i.q.data;
    periph[DmaPort].id   = hwpe_ctrl_req_i.q.user;

    if (ctrl_blk_sel) begin
      hwpe_ctrl_rsp_o.q_ready = hwpe_ctrl_req_i.q_valid;
      hwpe_ctrl_rsp_o.p_valid = '1;
    end else begin
      // request channel
      if (periph_sel_d == AccPort) begin
        periph[AccPort].req     = hwpe_ctrl_req_i.q_valid;
        hwpe_ctrl_rsp_o.q_ready = periph[AccPort].gnt;
      end else begin
        periph[DmaPort].req     = hwpe_ctrl_req_i.q_valid;
        hwpe_ctrl_rsp_o.q_ready = periph[DmaPort].gnt;
      end
      // response channel
      if (periph_sel_q == AccPort) begin
        hwpe_ctrl_rsp_o.p.data  = periph[AccPort].r_data;
        hwpe_ctrl_rsp_o.p_valid = periph[AccPort].r_valid;
      end else begin
        hwpe_ctrl_rsp_o.p.data  = periph[DmaPort].r_data;
        hwpe_ctrl_rsp_o.p_valid = periph[DmaPort].r_valid;
      end
    end

  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      clk_en <= '0;
    end else begin
      if (ctrl_blk_sel && (ctrl_blk_idx == CtrlClkEn) && hwpe_ctrl_req_i.q_valid &&
          hwpe_ctrl_req_i.q.write) begin
        clk_en <= hwpe_ctrl_req_i.q.data[NumHwpe-1:0];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mux_sel <= '0;
    end else begin
      if (ctrl_blk_sel && (ctrl_blk_idx == CtrlMuxSel) && hwpe_ctrl_req_i.q_valid &&
          hwpe_ctrl_req_i.q.write) begin
        mux_sel <= hwpe_ctrl_req_i.q.data[HwpeSelWidth-1:0];
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

  tc_clk_gating i_acc_clk_gate (
    .clk_i    (clk_i),
    .en_i     (clk_en[AccPort]),
    .test_en_i('0),
    .clk_o    (hwpe_clk[AccPort])
  );

  tc_clk_gating i_datamover_clk_gate (
    .clk_i    (clk_i),
    .en_i     (clk_en[DmaPort]),
    .test_en_i('0),
    .clk_o    (hwpe_clk[DmaPort])
  );

  if (IsSurya) begin : gen_surya
    `ASSERT_INIT(SuryaRegfileFitsWindow, surya_regif_pkg::SURYA_REGIF_SIZE <= (1 << AccWindowWidth))

    surya_hwpe_top #(
      .HCI_SIZE_tcdm(HCISizeTcdm),
      .NumCores     (NrCores),
      .IdWidth      (IdWidth)
    ) i_surya_top (
      .clk_i (hwpe_clk[AccPort]),
      .rst_ni(rst_ni),
      .busy_o(busy),
      .evt_o (evt[AccPort]),
      .tcdm  (tcdm_to_mux[AccPort]),
      .periph(periph[AccPort])
    );
  end else begin : gen_mxcore
    mxcore_hwpe_top #(
      .N_CORES(NrCores)
    ) i_mxcore_top (
      .clk_i      (hwpe_clk[AccPort]),
      .rst_ni     (rst_ni),
      .test_mode_i(test_mode_i),
      .evt_o      (evt[AccPort]),
      .busy_o     (busy),
      .tcdm       (tcdm_to_mux[AccPort]),
      .periph     (periph[AccPort])
    );
  end

  datamover_top #(
    .ID           (IdWidth),
    .N_CORES      (NrCores),
    .BW           (HwpeDataWidth),
    .HCI_SIZE_tcdm(HCISizeTcdm)
  ) i_datamover_top (
    .clk_i      (hwpe_clk[DmaPort]),
    .rst_ni     (rst_ni),
    .test_mode_i(test_mode_i),
    .evt_o      (evt[DmaPort]),
    .tcdm       (tcdm_to_mux[DmaPort]),
    .periph     (periph[DmaPort])
  );

  hci_core_mux_static #(
    .NB_CHAN    (NumHwpe),
    .HCI_SIZE_in(HCISizeTcdm)
  ) i_static_mux (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .clear_i(1'b0),
    .sel_i  (mux_sel),
    .in     (tcdm_to_mux),
    .out    (tcdm)
  );

endmodule : snitch_hwpe_subsystem
