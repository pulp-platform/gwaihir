set cells [get_cells -hierarchical -filter "full_name =~ *floo_router*"]


sizeof_collection $cells

change_selection $cells


gui_change_highlight -color red -collection $cells

open_lib save/512_1024_run/lib.ndm
 open_block cluster_tile/floorplan



/scratch2/sem26f34/gwaihir/sw/snitch/apps/axpy/scripts/verify.py \
  placeholder \
  /scratch2/sem26f34/gwaihir/sw/snitch/apps/axpy/build/axpy.elf \
  --no-ipc --memdump l2mem.bin --memaddr 0x70000000



  make pnr-cluster_tile HANDOFF=bottom_up TO_STAGE=placement RUN_NAME=