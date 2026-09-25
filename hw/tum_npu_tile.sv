// Copyright 2025 ETH Zurich and University of Bologna.
// Copyright 2026 Technical University of Munich.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51


module tum_npu_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
#(

  parameter logic        [AxiCfgW.AddrWidth-1:0] TumNpuBaseAddr  = 48'h0000_4000_0000,
  /// Max outstanding transactions on the NPU manager port.
  parameter int unsigned                         MstMaxUniqIds   = 4,
  parameter int unsigned                         MstMaxTxnsPerId = 4
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_enable_i,
  input  id_t  id_i,
  input  logic irq_i,
  output logic halted_o,
  output logic fault_o,
  output logic wfi_o,

  output floo_req_t  floo_req_east_o,
  input  floo_rsp_t  floo_rsp_east_i,
  output floo_wide_t floo_wide_east_o,
  input  floo_req_t  floo_req_east_i,
  output floo_rsp_t  floo_rsp_east_o,
  input  floo_wide_t floo_wide_east_i,

  output floo_req_t  floo_req_south_o,
  input  floo_rsp_t  floo_rsp_south_i,
  output floo_wide_t floo_wide_south_o,
  input  floo_req_t  floo_req_south_i,
  output floo_rsp_t  floo_rsp_south_o,
  input  floo_wide_t floo_wide_south_i,

  output floo_req_t  floo_req_west_o,
  input  floo_rsp_t  floo_rsp_west_i,
  output floo_wide_t floo_wide_west_o,
  input  floo_req_t  floo_req_west_i,
  output floo_rsp_t  floo_rsp_west_o,
  input  floo_wide_t floo_wide_west_i
);

  ////////////
  // Router //
  ////////////

  floo_req_t [Eject:North] router_floo_req_out, router_floo_req_in;
  floo_rsp_t [Eject:North] router_floo_rsp_out, router_floo_rsp_in;
  floo_wide_t [Eject:North] router_floo_wide_out, router_floo_wide_in;

  floo_nw_router #(
    .AxiCfgN       (AxiCfgN),
    .AxiCfgW       (AxiCfgW),
    .RouteAlgo     (RouteCfg.RouteAlgo),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl)
  ) i_router (
    .clk_i,
    .rst_ni,
    .test_enable_i,
    .id_i,
    .id_route_map_i      ('0),
    .floo_req_i          (router_floo_req_in),
    .floo_rsp_o          (router_floo_rsp_out),
    .floo_req_o          (router_floo_req_out),
    .floo_rsp_i          (router_floo_rsp_in),
    .floo_wide_i         (router_floo_wide_in),
    .floo_wide_o         (router_floo_wide_out),
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  ///////////
  // Links //
  ///////////

  assign floo_req_east_o           = router_floo_req_out[East];
  assign router_floo_req_in[East]  = floo_req_east_i;
  assign floo_rsp_east_o           = router_floo_rsp_out[East];
  assign router_floo_rsp_in[East]  = floo_rsp_east_i;
  assign floo_wide_east_o          = router_floo_wide_out[East];
  assign router_floo_wide_in[East] = floo_wide_east_i;

  assign floo_req_south_o           = router_floo_req_out[South];
  assign router_floo_req_in[South]  = floo_req_south_i;
  assign floo_rsp_south_o           = router_floo_rsp_out[South];
  assign router_floo_rsp_in[South]  = floo_rsp_south_i;
  assign floo_wide_south_o          = router_floo_wide_out[South];
  assign router_floo_wide_in[South] = floo_wide_south_i;

  assign floo_req_west_o           = router_floo_req_out[West];
  assign router_floo_req_in[West]  = floo_req_west_i;
  assign floo_rsp_west_o           = router_floo_rsp_out[West];
  assign router_floo_rsp_in[West]  = floo_rsp_west_i;
  assign floo_wide_west_o          = router_floo_wide_out[West];
  assign router_floo_wide_in[West] = floo_wide_west_i;

  assign router_floo_req_in[North]  = '0;
  assign router_floo_rsp_in[North]  = '0;
  assign router_floo_wide_in[North] = '0;


  assign router_floo_req_in[Eject]  = '0;
  assign router_floo_rsp_in[Eject]  = '0;
  assign router_floo_wide_in[Eject] = '0;

  //////////////
  // Sideband //
  //////////////

  assign halted_o = 1'b0;
  assign fault_o  = 1'b0;
  assign wfi_o    = 1'b0;

endmodule : tum_npu_tile
