#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Jayanth Jonnalagadda <jjonnalagadd@iis.ee.ethz.ch>
#
# Verification script for `mxcore_multi.c`. Compares the concatenated,
# per-cluster result_mx/scale_result_mx arrays (one 128x128x128 tile per
# cluster, all clusters sharing the same L2-resident symbols) against the
# concatenated golden arrays byte-for-byte.

import sys
import numpy as np
import snitch.util.sim.verif_utils as vu


class Verifier(vu.Verifier):

    OUTPUT_UIDS = ['result_mx', 'scale_result_mx']

    def __init__(self):
        super().__init__()
        self.elf = vu.Elf(self.args.symbols_bin) if self.args.symbols_bin else vu.Elf(self.args.snitch_bin)
        self.OUTPUT_UIDS = [uid for uid in self.OUTPUT_UIDS if self.elf.symtab.get_symbol_by_name(uid)]

    def get_actual_results(self):
        return np.concatenate([np.frombuffer(self.raw_outputs[uid], dtype=np.uint8) for uid in self.OUTPUT_UIDS])

    def get_expected_results(self):
        return np.concatenate([np.frombuffer(self.elf.get_raw_symbol_contents(f'golden_{uid}'), dtype=np.uint8)
                               for uid in self.OUTPUT_UIDS])

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
