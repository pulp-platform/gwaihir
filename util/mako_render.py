#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
import sys
from pathlib import Path

import yaml
from mako.exceptions import RichTraceback
from mako.lookup import TemplateLookup
from mako.template import Template


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mako to YAML renderer."
    )

    parser.add_argument(
        "-t",
        "--template",
        required=True,
        help="Input Mako template file",
    )

    parser.add_argument(
        "-y",
        "--yaml",
        required=True,
        help="Input YAML file",
    )

    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output file",
    )

    args = parser.parse_args()

    template_path = Path(args.template)
    yml_path = Path(args.yaml)
    output_path = Path(args.output)

    with yml_path.open("r", encoding="utf-8") as f:
        yml = yaml.safe_load(f)

    if yml is None:
        yml = {}

    if not isinstance(yml, dict):
        raise TypeError("Top-level YAML object must be a mapping/dictionary")

    try:
        template_path = template_path.resolve()
        lookup = TemplateLookup(
            directories=[str(template_path.parent)],
            input_encoding="utf-8",
            output_encoding=None,
        )

        template = lookup.get_template(template_path.name)

        rendered = template.render(
            **yml,
            cfg=yml,
        )

    except Exception:
        traceback = RichTraceback()

        for filename, lineno, function, line in traceback.traceback:
            print(
                f"{filename}:{lineno}: in {function}: {line}",
                file=sys.stderr,
            )

        print(
            f"{traceback.error.__class__.__name__}: {traceback.error}",
            file=sys.stderr,
        )

        return 1

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as f:
        f.write(rendered)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
