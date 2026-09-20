// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

// The host initializes the Cheshire UART before offloading (simple_offload.c).
// Only one core should print at a time; this backend does not serialize cores.
void _putchar(char character) {
    volatile uint8_t *uart =
        (volatile uint8_t *)GW_CHESHIRE_INTERNAL_CHESHIRE_UART_BASE_ADDR;
    // 16550 registers are spaced four bytes apart. Wait for THR empty.
    while (!(uart[5 * 4] & (1u << 5))) {
    }
    uart[0] = (uint8_t)character;
}
