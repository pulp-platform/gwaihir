#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
#
# Verification script for `mx_e2e.c`

import sys

import numpy as np
import snitch.util.sim.verif_utils as vu

M, N, K = 128, 64, 64
MT, NT, KT = M // 64, N // 32, K // 32
E5M2_EMAX = 15


def mx_quant(blocks):
    # OCP E8M0 scale, E5M2 elements; inputs are exact by construction
    amax = np.abs(blocks).max(axis=1)
    _, e = np.frexp(amax)
    sexp = np.clip(np.where(amax == 0, -127, e - 1 - E5M2_EMAX), -127, 127)
    q = blocks / np.exp2(sexp)[:, None]
    h = q.astype(np.float16)
    assert np.array_equal(h.astype(np.float64), q)
    bits = h.view(np.uint16)
    assert not np.any(bits & 0xFF)
    return (bits >> 8).astype(np.uint8), (sexp + 127).astype(np.uint8)


def e5m2_rne(x):
    # Single rounding FP32 -> E5M2 via the exact FP64 -> FP16 bit pattern
    b = np.asarray(x, np.float32).astype(np.float64)
    out = np.zeros(b.shape, np.uint8)
    for i, v in np.ndenumerate(b):
        cand = np.arange(256, dtype=np.uint16) << 8
        vals = cand.view(np.float16).astype(np.float64)
        ok = np.isfinite(vals) & (np.abs(vals) <= 57344.0)
        with np.errstate(invalid='ignore'):
            d = np.where(ok, np.abs(vals - v), np.inf)
        best = np.flatnonzero(d == d.min())
        out[i] = best[np.argmin(best & 1)] if len(best) > 1 else best[0]
    return out


def e5m2_to_f64(b):
    return (b.astype(np.uint16) << 8).view(np.float16).astype(np.float64)


def tiles(x, rows, cols):
    # [R][K] -> [rt][kt][r][32]
    r, k = x.shape
    return x.reshape(r // rows, rows, k // cols, cols).transpose(0, 2, 1, 3)


class Verifier(vu.Verifier):

    OUTPUT_UIDS = ['a_mx', 'a_scale', 'b_mx', 'b_scale', 'c_fp32', 'c_mx', 'c_scale', 'c_deq']

    def get_actual_results(self):
        fp32 = ('c_fp32', 'c_deq')
        return {uid: np.frombuffer(self.raw_outputs[uid], np.float32 if uid in fp32 else np.uint8)
                for uid in self.OUTPUT_UIDS}

    def get_expected_results(self):
        a = np.asarray(self.get_input_from_symbol('mx_a', 'float'), np.float64).reshape(M, K)
        b = np.asarray(self.get_input_from_symbol('mx_b', 'float'), np.float64).reshape(N, K)
        exp = {}
        for name, x, rows in (('a', a, 64), ('b', b, 32)):
            data, scale = mx_quant(tiles(x, rows, 32).reshape(-1, 32))
            exp[f'{name}_mx'], exp[f'{name}_scale'] = data.flatten(), scale
        c = a @ b.T
        # MXCore result order: [mt][nt][r][32]
        ct = tiles(c, 64, 32).reshape(-1, 32)
        exp['c_fp32'] = ct.flatten()
        amax = np.abs(ct).max(axis=1)
        _, e = np.frexp(amax)
        sexp = np.clip(e - 1 - E5M2_EMAX, -127, 127)
        cq = e5m2_rne(ct / np.exp2(sexp)[:, None])
        exp['c_mx'] = cq.flatten()
        exp['c_scale'] = (sexp + 127).astype(np.uint8)
        exp['c_deq'] = (e5m2_to_f64(cq) * np.exp2(sexp)[:, None]).flatten()
        return exp

    def check_results(self, actual, expected):
        fails = 0
        for uid in self.OUTPUT_UIDS:
            bad = int(np.count_nonzero(actual[uid] != expected[uid]))
            print(f'{uid}: {bad}/{actual[uid].size} mismatches')
            fails += bad != 0
        return int(fails != 0)


if __name__ == '__main__':
    sys.exit(Verifier().main())
