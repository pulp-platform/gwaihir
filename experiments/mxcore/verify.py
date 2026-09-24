#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Jayanth Jonnalagadda <jjonnalagadd@iis.ee.ethz.ch>
#
# Verification script for `mxcore.c`

import sys
import numpy as np
import snitch.util.sim.verif_utils as vu


class Verifier(vu.Verifier):

    OUTPUT_UIDS = ['result_mx', 'scale_result_mx']

    def get_actual_results(self):
        result = np.frombuffer(self.raw_outputs['result_mx'], dtype=np.uint8)
        scale_result = np.frombuffer(self.raw_outputs['scale_result_mx'], dtype=np.uint8)
        return np.concatenate([result, scale_result])

    def get_expected_results(self):
        elf = vu.Elf(self.args.symbols_bin) if self.args.symbols_bin else vu.Elf(self.args.snitch_bin)
        golden = np.frombuffer(elf.get_raw_symbol_contents('golden_result_mx'), dtype=np.uint8)
        golden_scale = np.frombuffer(elf.get_raw_symbol_contents('golden_scale_result_mx'), dtype=np.uint8)
        return np.concatenate([golden, golden_scale])

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
