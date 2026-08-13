#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Sweep script: patches dma_data_width (snitch_cluster.json),
# wide data_width (gwaihir_noc.yml), MEM_TILES/DOT_PRODUCT (main.c),
# and n_tiles/n (params.json), runs the selected benchmark,
# and archives transcript per configuration into sweep_results/.
#
# Usage:  python3 run_sweep.py
#         (edit CONFIG_PAIRS below to define the sweep)

import os
import re
import shutil
import subprocess
import sys

# ---------------------------------------------------------------------------
# Configuration tuples:
#   For modes "axpy"/"opt"/"read_only":
#   (dma_data_width, wide_data_width, mem_tiles, mode, n_tiles, repetitions[, active_clusters])
#
#   For mode "gemv":
#   (dma_data_width, wide_data_width, mem_tiles, "gemv", m, n[, gemv_repetitions[, active_clusters]])
#   dma_data_width  – snitch_cluster.json  (affects RTL, triggers full rebuild)
#   wide_data_width – gwaihir_noc.yml      (affects RTL, triggers full rebuild)
#   mem_tiles       – sw/snitch/apps/axpy/src/main.c  (SW only, 1 / 4 / 8)
#   mode            – "axpy", "opt" (dot-product), "read_only", or "gemv"
#   n_tiles         – sw/snitch/apps/axpy/data/params.json
#                     n is derived as n_tiles * 2048
#   repetitions     – sw/snitch/apps/axpy/data/params.json repetitions field
#   active_clusters – optional, sw/snitch/apps/axpy/src/main.c ACTIVE_CLUSTERS
#                     defaults to 16 when omitted
#
#   For mode="gemv":
#   - mem_tiles is ignored
#   - n_tiles maps to m
#   - repetitions maps to n
#   - optional gemv_repetitions controls repeated load/compute/store iterations
#   - active_clusters patches sw/snitch/apps/gemv/src/main.c
# ---------------------------------------------------------------------------
CONFIG_PAIRS = [
    #(512,2048, 1, "read_only", 2, 8, 16),


    (512,512,1, "read_only", 2, 8, 8),
    (1024,1024,1, "read_only", 2, 8, 8),


    (512,1024,1, "read_only", 2, 8, 8),
    (512,2048,1, "read_only", 2, 8, 8),
    (1024,2048,1, "read_only", 2, 8, 8),
    (1024,4096,1, "read_only", 2, 8, 8),


    (512,512,1, "read_only", 2, 8, 4),
    (1024,1024,1, "read_only", 2, 8, 4),

    
    (512,1024,1, "read_only", 2, 8, 4),
    (512,2048,1, "read_only", 2, 8, 4),
    (1024,2048,1, "read_only", 2, 8, 4),
    (1024,4096,1, "read_only", 2, 8, 4),

    (512,512,1, "axpy", 2, 40, 8),
    (1024,1024,1, "axpy", 2, 40, 8),


    (512,1024,1, "axpy", 2, 40, 8),
    (512,2048,1, "axpy", 2, 40, 8),
    (1024,2048,1, "axpy", 2, 40, 8),
    (1024,4096,1, "axpy", 2, 40, 8),


    (512,512,1, "axpy", 2, 40, 4),
    (1024,1024,1, "axpy", 2, 40, 4),

    
    (512,1024,1, "axpy", 2, 40, 4),
    (512,2048,1, "axpy", 2, 40, 4),
    (1024,2048,1, "axpy", 2, 40, 4),
    (1024,4096,1, "axpy", 2, 40, 4),



    (512,512,1, "gemv", 80, 80, 50,8),
    (1024,1024,1, "gemv", 80, 80, 50,8),


    (512,1024,1, "gemv", 80, 80, 50,8),
    (512,2048,1, "gemv", 80, 80, 50,8),
    (1024,2048,1, "gemv", 80, 80, 50,8),
    (1024,4096,1, "gemv", 80, 80, 50,8),


    (512,512,1, "gemv", 80,80, 50,4),
    (1024,1024,1, "gemv", 80,80, 50,4),

    
    (512,1024,1, "gemv", 80,80, 50,4),
    (512,2048,1, "gemv", 80,80, 50,4),
    (1024,2048,1, "gemv", 80,80, 50,4),
    (1024,4096,1, "gemv", 80,80, 50,4),




]

# ---------------------------------------------------------------------------
# Paths  (relative to the directory this script lives in)
# ---------------------------------------------------------------------------
SCRIPT_DIR         = os.path.dirname(os.path.abspath(__file__))
SNITCH_CLUSTER_CFG = os.path.join(SCRIPT_DIR, "cfg", "snitch_cluster.json")
GWAIHIR_NOC_CFG    = os.path.join(SCRIPT_DIR, "cfg", "gwaihir_noc.yml")
AXPY_BENCHMARK     = os.path.join(SCRIPT_DIR, "axpy_auto_benchmark.sh")
OPT_BENCHMARK      = os.path.join(SCRIPT_DIR, "dot_product_benchmark.sh")
GEMV_BENCHMARK     = os.path.join(SCRIPT_DIR, "gemv_benchmark.sh")
MAIN_C             = os.path.join(SCRIPT_DIR, "sw", "snitch", "apps", "axpy", "src", "main.c")
PARAMS_JSON        = os.path.join(SCRIPT_DIR, "sw", "snitch", "apps", "axpy", "data", "params.json")
GEMV_MAIN_C        = os.path.join(SCRIPT_DIR, "sw", "snitch", "apps", "gemv", "src", "main.c")
GEMV_PARAMS_JSON   = os.path.join(SCRIPT_DIR, "sw", "snitch", "apps", "gemv", "data", "params.json")
TRANSCRIPT_FILE    = os.path.join(SCRIPT_DIR, "transcript")
SWEEP_RESULTS_DIR  = os.path.join(SCRIPT_DIR, "sweep_results_full")
BENCH_LOG_DIR      = os.path.join(SWEEP_RESULTS_DIR, "benchmark_logs")


# ---------------------------------------------------------------------------
# File-patching helpers
# ---------------------------------------------------------------------------

def set_snitch_dma_width(path: str, width: int) -> None:
    """Replace dma_data_width value in snitch_cluster.json (JSONC)."""
    with open(path) as f:
        content = f.read()
    if not re.search(r'dma_data_width:\s*\d+', content):
        sys.exit(f"ERROR: pattern 'dma_data_width' not found in {path}")
    new_content = re.sub(
        r'(dma_data_width:\s*)\d+',
        rf'\g<1>{width}',
        content,
    )
    with open(path, "w") as f:
        f.write(new_content)
    print(f"  snitch_cluster.json  dma_data_width -> {width}")


def set_wide_data_width(path: str, width: int) -> None:
    """Replace data_width inside *wide* protocol sections of gwaihir_noc.yml.

    Uses a stateful line scan so it never touches the narrow protocol
    entries (data_width: 64).
    """
    with open(path) as f:
        lines = f.readlines()

    in_wide_section = False
    replacements    = 0
    result          = []

    for line in lines:
        # A new list-item protocol entry resets the wide-section flag.
        if re.match(r'\s+- name:', line):
            in_wide_section = False

        # Entering a wide protocol section.
        if re.match(r'\s+type:\s+"wide"', line):
            in_wide_section = True

        # Patch data_width only while inside a wide section.
        if in_wide_section and re.match(r'\s+data_width:', line):
            line = re.sub(r'(\s+data_width:\s*)\d+', rf'\g<1>{width}', line)
            replacements += 1

        result.append(line)

    if replacements == 0:
        sys.exit(f"ERROR: no wide data_width entries found in {path}")

    with open(path, "w") as f:
        f.writelines(result)
    print(f"  gwaihir_noc.yml      wide data_width -> {width}  "
          f"({replacements} occurrence(s) replaced)")


def set_mem_tiles(path: str, tiles: int) -> None:
    """Replace the #define MEM_TILES value in main.c."""
    with open(path) as f:
        content = f.read()
    if not re.search(r'#define\s+MEM_TILES\s+\d+', content):
        sys.exit(f"ERROR: pattern '#define MEM_TILES' not found in {path}")
    new_content = re.sub(
        r'(#define\s+MEM_TILES\s+)\d+',
        rf'\g<1>{tiles}',
        content,
    )
    with open(path, "w") as f:
        f.write(new_content)
    print(f"  main.c               MEM_TILES -> {tiles}")


def set_active_clusters(path: str, active_clusters: int) -> None:
    """Replace #define ACTIVE_CLUSTERS value in main.c."""
    if active_clusters < 0 or active_clusters > 16:
        sys.exit(f"ERROR: ACTIVE_CLUSTERS must be in [0, 16], got {active_clusters}")

    with open(path) as f:
        content = f.read()
    if not re.search(r'#define\s+ACTIVE_CLUSTERS\s+\d+', content):
        sys.exit(f"ERROR: pattern '#define ACTIVE_CLUSTERS' not found in {path}")

    new_content = re.sub(
        r'(#define\s+ACTIVE_CLUSTERS\s+)\d+',
        rf'\g<1>{active_clusters}',
        content,
        count=1,
    )
    with open(path, "w") as f:
        f.write(new_content)
    print(f"  main.c               ACTIVE_CLUSTERS -> {active_clusters}")


def set_workload_mode(path: str, mode: str) -> None:
    """Set DOT_PRODUCT/READ_ONLY defines based on workload mode."""
    if mode == "axpy":
        dot_value = 0
        read_only_value = 0
    elif mode == "opt":
        dot_value = 1
        read_only_value = 0
    elif mode == "read_only":
        dot_value = 0
        read_only_value = 1
    else:
        sys.exit(f"ERROR: unsupported mode '{mode}'")

    with open(path) as f:
        content = f.read()
    if not re.search(r'#define\s+DOT_PRODUCT\s+\d+', content):
        sys.exit(f"ERROR: pattern '#define DOT_PRODUCT' not found in {path}")
    if not re.search(r'#define\s+READ_ONLY\s+\d+', content):
        sys.exit(f"ERROR: pattern '#define READ_ONLY' not found in {path}")

    new_content = re.sub(
        r'(#define\s+DOT_PRODUCT\s+)\d+',
        rf'\g<1>{dot_value}',
        content,
    )
    new_content = re.sub(
        r'(#define\s+READ_ONLY\s+)\d+',
        rf'\g<1>{read_only_value}',
        new_content,
    )

    with open(path, "w") as f:
        f.write(new_content)
    print(
        f"  main.c               DOT_PRODUCT -> {dot_value}, "
        f"READ_ONLY -> {read_only_value} ({mode})"
    )


def set_params(path: str, n_tiles: int, repetitions: int) -> int:
    """Set n_tiles, n, repetitions in params.json, with n = n_tiles * 2048."""
    n = n_tiles * 1024
    with open(path) as f:
        content = f.read()

    if not re.search(r'"n_tiles"\s*:\s*\d+', content):
        sys.exit(f"ERROR: pattern '\"n_tiles\"' not found in {path}")
    if not re.search(r'"n"\s*:\s*\d+', content):
        sys.exit(f"ERROR: pattern '\"n\"' not found in {path}")
    if not re.search(r'"repetitions"\s*:\s*\d+', content):
        sys.exit(f"ERROR: pattern '\"repetitions\"' not found in {path}")

    content = re.sub(
        r'("n_tiles"\s*:\s*)\d+',
        rf'\g<1>{n_tiles}',
        content,
        count=1,
    )
    content = re.sub(
        r'("n"\s*:\s*)\d+',
        rf'\g<1>{n}',
        content,
        count=1,
    )
    content = re.sub(
        r'("repetitions"\s*:\s*)\d+',
        rf'\g<1>{repetitions}',
        content,
        count=1,
    )

    with open(path, "w") as f:
        f.write(content)

    print(
        f"  params.json          n_tiles -> {n_tiles}, "
        f"n -> {n}, repetitions -> {repetitions}"
    )
    return n


def set_gemv_params(path: str, m: int, n: int, repetitions: int) -> int:
    """Set m, n, repetitions in GEMV params.json and return n (for filename reuse)."""
    with open(path) as f:
        content = f.read()

    if not re.search(r'("?m"?\s*:\s*)\d+', content):
        sys.exit(f"ERROR: pattern 'm' not found in {path}")
    if not re.search(r'("?n"?\s*:\s*)\d+', content):
        sys.exit(f"ERROR: pattern 'n' not found in {path}")
    if not re.search(r'("?repetitions"?\s*:\s*)\d+', content):
        sys.exit(f"ERROR: pattern 'repetitions' not found in {path}")

    content = re.sub(
        r'("?m"?\s*:\s*)\d+',
        rf'\g<1>{m}',
        content,
        count=1,
    )
    content = re.sub(
        r'("?n"?\s*:\s*)\d+',
        rf'\g<1>{n}',
        content,
        count=1,
    )
    content = re.sub(
        r'("?repetitions"?\s*:\s*)\d+',
        rf'\g<1>{repetitions}',
        content,
        count=1,
    )

    with open(path, "w") as f:
        f.write(content)

    print(f"  gemv params          m -> {m}, n -> {n}, repetitions -> {repetitions}")
    return n


# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

def run_benchmark(mode: str, bench_log_path: str) -> None:
    """Run benchmark script selected by mode and write output to a log file."""
    if mode == "axpy":
        script = AXPY_BENCHMARK
    elif mode == "opt":
        script = OPT_BENCHMARK
    elif mode == "read_only":
        script = OPT_BENCHMARK
    elif mode == "gemv":
        script = GEMV_BENCHMARK
    else:
        sys.exit(
            f"ERROR: unsupported mode '{mode}', expected 'axpy', 'opt', "
            "'read_only', or 'gemv'"
        )

    print(f"  Running benchmark … ({os.path.relpath(script, SCRIPT_DIR)})")
    print(f"  Benchmark log        -> {os.path.relpath(bench_log_path, SCRIPT_DIR)}")

    cmd = ["stdbuf", "-oL", "-eL", "bash", script]
    if shutil.which("stdbuf") is None:
        cmd = ["bash", script]

    os.makedirs(os.path.dirname(bench_log_path), exist_ok=True)
    with open(bench_log_path, "w") as logf:
        proc = subprocess.run(
            cmd,
            cwd=SCRIPT_DIR,
            stdout=logf,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    ret = proc.returncode
    if ret != 0:
        sys.exit(
            f"ERROR: benchmark exited with code {ret}. "
            f"See log: {bench_log_path}"
        )


# ---------------------------------------------------------------------------
# Transcript archival
# ---------------------------------------------------------------------------

def archive_transcript(dma_width: int, wide_width: int, mem_tiles: int,
                       mode: str, n_tiles: int, n: int,
                       repetitions: int, active_clusters: int) -> str:
    """Copy transcript to sweep_results/ with a filename that encodes exact config."""
    if not os.path.isfile(TRANSCRIPT_FILE):
        sys.exit(f"ERROR: transcript file not found at {TRANSCRIPT_FILE}")

    os.makedirs(SWEEP_RESULTS_DIR, exist_ok=True)

    fname = (
        f"transcript_dma{dma_width}_wide{wide_width}_mem{mem_tiles}"
        f"_mode{mode}_ntiles{n_tiles}_n{n}_rep{repetitions}"
        f"_active{active_clusters}.log"
    )
    dest = os.path.join(SWEEP_RESULTS_DIR, fname)
    shutil.copy2(TRANSCRIPT_FILE, dest)

    print(f"  Transcript copied to  {os.path.relpath(dest, SCRIPT_DIR)}")
    return dest


# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------

def main() -> None:
    print(f"Starting sweep over {len(CONFIG_PAIRS)} configuration(s).\n")
    os.makedirs(BENCH_LOG_DIR, exist_ok=True)

    for idx, config in enumerate(CONFIG_PAIRS, 1):
        gemv_repetitions = None
        if len(config) == 6:
            dma_width, wide_width, mem_tiles, mode, n_tiles, repetitions = config
            active_clusters = 16
        elif len(config) == 7:
            (
                dma_width,
                wide_width,
                mem_tiles,
                mode,
                n_tiles,
                repetitions,
                extra,
            ) = config
            if mode == "gemv":
                gemv_repetitions = extra
                active_clusters = 16
            else:
                active_clusters = extra
        elif len(config) == 8 and config[3] == "gemv":
            (
                dma_width,
                wide_width,
                mem_tiles,
                mode,
                n_tiles,
                repetitions,
                gemv_repetitions,
                active_clusters,
            ) = config
        else:
            sys.exit(
                "ERROR: invalid CONFIG_PAIRS entry. "
                "Use 6/7 fields for axpy-like modes, and 6/7/8 fields for gemv "
                "(the optional extra field is gemv_repetitions, then active_clusters)."
            )

        if mode not in ("axpy", "opt", "read_only", "gemv"):
            sys.exit(
                f"ERROR: mode must be 'axpy', 'opt', 'read_only', or 'gemv', got '{mode}'"
            )
        if active_clusters < 0 or active_clusters > 16:
            sys.exit(f"ERROR: active_clusters must be in [0, 16], got {active_clusters}")

        n = n_tiles * 2048
        run_repetitions = repetitions
        if mode == "gemv":
            if gemv_repetitions is None:
                gemv_repetitions = 16
            run_repetitions = gemv_repetitions
            print(
                f"[{idx}/{len(CONFIG_PAIRS)}] "
                f"dma_data_width={dma_width}  wide_data_width={wide_width}  "
                f"mode={mode}  m={n_tiles}  n={repetitions}  "
                f"gemv_repetitions={gemv_repetitions}  "
                f"active_clusters={active_clusters}"
            )
        else:
            print(f"[{idx}/{len(CONFIG_PAIRS)}] "
                  f"dma_data_width={dma_width}  wide_data_width={wide_width}  "
                  f"MEM_TILES={mem_tiles}  mode={mode}  "
                  f"n_tiles={n_tiles}  n={n}  repetitions={repetitions}  "
                  f"active_clusters={active_clusters}")

        set_snitch_dma_width(SNITCH_CLUSTER_CFG, dma_width)
        set_wide_data_width(GWAIHIR_NOC_CFG,     wide_width)
        if mode == "gemv":
            set_active_clusters(GEMV_MAIN_C, active_clusters)
            n = set_gemv_params(GEMV_PARAMS_JSON, n_tiles, repetitions, gemv_repetitions)
        else:
            set_mem_tiles(MAIN_C,                    mem_tiles)
            set_active_clusters(MAIN_C,              active_clusters)
            set_workload_mode(MAIN_C,                mode)
            n = set_params(PARAMS_JSON,              n_tiles, repetitions)

        bench_log = os.path.join(
            BENCH_LOG_DIR,
            (
                f"benchmark_dma{dma_width}_wide{wide_width}_mem{mem_tiles}"
                  f"_mode{mode}_ntiles{n_tiles}_n{n}_rep{run_repetitions}"
                f"_active{active_clusters}.log"
            ),
        )
        run_benchmark(mode, bench_log)
        archive_transcript(
            dma_width,
            wide_width,
            mem_tiles,
            mode,
            n_tiles,
            n,
              run_repetitions,
            active_clusters,
        )
        print()

    print("Sweep complete.")


if __name__ == "__main__":
    main()
