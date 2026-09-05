#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Luca Colagrande <colluca@iis.ee.ethz.ch>

from copy import deepcopy
import matplotlib.pyplot as plt
import networkx as nx
import numpy as np
import os
import random
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), "../../../../../util/"))
import snitch.util.sim.data_utils as du # noqa: E402
from data_utils import format_scalar_definition, format_array_definition, \
                       format_array_declaration, DataGen, from_bits  # noqa: E402


random.seed(42)

# AXI splits bursts crossing 4KB address boundaries. To minimize
# the occurrence of these splits the data should be aligned to 4KB
BURST_ALIGNMENT = 4096


class BFSDataGen(du.DataGen):

    def parser(self):
        p = super().parser()
        p.add_argument(
            '--no-gui',
            action='store_true',
            help='Run without visualization')
        return p

    def golden_model(self, graph, frontier, dist):
        new_frontier = []
        new_dist = deepcopy(dist)
        for node in graph.nodes:
            if node not in frontier:
                neighbors = list(graph.neighbors(node))
                neighbors_in_frontier = [n for n in neighbors if n in frontier]
                if neighbors_in_frontier:
                    new_frontier.append(node)
                    new_dist[node] = new_dist[neighbors_in_frontier[0]] + 1
        return new_frontier, new_dist

    def to_csr(self, graph):
        adjacencies = []
        offsets = [0]
        for node in graph.nodes:
            neighbors = list(graph.neighbors(node))
            adjacencies.extend(neighbors)
            offsets.append(len(adjacencies))
        return offsets, adjacencies

    def from_csr(self, offsets, adjacencies):
        G = nx.Graph()
        num_nodes = len(offsets) - 1
        for i in range(num_nodes):
            start, end = offsets[i], offsets[i + 1]
            neighbors = adjacencies[start:end]
            if neighbors:
                for neighbor in neighbors:
                    G.add_edge(i, neighbor)
            else:
                G.add_node(i)
        return G

    def validate_config(self, **kwargs):
        n_cores_per_cluster = 8
        assert kwargs['num_vertices'] % n_cores_per_cluster == 0, \
            'Number of vertices must be an integer multiple of the number of cores per cluster'
        # TODO: we have to also assert that there are at least 32 vertices per cluster
        # otherwise clusters work on the same 32-bit chunk of the frontier

    def validate_data(self, graph):
        # Calculate graph size
        graph_size = 0
        for node in graph.nodes:
            graph_size += (len(list(graph.neighbors(node))) + 1) * 4

        # Calculate total TCDM occupation
        frontier_size = len(graph.nodes) / 8
        dist_size = 4 * len(graph.nodes)
        total_size = 2 * frontier_size + 2 * dist_size + graph_size
        du.validate_tcdm_footprint(total_size)

    def visualize_bfs_step(self, graph, old_frontier, new_frontier, dist, title=''):
        pos = nx.spring_layout(graph, seed=42)
        colors = ['royalblue'] * len(graph.nodes)
        for i, node in enumerate(graph.nodes):
            if node in old_frontier:
                colors[i] = 'red'
            elif node in new_frontier:
                colors[i] = 'green'
        labels = {n: f'{n}:{d}' for n, d in zip(graph.nodes, dist)}
        nx.draw(graph, pos=pos, node_color=colors, node_size=800, with_labels=True, labels=labels)
        plt.gcf().suptitle(title)
        plt.show()

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        # Validate configuration parameters
        self.validate_config(**kwargs)

        # Generate graph
        graph = nx.gnm_random_graph(kwargs['num_vertices'], kwargs['num_edges'], seed=42)

        # Validate generated graph
        self.validate_data(graph)

        # Generate frontier
        frontier_size = int(kwargs['frontier_fraction'] * kwargs['num_vertices'])
        frontier = random.sample(range(kwargs['num_vertices']), frontier_size)
        dist = [0 if i in frontier else -1 for i in range(kwargs['num_vertices'])]

        # Calculate new frontier and distances by performing one BFS iteration
        new_frontier, new_dist = self.golden_model(graph, frontier, dist)

        # Visualize BFS step
        #if not self.args.no_gui:
        self.visualize_bfs_step(graph, frontier, new_frontier, new_dist)

        # Convert data to C format
        frontier = from_bits([1 if i in frontier else 0 for i in range(kwargs['num_vertices'])])
        offsets, adjacencies = self.to_csr(graph)
        dist, frontier, offsets, adjacencies = map(
            np.array, [dist, frontier, offsets, adjacencies])

        # Format header
        header += [du.format_scalar_definition('uint32_t', 'num_vertices', kwargs['num_vertices'])]
        header += [du.format_array_definition('int32_t', 'dist', dist, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]
        header += [du.format_array_definition('uint32_t', 'frontier', frontier, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]
        header += [du.format_array_definition('uint32_t', 'offsets', offsets, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]
        header += [du.format_array_definition('uint32_t', 'adjacencies', adjacencies, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]
        header += [du.format_array_declaration('int32_t', 'out_dist', dist.shape, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]
        header += [du.format_array_declaration('uint32_t', 'out_frontier', frontier.shape, alignment=BURST_ALIGNMENT,
                   section=kwargs['section'])]

        header = '\n\n'.join(header)

        return header


if __name__ == '__main__':
    BFSDataGen().main()
