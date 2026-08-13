Files i changed and worked with for the semester project:

Gwaihir Main:
https://iis-git.ee.ethz.ch/lkroeger/gwaihir

Change DMA Data Width in cfg folder for noc and snitch cluster, change memtile implementation to include read interleaving, implemented in axi-to_detailed_mem_user_rr.sv

memtile can be instantiated with or without UseInterleaving set

cluster_tile.sv instantiates Data width adapter

Benchmarking sweep in run_sweep.py

Adjusted the sw benchamrks for gemv, axpy and added a read only benchamrk (also in axpy currently, loads the same arguments, need to set the flags in the main function of axpy to determine which benchmark is run)

Snitch Clsuter:
https://github.com/lkroeger1/snitch_cluster.git
minor changes, 
- properly assigning dma and dca data width (before i think dma data width form config json was used for both dma and dca)
- Disable assertion requiring dca and dma data width to be equal


FlooNoC:
https://github.com/lkroeger1/FlooNoC.git
Changes:
Added data width adapter, copied axi upiszer and downsizer with adjusted size field. Chimney, join etc now all take a parameter to determine if 4 bit axi size field is used. Adjusted floogen as well to work with the larger data widths.

If you want to change the axi size throughout the entire system, just adjust the axi_pkg.sv in the axi repo





