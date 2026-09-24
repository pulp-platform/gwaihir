// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Hand-maintained copy of the floogen-generated `.generated/hw/floo_gwaihir_noc_pkg.sv`.
// It is referenced directly from Bender.yml so that `make floo-hw-all` cannot overwrite it.
//
// Local modification w.r.t. the generated file: the transported (non-`collective_`)
// AXI user types keep the full collective user struct (`collective_mask`, `collective_op`)
// instead of stripping it, and `AxiCfgN`/`AxiCfgW.UserWidth` are widened accordingly, so
// the collective mask travels in the flit payload `user` field instead of being dropped
// at the chimney.
//
// Original header:
// AUTOMATICALLY GENERATED! DO NOT EDIT!

`include "axi/typedef.svh"
`include "floo_noc/typedef.svh"

package floo_gwaihir_noc_pkg;

  import floo_pkg::*;

  ////////////////////
  //   Parameters   //
  ////////////////////

  localparam int unsigned ClusterX = 4;
  localparam int unsigned ClusterY = 4;
  localparam int unsigned ClusterBase = 536870912;
  localparam int unsigned ClusterSize = 262144;
  localparam int unsigned L2Base = 555745280;
  localparam int unsigned L2Stride = 2097152;
  localparam int unsigned L2SizeLarge = 2097152;
  localparam int unsigned L2SizeSmall = 1048576;
  localparam int unsigned RegSize = 4096;
  localparam int unsigned ClusterCfgBase = 553648128;
  localparam int unsigned L2DmaBase = 553713664;
  localparam int unsigned L2CfgBase = 553730048;
  localparam int unsigned ChipletWinSize = 33554432;
  localparam int unsigned ChipletWinMask = 33554431;
  localparam int unsigned CshSlinkNumLanes = 8;


  /////////////////////////////
  //   Endpoint Dimensions   //
  /////////////////////////////

  localparam int unsigned NumClusterX = 4;
  localparam int unsigned NumClusterY = 4;


  /////////////////////
  //   Address Map   //
  /////////////////////

  typedef enum logic [4:0] {
    ClusterX0Y0  = 0,
    ClusterX0Y1  = 1,
    ClusterX0Y2  = 2,
    ClusterX0Y3  = 3,
    ClusterX1Y0  = 4,
    ClusterX1Y1  = 5,
    ClusterX1Y2  = 6,
    ClusterX1Y3  = 7,
    ClusterX2Y0  = 8,
    ClusterX2Y1  = 9,
    ClusterX2Y2  = 10,
    ClusterX2Y3  = 11,
    ClusterX3Y0  = 12,
    ClusterX3Y1  = 13,
    ClusterX3Y2  = 14,
    ClusterX3Y3  = 15,
    Cheshire     = 16,
    L2Spm0       = 17,
    L2Spm1       = 18,
    L2Spm2       = 19,
    L2Spm3       = 20,
    Ucie0        = 21,
    Ucie1        = 22,
    Pcie         = 23,
    NumEndpoints = 24
  } ep_id_e;



  typedef enum logic [5:0] {
    ClusterConfigX0Y0SamIdx = 0,
    ClusterX0Y0SamIdx       = 1,
    ClusterConfigX0Y1SamIdx = 2,
    ClusterX0Y1SamIdx       = 3,
    ClusterConfigX0Y2SamIdx = 4,
    ClusterX0Y2SamIdx       = 5,
    ClusterConfigX0Y3SamIdx = 6,
    ClusterX0Y3SamIdx       = 7,
    ClusterConfigX1Y0SamIdx = 8,
    ClusterX1Y0SamIdx       = 9,
    ClusterConfigX1Y1SamIdx = 10,
    ClusterX1Y1SamIdx       = 11,
    ClusterConfigX1Y2SamIdx = 12,
    ClusterX1Y2SamIdx       = 13,
    ClusterConfigX1Y3SamIdx = 14,
    ClusterX1Y3SamIdx       = 15,
    ClusterConfigX2Y0SamIdx = 16,
    ClusterX2Y0SamIdx       = 17,
    ClusterConfigX2Y1SamIdx = 18,
    ClusterX2Y1SamIdx       = 19,
    ClusterConfigX2Y2SamIdx = 20,
    ClusterX2Y2SamIdx       = 21,
    ClusterConfigX2Y3SamIdx = 22,
    ClusterX2Y3SamIdx       = 23,
    ClusterConfigX3Y0SamIdx = 24,
    ClusterX3Y0SamIdx       = 25,
    ClusterConfigX3Y1SamIdx = 26,
    ClusterX3Y1SamIdx       = 27,
    ClusterConfigX3Y2SamIdx = 28,
    ClusterX3Y2SamIdx       = 29,
    ClusterConfigX3Y3SamIdx = 30,
    ClusterX3Y3SamIdx       = 31,
    CheshireExternalSamIdx  = 32,
    CheshireInternalSamIdx  = 33,
    L2Spm0DmaSamIdx         = 34,
    L2Spm0ConfigSamIdx      = 35,
    L2Spm0SamIdx            = 36,
    L2Spm1DmaSamIdx         = 37,
    L2Spm1ConfigSamIdx      = 38,
    L2Spm1SamIdx            = 39,
    L2Spm2DmaSamIdx         = 40,
    L2Spm2ConfigSamIdx      = 41,
    L2Spm2SamIdx            = 42,
    L2Spm3DmaSamIdx         = 43,
    L2Spm3ConfigSamIdx      = 44,
    L2Spm3SamIdx            = 45,
    Ucie0AxiSerialCfgSamIdx = 46,
    Ucie0TileCfgSamIdx      = 47,
    Ucie0UcieCfgSamIdx      = 48,
    Ucie0SamIdx             = 49,
    Ucie1AxiSerialCfgSamIdx = 50,
    Ucie1TileCfgSamIdx      = 51,
    Ucie1UcieCfgSamIdx      = 52,
    Ucie1SamIdx             = 53,
    PcieSamIdx              = 54
  } sam_idx_e;



  typedef logic [0:0] rob_idx_t;
  typedef logic [0:0] port_id_t;
  typedef logic [3:0] x_bits_t;
  typedef logic [2:0] y_bits_t;
  typedef struct packed {
    x_bits_t  x;
    y_bits_t  y;
    port_id_t port_id;
  } id_t;

  typedef logic route_t;


  typedef struct packed {
    id_t idx;
    id_t start_addr;
    id_t end_addr;
  } route_map_rule_t;

  localparam int unsigned SamNumRules = 55;

  typedef struct packed {
    id_t         idx;
    logic [47:0] start_addr;
    logic [47:0] end_addr;
  } sam_rule_t;

  localparam sam_rule_t [SamNumRules-1:0] Sam = '{
      '{
          idx: '{x: 0, y: 4, port_id: 0},
          start_addr: 48'h000100000000,
          end_addr: 48'h000200000000
      },  // Pcie
      '{
          idx: '{x: 8, y: 0, port_id: 0},
          start_addr: 48'h000030000000,
          end_addr: 48'h000032000000
      },  // Ucie1
      '{
          idx: '{x: 8, y: 0, port_id: 0},
          start_addr: 48'h000034020000,
          end_addr: 48'h000034030000
      },  // Ucie1UcieCfg
      '{
          idx: '{x: 8, y: 0, port_id: 0},
          start_addr: 48'h000034031000,
          end_addr: 48'h000034032000
      },  // Ucie1TileCfg
      '{
          idx: '{x: 8, y: 0, port_id: 0},
          start_addr: 48'h000034041000,
          end_addr: 48'h000034042000
      },  // Ucie1AxiSerialCfg
      '{
          idx: '{x: 0, y: 0, port_id: 0},
          start_addr: 48'h000032000000,
          end_addr: 48'h000034000000
      },  // Ucie0
      '{
          idx: '{x: 0, y: 0, port_id: 0},
          start_addr: 48'h000034010000,
          end_addr: 48'h000034020000
      },  // Ucie0UcieCfg
      '{
          idx: '{x: 0, y: 0, port_id: 0},
          start_addr: 48'h000034030000,
          end_addr: 48'h000034031000
      },  // Ucie0TileCfg
      '{
          idx: '{x: 0, y: 0, port_id: 0},
          start_addr: 48'h000034040000,
          end_addr: 48'h000034041000
      },  // Ucie0AxiSerialCfg
      '{
          idx: '{x: 8, y: 3, port_id: 0},
          start_addr: 48'h000021800000,
          end_addr: 48'h000021900000
      },  // L2Spm3
      '{
          idx: '{x: 8, y: 3, port_id: 0},
          start_addr: 48'h000021017000,
          end_addr: 48'h000021018000
      },  // L2Spm3Config
      '{
          idx: '{x: 8, y: 3, port_id: 0},
          start_addr: 48'h000021013000,
          end_addr: 48'h000021014000
      },  // L2Spm3Dma
      '{
          idx: '{x: 8, y: 2, port_id: 0},
          start_addr: 48'h000021600000,
          end_addr: 48'h000021800000
      },  // L2Spm2
      '{
          idx: '{x: 8, y: 2, port_id: 0},
          start_addr: 48'h000021016000,
          end_addr: 48'h000021017000
      },  // L2Spm2Config
      '{
          idx: '{x: 8, y: 2, port_id: 0},
          start_addr: 48'h000021012000,
          end_addr: 48'h000021013000
      },  // L2Spm2Dma
      '{
          idx: '{x: 0, y: 3, port_id: 0},
          start_addr: 48'h000021400000,
          end_addr: 48'h000021500000
      },  // L2Spm1
      '{
          idx: '{x: 0, y: 3, port_id: 0},
          start_addr: 48'h000021015000,
          end_addr: 48'h000021016000
      },  // L2Spm1Config
      '{
          idx: '{x: 0, y: 3, port_id: 0},
          start_addr: 48'h000021011000,
          end_addr: 48'h000021012000
      },  // L2Spm1Dma
      '{
          idx: '{x: 0, y: 2, port_id: 0},
          start_addr: 48'h000021200000,
          end_addr: 48'h000021400000
      },  // L2Spm0
      '{
          idx: '{x: 0, y: 2, port_id: 0},
          start_addr: 48'h000021014000,
          end_addr: 48'h000021015000
      },  // L2Spm0Config
      '{
          idx: '{x: 0, y: 2, port_id: 0},
          start_addr: 48'h000021010000,
          end_addr: 48'h000021011000
      },  // L2Spm0Dma
      '{
          idx: '{x: 8, y: 4, port_id: 0},
          start_addr: 48'h000000000000,
          end_addr: 48'h000020000000
      },  // CheshireInternal
      '{
          idx: '{x: 8, y: 4, port_id: 0},
          start_addr: 48'h000080000000,
          end_addr: 48'h000100000000
      },  // CheshireExternal
      '{
          idx: '{x: 7, y: 3, port_id: 0},
          start_addr: 48'h0000203c0000,
          end_addr: 48'h000020400000
      },  // ClusterX3Y3
      '{
          idx: '{x: 7, y: 3, port_id: 0},
          start_addr: 48'h00002100f000,
          end_addr: 48'h000021010000
      },  // ClusterConfigX3Y3
      '{
          idx: '{x: 7, y: 2, port_id: 0},
          start_addr: 48'h000020380000,
          end_addr: 48'h0000203c0000
      },  // ClusterX3Y2
      '{
          idx: '{x: 7, y: 2, port_id: 0},
          start_addr: 48'h00002100e000,
          end_addr: 48'h00002100f000
      },  // ClusterConfigX3Y2
      '{
          idx: '{x: 7, y: 1, port_id: 0},
          start_addr: 48'h000020340000,
          end_addr: 48'h000020380000
      },  // ClusterX3Y1
      '{
          idx: '{x: 7, y: 1, port_id: 0},
          start_addr: 48'h00002100d000,
          end_addr: 48'h00002100e000
      },  // ClusterConfigX3Y1
      '{
          idx: '{x: 7, y: 0, port_id: 0},
          start_addr: 48'h000020300000,
          end_addr: 48'h000020340000
      },  // ClusterX3Y0
      '{
          idx: '{x: 7, y: 0, port_id: 0},
          start_addr: 48'h00002100c000,
          end_addr: 48'h00002100d000
      },  // ClusterConfigX3Y0
      '{
          idx: '{x: 6, y: 3, port_id: 0},
          start_addr: 48'h0000202c0000,
          end_addr: 48'h000020300000
      },  // ClusterX2Y3
      '{
          idx: '{x: 6, y: 3, port_id: 0},
          start_addr: 48'h00002100b000,
          end_addr: 48'h00002100c000
      },  // ClusterConfigX2Y3
      '{
          idx: '{x: 6, y: 2, port_id: 0},
          start_addr: 48'h000020280000,
          end_addr: 48'h0000202c0000
      },  // ClusterX2Y2
      '{
          idx: '{x: 6, y: 2, port_id: 0},
          start_addr: 48'h00002100a000,
          end_addr: 48'h00002100b000
      },  // ClusterConfigX2Y2
      '{
          idx: '{x: 6, y: 1, port_id: 0},
          start_addr: 48'h000020240000,
          end_addr: 48'h000020280000
      },  // ClusterX2Y1
      '{
          idx: '{x: 6, y: 1, port_id: 0},
          start_addr: 48'h000021009000,
          end_addr: 48'h00002100a000
      },  // ClusterConfigX2Y1
      '{
          idx: '{x: 6, y: 0, port_id: 0},
          start_addr: 48'h000020200000,
          end_addr: 48'h000020240000
      },  // ClusterX2Y0
      '{
          idx: '{x: 6, y: 0, port_id: 0},
          start_addr: 48'h000021008000,
          end_addr: 48'h000021009000
      },  // ClusterConfigX2Y0
      '{
          idx: '{x: 5, y: 3, port_id: 0},
          start_addr: 48'h0000201c0000,
          end_addr: 48'h000020200000
      },  // ClusterX1Y3
      '{
          idx: '{x: 5, y: 3, port_id: 0},
          start_addr: 48'h000021007000,
          end_addr: 48'h000021008000
      },  // ClusterConfigX1Y3
      '{
          idx: '{x: 5, y: 2, port_id: 0},
          start_addr: 48'h000020180000,
          end_addr: 48'h0000201c0000
      },  // ClusterX1Y2
      '{
          idx: '{x: 5, y: 2, port_id: 0},
          start_addr: 48'h000021006000,
          end_addr: 48'h000021007000
      },  // ClusterConfigX1Y2
      '{
          idx: '{x: 5, y: 1, port_id: 0},
          start_addr: 48'h000020140000,
          end_addr: 48'h000020180000
      },  // ClusterX1Y1
      '{
          idx: '{x: 5, y: 1, port_id: 0},
          start_addr: 48'h000021005000,
          end_addr: 48'h000021006000
      },  // ClusterConfigX1Y1
      '{
          idx: '{x: 5, y: 0, port_id: 0},
          start_addr: 48'h000020100000,
          end_addr: 48'h000020140000
      },  // ClusterX1Y0
      '{
          idx: '{x: 5, y: 0, port_id: 0},
          start_addr: 48'h000021004000,
          end_addr: 48'h000021005000
      },  // ClusterConfigX1Y0
      '{
          idx: '{x: 4, y: 3, port_id: 0},
          start_addr: 48'h0000200c0000,
          end_addr: 48'h000020100000
      },  // ClusterX0Y3
      '{
          idx: '{x: 4, y: 3, port_id: 0},
          start_addr: 48'h000021003000,
          end_addr: 48'h000021004000
      },  // ClusterConfigX0Y3
      '{
          idx: '{x: 4, y: 2, port_id: 0},
          start_addr: 48'h000020080000,
          end_addr: 48'h0000200c0000
      },  // ClusterX0Y2
      '{
          idx: '{x: 4, y: 2, port_id: 0},
          start_addr: 48'h000021002000,
          end_addr: 48'h000021003000
      },  // ClusterConfigX0Y2
      '{
          idx: '{x: 4, y: 1, port_id: 0},
          start_addr: 48'h000020040000,
          end_addr: 48'h000020080000
      },  // ClusterX0Y1
      '{
          idx: '{x: 4, y: 1, port_id: 0},
          start_addr: 48'h000021001000,
          end_addr: 48'h000021002000
      },  // ClusterConfigX0Y1
      '{
          idx: '{x: 4, y: 0, port_id: 0},
          start_addr: 48'h000020000000,
          end_addr: 48'h000020040000
      },  // ClusterX0Y0
      '{
          idx: '{x: 4, y: 0, port_id: 0},
          start_addr: 48'h000021000000,
          end_addr: 48'h000021001000
      }  // ClusterConfigX0Y0

  };

  localparam int unsigned CollectiveSamNumRules = 55;

  typedef struct packed {
    int unsigned offset;
    int unsigned len;
    int unsigned base_id;
  } collective_mask_sel_t;

  typedef struct packed {
    id_t                  id;
    collective_mask_sel_t mask_x;
    collective_mask_sel_t mask_y;
  } collective_idx_t;

  typedef struct packed {
    collective_idx_t idx;
    logic [47:0]     start_addr;
    logic [47:0]     end_addr;
  } collective_sam_rule_t;

  localparam collective_sam_rule_t [CollectiveSamNumRules-1:0] CollectiveSam = '{
      '{
          idx: '{
              id: '{x: 0, y: 4, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000100000000,
          end_addr: 48'h000200000000
      },  // Pcie
      '{
          idx: '{
              id: '{x: 8, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000030000000,
          end_addr: 48'h000032000000
      },  // Ucie1
      '{
          idx: '{
              id: '{x: 8, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034020000,
          end_addr: 48'h000034030000
      },  // Ucie1UcieCfg
      '{
          idx: '{
              id: '{x: 8, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034031000,
          end_addr: 48'h000034032000
      },  // Ucie1TileCfg
      '{
          idx: '{
              id: '{x: 8, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034041000,
          end_addr: 48'h000034042000
      },  // Ucie1AxiSerialCfg
      '{
          idx: '{
              id: '{x: 0, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000032000000,
          end_addr: 48'h000034000000
      },  // Ucie0
      '{
          idx: '{
              id: '{x: 0, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034010000,
          end_addr: 48'h000034020000
      },  // Ucie0UcieCfg
      '{
          idx: '{
              id: '{x: 0, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034030000,
          end_addr: 48'h000034031000
      },  // Ucie0TileCfg
      '{
          idx: '{
              id: '{x: 0, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000034040000,
          end_addr: 48'h000034041000
      },  // Ucie0AxiSerialCfg
      '{
          idx: '{
              id: '{x: 8, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021800000,
          end_addr: 48'h000021900000
      },  // L2Spm3
      '{
          idx: '{
              id: '{x: 8, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021017000,
          end_addr: 48'h000021018000
      },  // L2Spm3Config
      '{
          idx: '{
              id: '{x: 8, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021013000,
          end_addr: 48'h000021014000
      },  // L2Spm3Dma
      '{
          idx: '{
              id: '{x: 8, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021600000,
          end_addr: 48'h000021800000
      },  // L2Spm2
      '{
          idx: '{
              id: '{x: 8, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021016000,
          end_addr: 48'h000021017000
      },  // L2Spm2Config
      '{
          idx: '{
              id: '{x: 8, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021012000,
          end_addr: 48'h000021013000
      },  // L2Spm2Dma
      '{
          idx: '{
              id: '{x: 0, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021400000,
          end_addr: 48'h000021500000
      },  // L2Spm1
      '{
          idx: '{
              id: '{x: 0, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021015000,
          end_addr: 48'h000021016000
      },  // L2Spm1Config
      '{
          idx: '{
              id: '{x: 0, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021011000,
          end_addr: 48'h000021012000
      },  // L2Spm1Dma
      '{
          idx: '{
              id: '{x: 0, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021200000,
          end_addr: 48'h000021400000
      },  // L2Spm0
      '{
          idx: '{
              id: '{x: 0, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021014000,
          end_addr: 48'h000021015000
      },  // L2Spm0Config
      '{
          idx: '{
              id: '{x: 0, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021010000,
          end_addr: 48'h000021011000
      },  // L2Spm0Dma
      '{
          idx: '{
              id: '{x: 8, y: 4, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000000000000,
          end_addr: 48'h000020000000
      },  // CheshireInternal
      '{
          idx: '{
              id: '{x: 8, y: 4, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000080000000,
          end_addr: 48'h000100000000
      },  // CheshireExternal
      '{
          idx: '{
              id: '{x: 7, y: 3, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h0000203c0000,
          end_addr: 48'h000020400000
      },  // ClusterX3Y3
      '{
          idx: '{
              id: '{x: 7, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100f000,
          end_addr: 48'h000021010000
      },  // ClusterConfigX3Y3
      '{
          idx: '{
              id: '{x: 7, y: 2, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020380000,
          end_addr: 48'h0000203c0000
      },  // ClusterX3Y2
      '{
          idx: '{
              id: '{x: 7, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100e000,
          end_addr: 48'h00002100f000
      },  // ClusterConfigX3Y2
      '{
          idx: '{
              id: '{x: 7, y: 1, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020340000,
          end_addr: 48'h000020380000
      },  // ClusterX3Y1
      '{
          idx: '{
              id: '{x: 7, y: 1, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100d000,
          end_addr: 48'h00002100e000
      },  // ClusterConfigX3Y1
      '{
          idx: '{
              id: '{x: 7, y: 0, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020300000,
          end_addr: 48'h000020340000
      },  // ClusterX3Y0
      '{
          idx: '{
              id: '{x: 7, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100c000,
          end_addr: 48'h00002100d000
      },  // ClusterConfigX3Y0
      '{
          idx: '{
              id: '{x: 6, y: 3, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h0000202c0000,
          end_addr: 48'h000020300000
      },  // ClusterX2Y3
      '{
          idx: '{
              id: '{x: 6, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100b000,
          end_addr: 48'h00002100c000
      },  // ClusterConfigX2Y3
      '{
          idx: '{
              id: '{x: 6, y: 2, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020280000,
          end_addr: 48'h0000202c0000
      },  // ClusterX2Y2
      '{
          idx: '{
              id: '{x: 6, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h00002100a000,
          end_addr: 48'h00002100b000
      },  // ClusterConfigX2Y2
      '{
          idx: '{
              id: '{x: 6, y: 1, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020240000,
          end_addr: 48'h000020280000
      },  // ClusterX2Y1
      '{
          idx: '{
              id: '{x: 6, y: 1, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021009000,
          end_addr: 48'h00002100a000
      },  // ClusterConfigX2Y1
      '{
          idx: '{
              id: '{x: 6, y: 0, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020200000,
          end_addr: 48'h000020240000
      },  // ClusterX2Y0
      '{
          idx: '{
              id: '{x: 6, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021008000,
          end_addr: 48'h000021009000
      },  // ClusterConfigX2Y0
      '{
          idx: '{
              id: '{x: 5, y: 3, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h0000201c0000,
          end_addr: 48'h000020200000
      },  // ClusterX1Y3
      '{
          idx: '{
              id: '{x: 5, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021007000,
          end_addr: 48'h000021008000
      },  // ClusterConfigX1Y3
      '{
          idx: '{
              id: '{x: 5, y: 2, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020180000,
          end_addr: 48'h0000201c0000
      },  // ClusterX1Y2
      '{
          idx: '{
              id: '{x: 5, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021006000,
          end_addr: 48'h000021007000
      },  // ClusterConfigX1Y2
      '{
          idx: '{
              id: '{x: 5, y: 1, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020140000,
          end_addr: 48'h000020180000
      },  // ClusterX1Y1
      '{
          idx: '{
              id: '{x: 5, y: 1, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021005000,
          end_addr: 48'h000021006000
      },  // ClusterConfigX1Y1
      '{
          idx: '{
              id: '{x: 5, y: 0, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020100000,
          end_addr: 48'h000020140000
      },  // ClusterX1Y0
      '{
          idx: '{
              id: '{x: 5, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021004000,
          end_addr: 48'h000021005000
      },  // ClusterConfigX1Y0
      '{
          idx: '{
              id: '{x: 4, y: 3, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h0000200c0000,
          end_addr: 48'h000020100000
      },  // ClusterX0Y3
      '{
          idx: '{
              id: '{x: 4, y: 3, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021003000,
          end_addr: 48'h000021004000
      },  // ClusterConfigX0Y3
      '{
          idx: '{
              id: '{x: 4, y: 2, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020080000,
          end_addr: 48'h0000200c0000
      },  // ClusterX0Y2
      '{
          idx: '{
              id: '{x: 4, y: 2, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021002000,
          end_addr: 48'h000021003000
      },  // ClusterConfigX0Y2
      '{
          idx: '{
              id: '{x: 4, y: 1, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020040000,
          end_addr: 48'h000020080000
      },  // ClusterX0Y1
      '{
          idx: '{
              id: '{x: 4, y: 1, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021001000,
          end_addr: 48'h000021002000
      },  // ClusterConfigX0Y1
      '{
          idx: '{
              id: '{x: 4, y: 0, port_id: 0},
              mask_x: '{offset: 20, len: 2, base_id: 4},
              mask_y: '{offset: 18, len: 2, base_id: 0}
          },
          start_addr: 48'h000020000000,
          end_addr: 48'h000020040000
      },  // ClusterX0Y0
      '{
          idx: '{
              id: '{x: 4, y: 0, port_id: 0},
              mask_x: '{default: '0},
              mask_y: '{default: '0}
          },
          start_addr: 48'h000021000000,
          end_addr: 48'h000021001000
      }  // ClusterConfigX0Y0

  };



  localparam route_cfg_t RouteCfg = '{
      RouteAlgo: YXRoutingMirrored,
      UseIdTable: 1'b1,
      XYAddrOffsetX: 33,
      XYAddrOffsetY: 37,
      IdAddrOffset: 0,
      NumSamRules: 55,
      NumRoutes: 0,
      CollectiveCfg: '{
          OpCfg: '{
              EnNarrowMulticast: 1'b1,
              EnWideMulticast: 1'b1,
              EnLsbAnd: 1'b1,
              EnFpAdd: 1'b1,
              EnFpMul: 1'b1,
              EnFpMin: 1'b1,
              EnFpMax: 1'b1,
              EnIntAdd: 1'b0,
              EnIntMul: 1'b0,
              EnIntMinS: 1'b0,
              EnIntMinU: 1'b0,
              EnIntMaxS: 1'b0,
              EnIntMaxU: 1'b0
          },
          NarrRedCfg: RedDefaultCfg,
          WideRedCfg: '{RdPipelineDepth: 5, CutOffloadIntf: 1'b1}
      }
  };

  localparam wide_rw_decouple_e WideRwDecouple = Phys;
  localparam vc_impl_e VcImpl = VcNaive;


  typedef logic [47:0] collective_axi_narrow_in_addr_t;
  typedef logic [63:0] collective_axi_narrow_in_data_t;
  typedef logic [7:0] collective_axi_narrow_in_strb_t;
  typedef logic [4:0] collective_axi_narrow_in_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
    logic [5:0]  user;
  } collective_axi_narrow_in_user_t;

  `AXI_TYPEDEF_ALL_CT(collective_axi_narrow_in, collective_axi_narrow_in_req_t,
                      collective_axi_narrow_in_rsp_t, collective_axi_narrow_in_addr_t,
                      collective_axi_narrow_in_id_t, collective_axi_narrow_in_data_t,
                      collective_axi_narrow_in_strb_t, collective_axi_narrow_in_user_t)


  typedef logic [47:0] axi_narrow_in_addr_t;
  typedef logic [63:0] axi_narrow_in_data_t;
  typedef logic [7:0] axi_narrow_in_strb_t;
  typedef logic [4:0] axi_narrow_in_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
    logic [5:0]  user;
  } axi_narrow_in_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_narrow_in, axi_narrow_in_req_t, axi_narrow_in_rsp_t, axi_narrow_in_addr_t,
                      axi_narrow_in_id_t, axi_narrow_in_data_t, axi_narrow_in_strb_t,
                      axi_narrow_in_user_t)


  typedef logic [47:0] collective_axi_narrow_out_addr_t;
  typedef logic [63:0] collective_axi_narrow_out_data_t;
  typedef logic [7:0] collective_axi_narrow_out_strb_t;
  typedef logic [1:0] collective_axi_narrow_out_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
    logic [5:0]  user;
  } collective_axi_narrow_out_user_t;

  `AXI_TYPEDEF_ALL_CT(collective_axi_narrow_out, collective_axi_narrow_out_req_t,
                      collective_axi_narrow_out_rsp_t, collective_axi_narrow_out_addr_t,
                      collective_axi_narrow_out_id_t, collective_axi_narrow_out_data_t,
                      collective_axi_narrow_out_strb_t, collective_axi_narrow_out_user_t)


  typedef logic [47:0] axi_narrow_out_addr_t;
  typedef logic [63:0] axi_narrow_out_data_t;
  typedef logic [7:0] axi_narrow_out_strb_t;
  typedef logic [1:0] axi_narrow_out_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
    logic [5:0]  user;
  } axi_narrow_out_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_narrow_out, axi_narrow_out_req_t, axi_narrow_out_rsp_t,
                      axi_narrow_out_addr_t, axi_narrow_out_id_t, axi_narrow_out_data_t,
                      axi_narrow_out_strb_t, axi_narrow_out_user_t)


  typedef logic [47:0] collective_axi_wide_in_addr_t;
  typedef logic [511:0] collective_axi_wide_in_data_t;
  typedef logic [63:0] collective_axi_wide_in_strb_t;
  typedef logic [2:0] collective_axi_wide_in_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
  } collective_axi_wide_in_user_t;

  `AXI_TYPEDEF_ALL_CT(collective_axi_wide_in, collective_axi_wide_in_req_t,
                      collective_axi_wide_in_rsp_t, collective_axi_wide_in_addr_t,
                      collective_axi_wide_in_id_t, collective_axi_wide_in_data_t,
                      collective_axi_wide_in_strb_t, collective_axi_wide_in_user_t)


  typedef logic [47:0] axi_wide_in_addr_t;
  typedef logic [511:0] axi_wide_in_data_t;
  typedef logic [63:0] axi_wide_in_strb_t;
  typedef logic [2:0] axi_wide_in_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
  } axi_wide_in_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_wide_in, axi_wide_in_req_t, axi_wide_in_rsp_t, axi_wide_in_addr_t,
                      axi_wide_in_id_t, axi_wide_in_data_t, axi_wide_in_strb_t, axi_wide_in_user_t)


  typedef logic [47:0] collective_axi_wide_out_addr_t;
  typedef logic [511:0] collective_axi_wide_out_data_t;
  typedef logic [63:0] collective_axi_wide_out_strb_t;
  typedef logic [0:0] collective_axi_wide_out_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
  } collective_axi_wide_out_user_t;

  `AXI_TYPEDEF_ALL_CT(collective_axi_wide_out, collective_axi_wide_out_req_t,
                      collective_axi_wide_out_rsp_t, collective_axi_wide_out_addr_t,
                      collective_axi_wide_out_id_t, collective_axi_wide_out_data_t,
                      collective_axi_wide_out_strb_t, collective_axi_wide_out_user_t)


  typedef logic [47:0] axi_wide_out_addr_t;
  typedef logic [511:0] axi_wide_out_data_t;
  typedef logic [63:0] axi_wide_out_strb_t;
  typedef logic [0:0] axi_wide_out_id_t;
  typedef struct packed {
    logic [47:0] collective_mask;
    logic [3:0]  collective_op;
  } axi_wide_out_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_wide_out, axi_wide_out_req_t, axi_wide_out_rsp_t, axi_wide_out_addr_t,
                      axi_wide_out_id_t, axi_wide_out_data_t, axi_wide_out_strb_t,
                      axi_wide_out_user_t)



  `FLOO_TYPEDEF_HDR_T(hdr_t, id_t, id_t, nw_ch_e, rob_idx_t, id_t, collect_op_t)
  localparam axi_cfg_t AxiCfgN = '{
      AddrWidth: 48,
      DataWidth: 64,
      InIdWidth: 5,
      OutIdWidth: 2,
      UserWidth: 58  // $bits(axi_narrow_in_user_t): collective_mask 48 + collective_op 4 + user 6
  };
  localparam axi_cfg_t AxiCfgW = '{
      AddrWidth: 48,
      DataWidth: 512,
      InIdWidth: 3,
      OutIdWidth: 1,
      UserWidth: 52  // $bits(axi_wide_in_user_t): collective_mask 48 + collective_op 4
  };
  `FLOO_TYPEDEF_NW_CHAN_ALL(axi, req, rsp, wide, axi_narrow_in, axi_wide_in, AxiCfgN, AxiCfgW,
                            hdr_t)

  `FLOO_TYPEDEF_NW_VIRT_CHAN_LINK_ALL(req, rsp, wide, req, rsp, wide, 2, 2)

  typedef logic [AxiCfgW.DataWidth-1:0] floo_wide_red_data_t;
  `FLOO_RED_TYPEDEF_REQ_RSP_LINK(wide, floo_wide_red_data_t, wide_req, wide_rsp)


endpackage
