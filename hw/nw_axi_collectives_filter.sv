// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "axi/assign.svh"

module nw_axi_collectives_filter #(
  parameter type collective_axi_narrow_mst_req_t = logic,
  parameter type collective_axi_narrow_mst_rsp_t = logic,
  parameter type collective_axi_narrow_slv_req_t = logic,
  parameter type collective_axi_narrow_slv_rsp_t = logic,
  parameter type collective_axi_wide_mst_req_t   = logic,
  parameter type collective_axi_wide_mst_rsp_t   = logic,
  parameter type collective_axi_wide_slv_req_t   = logic,
  parameter type collective_axi_wide_slv_rsp_t   = logic,
  parameter type axi_narrow_mst_req_t            = logic,
  parameter type axi_narrow_mst_rsp_t            = logic,
  parameter type axi_narrow_slv_req_t            = logic,
  parameter type axi_narrow_slv_rsp_t            = logic,
  parameter type axi_wide_mst_req_t              = logic,
  parameter type axi_wide_mst_rsp_t              = logic,
  parameter type axi_wide_slv_req_t              = logic,
  parameter type axi_wide_slv_rsp_t              = logic
) (
  input  collective_axi_narrow_mst_req_t collective_axi_narrow_mst_req_i,
  output collective_axi_narrow_mst_rsp_t collective_axi_narrow_mst_rsp_o,
  output axi_narrow_mst_req_t            axi_narrow_mst_req_o,
  input  axi_narrow_mst_rsp_t            axi_narrow_mst_rsp_i,

  input  axi_narrow_slv_req_t            axi_narrow_slv_req_i,
  output axi_narrow_slv_rsp_t            axi_narrow_slv_rsp_o,
  output collective_axi_narrow_slv_req_t collective_axi_narrow_slv_req_o,
  input  collective_axi_narrow_slv_rsp_t collective_axi_narrow_slv_rsp_i,

  input  collective_axi_wide_mst_req_t collective_axi_wide_mst_req_i,
  output collective_axi_wide_mst_rsp_t collective_axi_wide_mst_rsp_o,
  output axi_wide_mst_req_t            axi_wide_mst_req_o,
  input  axi_wide_mst_rsp_t            axi_wide_mst_rsp_i,

  input  axi_wide_slv_req_t            axi_wide_slv_req_i,
  output axi_wide_slv_rsp_t            axi_wide_slv_rsp_o,
  output collective_axi_wide_slv_req_t collective_axi_wide_slv_req_o,
  input  collective_axi_wide_slv_rsp_t collective_axi_wide_slv_rsp_i
);

  always_comb begin
    `AXI_SET_REQ_STRUCT(axi_narrow_mst_req_o, collective_axi_narrow_mst_req_i)
    axi_narrow_mst_req_o.aw.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: collective_axi_narrow_mst_req_i.aw.user.user
    };
    axi_narrow_mst_req_o.w.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: collective_axi_narrow_mst_req_i.w.user.user
    };
    axi_narrow_mst_req_o.ar.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: collective_axi_narrow_mst_req_i.ar.user.user
    };

    `AXI_SET_RESP_STRUCT(collective_axi_narrow_mst_rsp_o, axi_narrow_mst_rsp_i)
    collective_axi_narrow_mst_rsp_o.b.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: axi_narrow_mst_rsp_i.b.user.user
    };
    collective_axi_narrow_mst_rsp_o.r.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: axi_narrow_mst_rsp_i.r.user.user
    };

    `AXI_SET_REQ_STRUCT(axi_wide_mst_req_o, collective_axi_wide_mst_req_i)
    axi_wide_mst_req_o.aw.user = '0;
    axi_wide_mst_req_o.w.user  = '0;
    axi_wide_mst_req_o.ar.user = '0;

    `AXI_SET_RESP_STRUCT(collective_axi_wide_mst_rsp_o, axi_wide_mst_rsp_i)
    collective_axi_wide_mst_rsp_o.b.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast
    };
    collective_axi_wide_mst_rsp_o.r.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast
    };

    `AXI_SET_REQ_STRUCT(collective_axi_wide_slv_req_o, axi_wide_slv_req_i)
    collective_axi_wide_slv_req_o.aw.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast
    };
    collective_axi_wide_slv_req_o.w.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast
    };
    collective_axi_wide_slv_req_o.ar.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast
    };

    `AXI_SET_RESP_STRUCT(axi_wide_slv_rsp_o, collective_axi_wide_slv_rsp_i)
    axi_wide_slv_rsp_o.b.user = '0;
    axi_wide_slv_rsp_o.r.user = '0;
  end

  always_comb begin
    `AXI_SET_REQ_STRUCT(collective_axi_narrow_slv_req_o, axi_narrow_slv_req_i)
    collective_axi_narrow_slv_req_o.aw.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: axi_narrow_slv_req_i.aw.user
    };
    collective_axi_narrow_slv_req_o.w.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: axi_narrow_slv_req_i.w.user
    };
    collective_axi_narrow_slv_req_o.ar.user = '{
        collective_mask: '0,
        collective_op: floo_pkg::Unicast,
        user: axi_narrow_slv_req_i.ar.user
    };

    `AXI_SET_RESP_STRUCT(axi_narrow_slv_rsp_o, collective_axi_narrow_slv_rsp_i)
    axi_narrow_slv_rsp_o.b.user = collective_axi_narrow_slv_rsp_i.b.user.user;
    axi_narrow_slv_rsp_o.r.user = collective_axi_narrow_slv_rsp_i.r.user.user;
  end

endmodule
