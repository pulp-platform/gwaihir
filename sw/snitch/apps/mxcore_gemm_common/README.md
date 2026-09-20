<!-- Copyright 2026 ETH Zurich and University of Bologna. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# MXCore GEMM applications

`mxcore_gemm_mxfp8_mxfp8_fp32` and `mxcore_gemm_mxfp8_mxfp8_mxfp8`
each execute one configured `Y = XW` on cluster 0. Both use MXFP8 inputs
(E5M2 payloads with E8M0 scales, one scale per 32 elements along K) and FP32
accumulation. The second application enables MXCore's E5M2 output quantizer.

These are ordinary SNRT applications, with the project's startup, linker script,
allocator, performance counters, and host offload protocol. No generated data,
custom testbench, or result-processing script is needed.

## Build and run

After the usual environment and hardware setup described in the root README:

```sh
make mxcore_gemm_mxfp8_mxfp8_fp32 M=64 N=64 K=256
make mxcore_gemm_mxfp8_mxfp8_mxfp8 M=64 N=64 K=256
make chs-sw-tests
make vsim-compile

make vsim-run-batch PRELMODE=3 \
  CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf \
  SN_BINARY=sw/snitch/apps/mxcore_gemm_mxfp8_mxfp8_fp32/build/mxcore_gemm_mxfp8_mxfp8_fp32.elf

make vsim-run-batch PRELMODE=3 \
  CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf \
  SN_BINARY=sw/snitch/apps/mxcore_gemm_mxfp8_mxfp8_mxfp8/build/mxcore_gemm_mxfp8_mxfp8_mxfp8.elf
```

The same ELF paths work with `vsim-run` or the project's VCS targets. On hardware,
load the Snitch ELF into L2 and run `simple_offload` using the normal boot/loader
procedure. The host initializes the Cheshire UART at 115200 baud before waking
Snitch, and drains it before returning. Only the cluster-0 DM core prints.
Other host launchers must also initialize the UART before offloading.

Defaults are `M=64`, `N=64`, `K=256` in `app.mk` in this directory. M and N are
independent: for example, `M=64 N=32 K=64` is supported. The application target
relinks when requested so make-variable changes always take effect. Both targets
are also included in `make sn-apps` and `make sw`.

## Execution and output

The DM core allocates and fills X, W, and their scales directly in its local TCDM.
Other cores use SNRT's normal exit barrier. The application performs a warm-up,
poisons Y again, and times a second launch. It then checks every output element
and, for MXFP8 output, every output scale using an integer reference. Initialization,
verification, printing, and register configuration are outside the timed interval.
There is no DMA transfer in either application.

The two printed lines contain the output format, M/N/K, buffer footprint in
bytes, runtime in cluster cycles, utilization, estimated combined read/write
bandwidth in B/cycle, read/write byte counts, and the number of verification
errors. Success returns 0; invalid dimensions/capacity, timeouts, and mismatches
return nonzero through `simple_offload`.

- **Runtime:** cluster performance counter 15, CYCLE event, sampled immediately
  before triggering and after polling completion. Includes launch/polling/counter
  overhead, so it is a software measurement rather than an exact RTL busy count.
- **Utilization:** `M * N * K / (1024 * cycles)`, displayed as a percentage;
  MXCore has 32 processing elements, each computing 32 MACs per cycle.
- **Bandwidth:** `(read_bytes + write_bytes) / cycles`. This is an analytical
  traffic estimate, including tile rereads and scales, not a hardware byte counter.
  Normally `read_bytes = (M*K + M*K/32)*(N/32) +
  (N*K + N*K/32)*(M/64)`. In the special `N=K=32` case, W scales are fetched
  once as a 64-byte beat; this special case supports only `M=64`.
  Writes are `4*M*N` for FP32 or `M*N + M*N/32` for MXFP8.

These applications own MXCore, its shared-port selection, and counter 15 on
cluster 0. They measure an otherwise idle local cluster. The standard host and
SNRT initialization may give different timings from the archived custom-launcher
benchmarks in `learning/`.

## Supported dimensions and memory

M must be a positive multiple of 64, N and K positive multiples of 32.
The register fields further limit M to 960, N to 992, and K to 4064.
The W-scale matrix must occupy a whole 64-byte beat (`N*K/32` divisible by 64),
except that the hardware also supports a single 32-byte scale block with padding
when `M=64`. With `N=K=32` and `M>64`, the current RTL fetches that scale block
only once but consumes it after the first M tile, so the driver rejects the
shape instead of launching a job that would stall.
Other partial W-scale beats are rejected because the current streamer truncates
their length.

Buffers must fit the **available SNRT L1 heap**, which is less than the physical
128 KiB TCDM because SNRT reserves stack and cluster-local storage. The program
checks the actual allocator bounds before allocation. All buffers start at
64-byte boundaries. An unsupported shape or an oversized allocation prints
`N.A.` and returns an error without launching MXCore.

## Reusing the GEMM code

`mxcore.h` contains `mxcore_gemm(m, n, k, buffers, output, &cycles)`. M/N/K are
runtime function arguments; the applications supply make-configured defaults.
`benchmark.h` contains the shared allocation, example data, timing setup, result
checking, and printing. Each application's C entry point selects its output type.

To use your own resident matrices, provide distinct 64-byte-aligned buffers in
the calling cluster's TCDM, select MXCore on the shared port, enable its clock,
and start counter 15 with the CYCLE event as shown in `benchmark.h`. The function
overwrites Y; it does not read the previous Y. Buffers use these packed layouts,
with the rightmost dimension contiguous:

| Buffer | Layout | Element encoding |
| --- | --- | --- |
| X | `[M/64][K/32][64][32]` | E5M2 |
| W | `[N/32][K/32][32 columns][32 K elements]` | E5M2 |
| SX | `[M/64][K/32][64]` | E8M0 |
| SW | `[N/32][K/32][32]` | E8M0; allocate at least 64 bytes |
| Y | `[M/64][N/32][64][32 columns]` | FP32 or E5M2 |
| SY | `[M/64][N/32][64]` | Native signed 8-bit exponent; absent for FP32 |

**Output-scale encoding:** the current RTL writes a signed, unbiased exponent
for each 32-element Y block. Thus decoded output is `E5M2(Y) * 2^SY`.
It does not write the biased E8M0 encoding used by the inputs. For the finite
outputs in these examples, add 127 to SY when converting to standard MXFP8 E8M0
scales or feeding a result back as an input. The timed operation and correctness
check retain the native hardware encoding, as in the reference benchmark.

The example data varies signs, row/column magnitudes, and K-block scales. Its
reference and quantization checks use integer arithmetic so they also run on
the DM core, which has no floating-point unit. They are specific to this example
pattern; `mxcore_gemm` itself accepts arbitrary correctly encoded input data.
The application makefile uses `-mno-implicit-float` to keep compiler-generated
memory operations scalar as well: disabling loop vectorization alone still
allows vector lowering of `memset`, which the DM core cannot execute.
