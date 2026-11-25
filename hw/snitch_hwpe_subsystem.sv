// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

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
  parameter hwpe_acc_e   Accelerator   = gwaihir_pkg::HwpeMxCore,
  parameter bit          UseDatamover  = 1'b1
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

  localparam int unsigned NumHwpe = UseDatamover ? 2 : 1;
  localparam int unsigned AccPort = 0;
  localparam int unsigned DmaPort = 1;
  localparam int unsigned HwpeSelWidth = cc_pkg::idx_width(NumHwpe);

  localparam int unsigned AccWindowWidth = 9;
  localparam int unsigned SlotWidth = 2;
  localparam int unsigned FrameWidth = AccWindowWidth + SlotWidth;
  localparam logic [SlotWidth-1:0] CtrlSlot = 1;
  localparam logic [SlotWidth-1:0] DmaSlot = 2;
  localparam logic [SlotWidth-1:0] UnusedSlot = 3;

  localparam int unsigned NumCtrlRegs = 3;
  localparam int unsigned CtrlIdxWidth = $clog2(NumCtrlRegs);
  localparam int unsigned CtrlIdxOffset = $clog2(CtrlDataWidth / 8);

  localparam logic [CtrlIdxWidth-1:0] CtrlEvtClr = 0;
  localparam logic [CtrlIdxWidth-1:0] CtrlMuxSel = 1;
  localparam logic [CtrlIdxWidth-1:0] CtrlClkEn = 2;

  `ASSERT_INIT(CtrlRegsFitSlot, NumCtrlRegs * (CtrlDataWidth / 8) <= (1 << AccWindowWidth),
               "The control registers must fit in one slot")

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
  logic [NumHwpe-1:0][NrCores-1:0]                    hwpe_irq_evt;

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

  logic [   SlotWidth-1:0] slot;
  logic                    ctrl_blk_sel;
  logic [CtrlIdxWidth-1:0] ctrl_blk_idx;
  assign slot         = hwpe_ctrl_req_i.q.addr[AccWindowWidth+:SlotWidth];
  assign ctrl_blk_sel = (slot == CtrlSlot);
  assign ctrl_blk_idx = hwpe_ctrl_req_i.q.addr[CtrlIdxOffset+:CtrlIdxWidth];

  logic ctrl_write;
  assign ctrl_write = ctrl_blk_sel && hwpe_ctrl_req_i.q_valid && hwpe_ctrl_req_i.q.write;

  // One-hot HWPE of the request. The accelerator takes every slot that is not the datamover's,
  // so each request is answered.
  logic [NumHwpe-1:0] hwpe_sel;
  assign hwpe_sel[AccPort] = !(UseDatamover && (slot == DmaSlot));
  if (UseDatamover) begin : gen_dm_sel
    assign hwpe_sel[DmaPort] = (slot == DmaSlot);
  end

  // The TCDM mux can only be set if there is a datamover
  if (UseDatamover) begin : gen_mux_sel
    `FFL(mux_sel, hwpe_ctrl_req_i.q.data[HwpeSelWidth-1:0],
         ctrl_write && (ctrl_blk_idx == CtrlMuxSel), '0)
  end else begin : gen_no_mux_sel
    assign mux_sel = HwpeSelWidth'(AccPort);
  end

  // Request to the selected HWPE, answers of all of them
  logic [NumHwpe-1:0]       hwpe_gnt;
  logic [NumHwpe-1:0]       hwpe_r_valid;
  logic [NumHwpe-1:0][31:0] hwpe_r_data;

  for (genvar i = 0; i < NumHwpe; i++) begin : gen_periph
    assign periph[i].req  = hwpe_ctrl_req_i.q_valid && !ctrl_blk_sel && hwpe_sel[i];
    assign periph[i].add  = AccWindowWidth'(hwpe_ctrl_req_i.q.addr);
    assign periph[i].wen  = ~hwpe_ctrl_req_i.q.write;
    assign periph[i].be   = hwpe_ctrl_req_i.q.strb;
    assign periph[i].data = hwpe_ctrl_req_i.q.data;
    assign periph[i].id   = hwpe_ctrl_req_i.q.user;

    assign hwpe_gnt[i]     = periph[i].gnt;
    assign hwpe_r_valid[i] = periph[i].r_valid;
    assign hwpe_r_data[i]  = periph[i].r_data;
  end

  always_comb begin
    hwpe_ctrl_rsp_o.q_ready = '0;
    hwpe_ctrl_rsp_o.p.data  = '0;
    hwpe_ctrl_rsp_o.p_valid = '0;

    if (ctrl_blk_sel) begin
      hwpe_ctrl_rsp_o.q_ready = hwpe_ctrl_req_i.q_valid;
      hwpe_ctrl_rsp_o.p_valid = '1;
    end else begin
      hwpe_ctrl_rsp_o.q_ready = |(hwpe_gnt & hwpe_sel);
      // Only the HWPE that was asked answers
      for (int i = 0; i < NumHwpe; i++) begin
        if (hwpe_r_valid[i]) begin
          hwpe_ctrl_rsp_o.p.data  = hwpe_r_data[i];
          hwpe_ctrl_rsp_o.p_valid = 1'b1;
        end
      end
    end
  end

  `FFL(clk_en, hwpe_ctrl_req_i.q.data[NumHwpe-1:0], ctrl_write && (ctrl_blk_idx == CtrlClkEn), '0)

  // An event of the selected HWPE sets the flag of its core, a write of that core's bit clears it
  logic [NrCores-1:0] hwpe_evt_d;

  for (genvar ii = 0; ii < NrCores; ii++) begin : gen_hwpe_evt
    assign hwpe_irq_evt[AccPort][ii] = IsSurya ? |evt[AccPort][ii] : evt[AccPort][ii][1];
    if (UseDatamover) begin : gen_datamover_evt
      assign hwpe_irq_evt[DmaPort][ii] = |evt[DmaPort][ii];
    end

    always_comb begin
      hwpe_evt_d[ii] = hwpe_evt_q[ii];
      if (hwpe_irq_evt[mux_sel][ii]) begin
        hwpe_evt_d[ii] = 1'b1;
      end else if (ctrl_write && (ctrl_blk_idx == CtrlEvtClr) &&
                   hwpe_ctrl_req_i.q.data == (1 << ii)) begin
        hwpe_evt_d[ii] = 1'b0;
      end
    end
  end
  `FF(hwpe_evt_q, hwpe_evt_d, '0)
  assign hwpe_evt_o = hwpe_evt_q;

  tc_clk_gating i_acc_clk_gate (
    .clk_i    (clk_i),
    .en_i     (clk_en[AccPort]),
    .test_en_i('0),
    .clk_o    (hwpe_clk[AccPort])
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
      .NumCores(NrCores)
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

  if (UseDatamover) begin : gen_datamover
    tc_clk_gating i_datamover_clk_gate (
      .clk_i    (clk_i),
      .en_i     (clk_en[DmaPort]),
      .test_en_i('0),
      .clk_o    (hwpe_clk[DmaPort])
    );

    datamover_top #(
      .IdWidth           (IdWidth),
      .Bandwidth         (HwpeDataWidth),
      .NumCores          (NrCores),
      .MisalignedAccesses(0),
      .HCI_SIZE_tcdm     (HCISizeTcdm)
    ) i_datamover_top (
      .clk_i      (hwpe_clk[DmaPort]),
      .rst_ni     (rst_ni),
      .test_mode_i(test_mode_i),
      .evt_o      (evt[DmaPort]),
      .busy_o     (),
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
  end else begin : gen_no_datamover
    // The accelerator owns the TCDM port.
    hci_core_assign i_acc_to_tcdm (
      .tcdm_target   (tcdm_to_mux[AccPort]),
      .tcdm_initiator(tcdm)
    );
  end

  // Every access must hit a register: the accelerator slot, the datamover slot (if there is one)
  // or a control register. The decode above ignores the other address bits, so anything else
  // would alias a register. That is a software bug.
`ifdef INC_ASSERT
  logic unmapped_access;
  always_comb begin
    // Above the frame, which is 2 KiB of the 4 KiB `ext_mem` window of the cluster
    unmapped_access = hwpe_ctrl_req_i.q.addr[FrameWidth] || (slot == UnusedSlot);
    if (slot == DmaSlot && !UseDatamover) begin
      unmapped_access = 1'b1;
    end
    // Only the registers 0 to NumCtrlRegs-1, word aligned, exist in the control slot
    if (ctrl_blk_sel) begin
      unmapped_access |= (ctrl_blk_idx >= NumCtrlRegs) ||
                         (|hwpe_ctrl_req_i.q.addr[AccWindowWidth-1:CtrlIdxOffset+CtrlIdxWidth]) ||
                         (|hwpe_ctrl_req_i.q.addr[CtrlIdxOffset-1:0]);
    end
  end
`endif
  `ASSERT_NEVER(UnmappedAccess,
                hwpe_ctrl_req_i.q_valid && hwpe_ctrl_rsp_o.q_ready && unmapped_access, clk_i,
                !rst_ni, "Access to an address the HWPE subsystem does not map")

endmodule : snitch_hwpe_subsystem
