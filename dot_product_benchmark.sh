make all
make sw
make vsim-compile


make vsim-run-batch PRELMODE=3 CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf SN_BINARY=sw/snitch/apps/axpy/build/axpy.elf