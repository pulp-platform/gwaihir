#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Verification script for `reduction_bf16.c`

import sys
import struct
import snitch.util.sim.verif_utils as vu


def bf16_to_float(x):
    return struct.unpack('<f', struct.pack('<I', int(x) << 16))[0]


class Verifier(vu.Verifier):

    OUTPUT_UIDS = ['output']

    def get_actual_results(self):
        raw = self.get_output_from_symbol(self.OUTPUT_UIDS[0], 'uint16_t')
        return [bf16_to_float(x) for x in raw]

    def get_expected_results(self):
        length = int(self.get_input_from_symbol('length', 'uint32_t')[0])
        n_clusters = int(self.get_input_from_symbol('n_clusters', 'uint32_t')[0])
        return [(i % 8) * n_clusters + sum(range(n_clusters)) for i in range(length)]

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(Verifier().main())
