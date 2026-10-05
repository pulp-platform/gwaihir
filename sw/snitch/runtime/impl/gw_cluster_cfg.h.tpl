// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

<%!
import math

def next_power_of_2(n):
    """Returns the next power of 2 greater than or equal to n."""
    return 1 if n == 0 else 2**math.ceil(math.log2(n))
%>
<%
  # Mirror the Snitch cluster address map.
  tcdm_size = next_power_of_2(cfg['cluster']['tcdm']['size']) * 1024
  bootrom_size = 4 * 1024 if cfg['cluster']['int_bootrom_enable'] else 0
  periph_size = cfg['cluster']['cluster_periph_size'] * 1024
  ext_mem_offset = tcdm_size + bootrom_size + periph_size
%>
#ifndef GW_CLUSTER_CFG_H_
#define GW_CLUSTER_CFG_H_

// Offset of the cluster external memory region from the cluster base address
#define GW_CLUSTER_EXT_MEM_OFFSET ${hex(ext_mem_offset)}
#define GW_CLUSTER_EXT_MEM_SIZE ${hex(cfg['cluster']['ext_mem_size'] * 1024)}

#endif /* GW_CLUSTER_CFG_H_ */
