#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Patch a copied Snitch cluster RDL into the H-tile RDL.

The H tile is integrated homogeneously as another Snitch cluster tile.  The RTL
and runtime therefore use the normal Snitch generated collateral.  This script
only gives the generated RDL addrmap a distinct name so the top-level address
map can expose a separate `htile` field.
"""

import argparse
from pathlib import Path

def replace_once(text: str, old: str, new: str, source: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected exactly one occurrence of {old!r} in {source}, found {count}"
        )
    return text.replace(old, new, 1)


def patch_rdl(rdl: Path) -> None:
    text = rdl.read_text()
    text = replace_once(text, "`ifndef __SNITCH_CLUSTER_RDL__", "`ifndef __HTILE_RDL__", rdl)
    text = replace_once(text, "`define __SNITCH_CLUSTER_RDL__", "`define __HTILE_RDL__", rdl)
    text = replace_once(text, "addrmap snitch_cluster {", "addrmap htile {", rdl)
    text = replace_once(text, "`endif // __SNITCH_CLUSTER_RDL__", "`endif // __HTILE_RDL__", rdl)
    rdl.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("rdl", type=Path)
    args = parser.parse_args()

    patch_rdl(args.rdl)


if __name__ == "__main__":
    main()
