# gwaihir 🦅

*gwaihir* is an open-source research platform focusing on AI and Machine Learning acceleration.

*gwaihir* is developed as part of the [PULP (Parallel Ultra-Low Power) project](https://pulp-platform.org/), a joint effort between ETH Zurich and the University of Bologna. *gwaihir* is also supported by the [EUPilot project](https://eupilot.eu), under the name MLS.

## ⚡ Getting started

### Environment setup for IIS-members

For IIS-members, the environment can be set up by sourcing the `iis-env.sh` script:

```bash
source iis-env.sh
```

This will set up all environment variables, and install the virtual python environment, which is needed to generate the RTL and SW sources.

### Environment setup for non-IIS members

For non-IIS members, there is some additional setup required to get the environment up and running.

#### Bender

The first requirement you need to install is `bender`. Check the [installation page](https://github.com/pulp-platform/bender/tree/master?tab=readme-ov-file#installation) on how to set it up.

#### Python environment

To generate certain source files with python you need to have [uv](https://docs.astral.sh/uv/) installed, which will create the virtual environment and install the required dependencies. To set up the environment, run:

```bash
uv sync --locked
source .venv/bin/activate
```

#### Toolchains

Gwaihir requires two different toolchains at the moment:

* Snitch software tests require the Clang compiler extended with Snitch-specific instructions. There are some precompiled releases available on the [PULP Platform LLVM Project](https://github.com/pulp-platform/llvm-project/releases/download/0.12.0/riscv32-pulp-llvm-ubuntu2004-0.12.0.tar.gz) fork that are ready to be downloaded and unzipped.
* Cheshire requires a 64-bit GCC toolchain that can be installed from the [riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) git following the *Installation (Newlib)* instructions.

Once LLVM and GCC are obtained, export a `LLVM_BINROOT` environment variable to the binary folder of the LLVM toolchain installation. Then, add the GCC binary folder to your `$PATH`:

```bash
export LLVM_BINROOT=/path/to/llvm/bin
export PATH=$PATH:/path/to/gcc/bin
```

#### Verible (Optional)

For automatic formatting of generated sources, install [`verible`](https://github.com/chipsalliance/verible). By default, the Makefile will look for a `verible-verilog-format` in your path, but you can also set it explicitly with the `VERIBLE_FMT` environment variable. This dependency is optional for normal users, but it is required to contribute to the project, since the CI will use verible to check the formatting of the code. Once installed, you can format the SV code in this repository with:

```bash
make verible-fmt
```

### RTL code generation

After setting up the environment, you can generate all the RTL code for Cheshire, FlooNoC, and Snitch by running:

```bash
make all
```

or more selectively:

```bash
make floo-hw-all
make chs-hw-all
make sn-hw-all
```

### Compile software tests

To compile the software for Cheshire and the snitch cluster, you can run the following commands:

```bash
make sw
```

or more selectively:

```bash
make chs-sw-tests
make sn-tests
```

### Simulation

Gwaihir supports two simulation flows: **QuestaSim** and **Synopsys VCS**.
Tests can be executed by setting the required command-line variables for Cheshire — see the [Cheshire Docs](https://pulp-platform.github.io/cheshire/gs/) for more details.

Use the `PRELMODE=3` flag to enable fast preload of the Snitch binary and speed up simulation.

#### QuestaSim

To compile the RTL:

```bash
make vsim-compile
```

To run a simple Cheshire helloworld in Gwaihir:

```bash
make vsim-run CHS_BINARY=sw/cheshire/tests/helloworld.spm.elf
```

To run an offloading example test for Snitch:

```bash
make vsim-run CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf SN_BINARY=sw/snitch/tests/build/simple.elf
```

Use `vsim-run-batch` to run in batch mode with RTL optimizations to reduce runtime.

Some applications produce a lot of output data that is time-consuming to check in simulation. These applications usually come with a Python verification script that checks results from a memory dump at the end of simulation. For example, to run and verify the GEMM kernel:

```bash
make vsim-run-batch-verify VERIFY_PY=$(bender path snitch_cluster)/sw/blas/gemm/scripts/verify.py PRELMODE=3 CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf SN_BINARY=sw/snitch/apps/blas/gemm/build/gemm.elf
```

#### VCS

Gwaihir provides two VCS run modes: **batch** (no debug overhead, faster) and **GUI** (full signal visibility for Verdi). Compilation is handled automatically by the run targets.

To run in batch mode:

```bash
make vcs-run-batch CHS_BINARY=sw/cheshire/tests/helloworld.spm.elf
```

To run an offloading example test for Snitch:

```bash
make vcs-run-batch CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf SN_BINARY=sw/snitch/tests/build/simple.elf
```

To open the simulation in the Verdi GUI (compiled with full debug access):

```bash
make vcs-run CHS_BINARY=sw/cheshire/tests/helloworld.spm.elf
```

Use `vcs-clean` to remove all VCS build artifacts and force a full recompilation.

### Additional help

Additionally, you can run the following command to get a list of all available commands:

```bash
make help
```

## 🔐 License
Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources are licensed under the Solderpad Hardware License 0.51 (see [`LICENSE`](LICENSE)), and all software sources are licensed under the Apache License 2.0.
