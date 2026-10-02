#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate the H-tile RDL from the normal Snitch cluster configuration.

The H tile is integrated homogeneously as another Snitch cluster tile.  The RTL
and runtime therefore use the normal Snitch generated collateral.  Only the RDL
addrmap gets a distinct name so the top-level address map can expose a separate
`htile` field.
"""

import argparse
import subprocess
from pathlib import Path

def replace_once(text: str, old: str, new: str, source: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected exactly one occurrence of {old!r} in {source}, found {count}"
        )
    return text.replace(old, new, 1)


def run_cluster_gen(cluster_gen: Path, cfg: Path, template: Path, out: Path) -> None:
    subprocess.run(
        [
            str(cluster_gen),
            "-c",
            str(cfg),
            "-o",
            str(out),
            "--template",
            str(template),
        ],
        check=True,
    )


def patch_rdl(rdl: Path) -> None:
    text = rdl.read_text()
    text = replace_once(text, "`ifndef __SNITCH_CLUSTER_RDL__", "`ifndef __HTILE_RDL__", rdl)
    text = replace_once(text, "`define __SNITCH_CLUSTER_RDL__", "`define __HTILE_RDL__", rdl)
    text = replace_once(text, "addrmap snitch_cluster {", "addrmap htile {", rdl)
    text = replace_once(text, "`endif // __SNITCH_CLUSTER_RDL__", "`endif // __HTILE_RDL__", rdl)
    rdl.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cfg", required=True, type=Path)
    parser.add_argument("--sn-root", required=True, type=Path)
    parser.add_argument("--cluster-gen", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()

    snitch_src = args.sn_root / "hw" / "snitch_cluster" / "src"
    rdl_tpl = snitch_src / "snitch_cluster.rdl.tpl"

    args.out_dir.mkdir(parents=True, exist_ok=True)

    rdl_out = args.out_dir / "htile.rdl"

    run_cluster_gen(args.cluster_gen, args.cfg, rdl_tpl, rdl_out)
    patch_rdl(rdl_out)


if __name__ == "__main__":
    main()
