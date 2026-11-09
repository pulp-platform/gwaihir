#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Data for `spatz_softmax`: random attention scores S [heads][tokens][tokens] in BF16, and one
# PACE table that holds exp and 1/x.

import sys

import numpy as np
import snitch.util.sim.data_utils as du

PACE_PARTS = 16  # pace_parts in cfg/snitch_cluster.json.mako
EXP_PARTS = 13  # on [-10, 0]
INV_PARTS = PACE_PARTS - 1 - EXP_PARTS  # on [1, 2)
PACE_TABLE_WORDS = 80  # 65 words, padded to 64 B lines


def bf16_bits(x):
    """Rounds to the nearest BF16 (ties to even) and returns the bit patterns."""
    u = np.asarray(x, np.float32).view(np.uint32).astype(np.uint64)
    return (((u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF).astype(np.uint16)


def bf16_to_float(bits):
    return (np.asarray(bits).astype(np.uint32) << 16).view(np.float32).astype(np.float64)


def bf16_round(x):
    return bf16_to_float(bf16_bits(x))


def fit_line(func, lo, hi):
    """Least-squares line on Chebyshev nodes of [lo, hi]. Returns c1 (offset), c2 (slope)."""
    t = np.cos(np.pi * (np.arange(64) + 0.5) / 64)
    xs = (lo + hi) / 2 + (hi - lo) / 2 * t
    return np.polyfit(xs, func(xs), 1)[::-1]


def bst_order(bounds):
    """The sorted bounds in the level order of a balanced search tree, as PACE stores them."""
    out = [None] * len(bounds)

    def fill(lo, hi, idx):
        if lo <= hi:
            mid = (lo + hi) // 2
            out[idx] = bounds[mid]
            fill(lo, mid - 1, 2 * idx + 1)
            fill(mid + 1, hi, 2 * idx + 2)

    fill(0, len(bounds) - 1, 0)
    return out


def compare_bits(x):
    """A BF16 value in the 32-bit layout of the PACE comparator: sign, exponent, then the
    7 mantissa bits in the low bits."""
    b = int(bf16_bits(x))
    return ((b >> 15) << 31) | (((b >> 7) & 0xFF) << 23) | (b & 0x7F)


def pace_table():
    """One table of lines (PACE degree 1) for exp and 1/x.

    Part 0 gives exp(x) = 0 for x <= -10. Parts 1 to EXP_PARTS hold exp on (-10, 0], denser near 0
    where exp is largest. vpace.inv reduces its input to [1, 2), and the last INV_PARTS parts hold
    1/x there. At degree 1, PACE reads the slope from the c2 slot and the offset from the c1 slot.
    The bound 0.5 separates the two functions.
    """
    k = np.arange(EXP_PARTS + 1)
    exp_bounds = bf16_round(-10.0 * (1 - k / EXP_PARTS) ** 1.65)
    inv_bounds = bf16_round(np.linspace(1.0, 2.0, INV_PARTS + 1))
    coeffs = np.zeros((PACE_PARTS, 3))
    for i in range(EXP_PARTS):
        coeffs[1 + i, 1:] = fit_line(np.exp, exp_bounds[i], exp_bounds[i + 1])
    for i in range(INV_PARTS):
        coeffs[1 + EXP_PARTS + i, 1:] = fit_line(lambda x: 1 / x, inv_bounds[i],
                                                 inv_bounds[i + 1])
    bounds = list(exp_bounds[:-1]) + [0.5] + list(inv_bounds[1:-1])

    # Layout: c2[16], c1[16], c0[16], 15 bounds, eps, eps_const. vpace.inv returns eps_const
    # below eps.
    words = [int(bf16_bits(coeffs[part, deg])) for deg in (2, 1, 0) for part in range(PACE_PARTS)]
    words += [compare_bits(b) for b in bst_order(bounds)]
    words += [compare_bits(2.0**-60), int(bf16_bits(0.0))]
    words += [0] * (PACE_TABLE_WORDS - len(words))
    return np.array(words, np.uint32)


class SoftmaxDataGen(du.DataGen):

    def emit_header(self, **kwargs):
        heads, tokens = kwargs['heads'], kwargs['tokens']
        rng = np.random.default_rng(kwargs['seed'])
        # With a standard deviation of 3, x - max(x) spans the range of the exp table.
        s = bf16_bits(rng.normal(0.0, 3.0, heads * tokens * tokens))
        # The fast ELF preload needs section lengths in multiples of 4 B: pad to 64 B.
        padded = (s.size + 31) // 32 * 32
        s = np.pad(s, (0, padded - s.size))

        header = [super().emit_header()]
        header += [f'#define HEADS {heads}', f'#define TOKENS {tokens}']
        header += [du.format_scalar_definition('extern const uint32_t', 'heads', heads)]
        header += [du.format_scalar_definition('extern const uint32_t', 'tokens', tokens)]
        header += [du.format_array_definition('uint16_t', 's', s, alignment=64,
                                              section=kwargs['section'])]
        header += [du.format_array_declaration('uint16_t', 'p', [padded], alignment=64,
                                               section='.dram')]
        header += [du.format_array_definition('uint32_t', 'pace_table', pace_table(),
                                              alignment=64)]
        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(SoftmaxDataGen().main())
