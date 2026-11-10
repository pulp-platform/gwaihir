#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Verification script for `spatz_softmax`: compares the BF16 output with a numpy softmax that
# rounds at the same points as the kernel, with exact exp and 1/x.

import sys

import numpy as np
from snitch.util.sim.verif_utils import Verifier

from datagen import bf16_round, bf16_to_float

# The PACE exp and the PACE 1/x with one Newton step give a model error of 7.8e-3 at most over
# 20 seeds.
ATOL = 1.5e-2


def softmax_reference(x):
    e = bf16_round(np.exp(bf16_round(x - x.max(axis=1, keepdims=True))))
    s = e.sum(axis=1, dtype=np.float32)
    r = bf16_round(1 / bf16_round(s))
    return bf16_round(e * r[:, None])


class SoftmaxVerifier(Verifier):

    OUTPUT_UIDS = ['p', 'cycles']

    def __init__(self):
        super().__init__()
        heads = int(self.get_input_from_symbol('heads', 'uint32_t')[0])
        self.cols = int(self.get_input_from_symbol('tokens', 'uint32_t')[0])
        self.rows = heads * self.cols

    def get_actual_results(self):
        p = self.get_output_from_symbol('p', 'uint16_t')[:self.rows * self.cols]
        return bf16_to_float(p).reshape(self.rows, self.cols)

    def get_expected_results(self):
        s = self.get_input_from_symbol('s', 'uint16_t')[:self.rows * self.cols]
        return softmax_reference(bf16_to_float(s).reshape(self.rows, self.cols))

    def check_results(self, actual, expected):
        cycles = self.get_output_from_symbol('cycles', 'uint32_t')
        print(f'{self.rows} x {self.cols}: {cycles[0]} cycles, '
              f'{cycles[0] / (self.rows * self.cols):.3f} cycles/element, '
              f'{cycles[1] / self.rows:.0f} Spatz cycles/row')
        err = np.abs(actual - expected)
        bad = np.flatnonzero((err > ATOL).any(axis=1))
        sums = actual.sum(axis=1)
        print(f'max abs error {err.max():.2e} (limit {ATOL:.1e}), '
              f'row sums {sums.min():.4f} .. {sums.max():.4f}, '
              f'{bad.size} bad rows {bad[:8].tolist()}')
        return super().check_results(actual, expected, atol=ATOL)


if __name__ == "__main__":
    sys.exit(SoftmaxVerifier().main())
