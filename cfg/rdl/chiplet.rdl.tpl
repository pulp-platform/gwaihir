// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Internal addrmap of the chiplet alias windows (ucie0/ucie1). The offset of
// each region inside the window equals the low bits of its canonical address,
// so the layout is derived from the endpoints in gwaihir_noc.yml.
// Only the cluster tiles and L2 SPM are exposed through the alias windows.

<%
cluster = next(ep for ep in endpoints if ep["name"] == "cluster")
# L2 SPM is now four individual, heterogeneously-sized endpoints (l2_spm_0..3)
# instead of one uniform array, so mirror each tile separately in the window.
l2_tiles = sorted(
    (ep for ep in endpoints if ep["name"].startswith("l2_spm_")),
    key=lambda ep: int(ep["name"].rsplit("_", 1)[1]),
)
ucie    = next(ep for ep in endpoints if ep["name"] == "ucie0")

win_mask  = ucie["addr_range"]["size"] - 1

cluster_tile = cluster["addr_range"][0]
n_cluster    = int(cluster["array"][0]) * int(cluster["array"][1])
%>\
`ifndef __CHIPLET_RDL__
`define __CHIPLET_RDL__

`include "snitch_cluster.rdl"

addrmap chiplet {
  snitch_cluster cluster[${n_cluster}] @${hex(cluster_tile["base"] & win_mask)} += ${hex(cluster_tile["size"])};
% for ep in l2_tiles:
  external mem { mementries = ${hex(ep["addr_range"][0]["size"] // 4)}; memwidth = 32; } ${ep["name"]} @${hex(ep["addr_range"][0]["base"] & win_mask)};
% endfor
};

`endif // __CHIPLET_RDL__
