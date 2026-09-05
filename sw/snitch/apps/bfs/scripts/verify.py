#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import numpy as np
import sys
import os
from pathlib import Path
from datagen import BFSDataGen

sys.path.append(os.path.join(os.path.dirname(__file__), "../../../../../util/"))
import snitch.util.sim.verif_utils as vu # noqa: E402
from data_utils import to_bits  # noqa: E402


class BFSVerifier(vu.Verifier):

    OUTPUT_UIDS = ['out_frontier', 'out_dist']

    def parser(self):
        p = super().parser()
        p.add_argument(
            '--no-gui',
            action='store_true',
            help='Run without GUI')
        return p

    def convert_frontier_to_bits(self, chunks):
        return [i for i, bit in enumerate(to_bits(chunks)) if bit == 1]

    def get_actual_results(self):
        self.actual_frontier = self.convert_frontier_to_bits(
            self.get_output_from_symbol('out_frontier', 'uint32_t'))
        self.actual_dist = self.get_output_from_symbol('out_dist', 'int32_t')
        print('Actual', self.actual_frontier, self.actual_dist)
        return np.concatenate((self.actual_frontier, self.actual_dist))

    def get_expected_results(self):
        # Get inputs from ELF
        self.old_frontier = self.convert_frontier_to_bits(
            self.get_input_from_symbol('frontier', 'uint32_t'))
        dist = self.get_input_from_symbol('dist', 'int32_t').tolist()
        offsets = self.get_input_from_symbol('offsets', 'uint32_t').tolist()
        adjacencies = self.get_input_from_symbol('adjacencies', 'uint32_t').tolist()
        print('Original', self.old_frontier, dist)

        # Reconstruct graph from CSR offsets and adjacencies
        self.graph = BFSDataGen().from_csr(offsets, adjacencies)
        # BFSDataGen().visualize_bfs_step(self.graph, self.old_frontier, [], dist, title='Expected')

        # Compute expected results
        self.expected_frontier, self.expected_dist = BFSDataGen().golden_model(self.graph, self.old_frontier, dist)
        self.expected_frontier.sort()
        # print('Expected', self.expected_frontier, self.expected_dist)
        return np.concatenate((self.expected_frontier, self.expected_dist))

    def check_results(self, *args):
        return super().check_results(*args, rtol=0)

    def main(self):
        retcode = super().main()

        # Visualize results
        if not self.args.no_gui:
            BFSDataGen().visualize_bfs_step(self.graph, self.old_frontier, self.expected_frontier, self.expected_dist, title='Expected')
            BFSDataGen().visualize_bfs_step(self.graph, self.old_frontier, self.actual_frontier, self.actual_dist, title='Actual')

        return retcode


if __name__ == "__main__":
    sys.exit(BFSVerifier().main())
