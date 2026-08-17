#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>
# Lorenzo Leone <lleone@iis.ee.ethz.ch>

import math

LPDDR4X_TRANSFER_RATE = 4267  # in MT/s
LPDDR4X_BITWIDTH = 16  # in bits
LPDDR4X_BANDWIDTH = LPDDR4X_TRANSFER_RATE * LPDDR4X_BITWIDTH / 8  # in MBps
LPDDR4X_TO_SOC_FREQ_RATIO = 1  # assuming SoC runs at same frequency as LPDDR4X (1066 MHz)
SOC_FREQ = 1066  # in MHz

PREC = 1  # in bytes
L2_BW = 64  # in bytes/cycle
L3_BW = LPDDR4X_BANDWIDTH / LPDDR4X_TO_SOC_FREQ_RATIO / SOC_FREQ  # in bytes/cycle
L1_PEAK_PERF = 1024  # 8b MAC/cycle of MXCore
L1_SIZE = 64 * 1024  # in bytes
L2_SIZE = 4 * 1024 * 1024  # in bytes
UTIL = 0.981  # median utilization from https://arxiv.org/pdf/2506.10921
MESH_SIZE = 4  # 4x4 mesh of MXCore tiles


def beats(bytes, bw):
    return math.ceil(bytes / bw)


def max_square_problem_size(size, round_multiple_of):
    n = math.floor(math.sqrt(size / (6 * PREC)))
    # Round to nearest lower multiple of `round_multiple_of`
    return (n // round_multiple_of) * round_multiple_of


def max_square_l1_problem_size():
    return max_square_problem_size(L1_SIZE, 8)


def max_square_l2_problem_size():
    return max_square_problem_size(L2_SIZE, 4)


# Time for L1 computation (one cluster)
def t_comp_l1(Mt, Nt, Kt):
    return (Mt * Nt * Kt) / (UTIL * L1_PEAK_PERF)


# Time for L2 computation (all clusters)
def t_comp_l2(Mt_l2, Nt_l2, Kt_l2, Mt_l1, Nt_l1, Kt_l1):
    Mt_l2_per_cluster = Mt_l2 / MESH_SIZE
    Nt_l2_per_cluster = Nt_l2 / MESH_SIZE
    k_tiles = math.ceil(Kt_l2 / Kt_l1)
    m_tiles = math.ceil(Mt_l2_per_cluster / Mt_l1)
    n_tiles = math.ceil(Nt_l2_per_cluster / Nt_l1)
    return k_tiles * m_tiles * n_tiles * t_comp_l1(Mt_l1, Nt_l1, Kt_l1)


def t_comm(n_masters, Mt, Nt, Kt, bw):
    return n_masters * beats((Mt * Kt + Nt * Kt) * PREC, bw)


def t_comm_l2(Mt, Nt, Kt):
    return t_comm(MESH_SIZE, Mt, Nt, Kt, L2_BW)


def t_comm_l3(Mt, Nt, Kt):
    return t_comm(1, Mt, Nt, Kt, L3_BW)


def main():
    Mt_l1 = max_square_l1_problem_size()
    print("L1 problem size:", Mt_l1)
    print("Cluster computation time:", t_comp_l1(Mt_l1, Mt_l1, Mt_l1))
    print("L2->L1 communication time:", t_comm_l2(Mt_l1, Mt_l1, Mt_l1))


if __name__ == "__main__":
    main()
