#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
import sys
from pathlib import Path
from pysynthutils import LintViolations


WAIVERS = [
    # unsigned argument passed to $unsigned system function
    'WRN_1024',
    # flop enable pin is constant
    'FlopEConst',
    # operand width mismatch across arithmetic/comparison operators
    'W116',
    # input declared but not read
    'W240',
    # instance output port left unconnected
    'W287b',
    # operand width mismatch across relational operators
    'W362',
    # signal assigned multiple times in the same always block
    'W415a',
    # based number literal contains don't-care (?), sim/synth mismatch risk
    'W467',
    # shift result wider than LHS truncates bits
    'W486',
    # variable assigned but never read
    'W528'
]

# Rule waivers scoped to a file or IP (bender checkout), rather than to the whole tile.
# `pattern` is a regex matched against the full source path; an entry of the form
# `/ip-[0-9a-f]+/` matches the `ip` checkout directory for any commit hash.
TILE_FILE_WAIVERS = {
    'cheshire_tile': [
        # axi_in_req[6] is unconnected in this configuration: read but never set
        ('W123', r'cheshire_soc\.sv'),
        # axi_in_req[6] and reg_out_rsp[13] are unconnected in this configuration
        ('W287a', r'cheshire_soc\.sv'),
        # divsqrt handshake unset in scalar path (false positive)
        ('W123', r'fpnew\.pickle\.sv'),

        # initial assignment at declaration is ignored by synthesis
        ('SYNTH_89', r'/cva6-[0-9a-f]+/'),
        # hanging user instance removed during optimization (unused in this config)
        ('SYNTH_5032', r'/cheshire-[0-9a-f]+/'),
        # unreachable branch (dead case label)
        ('SYNTH_5037', r'/riscv-iommu-[0-9a-f]+/'),
        # assert statements are not synthesizable and are ignored
        ('SYNTH_5064', r'/cva6-[0-9a-f]+/'),
        ('SYNTH_5064', r'/tagger-[0-9a-f]+/'),
        # initial block is ignored for synthesis
        ('SYNTH_5143', r'/cva6-[0-9a-f]+/'),
        # unique if/case conditions are not all covered
        ('SYNTH_12605', r'/cva6-[0-9a-f]+/'),
        # property blocks are ignored for synthesis
        ('SYNTH_12611', r'/cva6-[0-9a-f]+/'),
        # asynchronous reset signal used as non-reset
        ('STARC05-1.3.1.3', r'/cva6-[0-9a-f]+/'),
        # clock signal used as a non-clock
        ('STARC05-1.4.3.4', r'/tech_cells_generic-[0-9a-f]+/'),
        # bit-width mismatch between function call argument and function input
        ('STARC05-2.1.3.1', r'/axi-[0-9a-f]+/'),
        ('STARC05-2.1.3.1', r'/axi_llc-[0-9a-f]+/'),
        ('STARC05-2.1.3.1', r'/cheshire-[0-9a-f]+/'),
        ('STARC05-2.1.3.1', r'/cva6-[0-9a-f]+/'),
        ('STARC05-2.1.3.1', r'cheshire_tile\.sv'),
        # logical operator used where a bit-wise operator is intended
        ('STARC05-2.1.4.5', r'/axi_llc-[0-9a-f]+/'),
        ('STARC05-2.1.4.5', r'/axi_riscv_atomics-[0-9a-f]+/'),
        ('STARC05-2.1.4.5', r'/cva6-[0-9a-f]+/'),
        # conditional expression does not evaluate to a scalar
        ('STARC05-2.1.5.3', r'/axi_llc-[0-9a-f]+/'),
        ('STARC05-2.1.5.3', r'/axi_riscv_atomics-[0-9a-f]+/'),
        ('STARC05-2.1.5.3', r'/cva6-[0-9a-f]+/'),
        # logical negation used on a vector
        ('STARC05-2.10.2.3', r'/axi_llc-[0-9a-f]+/'),
        ('STARC05-2.10.2.3', r'/cva6-[0-9a-f]+/'),
        # operand bit-width mismatch for logical operator
        ('STARC05-2.10.3.2a', r'/axi_riscv_atomics-[0-9a-f]+/'),
        ('STARC05-2.10.3.2a', r'/cva6-[0-9a-f]+/'),
        # flipflop assigned over the same signal
        ('STARC05-2.2.3.3', r'/cva6-[0-9a-f]+/'),
        # multi-bit expression where a one-bit expression is expected
        ('W224', r'/axi_llc-[0-9a-f]+/'),
        ('W224', r'/axi_riscv_atomics-[0-9a-f]+/'),
        ('W224', r'/cva6-[0-9a-f]+/'),
        # case label width does not match selector width
        ('W263', r'/clic-[0-9a-f]+/'),
        ('W263', r'/riscv-iommu-[0-9a-f]+/'),
        # bit select on an integer variable
        ('W215', r'/cva6-[0-9a-f]+/'),
        ('W215', r'/riscv-iommu-[0-9a-f]+/'),
        # loop index is not of type integer
        ('W480', r'/cva6-[0-9a-f]+/'),
        # parameter width does not match the assigned value
        ('ParamWidthMismatch-ML', r'/clic-[0-9a-f]+/'),
        ('ParamWidthMismatch-ML', r'/cva6-[0-9a-f]+/'),
        # parentheses around a reduction operator
        ('WRN_61', r'/cva6-[0-9a-f]+/'),
        # function sets a module-level variable (next-state convention)
        ('W424', r'/axi_llc-[0-9a-f]+/'),
        # design unit has an empty definition
        ('WarnAnalyzeBBox', r'/common_cells-[0-9a-f]+/'),
        # possibly unsynthesizable loop in a function
        ('W481a', r'/opentitan_peripherals-[0-9a-f]+/'),
        # blocking assignment in a clock-generation flip-flop (intentional)
        ('W336', r'/serial_link-[0-9a-f]+/'),
    ],
    'cluster_tile': [
        # initial assignment at declaration is ignored by synthesis
        ('SYNTH_89', r'/spatz_vpu-[0-9a-f]+/'),
        # unique if/case conditions are not all covered
        ('SYNTH_12605', r'/spatz_vpu-[0-9a-f]+/'),
        # ASSERT statements are not synthesizable
        # PACE assertion in FPnew, not intended to be synthesis
        ('SYNTH_5064', r'/fpnew-[0-9a-f]+/'),
        # vector `result_valid` used as a ternary condition in the reductions (implicit OR)
        ('W224', r'spatz_vfu\.sv'),
        ('STARC05-2.1.5.3', r'spatz_vfu\.sv'),

    ],

    'mem_tile_large': [
        # bit-width mismatch between function call argument and function input
        ('STARC05-2.1.3.1',   r'/cva6-[0-9a-f]+/'),
        # logical operator used where a bit-wise operator is intended
        ('STARC05-2.1.4.5',   r'/axi_riscv_atomics-[0-9a-f]+/'),
        # conditional expression does not evaluate to a scalar
        ('STARC05-2.1.5.3',   r'/axi_riscv_atomics-[0-9a-f]+/'),
        # operand bit-width mismatch for logical operator
        ('STARC05-2.10.3.2a', r'/axi_riscv_atomics-[0-9a-f]+/'),
        # multi-bit expression where a one-bit expression is expected
        ('W224',              r'/axi_riscv_atomics-[0-9a-f]+/'),
        # clock signal used as a non-clock
        ('STARC05-1.4.3.4',   r'/tech_cells_generic-[0-9a-f]+/'),
    ],

    'mem_tile_small': [
        # bit-width mismatch between function call argument and function input
        ('STARC05-2.1.3.1',   r'/cva6-[0-9a-f]+/'),
        # logical operator used where a bit-wise operator is intended
        ('STARC05-2.1.4.5',   r'/axi_riscv_atomics-[0-9a-f]+/'),
        # conditional expression does not evaluate to a scalar
        ('STARC05-2.1.5.3',   r'/axi_riscv_atomics-[0-9a-f]+/'),
        # operand bit-width mismatch for logical operator
        ('STARC05-2.10.3.2a', r'/axi_riscv_atomics-[0-9a-f]+/'),
        # multi-bit expression where a one-bit expression is expected
        ('W224',              r'/axi_riscv_atomics-[0-9a-f]+/'),
        # clock signal used as a non-clock
        ('STARC05-1.4.3.4',   r'/tech_cells_generic-[0-9a-f]+/'),
    ],
}





TILES_DIR = Path(__file__).parent / 'build'
TOP = 'gwaihir_top'

IMPLICIT_MACROS = [
    'TARGET_FLIST',
    'TARGET_RTL',
    'TARGET_CVA6',
    'TARGET_CV64A6_RT_HPDCACHE',
    'TARGET_GW_GEN_RTL',
    'TARGET_MXCORE_HWPE',
    'TARGET_TECH_CELLS_GENERIC_INCLUDE_TC_SYNC'
]


def tile_files(tile, tiles_dir):
    """Return the set of source files reachable from the `tile` top module.

    The file lists are generated by `bender script flist-plus --top <tile>`
    (generated by `make spyglass-<tile>`), so they follow the actual module hierarchy.
    A file shared by several tiles belongs to all of them. The pseudo-tile
    `gwaihir_top` selects the files only the top level needs.
    """
    def read(name):
        with open(tiles_dir / f'{name}.f') as f:
            return {str(Path(line.strip()).resolve()) for line in f
                    if line.strip() and not line.startswith('+')}

    if tile != TOP:
        return read(tile)
    others = set().union(*(read(f.stem) for f in tiles_dir.glob('*.f') if f.stem != TOP))
    return read(TOP) - others


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', help='Path to moresimple.rpt')
    parser.add_argument('--tile', help='Only report violations in files reachable from this tile '
                                       'top module (e.g. cluster_tile), or in files only the top '
                                       f'level needs ({TOP}). Default: report everything.')
    parser.add_argument('--tiles-dir', type=Path, default=TILES_DIR,
                        help='Directory with the per-tile file lists <tile>.f')
    args = parser.parse_args()

    # Parse report for violations
    df = LintViolations(args.report).df
    print(f'Read {len(df)} violations.')

    # Ignore all info messages (Severity == Info)
    df = df[df.severity != 'Info']
    print(f'Ignore info messages. {len(df)} messages remaining.')

    # Ignore overlapping conditions in decoder's unique case statement
    # (ignore SYNTH_12604 in snitch.sv and snitch_sequencer.sv)
    # TODO(colluca): do not ignore sequencer error
    df = df[~((df.rule == 'SYNTH_12604') &
              (df.file.str.contains(r'snitch(?:_sequencer)?\.sv')))]
    print(f'Ignore SYNTH_12604 in snitch and snitch_sequencer. {len(df)} messages remaining.')

    # Ignore "read but never set" on the fields of the decoder's request port
    # (ignore W123 on decoder_req_i in spatz_decoder.sv)
    # This is a fake error, which we have verified multiple times
    df = df[~((df.rule == 'W123') &
              (df.file.str.contains(r'spatz_decoder\.sv')) &
              (df.message.str.contains(r"Variable 'decoder_req_i\.")))]
    print(f'Ignore W123 on decoder_req_i in spatz_decoder. {len(df)} messages remaining.')

    # Ignore "read but never set" on the reorder buffer IDs in the VLSU
    # (ignore W123 on sb_id_i in spatz_controller.sv)
    # This is a fake error, the field is not in use without out-of-order read.
    df = df[~((df.rule == 'W123') &
              (df.file.str.contains(r'spatz_controller\.sv')) &
              (df.message.str.contains(r"Variable 'sb_id_i'")))]
    print(f'Ignore W123 on sb_id_i in spatz_controller. {len(df)} messages remaining.')

    # Ignore "read but never set" on the fields of the fpu_sequencer
    # (ignore W123 on issue_req_i in spatz_fpu_sequencer.sv)
    # This is a fake error, which we have verified multiple times
    df = df[~((df.rule == 'W123') &
              (df.file.str.contains(r'spatz_fpu_sequencer\.sv')) &
              (df.message.str.contains(r"Variable 'issue_req_i\.")))]
    print(f'Ignore W123 on issue_req_i in spatz_fpu_sequencer. {len(df)} messages remaining.')

    # Ignore "read but never set" on the fields of the fpu_sequencer
    # (ignore W123 on issue_req_i in spatz_fpu_sequencer.sv)
    # This is a fake error, which we have verified multiple times
    df = df[~((df.rule == 'W123') &
              (df.file.str.contains(r'spatz_fpu_sequencer\.sv')) &
              (df.message.str.contains(r"Variable 'issue_req_i\.")))]
    print(f'Ignore W123 on issue_req_i in spatz_fpu_sequencer. {len(df)} messages remaining.')

    # Ignore the width mismatch between the case labels and the selector in the FlooNoC reduction
    # arbiter. The labels are the (narrower) reserved opcodes: SystemVerilog zero-extends them to
    # the selector width, so the comparison is correct.
    df = df[~((df.rule == 'W263') &
              (df.file.str.contains(r'floo_reduction_arbiter\.sv')))]
    print(f'Ignore W263 in floo_reduction_arbiter. {len(df)} messages remaining.')

    # Ignore the width and enum type findings in the NoC reduction -> DCA decoder. Its enums use the
    # default 32-bit base type and are compared with, or assigned from, the narrower fields of
    # `dca_op_t`. SystemVerilog zero-extends them, so the decoding is correct.
    DCA_RULES = ['W263', 'STARC05-2.1.3.1', 'WRN_1459']
    df = df[~(df.rule.isin(DCA_RULES) & df.file.str.contains(r'floo_dca_decode\.sv'))]
    print(f'Ignore {", ".join(DCA_RULES)} in floo_dca_decode. {len(df)} messages remaining.')

    # Ignore everything in the deprecated common_cells wrappers (src/deprecated/*). They are thin
    # compatibility shims for the old module names and are not used by FlooNoC.
    df = df[~df.file.str.contains(r'common_cells[^/]*/src/deprecated/')]
    print(f'Ignore common_cells/src/deprecated. {len(df)} messages remaining.')

    # In hwpe-ctrl/rtl/deprecated/hwpe_ctrl_regfile.sv:314, the int unsigned EXT_IN_REGGED parameter
    # is passed as ~EXT_IN_REGGED to an if() condition: A logical NOT (!) is expected instead of bitwise
    # NOT (~). This anyway, is harmless for MXCore and can be waived rather than fixing it upstream,
    # since hwpe-ctrl is used outside MXCore too.
    df = df[~((df.rule == 'W224') &
              (df.message.str.contains('EXT_IN_REGGED')))]
    print(f'Ignore W224 for EXT_IN_REGGED in hwpe-ctrl. {len(df)} messages remaining.')

    # In hwpe-ctrl/rtl/deprecated/hwpe_ctrl_slave.sv:266, ignore the undriven regfile_flags.is_working
    # signal. This is a dead field and genuinely unused, never assigned and never read.
    df = df[~((df.rule == 'W287a') &
              (df.file.str.contains(r'hwpe_ctrl_slave\.sv')) &
              (df.message.str.contains('is_working')))]
    print(f'Ignore W287a for regfile_flags.is_working in hwpe_ctrl_slave. {len(df)} messages remaining.')

    # Waive unused macro warnings for macros created implicitly by bender
    df = df[~((df.rule == 'CMD_define02') &
              (df.message.str.contains('|'.join(IMPLICIT_MACROS))))]
    print(f'Waive CMD_define02 for {", ".join(IMPLICIT_MACROS)}. {len(df)} messages remaining.')

    # Waive safe to ignore rules
    df = df[~df.rule.isin(WAIVERS)]
    print(f'Waive {", ".join(WAIVERS)}. {len(df)} messages remaining.')

    # Restrict to the files owned by the requested tile
    if args.tile:
        files = tile_files(args.tile, args.tiles_dir)
        df = df[df.file.map(lambda f: str(Path(f).resolve()) in files)]
        print(f'Keep only violations in tile {args.tile}. {len(df)} messages remaining.')

    # Apply the file-scoped waivers reviewed for each tile, only to the files of that tile.
    # Without --tile, the waivers of all tiles apply.
    for tile in [args.tile] if args.tile else TILE_FILE_WAIVERS:
        files = tile_files(tile, args.tiles_dir)
        in_tile = df.file.map(lambda f: str(Path(f).resolve()) in files)
        for rule, pattern in TILE_FILE_WAIVERS.get(tile, []):
            df = df[~(in_tile.reindex(df.index) & (df.rule == rule) & df.file.str.contains(pattern))]
        print(f'Apply file waivers of tile {tile}. {len(df)} messages remaining.')

    # Fail on remaining messages
    if len(df) > 0:
        print(f'FAIL: {len(df)} violation(s) found')
        # Print remaining messages
        for _, v in df.iterrows():
            print(f'  [{v.severity}] {v.rule}  {v.file}:{v.line}  {v.message}')
        sys.exit(1)
    print('PASS')


if __name__ == '__main__':
    main()
