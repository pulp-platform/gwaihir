// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

<%
cluster = next(ep for ep in endpoints if ep["name"] == "cluster")

cluster_per_row = int(cluster["array"][0])
cluster_per_col = int(cluster["array"][1])

log2_cluster_per_row = cluster_per_row.bit_length() - 1
log2_cluster_per_col = cluster_per_col.bit_length() - 1

%>
#ifndef GW_CONFIG_H_
#define GW_CONFIG_H_

#define GW_CLUSTER_PER_ROW ${cluster_per_row}
#define GW_CLUSTER_PER_COL ${cluster_per_col}

#define GW_LOG2_CLUSTER_PER_ROW ${log2_cluster_per_row}
#define GW_LOG2_CLUSTER_PER_COL ${log2_cluster_per_col}

#endif /* GW_CONFIG_H_ */
