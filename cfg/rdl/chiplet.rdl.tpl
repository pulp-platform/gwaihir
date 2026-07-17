// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Internal addrmap of the chiplet alias windows (ucie0/ucie1). The offset of
// each region inside the window equals the low bits of its canonical address,
// so the layout is derived from the endpoints in gwaihir_noc.yml.
// Only TCDM and L2 SPM are exposed through the alias windows (see ADR 0001).

<%
cluster = next(ep for ep in endpoints if ep["name"] == "cluster")
l2      = next(ep for ep in endpoints if ep["name"] == "l2_spm")
ucie    = next(ep for ep in endpoints if ep["name"] == "ucie0")

win_mask  = ucie["addr_range"]["size"] - 1

tcdm      = cluster["addr_range"][0]
n_cluster = int(cluster["array"][0]) * int(cluster["array"][1])

l2r       = l2["addr_range"][0]
n_l2      = int(l2["array"][0])
%>\
`ifndef __CHIPLET_RDL__
`define __CHIPLET_RDL__

addrmap chiplet {
  external mem { mementries = ${hex(tcdm["size"] // 4)}; memwidth = 32; } cluster[${n_cluster}] @${hex(tcdm["base"] & win_mask)} += ${hex(tcdm["size"])};
  external mem { mementries = ${hex(l2r["size"] // 4)}; memwidth = 32; } l2_spm[${n_l2}] @${hex(l2r["base"] & win_mask)} += ${hex(l2r["size"])};
};

`endif // __CHIPLET_RDL__
