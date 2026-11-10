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

    def get_actual_results(self):
        return np.frombuffer(b''.join(self.raw_outputs[uid] for uid in self.OUTPUT_UIDS),
                             dtype=np.uint8)

    def get_expected_results(self):
        return np.frombuffer(b''.join(self.elf.get_raw_symbol_contents(gold)
                                      for _, gold in self.pairs), dtype=np.uint8)

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
