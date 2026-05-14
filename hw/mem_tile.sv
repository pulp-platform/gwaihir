// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//         Tim Fischer <fischeti@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "axi/typedef.svh"
`include "obi/typedef.svh"
`include "common_cells/assertions.svh"

module mem_tile
  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import gwaihir_pkg::*;
  import obi_pkg::*;
#(
  parameter bit          AxiUserAtop    = 1'b1,
  parameter int unsigned AxiUserAtopMsb = 3,
  parameter int unsigned AxiUserAtopLsb = 0,
  parameter int unsigned MemTileId      = 0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    test_enable_i,
  input  logic                    tile_clk_en_i,
  input  logic                    tile_rst_ni,
  input  logic                    clk_rst_bypass_i,
  // Chimney ports
  input  id_t                     id_i,
  // Router ports
  output floo_req_t  [West:North] floo_req_o,
  input  floo_rsp_t  [West:North] floo_rsp_i,
  output floo_wide_t [West:North] floo_wide_o,
  input  floo_req_t  [West:North] floo_req_i,
  output floo_rsp_t  [West:North] floo_rsp_o,
  input  floo_wide_t [West:North] floo_wide_i
);

  logic tile_clk;
  logic tile_rst_n;

  ////////////
  // Router //
  ////////////

  floo_req_t [Eject:North] router_floo_req_out, router_floo_req_in;
  floo_rsp_t [Eject:North] router_floo_rsp_out, router_floo_rsp_in;
  floo_wide_t [Eject:North] router_floo_wide_in;
  floo_wide_t [Eject:North] router_floo_wide_out;

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
    // TODO: Set this to 1'b1 after adding a separate path for iDMA access to local memory tile
    .NoLoopback    (1'b1)
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
    // Wide Reduction offload port
    .offload_wide_req_o  (),
    .offload_wide_rsp_i  ('0),
    // Narrow Reduction offload port
    .offload_narrow_req_o(),
    .offload_narrow_rsp_i('0)
  );

  assign floo_req_o                      = router_floo_req_out[West:North];
  assign router_floo_req_in[West:North]  = floo_req_i;
  assign floo_rsp_o                      = router_floo_rsp_out[West:North];
  assign router_floo_rsp_in[West:North]  = floo_rsp_i;
  // Only the local port uses both physical channels. Other outputs use only the lower.
  // for (genvar i = North; i <= West; i++) begin : gen_floo_wide_o
  //   assign floo_wide_o[i].valid = router_floo_wide_out[i].valid;
  //   assign floo_wide_o[i].ready = router_floo_wide_out[i].ready;
  //   assign floo_wide_o[i].wide = router_floo_wide_out[i].wide[0];
  // end
  assign router_floo_wide_in[West:North] = floo_wide_i;
  assign floo_wide_o[West:North]         = router_floo_wide_out[West:North];

  floo_gwaihir_noc_pkg::axi_wide_in_req_t [1:0] axi_dma_req_demux;
  floo_gwaihir_noc_pkg::axi_wide_in_rsp_t [1:0] axi_dma_rsp_demux;

  typedef enum logic {LOCAL, EXTERNAL} wide_axi_sel_e;

  /////////////
  // Chimney //
  /////////////

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t  axi_narrow_req;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t  axi_narrow_rsp;
  floo_gwaihir_noc_pkg::axi_wide_out_req_t    axi_wide_req;
  floo_gwaihir_noc_pkg::axi_wide_out_rsp_t    axi_wide_rsp;

  // DMA req/resp, supposed to access LPDDR tile, we also keep the option to access other tiles
  floo_gwaihir_noc_pkg::axi_wide_in_req_t     axi_dma_req;
  floo_gwaihir_noc_pkg::axi_wide_in_rsp_t     axi_dma_rsp;

  floo_nw_chimney #(
    .AxiCfgN             (AxiCfgN),
    .AxiCfgW             (AxiCfgW),
    .ChimneyCfgN         (set_ports(ChimneyDefaultCfg, 1'b1, 1'b0)),
    .ChimneyCfgW         (set_ports(ChimneyDefaultCfg, 1'b1, 1'b1)),
    .RouteCfg            (RouteCfgNoMcast),
    .AtopSupport         (1'b1),
    .WideRwDecouple      (WideRwDecouple),
    .VcImpl              (VcImpl),
    .MaxAtomicTxns       (1),
    .Sam                 (Sam),
    .id_t                (id_t),
    .rob_idx_t           (rob_idx_t),
    .hdr_t               (hdr_t),
    .sam_rule_t          (sam_rule_t),
    .axi_narrow_in_req_t (axi_narrow_in_req_t),
    .axi_narrow_in_rsp_t (axi_narrow_in_rsp_t),
    .axi_narrow_out_req_t(axi_narrow_out_req_t),
    .axi_narrow_out_rsp_t(axi_narrow_out_rsp_t),
    .axi_wide_in_req_t   (axi_wide_in_req_t),
    .axi_wide_in_rsp_t   (axi_wide_in_rsp_t),
    .axi_wide_out_req_t  (axi_wide_out_req_t),
    .axi_wide_out_rsp_t  (axi_wide_out_rsp_t),
    .floo_req_t          (floo_req_t),
    .floo_rsp_t          (floo_rsp_t),
    .floo_wide_t         (floo_wide_t)
  ) i_chimney (
    .clk_i               (tile_clk),
    .rst_ni              (tile_rst_n),
    .test_enable_i,
    .id_i,
    .route_table_i       ('0),
    .sram_cfg_i          ('0),
    .axi_narrow_in_req_i ('0),
    .axi_narrow_in_rsp_o (),
    .axi_narrow_out_req_o(axi_narrow_req),
    .axi_narrow_out_rsp_i(axi_narrow_rsp),
    // Receive transfer requests from DMA
    .axi_wide_in_req_i   (axi_dma_req_demux[EXTERNAL]),
    .axi_wide_in_rsp_o   (axi_dma_rsp_demux[EXTERNAL]),
    .axi_wide_out_req_o  (axi_wide_req),
    .axi_wide_out_rsp_i  (axi_wide_rsp),
    .floo_req_o          (router_floo_req_in[Eject]),
    .floo_rsp_o          (router_floo_rsp_in[Eject]),
    .floo_wide_o         (router_floo_wide_in[Eject]),
    .floo_req_i          (router_floo_req_out[Eject]),
    .floo_rsp_i          (router_floo_rsp_out[Eject]),
    .floo_wide_i         (router_floo_wide_out[Eject])
  );

  //////////////////////
  // Narrow AXI Demux //
  //////////////////////

  typedef enum logic {MEM, DMA} narrow_axi_sel_e;

  floo_gwaihir_noc_pkg::axi_narrow_out_req_t  [1:0] axi_narrow_req_demux;
  floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t  [1:0] axi_narrow_rsp_demux;

  logic [5:0] mem_tile_idx;

  // TODO: [ATTENTION] This part is related to the actual memory tile position, and the corresponding
  //                   address map, now the memory tile is at [x,y] = [{0,8},{0,1,2,3}]
  always_comb begin
    // Default to an invalid SAM index; the MemTileXValid assertion (if present)
    // guards against id_i.x / id_i.y combinations that would land here.
    unique case ({id_i.x, id_i.y})
      {4'd0, 2'd0}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm0SamIdx;
      {4'd0, 2'd1}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm1SamIdx;
      {4'd0, 2'd2}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm2SamIdx;
      {4'd0, 2'd3}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm3SamIdx;
      {4'd8, 2'd0}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm4SamIdx;
      {4'd8, 2'd1}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm5SamIdx;
      {4'd8, 2'd2}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm6SamIdx;
      {4'd8, 2'd3}: mem_tile_idx = floo_gwaihir_noc_pkg::L2Spm7SamIdx;
      default     : mem_tile_idx = '1;
    endcase
  end

  // Configure AXI Xbar
  localparam axi_pkg::xbar_cfg_t NarrowAxiXbarCfg = '{
    NoSlvPorts:         1,
    NoMstPorts:         2,
    // TODO: Check what the most suitable value are for MaxMstTrans and MaxSlvTrans
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    // TODO: If the timing allows, we can set FallThrough to high. Also check functionality.
    FallThrough:        0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    PipelineStages:     0,
    // TODO: Check if AxiIdWidthSlvPorts and AxiIdUsedSlvPorts are correctly assigned
    //       Not sure if this is correct: This xbar is actually a demux, so the id width
    //                                    for master and slave side should be the same
    //                                    and `axi_mst_` types and `axi_slv_` types are the
    //                                    same because the userwidth and id width are the same.
    AxiIdWidthSlvPorts: $bits(floo_gwaihir_noc_pkg::axi_narrow_out_id_t),
    AxiIdUsedSlvPorts:  $bits(floo_gwaihir_noc_pkg::axi_narrow_out_id_t),
    // TODO: Check if we should use UniqueIds
    UniqueIds:          0,
    AxiAddrWidth:       $bits(floo_gwaihir_noc_pkg::axi_narrow_out_addr_t),
    AxiDataWidth:       $bits(floo_gwaihir_noc_pkg::axi_narrow_out_data_t),
    NoAddrRules:        2,
    // Setting a `default` here allows for custom XBars with extended configs outside Cheshire.
    // Importantly, this requires that '0 *disables* any and all such custom extensions.
    default: '0
  };

  typedef struct packed {
    // Only two regions: MEM and DMA
    logic [$clog2(NarrowAxiXbarCfg.NoMstPorts)-1:0] idx;
    floo_gwaihir_noc_pkg::axi_narrow_out_addr_t     start_addr;
    floo_gwaihir_noc_pkg::axi_narrow_out_addr_t     end_addr;
  } narrow_rule_t;

  // Offset from an L2Spm SAM index to its matching DMA-reg SAM index.
  // Computed from the generated enum so it survives YAML / regeneration changes.
  // With the current SAM layout, L2SpmDma{i}SamIdx = L2Spm{i}SamIdx - 1, so the
  // offset is -1; declared as `int` (signed) to allow that.
  localparam int DmaIdxOffset =
      int'(floo_gwaihir_noc_pkg::L2SpmDma0SamIdx) -
      int'(floo_gwaihir_noc_pkg::L2Spm0SamIdx);

  // Generate address map for narrow_axi_demux
  narrow_rule_t [1:0] routing_rules_narrow;
  assign routing_rules_narrow = '{
    '{idx: MEM,
      start_addr: floo_gwaihir_noc_pkg::Sam[mem_tile_idx].start_addr,
      end_addr  : floo_gwaihir_noc_pkg::Sam[mem_tile_idx].end_addr},
    '{idx: DMA,
      start_addr: floo_gwaihir_noc_pkg::Sam[mem_tile_idx + DmaIdxOffset].start_addr,
      end_addr  : floo_gwaihir_noc_pkg::Sam[mem_tile_idx + DmaIdxOffset].end_addr}
  };

  axi_xbar #(
    .Cfg            (NarrowAxiXbarCfg ),
    // TODO: Check if we need to support ATOP, according to the parameter list, this is enabled
    .ATOPs          (1  ),
    .Connectivity   ('1 ),
    .slv_aw_chan_t  (axi_narrow_out_aw_chan_t ),
    .mst_aw_chan_t  (axi_narrow_out_aw_chan_t ),
    .w_chan_t       (axi_narrow_out_w_chan_t  ),
    .slv_b_chan_t   (axi_narrow_out_b_chan_t  ),
    .mst_b_chan_t   (axi_narrow_out_b_chan_t  ),
    .slv_ar_chan_t  (axi_narrow_out_ar_chan_t ),
    .mst_ar_chan_t  (axi_narrow_out_ar_chan_t ),
    .slv_r_chan_t   (axi_narrow_out_r_chan_t  ),
    .mst_r_chan_t   (axi_narrow_out_r_chan_t  ),
    .slv_req_t      (axi_narrow_out_req_t ),
    .slv_resp_t     (axi_narrow_out_rsp_t ),
    .mst_req_t      (axi_narrow_out_req_t ),
    .mst_resp_t     (axi_narrow_out_rsp_t ),
    .rule_t         (narrow_rule_t )
  ) i_axi_narrow_xbar (
    .clk_i                  (tile_clk             ),
    .rst_ni                 (tile_rst_n           ),
    .test_i                 (test_enable_i        ),
    .slv_ports_req_i        (axi_narrow_req       ),
    .slv_ports_resp_o       (axi_narrow_rsp       ),
    .mst_ports_req_o        (axi_narrow_req_demux ),
    .mst_ports_resp_i       (axi_narrow_rsp_demux ),
    .addr_map_i             (routing_rules_narrow ),
    .en_default_mst_port_i  ('0                   ),
    .default_mst_port_i     ('0                   )
  );

  ////////////////////////
  // DMA Wide AXI Demux //
  ////////////////////////

  // This module demuxes DMA AXI requests to local memory banks and external tiles.
  // Without this demux, floo_noc would have loopback.

  // Configure AXI Xbar
  localparam axi_pkg::xbar_cfg_t AxiDMAXbarCfg = '{
    NoSlvPorts:         1,
    NoMstPorts:         2,
    // TODO: Check what the most suitable value are for MaxMstTrans and MaxSlvTrans
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    // TODO: If the timing allows, we can set FallThrough to high. Also check functionality.
    FallThrough:        0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    PipelineStages:     0,
    // TODO: Check if AxiIdWidthSlvPorts and AxiIdUsedSlvPorts are correctly assigned
    //       Not sure if this is correct: This xbar is actually a demux, so the id width
    //                                    for master and slave side should be the same
    //                                    and `axi_mst_` types and `axi_slv_` types are the
    //                                    same because the userwidth and id width are the same.
    AxiIdWidthSlvPorts: $bits(floo_gwaihir_noc_pkg::axi_wide_in_id_t),
    AxiIdUsedSlvPorts:  $bits(floo_gwaihir_noc_pkg::axi_wide_in_id_t),
    // TODO: Check if we should use UniqueIds
    UniqueIds:          0,
    AxiAddrWidth:       $bits(floo_gwaihir_noc_pkg::axi_wide_in_addr_t),
    AxiDataWidth:       $bits(floo_gwaihir_noc_pkg::axi_wide_in_data_t),
    NoAddrRules:        2,
    // Setting a `default` here allows for custom XBars with extended configs outside Cheshire.
    // Importantly, this requires that '0 *disables* any and all such custom extensions.
    default: '0
  };

  typedef struct packed {
    // Only two regions: MEM and DMA
    logic [$clog2(AxiDMAXbarCfg.NoMstPorts)-1:0] idx;
    floo_gwaihir_noc_pkg::axi_wide_in_addr_t     start_addr;
    floo_gwaihir_noc_pkg::axi_wide_in_addr_t     end_addr;
  } dma_rule_t;

  // TODO: The address of EXTERNAL needs to be adapted
  // Generate address map for narrow_axi_demux
  dma_rule_t [1:0] routing_rules_dma;
  assign routing_rules_dma = '{
    '{idx: LOCAL,
      start_addr: floo_gwaihir_noc_pkg::Sam[mem_tile_idx].start_addr,
      end_addr  : floo_gwaihir_noc_pkg::Sam[mem_tile_idx].end_addr},
    '{idx: EXTERNAL,
      start_addr: floo_gwaihir_noc_pkg::Sam[mem_tile_idx + DmaIdxOffset].start_addr,
      end_addr  : floo_gwaihir_noc_pkg::Sam[mem_tile_idx + DmaIdxOffset].end_addr}
  };

  axi_xbar #(
    .Cfg            (AxiDMAXbarCfg ),
    // TODO: Check if we need to support ATOP, according to the parameter list, this is enabled
    .ATOPs          ('0 ),
    .Connectivity   ('1 ),
    .slv_aw_chan_t  (axi_wide_in_aw_chan_t ),
    .mst_aw_chan_t  (axi_wide_in_aw_chan_t ),
    .w_chan_t       (axi_wide_in_w_chan_t  ),
    .slv_b_chan_t   (axi_wide_in_b_chan_t  ),
    .mst_b_chan_t   (axi_wide_in_b_chan_t  ),
    .slv_ar_chan_t  (axi_wide_in_ar_chan_t ),
    .mst_ar_chan_t  (axi_wide_in_ar_chan_t ),
    .slv_r_chan_t   (axi_wide_in_r_chan_t  ),
    .mst_r_chan_t   (axi_wide_in_r_chan_t  ),
    .slv_req_t      (axi_wide_in_req_t ),
    .slv_resp_t     (axi_wide_in_rsp_t ),
    .mst_req_t      (axi_wide_in_req_t ),
    .mst_resp_t     (axi_wide_in_rsp_t ),
    .rule_t         (dma_rule_t )
  ) i_axi_dma_xbar (
    .clk_i                  (tile_clk          ),
    .rst_ni                 (tile_rst_n        ),
    .test_i                 (test_enable_i     ),
    .slv_ports_req_i        (axi_dma_req       ),
    .slv_ports_resp_o       (axi_dma_rsp       ),
    .mst_ports_req_o        (axi_dma_req_demux ),
    .mst_ports_resp_i       (axi_dma_rsp_demux ),
    .addr_map_i             (routing_rules_dma ),
    // Unmapped address go to the external port
    .en_default_mst_port_i  (1'b1              ),
    .default_mst_port_i     (EXTERNAL          )
  );

  /////////
  // DMA //
  /////////

  mem_tile_dma_wrap #(
    .AxiNarrowAddrWidth ($bits(floo_gwaihir_noc_pkg::axi_narrow_out_addr_t) ),
    .AxiNarrowDataWidth ($bits(floo_gwaihir_noc_pkg::axi_narrow_out_data_t) ),
    .AxiNarrowIdWidth   ($bits(floo_gwaihir_noc_pkg::axi_narrow_out_id_t)   ),
    .AxiNarrowUserWidth ($bits(floo_gwaihir_noc_pkg::axi_narrow_out_user_t) ),
    .AxiAddrWidth       ($bits(floo_gwaihir_noc_pkg::axi_wide_in_addr_t)    ),
    .AxiDataWidth       ($bits(floo_gwaihir_noc_pkg::axi_wide_in_data_t)    ),
    .AxiIdWidth         ($bits(floo_gwaihir_noc_pkg::axi_wide_in_id_t)      ),
    .AxiUserWidth       ($bits(floo_gwaihir_noc_pkg::axi_wide_in_user_t)    ),
    // TODO: Undrestand all these parameters: NumAxInFlight, MemSysDepth, JobFifoDepth, RAWCouplingAvail, IsTwoD
    .NumAxInFlight      (gwaihir_pkg::DmaNumAxInFlight                      ),
    .MemSysDepth        (gwaihir_pkg::DmaMemSysDepth                        ),
    .JobFifoDepth       (gwaihir_pkg::DmaJobFifoDepth                       ),
    .RAWCouplingAvail   (gwaihir_pkg::DmaRAWCouplingAvail                   ),
    .IsTwoD             (gwaihir_pkg::DmaConfEnableTwoD                     ),
    .axi_mst_req_t      (floo_gwaihir_noc_pkg::axi_wide_in_req_t            ),
    .axi_mst_rsp_t      (floo_gwaihir_noc_pkg::axi_wide_in_rsp_t            ),
    .axi_slv_req_t      (floo_gwaihir_noc_pkg::axi_narrow_out_req_t         ),
    .axi_slv_rsp_t      (floo_gwaihir_noc_pkg::axi_narrow_out_rsp_t         )
  ) i_mem_tile_dma (
    .clk_i          (tile_clk                   ),
    .rst_ni         (tile_rst_n                 ),
    .testmode_i     (test_enable_i              ),
    .axi_mst_req_o  (axi_dma_req                ),
    .axi_mst_rsp_i  (axi_dma_rsp                ),
    .axi_slv_req_i  (axi_narrow_req_demux[DMA]  ),
    .axi_slv_rsp_o  (axi_narrow_rsp_demux[DMA]  )
  );

  /////////////
  // NW Join //
  /////////////

  localparam axi_cfg_t AxiCfgJoin = floo_pkg::axi_join_cfg(AxiCfgN, AxiCfgW);

  typedef logic [AxiCfgJoin.OutIdWidth-1:0] nw_join_id_t;
  typedef logic [AxiCfgJoin.UserWidth-1:0] nw_join_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_nw_join, axi_nw_join_req_t, axi_nw_join_rsp_t, axi_wide_out_addr_t,
                      nw_join_id_t, axi_wide_out_data_t, axi_wide_out_strb_t, nw_join_user_t)

  axi_nw_join_req_t axi_req;
  axi_nw_join_rsp_t axi_rsp;

  floo_nw_join #(
    .AxiCfgN         (axi_cfg_swap_iw(AxiCfgN)),
    .AxiCfgW         (axi_cfg_swap_iw(AxiCfgW)),
    .AxiCfgJoin      (axi_cfg_swap_iw(AxiCfgJoin)),
    .EnAtopAdapter   (1'b0),
    .AtopUserAsId    (1'b1),
    .axi_narrow_req_t(axi_narrow_out_req_t),
    .axi_narrow_rsp_t(axi_narrow_out_rsp_t),
    .axi_wide_req_t  (axi_wide_out_req_t),
    .axi_wide_rsp_t  (axi_wide_out_rsp_t),
    .axi_req_t       (axi_nw_join_req_t),
    .axi_rsp_t       (axi_nw_join_rsp_t)
  ) i_floo_nw_join (
    .clk_i           (tile_clk),
    .rst_ni          (tile_rst_n),
    .test_enable_i   (test_enable_i),
    .axi_narrow_req_i(axi_narrow_req_demux[MEM]),
    .axi_narrow_rsp_o(axi_narrow_rsp_demux[MEM]),
    .axi_wide_req_i  (axi_wide_req),
    .axi_wide_rsp_o  (axi_wide_rsp),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp)
  );

  ////////////////////////////////
  // DMA wide axi2obi converter //
  ////////////////////////////////

  // iDMA never issues atomics (aw.atop is hardcoded to '0 in the iDMA
  // legalizer and the frontend has no software-visible register to set it),
  // so the DMA local-memory path uses a single non-atop OBI cfg end-to-end
  // and no atop resolver.
  localparam obi_pkg::obi_optional_cfg_t DMASbrObiOptionalCfg = '{
      UseAtop: 1'b0,
      UseMemtype: 1'b0,
      UseProt: 1'b0,
      UseDbg: 1'b0,
      AUserWidth: 0,
      WUserWidth: 0,
      RUserWidth: 0,
      MidWidth: 0,
      AChkWidth: 0,
      RChkWidth: 0
  };
  localparam obi_pkg::obi_cfg_t DMASbrObiCfg = obi_pkg::obi_default_cfg(
      AxiCfgW.AddrWidth,
      AxiCfgW.DataWidth,
      AxiCfgW.InIdWidth,
      DMASbrObiOptionalCfg
  );
  `OBI_TYPEDEF_MINIMAL_A_OPTIONAL(dma_sbr_obi_a_optional_t)
  `OBI_TYPEDEF_A_CHAN_T(dma_sbr_obi_a_chan_t, DMASbrObiCfg.AddrWidth, DMASbrObiCfg.DataWidth,
                        DMASbrObiCfg.IdWidth, dma_sbr_obi_a_optional_t)
  `OBI_TYPEDEF_DEFAULT_REQ_T(dma_sbr_obi_req_t, dma_sbr_obi_a_chan_t)
  `OBI_TYPEDEF_MINIMAL_R_OPTIONAL(dma_sbr_obi_r_optional_t)
  `OBI_TYPEDEF_R_CHAN_T(dma_sbr_obi_r_chan_t, DMASbrObiCfg.DataWidth, DMASbrObiCfg.IdWidth,
                        dma_sbr_obi_r_optional_t)
  `OBI_TYPEDEF_RSP_T(dma_sbr_obi_rsp_t, dma_sbr_obi_r_chan_t)

  // Number of outstanding transactions should be larger than round-trip
  // latency from converter to SRAM
  // TODO: Not sure if this is enough!!!
  localparam int unsigned DMAObiLatency = 4;

  dma_sbr_obi_req_t dma_obi_req, dma_mem_obi_req_cut;
  dma_sbr_obi_rsp_t dma_obi_rsp, dma_mem_obi_rsp_cut;

`ifndef SYNTHESIS
  // AXI Monitor dumper to improvce debiugging
  axi_dumper #(
    .BusName   ($sformatf("mem_tile_%d", MemTileId)),
    .LogAW     (1'b1),
    .LogAR     (1'b1),
    .LogW      (1'b1),
    .LogB      (1'b1),
    .LogR      (1'b1),
    .axi_req_t (floo_gwaihir_noc_pkg::axi_wide_in_req_t),
    .axi_resp_t(floo_gwaihir_noc_pkg::axi_wide_in_rsp_t)
  ) i_dma_axi_monitor (
    .clk_i,
    .rst_ni,
    .axi_req_i (axi_dma_req_demux[LOCAL]),
    .axi_resp_i(axi_dma_rsp_demux[LOCAL])
  );
`endif

  axi_to_obi #(
    .ObiCfg      (DMASbrObiCfg),
    .obi_req_t   (dma_sbr_obi_req_t),
    .obi_rsp_t   (dma_sbr_obi_rsp_t),
    .obi_a_chan_t(dma_sbr_obi_a_chan_t),
    .obi_r_chan_t(dma_sbr_obi_r_chan_t),
    .AxiAddrWidth(AxiCfgW.AddrWidth),
    .AxiDataWidth(AxiCfgW.DataWidth),
    .AxiIdWidth  (AxiCfgW.InIdWidth),
    .AxiUserWidth(AxiCfgW.UserWidth),
    .MaxTrans    (DMAObiLatency),
    .axi_req_t   (floo_gwaihir_noc_pkg::axi_wide_in_req_t),
    .axi_rsp_t   (floo_gwaihir_noc_pkg::axi_wide_in_rsp_t)
  ) i_dma_axi_to_obi (
    .clk_i     (tile_clk),
    .rst_ni    (tile_rst_n),
    .testmode_i(test_enable_i),
    .axi_req_i (axi_dma_req_demux[LOCAL]),
    .axi_rsp_o (axi_dma_rsp_demux[LOCAL]),
    .obi_req_o (dma_obi_req),
    .obi_rsp_i (dma_obi_rsp),

    // No atop on the DMA path: no aid round-trip, no user-field smuggling.
    .req_aw_id_o      (),
    .req_aw_user_o    (),
    .req_w_user_o     (),
    .req_write_aid_i  ('0),
    .req_write_auser_i('0),
    .req_write_wuser_i('0),

    .req_ar_id_o     (),
    .req_ar_user_o   (),
    .req_read_aid_i  ('0),
    .req_read_auser_i('0),

    .rsp_write_aw_user_o  (),
    .rsp_write_w_user_o   (),
    .rsp_write_bank_strb_o(),
    .rsp_write_rid_o      (),
    .rsp_write_ruser_o    (),
    .rsp_write_last_o     (),
    .rsp_write_hs_o       (),
    .rsp_b_user_i         ('0),

    .rsp_read_ar_user_o    (),
    .rsp_read_size_enable_o(),
    .rsp_read_rid_o        (),
    .rsp_read_ruser_o      (),
    .rsp_r_user_i          ('0)
  );

  ///////////////////////
  // DMA local mem req //
  ///////////////////////

  logic                            dma_mem_req;
  logic                            dma_mem_gnt;
  logic                            dma_mem_we;
  logic [   AxiCfgW.AddrWidth-1:0] dma_mem_addr;
  logic [   AxiCfgW.DataWidth-1:0] dma_mem_wdata;
  logic [ AxiCfgW.DataWidth/8-1:0] dma_mem_be;
  logic [   AxiCfgW.DataWidth-1:0] dma_mem_rdata;


  obi_cut #(
    .ObiCfg      (DMASbrObiCfg),
    .obi_a_chan_t(dma_sbr_obi_a_chan_t),
    .obi_r_chan_t(dma_sbr_obi_r_chan_t),
    .obi_req_t   (dma_sbr_obi_req_t),
    .obi_rsp_t   (dma_sbr_obi_rsp_t)
  ) i_dma_obi_cut (
    .clk_i         (tile_clk),
    .rst_ni        (tile_rst_n),
    .sbr_port_req_i(dma_obi_req),
    .sbr_port_rsp_o(dma_obi_rsp),
    .mgr_port_req_o(dma_mem_obi_req_cut),
    .mgr_port_rsp_i(dma_mem_obi_rsp_cut)
  );

  obi_sram_shim #(
    .ObiCfg   (DMASbrObiCfg),
    .obi_req_t(dma_sbr_obi_req_t),
    .obi_rsp_t(dma_sbr_obi_rsp_t)
  ) i_dma_sram_shim_bank (
    .clk_i    (tile_clk),
    .rst_ni   (tile_rst_n),
    .obi_req_i(dma_mem_obi_req_cut),
    .obi_rsp_o(dma_mem_obi_rsp_cut),
    .req_o    (dma_mem_req),
    .we_o     (dma_mem_we),
    .addr_o   (dma_mem_addr),
    .wdata_o  (dma_mem_wdata),
    .be_o     (dma_mem_be),
    .gnt_i    (dma_mem_gnt),
    .rdata_i  (dma_mem_rdata)
  );

  logic [NumBankRows-1:0] payload_dma_gnt;

  // Read data (direct output from SRAM memory macro)
  logic [NumBankRows-1:0][NumBanksPerWord-1:0][SramDataWidth-1:0]     arb_sram_rdata_split;

  logic                                                               dma_sram_req, dma_sram_gnt, dma_sram_we;
  logic [NumBanksPerWord-1:0][SramMacroSelWidth-1:0]                  dma_sram_macro_sel, dma_sram_macro_sel_q;
  logic [NumBanksPerWord-1:0][  SramAddrWidth-1:0]                    dma_sram_addr;
  logic [AxiCfgW.DataWidth-1:0]                                       dma_sram_rdata;

  logic [NumBanksPerWord-1:0][  SramDataWidth-1:0]                    dma_sram_wdata;
  logic [NumBanksPerWord-1:0][SramDataWidth/8-1:0]                    dma_sram_be;

  assign dma_sram_req   = dma_mem_req;
  assign dma_mem_gnt    = dma_sram_gnt;
  assign dma_sram_we    = dma_mem_we;
  assign dma_mem_rdata  = dma_sram_rdata;

  for (genvar bank = 0; bank < NumBanksPerWord; bank++) begin : gen_dma_wide_addresses
    // Calculate the addresses
    assign dma_sram_addr[bank]      = dma_mem_addr[SramAddrWidthOffset+:SramAddrWidth];
    assign dma_sram_macro_sel[bank] = dma_mem_addr[SramMacroSelOffset+:SramMacroSelWidth];
    // Register the macro selection to select the correct macro for the next cycle
    `FFL(dma_sram_macro_sel_q[bank], dma_sram_macro_sel[bank], dma_sram_req & dma_sram_gnt & ~dma_sram_we, '0);
    // Assign the data
    assign dma_sram_wdata[bank]                             = dma_mem_wdata[bank*SramDataWidth+:SramDataWidth];
    assign dma_sram_be[bank]                                = dma_mem_be[bank*SramDataWidth/8+:SramDataWidth/8];
    assign dma_sram_rdata[bank*SramDataWidth+:SramDataWidth] = arb_sram_rdata_split[dma_sram_macro_sel_q[bank]][bank];
  end

  assign dma_sram_gnt = |payload_dma_gnt;

  ///////////////////////
  // axi2obi converter //
  ///////////////////////

  // typedef obi for atomic config
  localparam obi_pkg::obi_optional_cfg_t MgrObiOptionalCfg = '{
      UseAtop: 1'b1,
      UseMemtype: 1'b0,
      UseProt: 1'b0,
      UseDbg: 1'b0,
      AUserWidth: 0,
      WUserWidth: 0,
      RUserWidth: 0,
      MidWidth: 0,
      AChkWidth: 0,
      RChkWidth: 0
  };
  localparam obi_pkg::obi_cfg_t MgrObiCfg = obi_pkg::obi_default_cfg(
      AxiCfgJoin.AddrWidth,
      AxiCfgJoin.DataWidth,
      (AxiUserAtop ? AxiUserAtopMsb + 1 - AxiUserAtopLsb : AxiCfgJoin.OutIdWidth),
      MgrObiOptionalCfg
  );
  `OBI_TYPEDEF_ATOP_A_OPTIONAL(mgr_obi_a_optional_t)
  `OBI_TYPEDEF_A_CHAN_T(mgr_obi_a_chan_t, MgrObiCfg.AddrWidth, MgrObiCfg.DataWidth,
                        MgrObiCfg.IdWidth, mgr_obi_a_optional_t)
  `OBI_TYPEDEF_DEFAULT_REQ_T(mgr_obi_req_t, mgr_obi_a_chan_t)
  typedef struct packed {logic exokay;} mgr_obi_r_optional_t;
  `OBI_TYPEDEF_R_CHAN_T(mgr_obi_r_chan_t, MgrObiCfg.DataWidth, MgrObiCfg.IdWidth,
                        mgr_obi_r_optional_t)
  `OBI_TYPEDEF_RSP_T(mgr_obi_rsp_t, mgr_obi_r_chan_t)


  // typedef obi for default config
  localparam obi_pkg::obi_optional_cfg_t SbrObiOptionalCfg = '{
      UseAtop: 1'b0,
      UseMemtype: 1'b0,
      UseProt: 1'b0,
      UseDbg: 1'b0,
      AUserWidth: 0,
      WUserWidth: 0,
      RUserWidth: 0,
      MidWidth: 0,
      AChkWidth: 0,
      RChkWidth: 0
  };
  localparam obi_pkg::obi_cfg_t SbrObiCfg = obi_pkg::obi_default_cfg(
      AxiCfgJoin.AddrWidth,
      AxiCfgJoin.DataWidth,
      (AxiUserAtop ? AxiUserAtopMsb + 1 - AxiUserAtopLsb : AxiCfgJoin.OutIdWidth),
      SbrObiOptionalCfg
  );
  `OBI_TYPEDEF_MINIMAL_A_OPTIONAL(sbr_obi_a_optional_t)
  `OBI_TYPEDEF_A_CHAN_T(sbr_obi_a_chan_t, SbrObiCfg.AddrWidth, SbrObiCfg.DataWidth,
                        SbrObiCfg.IdWidth, sbr_obi_a_optional_t)
  `OBI_TYPEDEF_DEFAULT_REQ_T(sbr_obi_req_t, sbr_obi_a_chan_t)
  `OBI_TYPEDEF_MINIMAL_R_OPTIONAL(sbr_obi_r_optional_t)
  `OBI_TYPEDEF_R_CHAN_T(sbr_obi_r_chan_t, SbrObiCfg.DataWidth, SbrObiCfg.IdWidth,
                        sbr_obi_r_optional_t)
  `OBI_TYPEDEF_RSP_T(sbr_obi_rsp_t, sbr_obi_r_chan_t)

  // Number of outstanding transactions should be larger than round-trip
  // latency from converter to SRAM
  localparam int unsigned ObiLatency = 4;

  logic [AxiCfgJoin.OutIdWidth-1:0] axi_in_aw_id, axi_in_ar_id;
  logic [AxiCfgJoin.UserWidth-1:0] axi_in_aw_user, axi_in_ar_user;
  logic [MgrObiCfg.IdWidth-1:0] obi_in_write_aid, obi_in_read_aid;

  logic [AxiCfgJoin.UserWidth-1:0] axi_in_r_user, axi_in_b_user;
  logic axi_in_rsp_write_bank_strobe, axi_in_rsp_read_size_enable;

  logic [MgrObiCfg.IdWidth-1:0] obi_in_rsp_write_rid, obi_in_rsp_read_rid;

  mgr_obi_req_t obi_req;
  mgr_obi_rsp_t obi_rsp;
  sbr_obi_req_t mem_obi_req, mem_obi_req_cut;
  sbr_obi_rsp_t mem_obi_rsp, mem_obi_rsp_cut;

  if (AxiUserAtop) begin : gen_user_atop
    assign obi_in_write_aid = axi_in_aw_user[AxiUserAtopMsb-1:AxiUserAtopLsb];
    assign obi_in_read_aid  = axi_in_ar_user[AxiUserAtopMsb-1:AxiUserAtopLsb];
  end else begin : gen_plain_atop
    assign obi_in_write_aid = axi_in_aw_id;
    assign obi_in_read_aid  = axi_in_ar_id;
  end

  always_comb begin : proc_obi_user
    axi_in_r_user = '0;
    axi_in_b_user = '0;
    // Respond with same ATOP ID
    if (AxiUserAtop) begin
      axi_in_r_user[AxiUserAtopMsb-1:AxiUserAtopLsb] |= axi_in_rsp_read_size_enable ?
                                                        obi_in_rsp_read_rid : '0;
      // No need to buffer the ATOP ID
      axi_in_b_user[AxiUserAtopMsb-1:AxiUserAtopLsb] |= axi_in_rsp_write_bank_strobe ?
                                                        obi_in_rsp_write_rid : '0;
    end
  end

`ifndef SYNTHESIS
  // AXI Monitor dumper to improvce debiugging
  axi_dumper #(
    .BusName   ($sformatf("mem_tile_%d", MemTileId)),
    .LogAW     (1'b1),
    .LogAR     (1'b1),
    .LogW      (1'b1),
    .LogB      (1'b1),
    .LogR      (1'b1),
    .axi_req_t (axi_nw_join_req_t),
    .axi_resp_t(axi_nw_join_rsp_t)
  ) i_axi_monitor (
    .clk_i,
    .rst_ni,
    .axi_req_i (axi_req),
    .axi_resp_i(axi_rsp)
  );
`endif

  axi_to_obi #(
    .ObiCfg      (MgrObiCfg),
    .obi_req_t   (mgr_obi_req_t),
    .obi_rsp_t   (mgr_obi_rsp_t),
    .obi_a_chan_t(mgr_obi_a_chan_t),
    .obi_r_chan_t(mgr_obi_r_chan_t),
    .AxiAddrWidth(AxiCfgJoin.AddrWidth),
    .AxiDataWidth(AxiCfgJoin.DataWidth),
    .AxiIdWidth  (AxiCfgJoin.OutIdWidth),
    .AxiUserWidth(AxiCfgJoin.UserWidth),
    .MaxTrans    (ObiLatency),
    .axi_req_t   (axi_nw_join_req_t),
    .axi_rsp_t   (axi_nw_join_rsp_t)
  ) i_axi_to_obi (
    .clk_i     (tile_clk),
    .rst_ni    (tile_rst_n),
    .testmode_i(test_enable_i),
    .axi_req_i (axi_req),
    .axi_rsp_o (axi_rsp),
    .obi_req_o (obi_req),
    .obi_rsp_i (obi_rsp),

    .req_aw_id_o      (axi_in_aw_id),
    .req_aw_user_o    (axi_in_aw_user),
    .req_w_user_o     (),
    .req_write_aid_i  (obi_in_write_aid),
    .req_write_auser_i('0),
    .req_write_wuser_i('0),

    .req_ar_id_o     (axi_in_ar_id),
    .req_ar_user_o   (axi_in_ar_user),
    .req_read_aid_i  (obi_in_read_aid),
    .req_read_auser_i('0),

    .rsp_write_aw_user_o  (),
    .rsp_write_w_user_o   (),
    .rsp_write_bank_strb_o(axi_in_rsp_write_bank_strobe),
    .rsp_write_rid_o      (obi_in_rsp_write_rid),
    .rsp_write_ruser_o    (),
    .rsp_write_last_o     (),
    .rsp_write_hs_o       (),
    .rsp_b_user_i         (axi_in_b_user),

    .rsp_read_ar_user_o    (),
    .rsp_read_size_enable_o(axi_in_rsp_read_size_enable),
    .rsp_read_rid_o        (obi_in_rsp_read_rid),
    .rsp_read_ruser_o      (),
    .rsp_r_user_i          (axi_in_r_user)
  );

  /////////////////
  // SRAM macros //
  /////////////////

  logic                            mem_req;
  logic                            mem_gnt;
  logic                            mem_we;
  logic [AxiCfgJoin.AddrWidth-1:0] mem_addr;
  logic [   AxiCfgW.DataWidth-1:0] mem_wdata;
  logic [ AxiCfgW.DataWidth/8-1:0] mem_be;
  logic [   AxiCfgW.DataWidth-1:0] mem_rdata;


  obi_atop_resolver #(
    .SbrPortObiCfg            (MgrObiCfg),
    .MgrPortObiCfg            (SbrObiCfg),
    .sbr_port_obi_req_t       (mgr_obi_req_t),
    .sbr_port_obi_rsp_t       (mgr_obi_rsp_t),
    .mgr_port_obi_req_t       (sbr_obi_req_t),
    .mgr_port_obi_rsp_t       (sbr_obi_rsp_t),
    .mgr_port_obi_a_optional_t(sbr_obi_a_optional_t),
    .mgr_port_obi_r_optional_t(sbr_obi_r_optional_t),
    .LrScEnable               (1'b1),
    .RiscvWordWidth           (32),
    .NumTxns                  (ObiLatency)
  ) i_obi_atop_resolver (
    .clk_i         (tile_clk),
    .rst_ni        (tile_rst_n),
    .testmode_i    (test_enable_i),
    .sbr_port_req_i(obi_req),
    .sbr_port_rsp_o(obi_rsp),
    .mgr_port_req_o(mem_obi_req),
    .mgr_port_rsp_i(mem_obi_rsp)
  );

  obi_cut #(
    .ObiCfg      (SbrObiCfg),
    .obi_a_chan_t(sbr_obi_a_chan_t),
    .obi_r_chan_t(sbr_obi_r_chan_t),
    .obi_req_t   (sbr_obi_req_t),
    .obi_rsp_t   (sbr_obi_rsp_t)
  ) i_obi_cut (
    .clk_i         (tile_clk),
    .rst_ni        (tile_rst_n),
    .sbr_port_req_i(mem_obi_req),
    .sbr_port_rsp_o(mem_obi_rsp),
    .mgr_port_req_o(mem_obi_req_cut),
    .mgr_port_rsp_i(mem_obi_rsp_cut)
  );

  obi_sram_shim #(
    .ObiCfg   (SbrObiCfg),
    .obi_req_t(sbr_obi_req_t),
    .obi_rsp_t(sbr_obi_rsp_t)
  ) i_sram_shim_bank (
    .clk_i    (tile_clk),
    .rst_ni   (tile_rst_n),
    .obi_req_i(mem_obi_req_cut),
    .obi_rsp_o(mem_obi_rsp_cut),
    .req_o    (mem_req),
    .we_o     (mem_we),
    .addr_o   (mem_addr),
    .wdata_o  (mem_wdata),
    .be_o     (mem_be),
    .gnt_i    (mem_gnt),
    .rdata_i  (mem_rdata)
  );

  logic [NumBankRows-1:0] payload_ext_gnt;

  logic                                                               sram_req, sram_gnt, sram_we;
  logic [NumBanksPerWord-1:0][SramMacroSelWidth-1:0]                  sram_macro_sel, sram_macro_sel_q;
  logic [NumBanksPerWord-1:0][  SramAddrWidth-1:0]                    sram_addr;
  logic [AxiCfgW.DataWidth-1:0]                                       sram_rdata;

  logic [NumBanksPerWord-1:0][  SramDataWidth-1:0]                    sram_wdata;
  logic [NumBanksPerWord-1:0][SramDataWidth/8-1:0]                    sram_be;

  assign sram_req   = mem_req;
  assign mem_gnt    = sram_gnt;
  assign sram_we    = mem_we;
  assign mem_rdata  = sram_rdata;

  for (genvar bank = 0; bank < NumBanksPerWord; bank++) begin : gen_addresses
    // Calculate the addresses
    assign sram_addr[bank]      = mem_addr[SramAddrWidthOffset+:SramAddrWidth];
    assign sram_macro_sel[bank] = mem_addr[SramMacroSelOffset+:SramMacroSelWidth];
    // Register the macro selection to select the correct macro for the next cycle
    `FFL(sram_macro_sel_q[bank], sram_macro_sel[bank], sram_req & sram_gnt & ~sram_we, '0);
    // Assign the data
    assign sram_wdata[bank]                               = mem_wdata[bank*SramDataWidth+:SramDataWidth];
    assign sram_be[bank]                                  = mem_be[bank*SramDataWidth/8+:SramDataWidth/8];
    assign sram_rdata[bank*SramDataWidth+:SramDataWidth]  = arb_sram_rdata_split[sram_macro_sel_q[bank]][bank];
  end

  assign sram_gnt = |payload_ext_gnt;

  /////////////////////////
  // Row Request Arbitor //
  /////////////////////////

  logic [NumBankRows-1:0] payload_ext_req, payload_dma_req;

  // Arbitor result signals
  logic [NumBankRows-1:0]                         arb_sram_req;
  logic [NumBankRows-1:0][SramAddrWidth-1:0]      arb_sram_addr;
  logic [NumBankRows-1:0]                         arb_sram_we;
  logic [NumBankRows-1:0][NumBanksPerWord-1:0][SramDataWidth-1:0]   arb_sram_wdata;
  logic [NumBankRows-1:0][NumBanksPerWord-1:0][SramDataWidth/8-1:0] arb_sram_be;

  typedef struct packed {
    logic [SramAddrWidth-1:0] addr;
    logic                     we;
    logic [NumBanksPerWord-1:0][SramDataWidth-1:0]    wdata;
    logic [NumBanksPerWord-1:0][SramDataWidth/8-1:0]  be;
  } sram_payload_t;

  // Pack memory request payload from external tiles
  sram_payload_t [NumBankRows-1:0] payload_ext, payload_dma;

  for (genvar row = 0; row < NumBankRows; row++) begin : gen_sram_row_arbitor
    // Memory request from external tiles and DMA
    assign  payload_ext_req[row] = sram_req && (sram_macro_sel[0] == row);
    assign  payload_dma_req[row] = dma_sram_req && (dma_sram_macro_sel[0] == row);

    assign    payload_ext[row].addr  = sram_addr[0];
    assign    payload_ext[row].we    = sram_we && (sram_macro_sel[0] == row);
    for (genvar bank = 0; bank < NumBanksPerWord; bank++) begin: gen_ext_payload_banks
      assign  payload_ext[row].wdata[bank]  = sram_wdata[bank];
      assign  payload_ext[row].be[bank]     = sram_be[bank];
    end
    // Pack memory request payload from DMA
    assign    payload_dma[row].addr  = dma_sram_addr[0];
    assign    payload_dma[row].we    = dma_sram_we && (dma_sram_macro_sel[0] == row);
    for (genvar bank = 0; bank < NumBanksPerWord; bank++) begin: gen_dma_payload_banks
      assign  payload_dma[row].wdata[bank]  = dma_sram_wdata[bank];
      assign  payload_dma[row].be[bank]     = dma_sram_be[bank];
    end

    // Requests from external tiles has higher priority
    rr_arb_tree #(
      .NumIn    (2               ),
      .DataWidth($bits(sram_payload_t)),
      .AxiVldRdy(1'b0            ),
      .ExtPrio  (1'b1            )
    ) i_row_arbiter (
      .clk_i  (tile_clk                            ),
      .rst_ni (tile_rst_n                           ),
      .flush_i(1'b0                             ),
      .rr_i   (1'b1                             ),
      .data_i ({payload_ext[row], payload_dma[row]}         ),
      .req_i  ({payload_ext_req[row], payload_dma_req[row]} ),
      .gnt_o  ({payload_ext_gnt[row], payload_dma_gnt[row]} ),
      .data_o ({arb_sram_addr[row], arb_sram_we[row], arb_sram_wdata[row], arb_sram_be[row]}),
      .idx_o (/* Unused */    ),
      .req_o (arb_sram_req[row] ),
      .gnt_i (arb_sram_req[row] ) // Acknowledge it directly
    );
  end

  for (genvar bank = 0; bank < NumBanksPerWord; bank++) begin : gen_sram_banks
    for (genvar row = 0; row < NumBankRows; row++) begin : gen_sram_macros
      tc_sram #(
        .NumWords (SramNumWords),
        .DataWidth(SramDataWidth),
        .NumPorts (1),
        .Latency  (1)
      ) i_mem (
        .clk_i  (tile_clk),
        .rst_ni (tile_rst_n),
        .req_i  (arb_sram_req[row]),
        .we_i   (arb_sram_we[row]),
        .addr_i (arb_sram_addr[row]),
        .wdata_i(arb_sram_wdata[row][bank]),
        .be_i   (arb_sram_be[row][bank]),
        .rdata_o(arb_sram_rdata_split[row][bank])
      );
    end
  end

  //////////////////////////
  // Clock Gating & Reset //
  //////////////////////////

  tc_clk_gating i_tc_clk_gating_mem_tile (
    .clk_i,
    .en_i     (tile_clk_en_i),
    .test_en_i(clk_rst_bypass_i),
    .clk_o    (tile_clk)
  );

`ifdef TARGET_XILINX
  // Using clk cells makes Vivado flag the reset as a clock tree
  assign tile_rst_n = (clk_rst_bypass_i) ? rst_ni : tile_rst_ni;
`else
  tc_clk_mux2 i_tc_reset_mux (
    .clk0_i   (tile_rst_ni),
    .clk1_i   (rst_ni),
    .clk_sel_i(clk_rst_bypass_i),
    .clk_o    (tile_rst_n)
  );
`endif
  // Add Assertion that no multicast / reduction can enter this tile!
  for (genvar r = 0; r < 4; r++) begin : gen_route_assertions
    `ASSERT(NoCollectivOperation_NReq_In,
            (!floo_req_i[r].valid | (floo_req_i[r].req[0].generic.hdr.collective_op == Unicast)),
            clk_i, !rst_ni, $sformatf(
            "Unsupported collective attempted with destination: %h",
            floo_req_i[r].req[0].narrow_aw.payload.addr
            ))
    `ASSERT(NoCollectivOperation_NRsp_In,
            (!floo_rsp_i[r].valid | (floo_rsp_i[r].rsp[0].generic.hdr.collective_op == Unicast)))
    `ASSERT(NoCollectivOperation_NWide_In,
            (!floo_wide_i[r].valid | (floo_wide_i[r].wide[0].generic.hdr.collective_op == Unicast)),
            clk_i, !rst_ni, $sformatf(
            "Unsupported collective attempted with destination: %h",
            floo_wide_i[r].wide[0].wide_aw.payload.addr
            ))
    `ASSERT(NoCollectivOperation_NReq_Out,
            (!floo_req_o[r].valid | (floo_req_o[r].req[0].generic.hdr.collective_op == Unicast)),
            clk_i, !rst_ni, $sformatf(
            "Unsupported collective attempted with destination: %h",
            floo_req_o[r].req[0].narrow_aw.payload.addr
            ))
    `ASSERT(NoCollectivOperation_NRsp_Out,
            (!floo_rsp_o[r].valid | (floo_rsp_o[r].rsp[0].generic.hdr.collective_op == Unicast)))
    `ASSERT(NoCollectivOperation_NWide_Out,
            (!floo_wide_o[r].valid | (floo_wide_o[r].wide[0].generic.hdr.collective_op == Unicast)),
            clk_i, !rst_ni, $sformatf(
            "Unsupported collective attempted with destination: %h",
            floo_wide_i[r].wide[0].wide_aw.payload.addr
            ))
  end

endmodule
