#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Verification script for `datamover.c`

import itertools
import sys
import numpy as np
import snitch.util.sim.verif_utils as vu

# The V block transposes of `datamover.c`.
V_BLOCKS = ((32, 16), (32, 32), (64, 32))
V_GUARD = 64
V_FILL = 0xa5


class Verifier(vu.Verifier):

    def __init__(self):
        super().__init__()
        self.elf = vu.Elf(self.args.symbols_bin or self.args.snitch_bin)
        # Pairs of (L2 output, golden), found from the outputs of `datamover.c`.
        self.pairs = []
        for i in itertools.count():
            if not self.elf.symtab.get_symbol_by_name(f'task{i}_result'):
                break
            self.pairs.append((f'task{i}_result', f'task{i}_golden_out'))
        if not self.pairs:
            raise ValueError('no task0 output symbol in the ELF')
        self.OUTPUT_UIDS = [out for out, _ in self.pairs]
        self.OUTPUT_UIDS += [f'v_result_{m}x{n}' for m, n in V_BLOCKS]

    def get_actual_results(self):
        return np.frombuffer(b''.join(self.raw_outputs[uid] for uid in self.OUTPUT_UIDS),
                             dtype=np.uint8)

    def get_expected_results(self):
        data = np.frombuffer(self.elf.get_raw_symbol_contents('task0_golden_in'), dtype=np.uint8)
        guard = np.full(V_GUARD, V_FILL, dtype=np.uint8)
        v = [np.concatenate([guard, data[:m * n].reshape(m, n).T.ravel(), guard])
             for m, n in V_BLOCKS]
        golden = b''.join(self.elf.get_raw_symbol_contents(gold) for _, gold in self.pairs)
        return np.concatenate([np.frombuffer(golden, dtype=np.uint8)] + v)

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
