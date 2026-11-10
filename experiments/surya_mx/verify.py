#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Verification script for `surya_mx.c`

import itertools
import sys
import numpy as np
import snitch.util.sim.verif_utils as vu


class Verifier(vu.Verifier):

    def __init__(self):
        super().__init__()
        self.elf = vu.Elf(self.args.symbols_bin or self.args.snitch_bin)
        # Pairs of (L2 output, golden), found from the outputs of `surya_mx.c`. A task with a BF16
        # output has an empty scale buffer and no scale golden.
        self.pairs = []
        for i in itertools.count():
            if not self.elf.symtab.get_symbol_by_name(f'task{i}_matrix_c_out'):
                break
            self.pairs.append((f'task{i}_matrix_c_out', f'task{i}_matrix_c'))
            if self.elf.get_symbol_size(f'task{i}_mx_out_scale_buf'):
                self.pairs.append((f'task{i}_mx_out_scale_buf', f'task{i}_mx_out_scale'))
        if not self.pairs:
            raise ValueError('no task0 output symbol in the ELF')
        self.OUTPUT_UIDS = [out for out, _ in self.pairs]

    def get_actual_results(self):
        return np.frombuffer(b''.join(self.raw_outputs[out] for out, _ in self.pairs),
                             dtype=np.uint8)

    def get_expected_results(self):
        return np.frombuffer(b''.join(self.elf.get_raw_symbol_contents(gold)
                                      for _, gold in self.pairs), dtype=np.uint8)

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
