// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

`include "common_cells/assertions.svh"

// Decodes reduction offload request coming from the NoC router into snitch cluster DCA request
module floo_dca_decode #(
  // Wide reduction supported by the NoC; if not, the DCA interface is tied off
  parameter bit EnWideReduction = 1'b1,
  // The offload controller already cuts the interface, so the cut here is bypassed
  parameter bit CutOffloadIntf  = 1'b1
) (
  input logic clk_i,
  input logic rst_ni,

  // Wide offload port of the NW router
  input  floo_gwaihir_noc_pkg::red_wide_req_t offload_req_i,
  output floo_gwaihir_noc_pkg::red_wide_rsp_t offload_rsp_o,

  // Snitch cluster DCA port
  output snitch_cluster_wrapper_pkg::dca_req_t dca_req_o,
  input  snitch_cluster_wrapper_pkg::dca_rsp_t dca_rsp_i
);

  // Wide sequential reduction op IDs, zero-based (opaque to the NoC). The order must match the
  // ops declared in cfg/gwaihir_noc.yml and the software opcode enum.
  typedef enum int unsigned {
    FpAdd   = 0,
    FpMul   = 1,
    FpMin   = 2,
    FpMax   = 3,
    FpAdd32 = 4,
    FpAdd16 = 5,
    FpAdd8  = 6,
    FpMax32 = 7,
    FpMax16 = 8,
    FpMax8  = 9
  } wide_red_op_e;

  if (EnWideReduction) begin : gen_wide_offload_reduction
    // Uncut DCA interface, cut below towards the cluster
    snitch_cluster_wrapper_pkg::dca_req_t offload_dca_req;
    snitch_cluster_wrapper_pkg::dca_rsp_t offload_dca_rsp;

    // Connect the DCA Request
    assign offload_dca_req.q_valid = offload_req_i.valid;
    assign offload_rsp_o.ready     = offload_dca_rsp.q_ready;

    // The number of wide ops must match the ones declared in the NoC
    `ASSERT_INIT(WideOpsMatch, int'(FpMax8) + 1 == floo_gwaihir_noc_pkg::NumWideSeqOps,
                 "wide_red_op_e does not match the wide ops of the NoC")

    // Wide ops are numbered after the reserved and the narrow ops.
    localparam int unsigned FirstWideOp =
        floo_pkg::NumReservedCollectOps + floo_gwaihir_noc_pkg::NumNarrowSeqOps;

    logic [$bits(floo_gwaihir_noc_pkg::collect_op_t)-1:0] wide_op_id;
    assign wide_op_id = offload_req_i.req.op - FirstWideOp;

    // Parse the FPU Request
    always_comb begin
      // Init default values
      offload_dca_req.q.operands = '0;

      // Set default Values
      offload_dca_req.q.src_fmt      = fpnew_pkg::FP64;
      offload_dca_req.q.dst_fmt      = fpnew_pkg::FP64;
      offload_dca_req.q.int_fmt      = fpnew_pkg::INT64;
      offload_dca_req.q.vectorial_op = 1'b0;
      offload_dca_req.q.op_mod       = 1'b0;
      offload_dca_req.q.rnd_mode     = fpnew_pkg::RNE;
      offload_dca_req.q.op           = fpnew_pkg::ADD;

      // Define the operation we want to execute on the FPU
      unique casez (wide_red_op_e'(wide_op_id))
        FpAdd: begin
          offload_dca_req.q.op          = fpnew_pkg::ADD;
          offload_dca_req.q.operands[0] = '0;
          offload_dca_req.q.operands[1] = offload_req_i.req.operand1;
          offload_dca_req.q.operands[2] = offload_req_i.req.operand2;
        end
        FpMul: begin
          offload_dca_req.q.op          = fpnew_pkg::MUL;
          offload_dca_req.q.operands[0] = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1] = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        FpMax: begin
          offload_dca_req.q.op          = fpnew_pkg::MINMAX;
          // fpnew_noncomp.sv encodes MINMAX via rnd_mode: RNE=MIN, RTZ=MAX.
          offload_dca_req.q.rnd_mode    = fpnew_pkg::RTZ;
          offload_dca_req.q.operands[0] = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1] = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        FpMin: begin
          offload_dca_req.q.op          = fpnew_pkg::MINMAX;
          offload_dca_req.q.rnd_mode    = fpnew_pkg::RNE;
          offload_dca_req.q.operands[0] = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1] = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2] = '0;
        end
        FpAdd32: begin
          offload_dca_req.q.op           = fpnew_pkg::ADD;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP32;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP32;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = '0;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[2]  = offload_req_i.req.operand2;
        end
        FpAdd16: begin
          offload_dca_req.q.op           = fpnew_pkg::ADD;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP16;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP16;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = '0;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[2]  = offload_req_i.req.operand2;
        end
        FpAdd8: begin
          offload_dca_req.q.op           = fpnew_pkg::ADD;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP8;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP8;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = '0;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[2]  = offload_req_i.req.operand2;
        end
        FpMax32: begin
          offload_dca_req.q.op           = fpnew_pkg::MINMAX;
          // fpnew_noncomp.sv encodes MINMAX via rnd_mode: RNE=MIN, RTZ=MAX.
          offload_dca_req.q.rnd_mode     = fpnew_pkg::RTZ;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP32;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP32;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2]  = '0;
        end
        FpMax16: begin
          offload_dca_req.q.op           = fpnew_pkg::MINMAX;
          // fpnew_noncomp.sv encodes MINMAX via rnd_mode: RNE=MIN, RTZ=MAX.
          offload_dca_req.q.rnd_mode     = fpnew_pkg::RTZ;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP16;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP16;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2]  = '0;
        end
        FpMax8: begin
          offload_dca_req.q.op           = fpnew_pkg::MINMAX;
          // fpnew_noncomp.sv encodes MINMAX via rnd_mode: RNE=MIN, RTZ=MAX.
          offload_dca_req.q.rnd_mode     = fpnew_pkg::RTZ;
          offload_dca_req.q.src_fmt      = fpnew_pkg::FP8;
          offload_dca_req.q.dst_fmt      = fpnew_pkg::FP8;
          offload_dca_req.q.vectorial_op = 1'b1;
          offload_dca_req.q.operands[0]  = offload_req_i.req.operand1;
          offload_dca_req.q.operands[1]  = offload_req_i.req.operand2;
          offload_dca_req.q.operands[2]  = '0;
        end
        default: begin
          offload_dca_req.q.op          = fpnew_pkg::ADD;
          offload_dca_req.q.operands[0] = '0;
          offload_dca_req.q.operands[1] = '0;
          offload_dca_req.q.operands[2] = '0;
        end
      endcase
    end

    // If CutOffloadIntf is enabled the cut is already in the NoC offload controller,
    // so this one is bypassed.
    reqrsp_cut #(
      .req_chan_t(snitch_cluster_wrapper_pkg::dca_req_chan_t),
      .rsp_chan_t(snitch_cluster_wrapper_pkg::dca_rsp_chan_t),
      .BypassReq (CutOffloadIntf),
      .BypassRsp (CutOffloadIntf)
    ) i_dca_router_cut (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .slv_req_i(offload_dca_req),
      .slv_rsp_o(offload_dca_rsp),
      .mst_req_o(dca_req_o),
      .mst_rsp_i(dca_rsp_i)
    );
    // Connect the Response
    assign offload_rsp_o.valid      = offload_dca_rsp.p_valid;
    assign offload_dca_req.p_ready  = offload_req_i.ready;
    assign offload_rsp_o.rsp.result = offload_dca_rsp.p.result;

    // No Wide Reduction supported
  end else begin : gen_no_wide_reduction
    assign dca_req_o                = '0;
    assign offload_rsp_o.ready      = '0;
    assign offload_rsp_o.rsp.result = '0;
    assign offload_rsp_o.valid      = '0;
  end

endmodule
