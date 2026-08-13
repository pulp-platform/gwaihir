make all
make sw DEBUG=ON
make vsim-compile


make vsim-run-batch-verify PRELMODE=3 CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf SN_BINARY=sw/snitch/apps/gemv/build/gemv.elf VERIFY_PY=$(bender path snitch_cluster)/sw/kernels/blas/gemv/scripts/verify.py




make sn-clean-traces sn-clean-perf
make sn-traces SN_BINARY=sw/snitch/apps/gemv/build/gemv.elf
make sn-perf
make sn-visual-trace SN_JOINT_PERF_DUMP=/scratch2/sem26f34/gwaihir/logs/perf.json SN_ROI_SPEC=/scratch2/sem26f34/gwaihir/cfg/roi_all_clusters.json
