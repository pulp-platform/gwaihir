// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

/**
 * @file
 * @brief Gwaihir helpers on top of the cluster DMA.
 */

/**
 * @brief Start the transposition of a row-major matrix with the DMA.
 * @details The DMA transposes one tile per transfer, a square of
 *          NE x NE elements with NE = beat bytes / element bytes. This
 *          function walks the matrix tile by tile. Each tile is its own small
 *          matrix, so the DMA masks the part that sticks out of an edge tile.
 *
 *          Memory around the matrix must be mapped: an edge tile still reads
 *          whole rows beyond the source, and writes (with a zero strobe)
 *          whole rows beyond the destination, up to the next multiple of NE.
 *
 * @param dst Destination, a row-major N x M matrix.
 * @param src Source, a row-major M x N matrix.
 * @param m Rows of the source, in elements.
 * @param n Columns of the source, in elements.
 * @param mode Element size selector; elements are 1 << mode bytes.
 * @note Wait for the transfers with `snrt_dma_wait_all()`.
 */
inline void gw_dma_start_transpose(volatile void *dst, volatile void *src,
                                   uint32_t m, uint32_t n, uint32_t mode) {
#ifdef SNRT_SUPPORTS_DMA_COMPUTE
    const uint32_t elem_bytes = 1u << mode;
    const uint32_t ne = SNRT_DMA_BYTES_PER_BEAT / elem_bytes;

    for (uint32_t col = 0; col < n; col += ne) {
        for (uint32_t row = 0; row < m; row += ne) {
            uint32_t tile_rows = (m - row < ne) ? m - row : ne;
            uint32_t tile_cols = (n - col < ne) ? n - col : ne;
            uint8_t *src_tile =
                (uint8_t *)src + ((size_t)row * n + col) * elem_bytes;
            uint8_t *dst_tile =
                (uint8_t *)dst + ((size_t)col * m + row) * elem_bytes;

            snrt_dma_enable_transpose(mode, tile_rows, tile_cols);
            // One transfer per tile row, each a full beat
            snrt_dma_start_2d(dst_tile, src_tile, SNRT_DMA_BYTES_PER_BEAT,
                              (size_t)m * elem_bytes, (size_t)n * elem_bytes,
                              ne);
        }
    }
    snrt_dma_disable_compute();
#endif
}
