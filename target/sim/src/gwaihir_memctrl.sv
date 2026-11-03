// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//

module gwaihir_memctrl
  import gwaihir_pkg::*;
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
(
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       test_mode_i,
  // FlooNoC ports for feed-through to the memory controller
  input  floo_req_t  cheshire_external_floo_req_south_i,
  output floo_rsp_t  cheshire_external_floo_rsp_south_o,
  input  floo_wide_t cheshire_external_floo_wide_south_i,
  output floo_req_t  cheshire_external_floo_req_south_o,
  input  floo_rsp_t  cheshire_external_floo_rsp_south_i,
  output floo_wide_t cheshire_external_floo_wide_south_o,

  output floo_req_t  memctrl_external_floo_req_south_o,
  input  floo_rsp_t  memctrl_external_floo_rsp_south_i,
  output floo_wide_t memctrl_external_floo_wide_south_o,
  input  floo_req_t  memctrl_external_floo_req_south_i,
  output floo_rsp_t  memctrl_external_floo_rsp_south_o,
  input  floo_wide_t memctrl_external_floo_wide_south_i,
  // FlooNoC ports for dummy tiles in memory controller
  input  floo_req_t  cheshire_external_floo_req_west_i,
  output floo_rsp_t  cheshire_external_floo_rsp_west_o,
  input  floo_wide_t cheshire_external_floo_wide_west_i,
  output floo_req_t  cheshire_external_floo_req_west_o,
  input  floo_rsp_t  cheshire_external_floo_rsp_west_i,
  output floo_wide_t cheshire_external_floo_wide_west_o,

  input  floo_req_t  tum_external_floo_req_east_i,
  output floo_rsp_t  tum_external_floo_rsp_east_o,
  input  floo_wide_t tum_external_floo_wide_east_i,
  output floo_req_t  tum_external_floo_req_east_o,
  input  floo_rsp_t  tum_external_floo_rsp_east_i,
  output floo_wide_t tum_external_floo_wide_east_o,

  input  id_t        ext_dummy_x2y4_id_i,
  input  floo_req_t  ext_dummy_x2y4_floo_req_i,
  output floo_rsp_t  ext_dummy_x2y4_floo_rsp_o,
  input  floo_wide_t ext_dummy_x2y4_floo_wide_i,
  output floo_req_t  ext_dummy_x2y4_floo_req_o,
  input  floo_rsp_t  ext_dummy_x2y4_floo_rsp_i,
  output floo_wide_t ext_dummy_x2y4_floo_wide_o,

  input  id_t        ext_dummy_x3y4_id_i,
  input  floo_req_t  ext_dummy_x3y4_floo_req_i,
  output floo_rsp_t  ext_dummy_x3y4_floo_rsp_o,
  input  floo_wide_t ext_dummy_x3y4_floo_wide_i,
  output floo_req_t  ext_dummy_x3y4_floo_req_o,
  input  floo_rsp_t  ext_dummy_x3y4_floo_rsp_i,
  output floo_wide_t ext_dummy_x3y4_floo_wide_o
);

  // Declarations
  floo_req_t [Eject:North] router_x2y4_floo_req_out, router_x2y4_floo_req_in;
  floo_rsp_t [Eject:North] router_x2y4_floo_rsp_out, router_x2y4_floo_rsp_in;
  floo_wide_t [Eject:North] router_x2y4_floo_wide_in, router_x2y4_floo_wide_out;

  floo_req_t [Eject:North] router_x3y4_floo_req_out, router_x3y4_floo_req_in;
  floo_rsp_t [Eject:North] router_x3y4_floo_rsp_out, router_x3y4_floo_rsp_in;
  floo_wide_t [Eject:North] router_x3y4_floo_wide_in, router_x3y4_floo_wide_out;

  // Cheshire feed-through
  assign memctrl_external_floo_req_south_o   = cheshire_external_floo_req_south_i;
  assign cheshire_external_floo_rsp_south_o  = memctrl_external_floo_rsp_south_i;
  assign memctrl_external_floo_wide_south_o  = cheshire_external_floo_wide_south_i;
  assign cheshire_external_floo_req_south_o  = memctrl_external_floo_req_south_i;
  assign memctrl_external_floo_rsp_south_o   = cheshire_external_floo_rsp_south_i;
  assign cheshire_external_floo_wide_south_o = memctrl_external_floo_wide_south_i;

  // Dummy X3Y4 <--> Cheshire
  assign router_x3y4_floo_req_in[East]      = cheshire_external_floo_req_west_i;
  assign cheshire_external_floo_rsp_west_o  = router_x3y4_floo_rsp_out[East];
  assign router_x3y4_floo_wide_in[East]     = cheshire_external_floo_wide_west_i;
  assign cheshire_external_floo_req_west_o  = router_x3y4_floo_req_out[East];
  assign router_x3y4_floo_rsp_in[East]      = cheshire_external_floo_rsp_west_i;
  assign cheshire_external_floo_wide_west_o = router_x3y4_floo_wide_out[East];

  // Dummy X3Y4 <--> C11
  assign router_x3y4_floo_req_in[South]  = ext_dummy_x3y4_floo_req_i;
  assign ext_dummy_x3y4_floo_rsp_o       = router_x3y4_floo_rsp_out[South];
  assign router_x3y4_floo_wide_in[South] = ext_dummy_x3y4_floo_wide_i;
  assign ext_dummy_x3y4_floo_req_o       = router_x3y4_floo_req_out[South];
  assign router_x3y4_floo_rsp_in[South]  = ext_dummy_x3y4_floo_rsp_i;
  assign ext_dummy_x3y4_floo_wide_o      = router_x3y4_floo_wide_out[South];

  // Dummy X3Y4 tie-offs (no local port, North is the mesh border)
  assign router_x3y4_floo_req_in[Eject]  = '0;
  assign router_x3y4_floo_rsp_in[Eject]  = '0;
  assign router_x3y4_floo_wide_in[Eject] = '0;
  assign router_x3y4_floo_req_in[North]  = '0;
  assign router_x3y4_floo_rsp_in[North]  = '0;
  assign router_x3y4_floo_wide_in[North] = '0;

  floo_nw_router #(
    .AxiCfgN       (AxiCfgN),
    .AxiCfgW       (AxiCfgW),
    .RouteAlgo     (RouteCfgNoMcast.RouteAlgo),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl),
    .collect_op_t  (floo_gwaihir_noc_pkg::collect_op_t)
  ) i_x3y4_router (
    .clk_i,
    .rst_ni,
    .test_enable_i       (test_mode_i),
    .id_i                (ext_dummy_x3y4_id_i),
    .id_route_map_i      ('0),
    .floo_req_i          (router_x3y4_floo_req_in),
    .floo_rsp_o          (router_x3y4_floo_rsp_out),
    .floo_req_o          (router_x3y4_floo_req_out),
    .floo_rsp_i          (router_x3y4_floo_rsp_in),
    .floo_wide_i         (router_x3y4_floo_wide_in),
    .floo_wide_o         (router_x3y4_floo_wide_out),
    // Wide Reduction offload port
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    // Narrow Reduction offload port
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  // Dummy X3Y4 <--> Dummy X2Y4
  assign router_x3y4_floo_req_in[West]  = router_x2y4_floo_req_out[East];
  assign router_x2y4_floo_rsp_in[East]  = router_x3y4_floo_rsp_out[West];
  assign router_x3y4_floo_wide_in[West] = router_x2y4_floo_wide_out[East];
  assign router_x2y4_floo_req_in[East]  = router_x3y4_floo_req_out[West];
  assign router_x3y4_floo_rsp_in[West]  = router_x2y4_floo_rsp_out[East];
  assign router_x2y4_floo_wide_in[East] = router_x3y4_floo_wide_out[West];

  // Dummy X2Y4 <--> C07
  assign router_x2y4_floo_req_in[South]  = ext_dummy_x2y4_floo_req_i;
  assign ext_dummy_x2y4_floo_rsp_o       = router_x2y4_floo_rsp_out[South];
  assign router_x2y4_floo_wide_in[South] = ext_dummy_x2y4_floo_wide_i;
  assign ext_dummy_x2y4_floo_req_o       = router_x2y4_floo_req_out[South];
  assign router_x2y4_floo_rsp_in[South]  = ext_dummy_x2y4_floo_rsp_i;
  assign ext_dummy_x2y4_floo_wide_o      = router_x2y4_floo_wide_out[South];

  // Dummy X2Y4 <--> TUM
  assign router_x2y4_floo_req_in[West]  = tum_external_floo_req_east_i;
  assign tum_external_floo_rsp_east_o   = router_x2y4_floo_rsp_out[West];
  assign router_x2y4_floo_wide_in[West] = tum_external_floo_wide_east_i;
  assign tum_external_floo_req_east_o   = router_x2y4_floo_req_out[West];
  assign router_x2y4_floo_rsp_in[West]  = tum_external_floo_rsp_east_i;
  assign tum_external_floo_wide_east_o  = router_x2y4_floo_wide_out[West];

  // Dummy X2Y4 tie-offs (no local port, North is the mesh border)
  assign router_x2y4_floo_req_in[Eject]  = '0;
  assign router_x2y4_floo_rsp_in[Eject]  = '0;
  assign router_x2y4_floo_wide_in[Eject] = '0;
  assign router_x2y4_floo_req_in[North]  = '0;
  assign router_x2y4_floo_rsp_in[North]  = '0;
  assign router_x2y4_floo_wide_in[North] = '0;

  floo_nw_router #(
    .AxiCfgN       (AxiCfgN),
    .AxiCfgW       (AxiCfgW),
    .RouteAlgo     (RouteCfgNoMcast.RouteAlgo),
    .NumRoutes     (5),
    .InFifoDepth   (2),
    .OutFifoDepth  (2),
    .id_t          (id_t),
    .hdr_t         (hdr_t),
    .floo_req_t    (floo_req_t),
    .floo_rsp_t    (floo_rsp_t),
    .floo_wide_t   (floo_wide_t),
    .WideRwDecouple(WideRwDecouple),
    .VcImpl        (VcImpl),
    .collect_op_t  (floo_gwaihir_noc_pkg::collect_op_t)
  ) i_x2y4_router (
    .clk_i,
    .rst_ni,
    .test_enable_i       (test_mode_i),
    .id_i                (ext_dummy_x2y4_id_i),
    .id_route_map_i      ('0),
    .floo_req_i          (router_x2y4_floo_req_in),
    .floo_rsp_o          (router_x2y4_floo_rsp_out),
    .floo_req_o          (router_x2y4_floo_req_out),
    .floo_rsp_i          (router_x2y4_floo_rsp_in),
    .floo_wide_i         (router_x2y4_floo_wide_in),
    .floo_wide_o         (router_x2y4_floo_wide_out),
    // Wide Reduction offload port
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    // Narrow Reduction offload port
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

endmodule  // gwaihir_memctrl
