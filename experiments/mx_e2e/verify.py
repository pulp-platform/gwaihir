#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
#
# Verification script for `mx_e2e.c` and `mx_e2e_fp16.c`. Goldens: iDMA's
# test/idma_mx_golden.h for quant/dequant, MXCore's PyGolden for the GEMM,
# its operand/result layout and the result quantization.

import contextlib
import ctypes
import io
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import snitch.util.sim.verif_utils as vu

GW_ROOT = Path(__file__).resolve().parents[2]
M, N, K = 128, 64, 64
VS, MXU, OBUFF, BLK = 32, 32, 64, 32
GUARD, CANARY = 64, 0xA5


def bender_path(dep):
    return subprocess.run(['bender', '-d', str(GW_ROOT), 'path', dep], check=True,
                          capture_output=True, text=True).stdout.strip()


sys.path.insert(0, bender_path('mxcore'))
from PyGolden import utils, fp_functions  # noqa: E402,F401 (import order breaks a cycle)
from PyGolden import mxcore_gemm_functions as mg  # noqa: E402
from PyGolden.fp9 import FP9  # noqa: E402
from PyGolden.scale import Scale  # noqa: E402

OPS = ('quant_fp32', 'quant_fp16', 'dequant_fp32', 'dequant_fp16')


def idma_golden():
    src = '#include "idma_mx_golden.h"\n' + ''.join(
        f'void {op}(void *a, void *b, void *c, uint32_t n) {{ mx_{op}(a, b, c, n); }}\n'
        for op in OPS)
    lib = Path(tempfile.mkdtemp()) / 'idma_mx_golden.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-I', f'{bender_path("idma")}/test',
                    '-x', 'c', '-', '-o', str(lib)], input=src, text=True, check=True)
    golden = ctypes.CDLL(str(lib))
    for op in OPS:
        getattr(golden, op).argtypes = [ctypes.c_void_p] * 3 + [ctypes.c_uint32]
    return golden


GOLDEN = idma_golden()


def idma_quant(src, fp16):
    n = src.nbytes // BLK // (2 if fp16 else 4)
    data, scale = np.zeros(n * BLK, np.uint8), np.zeros(n, np.uint8)
    getattr(GOLDEN, 'quant_fp16' if fp16 else 'quant_fp32')(
        src.ctypes.data, data.ctypes.data, scale.ctypes.data, n)
    return data, scale


def idma_dequant(data, scale, fp16):
    out = np.zeros(data.size * (2 if fp16 else 4), np.uint8)
    getattr(GOLDEN, 'dequant_fp16' if fp16 else 'dequant_fp32')(
        np.ascontiguousarray(data).ctypes.data, np.ascontiguousarray(scale).ctypes.data,
        out.ctypes.data, scale.size)
    return out


def pygolden(data, scale, rows):
    # Row-major MX planes to PyGolden FP9 elements and E8M0 Scale objects
    fp9 = [[FP9('FP8', f'{x:08b}0') for x in r] for r in data.reshape(rows, K)]
    sc = [[Scale(int(x) - 127) for x in r] for r in scale.reshape(rows, K // BLK)]
    return fp9, sc


def c_header_array(text, name, dtype):
    body = re.search(rf'\b{name}\[\w+\] = {{(.*?)}};', text, re.S).group(1)
    return np.array([int(v, 0) for v in body.replace(',', ' ').split()]).astype(dtype)


def mxcore_golden(a_mx, a_scale, b_mx, b_scale):
    a, sa = pygolden(a_mx, a_scale, M)
    b, sb = pygolden(b_mx, b_scale, N)
    tmp = Path(tempfile.mkdtemp())
    mg.MEMORY_EXPORT = True
    with contextlib.redirect_stdout(io.StringIO()):
        mg.mxcore_gemm(a, list(map(list, zip(*b))), sa, list(map(list, zip(*sb))),
                       hardware_vector_size=VS, vector_size=VS, num_compute_units=MXU,
                       num_out_buffers=OBUFF, BLOCK_SIZE=BLK, mem_file=tmp / 'mem.txt',
                       res_file=tmp / 'res.txt', res_mx_file=tmp / 'res_mx.txt',
                       header_path=tmp / 'data.h')
    hdr = (tmp / 'data.h').read_text()
    exp = {uid: c_header_array(hdr, sym, np.uint8) for uid, sym in (
        ('a_mx', 'vector_a'), ('a_scale', 'scale_a'), ('b_mx', 'vectors_b'),
        ('b_scale', 'scale_b'), ('c_mx', 'golden_result_mx'),
        ('c_scale', 'golden_scale_result_mx'))}
    exp['c_fp32'] = np.array([int(w, 16) for w in (tmp / 'res.txt').read_text().split()],
                             np.uint32).view(np.uint8)
    return exp


class Verifier(vu.Verifier):

    OUTPUT_UIDS = ['a_mx', 'a_scale', 'b_mx', 'b_scale', 'c_fp32', 'c_mx', 'c_scale', 'c_deq']

    def elf(self):
        return vu.Elf(self.args.symbols_bin or self.args.snitch_bin)

    def get_actual_results(self):
        return {uid: np.frombuffer(self.raw_outputs[uid], np.uint8) for uid in self.OUTPUT_UIDS}

    def get_expected_results(self):
        elf = self.elf()
        src = {s: np.frombuffer(elf.get_raw_symbol_contents(s), np.uint8) for s in ('mx_a', 'mx_b')}
        self.fp16 = src['mx_a'].size == M * K * 2
        a_mx, a_scale = idma_quant(src['mx_a'], self.fp16)
        b_mx, b_scale = idma_quant(src['mx_b'], self.fp16)
        exp = mxcore_golden(a_mx, a_scale, b_mx, b_scale)
        exp['c_deq'] = idma_dequant(exp['c_mx'], exp['c_scale'], self.fp16)
        return exp

    def check_results(self, actual, expected):
        print(f'mx_e2e {"FP16" if self.fp16 else "FP32"}')
        body = {uid: v[GUARD:-GUARD] for uid, v in actual.items()}
        fails = 0

        def check(name, act, exp):
            bad = int(np.count_nonzero(act != exp))
            print(f'{name}: {bad}/{act.size} mismatches')
            return int(bad != 0)

        for uid, v in actual.items():
            fails += check(f'{uid} canaries', np.r_[v[:GUARD], v[-GUARD:]], CANARY)
        for uid in self.OUTPUT_UIDS:
            fails += check(uid, body[uid], expected[uid])
        # iDMA dequant of the planes MXCore actually wrote
        fails += check('c_deq of the MXCore planes', body['c_deq'],
                       idma_dequant(body['c_mx'], body['c_scale'], self.fp16))
        return int(fails != 0)


if __name__ == '__main__':
    sys.exit(Verifier().main())
