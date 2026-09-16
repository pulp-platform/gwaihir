// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors: Sergio Mazzola <smazzola@iis.ee.ethz.ch>
//          Cyrill Durrer <cdurrer@iis.ee.ethz.ch>

`include "hci_helpers.svh"

module konark_tcdm_aligner
  import hci_package::*;
  import gwaihir_pkg::ceildiv;
#(
  parameter type         tcdm_req_t    = logic,
  parameter type         tcdm_rsp_t    = logic,
  parameter int unsigned DATA_WIDTH     = 512,   // Combined data width of all TCDM plugs [bits] - Limitation: must be a multiple of SB_WIDTH!
  parameter int unsigned SB_WIDTH       = 256,   // Superbank data width [bits]
  parameter int unsigned WORD_WIDTH     = 64,
  parameter int unsigned ADDR_WIDTH     = 48,
  parameter int unsigned MISALIGNED_ACCESSES = 1,
  // Dependent parameters: do not modify!
  localparam int unsigned ByteWidth = 8,
  localparam int unsigned DataWidthActual = (MISALIGNED_ACCESSES == 1) ? DATA_WIDTH - WORD_WIDTH : DATA_WIDTH,
  localparam int unsigned NumPlugs = (MISALIGNED_ACCESSES == 1) ? (DATA_WIDTH / SB_WIDTH) + 1 : ceildiv(DATA_WIDTH, SB_WIDTH),
  localparam int unsigned RemainingBytes = (DATA_WIDTH / ByteWidth) - ((NumPlugs - 1) * (SB_WIDTH / ByteWidth)),
  localparam int unsigned SbAddrBits = $clog2(SB_WIDTH / ByteWidth),    // SB_WIDTH has to be power of 2!
  localparam logic [ADDR_WIDTH-1:0] SbAddrMask = {
    {ADDR_WIDTH-SbAddrBits{1'b1}},
    {SbAddrBits{1'b0}}
  },
  localparam int unsigned AlignedDW = NumPlugs * SB_WIDTH   // Full aligned window width [bits]
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  hci_core_intf         tcdm_misaligned,
  output tcdm_req_t [NumPlugs-1:0]  tcdm_req_aligned_o,
  input  tcdm_rsp_t [NumPlugs-1:0]  tcdm_rsp_aligned_i
);

  logic [SbAddrBits-1:0] sb_offset_d, sb_offset_q;
  logic [SbAddrBits-1:0] req_offset_bytes;
  logic [ADDR_WIDTH-1:0] req_base_addr;
  logic [AlignedDW/ByteWidth-1:0] req_strb_aligned;
  logic [AlignedDW-1:0]           req_data_aligned;
  logic [AlignedDW-1:0]           aligned_rsp_data;

  // Alignment: compute the superbank-aligned base address and misalignment byte offset
  assign sb_offset_d = (tcdm_misaligned.req && tcdm_misaligned.gnt) ? tcdm_misaligned.add[SbAddrBits-1:0] : sb_offset_q;
  assign req_base_addr = (MISALIGNED_ACCESSES == 1) ? (tcdm_misaligned.add & SbAddrMask)
                                                     : tcdm_misaligned.add;
  assign req_offset_bytes = (MISALIGNED_ACCESSES == 1) ? sb_offset_d : '0;

  // Barrel-shift data and strobe into the aligned window
  always_comb begin
    req_strb_aligned = '0;
    req_data_aligned = '0;

    for (int unsigned src_byte = 0; src_byte < (DATA_WIDTH / ByteWidth); src_byte++) begin
      if ((req_offset_bytes + src_byte) < (AlignedDW / ByteWidth)) begin
        req_strb_aligned[req_offset_bytes + src_byte] = tcdm_misaligned.be[src_byte];
        req_data_aligned[((req_offset_bytes + src_byte) * ByteWidth) +: ByteWidth] =
          tcdm_misaligned.data[(src_byte * ByteWidth) +: ByteWidth];
      end
    end
  end

  // Internal wide HCI interface carrying the aligned full window; fed into konark_tcdm_split as target
  localparam hci_size_parameter_t `HCI_SIZE_PARAM(tcdm_aligned_wide) = '{
    DW:  AlignedDW,
    AW:  ADDR_WIDTH,
    BW:  ByteWidth,
    UW:  0,
    IW:  1,
    EW:  0,
    EHW: 0
  };
  `HCI_INTF(tcdm_aligned_wide, clk_i);

  // Drive the wide interface forward signals from alignment logic
  assign tcdm_aligned_wide.req      = tcdm_misaligned.req;
  assign tcdm_aligned_wide.add      = req_base_addr;
  assign tcdm_aligned_wide.wen      = tcdm_misaligned.wen;
  assign tcdm_aligned_wide.be       = req_strb_aligned;
  assign tcdm_aligned_wide.data     = req_data_aligned;
  assign tcdm_aligned_wide.user     = '0;
  assign tcdm_aligned_wide.id       = '0;
  assign tcdm_aligned_wide.ecc      = '0;
  assign tcdm_aligned_wide.r_ready  = '1;
  assign tcdm_aligned_wide.ereq     = '0;
  assign tcdm_aligned_wide.r_eready = '1;

  // Split the aligned window into NumPlugs superbank-width ports.
  // konark_tcdm_split: no request buffering (gnt only when all banks simultaneously ready),
  // response buffering per-channel so r_valid always fires exactly gnt+1.
  konark_tcdm_split #(
    .DW                          (AlignedDW),
    .BW                          (ByteWidth),
    .NB_OUT_CHAN                 (NumPlugs),
    .tcdm_req_t                  (tcdm_req_t),
    .tcdm_rsp_t                  (tcdm_rsp_t),
    .`HCI_SIZE_PARAM(tcdm_target)(HCI_SIZE_tcdm_aligned_wide)
  ) i_konark_tcdm_split (
    .clk_i,
    .rst_ni,
    .clear_i   (1'b0),
    .tcdm_target (tcdm_aligned_wide),
    .tcdm_req_o  (tcdm_req_aligned_o),
    .tcdm_rsp_i  (tcdm_rsp_aligned_i)
  );

  // Response data: assembled by konark_tcdm_split (channel 0 at LSBs);
  // shift back by sb_offset_q to undo the request-side barrel shift for misaligned reads.
  assign aligned_rsp_data = tcdm_aligned_wide.r_data;

  generate
    for (genvar ByteIdx = 0; ByteIdx < (DATA_WIDTH / ByteWidth); ByteIdx++) begin : gen_r_data_bytes
      if (MISALIGNED_ACCESSES == 0) begin : gen_r_data_aligned
        assign tcdm_misaligned.r_data[(ByteIdx * ByteWidth) +: ByteWidth] =
          aligned_rsp_data[(ByteIdx * ByteWidth) +: ByteWidth];
      end else begin : gen_r_data_misaligned
        assign tcdm_misaligned.r_data[(ByteIdx * ByteWidth) +: ByteWidth] =
          aligned_rsp_data[((ByteIdx + sb_offset_q) * ByteWidth) +: ByteWidth];
      end
    end
  endgenerate

  // Handshake and sideband signals back to the misaligned port
  assign tcdm_misaligned.gnt      = tcdm_aligned_wide.gnt;
  assign tcdm_misaligned.r_valid  = tcdm_aligned_wide.r_valid;
  assign tcdm_misaligned.r_opc    = '0;
  assign tcdm_misaligned.r_user   = '0;
  assign tcdm_misaligned.r_id     = '0;
  assign tcdm_misaligned.r_ecc    = '0;
  assign tcdm_misaligned.egnt     = '0;
  assign tcdm_misaligned.r_evalid = '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      sb_offset_q <= '0;
    else
      sb_offset_q <= sb_offset_d;
  end

endmodule
