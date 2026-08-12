// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

`include "cheshire/typedef.svh"
`include "axi/typedef.svh"
`include "apb/typedef.svh"
`include "tcdm_interface/typedef.svh"

package gwaihir_pkg;

  import floo_pkg::*;
  import floo_gwaihir_noc_pkg::*;
  import cheshire_pkg::*;
  import snitch_cluster_wrapper_pkg::*;
  import ucie_slink_reg_pkg::*;


  typedef axi_narrow_in_addr_t addr_t;

  ///////////////
  //  FlooNoC  //
  ///////////////

  typedef struct packed {
    int unsigned x;
    int unsigned y;
  } mesh_dim_t;

  // This function return the MAX X and Y coordinates, regardless of empty columns.
  function automatic mesh_dim_t get_max_id();
    mesh_dim_t tile_id_max = '{x: 0, y: 0};
    mesh_dim_t tile_id_min = '{x: '1, y: '1};
    for (int i = 0; i < SamNumRules; i++) begin
      tile_id_max.x = max(tile_id_max.x, int'(Sam[i].idx.x));
      tile_id_max.y = max(tile_id_max.y, int'(Sam[i].idx.y));
    end
    return '{x: tile_id_max.x, y: tile_id_max.y};
  endfunction

  function automatic mesh_dim_t get_min_id();
    mesh_dim_t tile_id_max = '{x: 0, y: 0};
    mesh_dim_t tile_id_min = '{x: '1, y: '1};
    for (int i = 0; i < SamNumRules; i++) begin
      tile_id_min.x = min(tile_id_min.x, int'(Sam[i].idx.x));
      tile_id_min.y = min(tile_id_min.y, int'(Sam[i].idx.y));
    end
    return '{x: tile_id_min.x, y: tile_id_min.y};
  endfunction

  localparam mesh_dim_t MaxId = get_max_id();
  localparam mesh_dim_t MinId = get_min_id();
  typedef logic [MaxId.y:0][MaxId.x:0] mesh_map_t;

  localparam mesh_map_t MeshMap = get_mesh_map();

  // Generate a bitmap of the NoC mesh.
  // Non existing tiles are set to 0.
  function automatic mesh_map_t get_mesh_map();
    mesh_map_t mesh_map = '0;
    for (int i = 0; i < SamNumRules; i++) begin
      mesh_map[Sam[i].idx.y][Sam[i].idx.x] = 1'b1;
    end
    return mesh_map;
  endfunction

  function automatic mesh_dim_t get_mesh_dim();
    int unsigned column_cnt = 0;
    int unsigned row_cnt = 0;
    // Count the number of columns that have at least one tile
    for (int col = 0; col <= MaxId.x; col++) begin
      for (int row = 0; row <= MaxId.y; row++) begin
        if (MeshMap[row][col] == 1'b1) begin
          column_cnt++;
          break;
        end
      end
    end
    // Count the number of rows that have at least one tile
    for (int row = 0; row <= MaxId.y; row++) begin
      if ($countones(MeshMap[row]) > 0) begin
        row_cnt++;
      end
    end
    return '{x: column_cnt, y: row_cnt};
  endfunction

  localparam mesh_dim_t MeshDim = get_mesh_dim();
  localparam int unsigned NumTiles = MeshDim.x * MeshDim.y;
  localparam int unsigned NumClusters = NumClusterX * NumClusterY;
  localparam int unsigned NumMemTiles = 4;
  localparam int unsigned NumUcieTiles = 2;

  localparam int unsigned NumDummyTiles = NumTiles - $countones(MeshMap);


  // This function will generate a bit map indicating which columns are empty.
  // An bit set to 1 in the map indicates an empty column.
  function automatic bit [MaxId.x:0] get_empty_cols(mesh_map_t MeshMap);
    bit [MaxId.x:0] empty_cols;
    // Initialize all columns as empty
    empty_cols = '1;
    // Loop over the mesh map and set the non empty columns to 0
    for (int col = 0; col <= MaxId.x; col++) begin
      for (int row = 0; row <= MaxId.y; row++) begin
        if (MeshMap[row][col] == 1'b1) begin
          empty_cols[col] = 1'b0;
          break;
        end
      end
    end
    return empty_cols;
  endfunction

  // This function will generate a bit map indicating which columns are empty.
  // An bit set to 1 in the map indicates an empty column.
  function automatic bit [MaxId.y:0] get_empty_rows(mesh_map_t MeshMap);
    bit [MaxId.y:0] empty_rows;
    // Initialize all columns as empty
    empty_rows = '1;
    // Loop over the mesh map and set the non empty columns to 0
    for (int row = 0; row <= MaxId.y; row++) begin
      for (int col = 0; col <= MaxId.x; col++) begin
        if (MeshMap[row][col] == 1'b1) begin
          empty_rows[row] = 1'b0;
          break;
        end
      end
    end
    return empty_rows;
  endfunction

  // This function loops over the System Address Map (SAM) and shifts the X coordinate
  // of each tile to the left if there are empty columns on its left. This adjustment
  // ensures that all tiles are properly connected, regardless of any XY coordinate offset.
  // It preserves all other fields of each SAM rule.
  function automatic sam_rule_t [SamNumRules-1:0] align_x_coordinate(
      sam_rule_t [SamNumRules-1:0] sam_to_convert, bit [MaxId.x:0] empty_cols);

    sam_rule_t   [SamNumRules-1:0] ret_sam;
    int unsigned                   left_empty_cols;
    int unsigned                   current_x;

    for (int rule = 0; rule < SamNumRules; rule++) begin
      current_x       = int'(sam_to_convert[rule].idx.x);
      left_empty_cols = 0;

      // Count how many empty columns are to the left of the current tile
      for (int col = 0; col < current_x; col++) begin
        if (empty_cols[col] == 1'b1) begin
          left_empty_cols++;
        end
      end

      // Shift the X coordinate if there are empty columns to the left
      if (left_empty_cols > 0) begin
        ret_sam[rule].idx.x = sam_to_convert[rule].idx.x - left_empty_cols;
      end else begin
        ret_sam[rule].idx.x = sam_to_convert[rule].idx.x;
      end

      // Copy the remaining fields of the rule
      ret_sam[rule].idx.y       = sam_to_convert[rule].idx.y;
      ret_sam[rule].idx.port_id = sam_to_convert[rule].idx.port_id;
      ret_sam[rule].start_addr  = sam_to_convert[rule].start_addr;
      ret_sam[rule].end_addr    = sam_to_convert[rule].end_addr;
    end
    return ret_sam;
  endfunction

  // Mirrors align_x_coordinate for the Y axis: shifts each tile's Y coordinate down
  // by the number of empty rows below it, collapsing any row gaps introduced by
  // xy_id_offset in the NoC configuration.
  function automatic sam_rule_t [SamNumRules-1:0] align_y_coordinate(
      sam_rule_t [SamNumRules-1:0] sam_to_convert, bit [MaxId.y:0] empty_rows);

    sam_rule_t   [SamNumRules-1:0] ret_sam;
    int unsigned                   bottom_empty_rows;
    int unsigned                   current_y;

    for (int rule = 0; rule < SamNumRules; rule++) begin
      current_y         = int'(sam_to_convert[rule].idx.y);
      bottom_empty_rows = 0;

      // Count how many empty rows are below the current tile
      for (int row = 0; row < current_y; row++) begin
        if (empty_rows[row] == 1'b1) begin
          bottom_empty_rows++;
        end
      end

      // Shift the Y coordinate if there are empty rows below
      if (bottom_empty_rows > 0) begin
        ret_sam[rule].idx.y = sam_to_convert[rule].idx.y - bottom_empty_rows;
      end else begin
        ret_sam[rule].idx.y = sam_to_convert[rule].idx.y;
      end

      // Copy the remaining fields of the rule
      ret_sam[rule].idx.x       = sam_to_convert[rule].idx.x;
      ret_sam[rule].idx.port_id = sam_to_convert[rule].idx.port_id;
      ret_sam[rule].start_addr  = sam_to_convert[rule].start_addr;
      ret_sam[rule].end_addr    = sam_to_convert[rule].end_addr;
    end
    return ret_sam;
  endfunction

  // Applies both X and Y coordinate alignment, collapsing all gaps introduced by
  // xy_id_offset in both dimensions.
  function automatic sam_rule_t [SamNumRules-1:0] align_coordinate(
      sam_rule_t [SamNumRules-1:0] sam_to_convert, bit [MaxId.x:0] empty_cols,
      bit [MaxId.y:0] empty_rows);
    sam_rule_t [SamNumRules-1:0] ret_sam;
    ret_sam = align_x_coordinate(sam_to_convert, empty_cols);
    ret_sam = align_y_coordinate(ret_sam, empty_rows);
    return ret_sam;
  endfunction

  // To support multicast, the X and Y coordinates of the first tile in a multicast
  // group must be powers of two. For this reason, in the gwaihir system, the second
  // column begins with an offset to associate X = 4 with Cluster 0.
  //
  // This offset introduces empty columns in the System Address Map (SAM). Similarly,
  // xy_id_offset on the Y axis may introduce empty rows. Therefore, to properly connect
  // all tiles, we regenerate the SAM to reflect the physical topology, ensuring tiles
  // are aligned and connected correctly within the adjusted coordinate space.
  localparam bit [MaxId.x:0] EmptyCols = get_empty_cols(MeshMap);
  localparam bit [MaxId.y:0] EmptyRows = get_empty_rows(MeshMap);
  localparam sam_rule_t [SamNumRules-1:0] SamPhysical = align_coordinate(
      floo_gwaihir_noc_pkg::Sam, EmptyCols, EmptyRows
  );

  // Dummy tiles X, Y coordinates
  typedef id_t [NumDummyTiles-1:0] dummy_idx_t;

  // For each (col, row) in MeshMap: if the column is not fully empty (has at least one
  // occupied tile), the row is not fully empty, but this specific position is unoccupied,
  // insert a dummy tile there. Empty rows are skipped because they do not exist in the
  // physical mesh and are not counted in NumDummyTiles.
  // The returned indices are in SAM-space coordinates (matching MeshMap).
  function automatic dummy_idx_t get_dummy_idx(mesh_map_t MeshMap);
    dummy_idx_t              dummy_idx;
    int unsigned             found_tiles;
    bit          [MaxId.x:0] empty_cols;
    bit          [MaxId.y:0] empty_rows;

    found_tiles = 0;
    empty_cols  = get_empty_cols(MeshMap);
    empty_rows  = get_empty_rows(MeshMap);

    for (int col = 0; col <= MaxId.x; col++) begin
      if (!empty_cols[col]) begin
        for (int row = 0; row <= MaxId.y; row++) begin
          if (!empty_rows[row] && MeshMap[row][col] == 1'b0) begin
            dummy_idx[found_tiles] = '{x: col, y: row, port_id: 0};
            found_tiles++;
          end
        end
      end
    end
    return dummy_idx;
  endfunction

  // For each SAM-space dummy index, subtract the number of fully-empty columns to its
  // left and fully-empty rows below it. This gives the physical array index used to
  // connect floo_req/rsp signals, mirroring the transformation applied by align_coordinate.
  function automatic dummy_idx_t get_dummy_physical_idx(dummy_idx_t dummy_idx);
    dummy_idx_t  ret;
    int unsigned left_empty_cols;
    int unsigned bottom_empty_rows;
    int unsigned current_x;
    int unsigned current_y;

    for (int d = 0; d < NumDummyTiles; d++) begin
      current_x         = int'(dummy_idx[d].x);
      current_y         = int'(dummy_idx[d].y);
      left_empty_cols   = 0;
      bottom_empty_rows = 0;
      for (int col = 0; col < current_x; col++) begin
        if (EmptyCols[col] == 1'b1) left_empty_cols++;
      end
      for (int row = 0; row < current_y; row++) begin
        if (EmptyRows[row] == 1'b1) bottom_empty_rows++;
      end
      ret[d].x       = dummy_idx[d].x - left_empty_cols;
      ret[d].y       = dummy_idx[d].y - bottom_empty_rows;
      ret[d].port_id = dummy_idx[d].port_id;
    end
    return ret;
  endfunction

  localparam dummy_idx_t DummyIdx = get_dummy_idx(MeshMap);
  localparam dummy_idx_t DummyPhysicalIdx = get_dummy_physical_idx(DummyIdx);

  // Whether the connection is a tie-off or a valid neighbor
  function automatic bit is_tie_off(int x, int y, route_direction_e dir);
    return (x == 0 && dir == West) || (x == MeshDim.x-1 && dir == East) ||
           (y == 0 && dir == South) || (y == MeshDim.y-1 && dir == North);
  endfunction

  // Returns the X-coordinate of the neighbor in the given direction
  function automatic int neighbor_x(int x, route_direction_e dir);
    return (dir == West) ? x - 1 : (dir == East) ? x + 1 : x;
  endfunction

  // Returns the Y-coordinate of the neighbor in the given direction
  function automatic int neighbor_y(int y, route_direction_e dir);
    return (dir == South) ? y - 1 : (dir == North) ? y + 1 : y;
  endfunction

  // Returns the opposite direction
  function automatic route_direction_e opposite_dir(route_direction_e dir);
    return (dir == West) ? East : (dir == East) ? West : (dir == South) ? North : South;
  endfunction

  // Returns the address size of a FlooNoC endpoint
  function automatic int unsigned ep_addr_size(sam_idx_e ep);
    return Sam[ep].end_addr - Sam[ep].start_addr;
  endfunction

  /////////////////////
  //   MULTICAST     //
  /////////////////////

  function automatic floo_pkg::route_cfg_t gen_nomcast_route_cfg();
    floo_pkg::route_cfg_t ret = floo_gwaihir_noc_pkg::RouteCfg;
    // Disable multicast for non-cluster tiles
    ret.CollectiveCfg = CollectiveDefaultCfg;
    return ret;
  endfunction

  // Define no multicast RouteCfg for Memory tiles, Cheshire and FhG
  localparam floo_pkg::route_cfg_t RouteCfgNoMcast = gen_nomcast_route_cfg();

  ////////////////
  //  Cheshire  //
  ////////////////

  typedef enum bit [MaxExtRegSlvWidth-1:0] {
    CshRegExtFLL      = 0,  // FLL registers
    CshRegExtChipCtrl = 1,  // Chip-level registers
    CshRegLPDDR       = 2,  // LPDDR config
    CshRegExtNumSlv   = 3   // Number of external register slaves
  } cheshire_reg_ext_e;

  // Define function to derive configuration from Cheshire defaults.
  function automatic cheshire_pkg::cheshire_cfg_t gen_cheshire_cfg();
    cheshire_pkg::cheshire_cfg_t ret = cheshire_pkg::DefaultCfg;
    // Enable the external AXI master and slave interfaces
    ret.AxiExtNumMst   = 1;
    ret.AxiExtNumSlv   = 1;
    ret.AxiExtNumRules = 1;
    ret.RegExtNumSlv   = CshRegExtNumSlv;
    ret.RegExtNumRules = CshRegExtNumSlv;

    // TODO(fischeti): Inherit these from generated SV/RDL.
    ret.AxiExtRegionIdx[0]                   = 0;
    ret.AxiExtRegionStart[0]                 = 'h2000_0000;
    ret.AxiExtRegionEnd[0]                   = 'h6_0000_0000;
    ret.RegExtRegionIdx[CshRegExtFLL]        = CshRegExtFLL;
    ret.RegExtRegionStart[CshRegExtFLL]      = 'h1800_1000;
    ret.RegExtRegionEnd[CshRegExtFLL]        = 'h1800_2000;
    ret.RegExtRegionIdx[CshRegExtChipCtrl]   = CshRegExtChipCtrl;
    ret.RegExtRegionStart[CshRegExtChipCtrl] = 'h1800_2000;
    ret.RegExtRegionEnd[CshRegExtChipCtrl]   = 'h1800_3000;
    ret.RegExtRegionIdx[CshRegLPDDR]         = CshRegLPDDR;
    ret.RegExtRegionStart[CshRegLPDDR]       = 'h1900_0000;
    ret.RegExtRegionEnd[CshRegLPDDR]         = 'h1a00_1020;

    // TODO(fischeti): Currently, I don't see a reason to have a CIE region
    // Which is why we just set the CIE region to size 0 for now
    ret.Cva6ExtCieOnTop  = 0;
    ret.Cva6ExtCieLength = 'h0;
    ret.AddrWidth        = aw_bt'(AxiCfgN.AddrWidth);
    ret.AxiDataWidth     = dw_bt'(AxiCfgN.DataWidth);
    ret.AxiUserWidth     = dw_bt'(max(AxiCfgN.UserWidth, AxiCfgW.UserWidth));
    ret.AxiMstIdWidth    = aw_bt'(max(AxiCfgN.OutIdWidth, AxiCfgW.OutIdWidth));

    // TODO(fischeti): Check if we need external interrupts for each hart/cluster
    ret.NumExtIrqHarts = doub_bt'(NumClusters);
    // We do not need/want VGA
    ret.Vga            = 1'b0;
    // We do not need/want USB
    ret.Usb            = 1'b0;

    ret.LlcOutRegionStart = 'h8000_0000;
    ret.LlcOutRegionEnd   = 'h1_0000_0000;
    ret.SlinkRegionStart  = 'h100_0000_0000;
    ret.SlinkRegionEnd    = 'h200_0000_0000;

    // RT features
    ret.Cva6InstrTlbEntries = 16;
    ret.Cva6DataTlbEntries  = 16;  // TODO: can be increased to 32.
    ret.Cva6TlbColoring     = 1;
    ret.Cva6NumTlbColors    = 16;
    ret.Cva6LockableTlbWays = 8;
    ret.Cva6UseSharedTlb    = 0;
    ret.AxiRt               = 1;
    ret.Clic                = 1;
    ret.ClicVsclic          = 1;
    ret.ClicVsprio          = 1;
    ret.ClicNumVsctxts      = 4;
    ret.ClicPrioWidth       = 1;
    ret.LlcCachePartition   = 1;
    return ret;
  endfunction

  localparam cheshire_cfg_t CheshireCfg = gen_cheshire_cfg();

  `CHESHIRE_TYPEDEF_ALL(csh_, CheshireCfg)

  ////////////////////
  //  Cluster Tile  //
  ////////////////////

  localparam bit UseHWPE = 1'b1;
  localparam int unsigned ClusterTileSize = ep_addr_size(ClusterX0Y0SamIdx);

  typedef logic [gw_tile_regs_pkg::GW_TILE_REGS_DATA_WIDTH-1:0] tile_cfg_reg_data_t;
  typedef logic [gw_tile_regs_pkg::GW_TILE_REGS_DATA_WIDTH/8-1:0] tile_cfg_reg_strb_t;

  `AXI_LITE_TYPEDEF_ALL(tile_cfg_axi_lite, addr_t, axi_narrow_out_data_t, axi_narrow_out_strb_t)
  `AXI_LITE_TYPEDEF_ALL(tile_cfg_axi_lite_32, addr_t, tile_cfg_reg_data_t, tile_cfg_reg_strb_t)
  `APB_TYPEDEF_ALL(tile_cfg_apb, addr_t, tile_cfg_reg_data_t, tile_cfg_reg_strb_t)

  localparam int unsigned HWPECtrlAddrWidth = snitch_cluster_wrapper_pkg::AddrWidth;
  localparam int unsigned HWPECtrlDataWidth = 32;
  typedef logic [HWPECtrlAddrWidth-1:0] addr_hwpe_ctrl_t;
  typedef logic [HWPECtrlDataWidth-1:0] data_hwpe_ctrl_t;
  typedef logic [3:0] strb_hwpe_ctrl_t;

  `AXI_TYPEDEF_ALL(cluster_narrow_out_dw_conv, snitch_cluster_wrapper_pkg::addr_t,
                   snitch_cluster_wrapper_pkg::narrow_out_id_t, data_hwpe_ctrl_t, strb_hwpe_ctrl_t,
                   snitch_cluster_wrapper_pkg::user_narrow_t)

  `TCDM_TYPEDEF_ALL(hwpectrl, HWPECtrlDataWidth, HWPECtrlAddrWidth,
                    snitch_cluster_wrapper_pkg::NarrowUserWidth)

  ////////////////
  //  Mem Tile  //
  ////////////////

  // The maximum data width of the instantiated SRAMs
  localparam int unsigned SramDataWidth = 128;  // in bits
  // The number of words in the instantiated SRAMs
  localparam int unsigned SramNumWords = 1024;  // in #words

  // The number of banks required to store a wide word
  localparam int unsigned NumBanksPerWord = AxiCfgW.DataWidth / SramDataWidth;

  // The number of LSBs to address the bytes in an SRAM word
  localparam int unsigned SramByteOffsetWidth = $clog2(SramDataWidth / 8);
  // The number of bits required to select the subbank for a wide word
  localparam int unsigned SramBankSelWidth = $clog2(NumBanksPerWord);
  // The number of bits for the SRAM address
  localparam int unsigned SramAddrWidth = $clog2(SramNumWords);

  // Various offsets for the SRAM address
  localparam int unsigned SramBankSelOffset = SramByteOffsetWidth;
  localparam int unsigned SramAddrWidthOffset = SramBankSelOffset + SramBankSelWidth;
  localparam int unsigned SramMacroSelOffset = SramAddrWidthOffset + SramAddrWidth;

  // SAM enum entries per L2 mem tile (idma, config, spm).
  localparam int unsigned L2SpmIdxStride = int'(L2Spm1SamIdx) - int'(L2Spm0SamIdx);

  // Function to get the memory size.
  function automatic int unsigned mem_tile_size(int unsigned t);
    return ep_addr_size(sam_idx_e'(int'(L2Spm0SamIdx) + L2SpmIdxStride * t));
  endfunction

  // Number of SRAM macro rows of mem tile `t`.
  function automatic int unsigned mem_tile_num_bank_rows(int unsigned t);
    return (mem_tile_size(t) / (AxiCfgW.DataWidth / 8)) / SramNumWords;
  endfunction

  // Largest row count across all mem tiles, for statically sizing arrays used in tb_gwaihir_tasks.svh.
  function automatic int unsigned get_max_num_bank_rows();
    int unsigned max_rows = 0;
    for (int t = 0; t < NumMemTiles; t++) begin
      if (mem_tile_num_bank_rows(t) > max_rows) max_rows = mem_tile_num_bank_rows(t);
    end
    return max_rows;
  endfunction
  //Heterogeneous memory tile size
  localparam int unsigned MemTileSizeLarge = mem_tile_size(0);
  localparam int unsigned MemTileSizeSmall = mem_tile_size(1);

  localparam int unsigned MaxNumBankRows = get_max_num_bank_rows();
  // Macro-row select width of the largest tile. Also a safe extraction width
  // for smaller tiles: their windows are size-aligned, so the extra MSB is 0.
  localparam int unsigned MaxSramMacroSelWidth = $clog2(MaxNumBankRows);

  // DMA-related parameters
  localparam int unsigned DmaNumAxInFlight = 16;
  localparam int unsigned DmaMemSysDepth = 8;
  localparam int unsigned DmaJobFifoDepth = 2;
  localparam int unsigned DmaRAWCouplingAvail = 1;
  localparam int unsigned DmaConfEnableTwoD = 1;
  localparam bit DmaEnableCompute = 1;
  // MX quant/dequant only; the transpose engine is not elaborated in the mem tile.
  localparam idma_pkg::compute_enable_t DmaComputeOps = '{
      transpose: 1'b0,
      mxquant: 1'b1,
      mxdequant: 1'b1,
      mxfp16: 1'b1
  };

  localparam int unsigned L2SpmNumAddrRules = L2Spm1SamIdx - L2Spm0SamIdx;

  localparam axi_cfg_t AxiCfgMemJoin = floo_pkg::axi_join_cfg(AxiCfgN, AxiCfgW);

  typedef logic [AxiCfgMemJoin.OutIdWidth-1:0] mtile_nw_join_id_t;
  typedef logic [AxiCfgMemJoin.UserWidth-1:0] mtile_nw_join_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_mtile_nw_join, axi_mtile_nw_join_req_t, axi_mtile_nw_join_rsp_t,
                      axi_wide_out_addr_t, mtile_nw_join_id_t, axi_wide_out_data_t,
                      axi_wide_out_strb_t, mtile_nw_join_user_t)

  ////////////////
  // UCIe Tile  //
  ////////////////

  localparam int unsigned UcieNumAddrRules = Ucie1SamIdx - Ucie0SamIdx;
  localparam int unsigned NumBitsPerCycle = NumLanes * (1 + EnDdr);


  function automatic addr_t alias_clear_mask();
    addr_t ucie0_base, ucie1_base, canonical_base;
    ucie0_base     = addr_t'(Sam[Ucie0SamIdx].start_addr);
    ucie1_base     = addr_t'(Sam[Ucie1SamIdx].start_addr);
    canonical_base = addr_t'(Sam[ClusterX0Y0SamIdx].start_addr);
    return (ucie0_base | ucie1_base) & ~canonical_base;
  endfunction

  // Shift alias addr according to whether it's cluster or l2.
  function automatic addr_t ingress_half_shift(input addr_t addr);
    localparam addr_t TcdmExposedBase = addr_t'(Sam[ClusterX0Y0SamIdx].start_addr);
    localparam addr_t TcdmHalfShift = addr_t'((NumClusters / 2) * ClusterTileSize);
    localparam addr_t TcdmExposedEnd = TcdmExposedBase + TcdmHalfShift;
    localparam addr_t L2ExposedBase = addr_t'(Sam[L2Spm0SamIdx].start_addr);
    // Base-address gap from tile 0 to tile (NumMemTiles/2). Tiles are heterogeneous
    // but grid-aligned, so this is the exact lower->upper half shift. Replaces the
    // old (NumMemTiles/2)*MemTileSize, which assumed a uniform tile size.
    localparam addr_t L2HalfShift = addr_t'(
        Sam[sam_idx_e'(int'(L2Spm0SamIdx) + L2SpmIdxStride * (NumMemTiles / 2))].start_addr)
        - L2ExposedBase;
    localparam addr_t L2ExposedEnd = L2ExposedBase + L2HalfShift;
    if (addr >= TcdmExposedBase && addr < TcdmExposedEnd) return addr + TcdmHalfShift;
    else if (addr >= L2ExposedBase && addr < L2ExposedEnd) return addr + L2HalfShift;
    else return addr;
  endfunction

  // Translate an ingress UCIe address to its canonical form: clear the alias
  // bits, then, if `en_half_shift` is set (i.e. on the chiplet owning the
  // upper half of the exposed regions), apply the half shift.
  function automatic addr_t unalias_ucie_address(input addr_t addr, input logic en_half_shift);
    localparam addr_t AliasClearMask = alias_clear_mask();
    addr_t cleared;
    cleared = addr & ~AliasClearMask;
    return en_half_shift ? ingress_half_shift(cleared) : cleared;
  endfunction

  // Narrow config without ATOP support
  localparam axi_cfg_t AxiCfgNoAtop = '{
      AddrWidth: AxiCfgN.AddrWidth,
      DataWidth: AxiCfgN.DataWidth,
      InIdWidth: 1,
      OutIdWidth: 1,
      UserWidth: 1
  };

  // Narrow/wide join types for `floo_nw_join`
  localparam axi_cfg_t AxiCfgUcieJoin = floo_pkg::axi_join_cfg(AxiCfgNoAtop, AxiCfgW);

  typedef logic [AxiCfgUcieJoin.OutIdWidth-1:0] utile_nw_join_id_t;
  typedef logic [AxiCfgUcieJoin.UserWidth-1:0] utile_nw_join_user_t;

  `AXI_TYPEDEF_ALL_CT(axi_utile_nw_join, axi_utile_nw_join_req_t, axi_utile_nw_join_rsp_t,
                      axi_wide_in_addr_t, utile_nw_join_id_t, axi_wide_in_data_t,
                      axi_wide_in_strb_t, utile_nw_join_user_t)


  localparam int unsigned UcieCfgRegDataWidth = UCIE_SLINK_REG_DATA_WIDTH;

  typedef logic [UcieCfgRegDataWidth-1:0] ucie_cfg_reg_data_t;
  typedef logic [UcieCfgRegDataWidth/8-1:0] ucie_cfg_reg_strb_t;

  `AXI_LITE_TYPEDEF_ALL(ucie_cfg_axi_lite, addr_t, axi_narrow_out_data_t, axi_narrow_out_strb_t)
  `AXI_LITE_TYPEDEF_ALL(ucie_cfg_axi_lite_32, addr_t, ucie_cfg_reg_data_t, ucie_cfg_reg_strb_t)
  `APB_TYPEDEF_ALL(ucie_cfg_apb, addr_t, ucie_cfg_reg_data_t, ucie_cfg_reg_strb_t)

endpackage
