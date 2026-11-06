// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>

module stream2rdi #(
  parameter int unsigned DataWidth = 256,
  /// Cut the paths between the stream and the RDI data and handshake with a
  /// two-entry FIFO. `link_active_i` is not registered here: it must come from
  /// a flip-flop when `CutRdi` is set.
  parameter bit          CutRdi    = 1'b1,
  /// Copies of the FIFO read pointer, each selecting a slice of `lp_data_o`
  parameter int unsigned NumRdPtrs = 4
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic [DataWidth-1:0] inp_data_i,
  input  logic                 inp_valid_i,
  output logic                 inp_ready_o,
  output logic [DataWidth-1:0] lp_data_o,
  output logic                 lp_valid_o,
  output logic                 lp_irdy_o,
  input  logic                 pl_trdy_i,
  input  logic                 link_active_i
);

  logic [DataWidth-1:0] rdi_data;
  logic rdi_valid, rdi_ready;

  if (CutRdi) begin : gen_cut
    // Two-entry FIFO: `pl_trdy` only moves the read pointer and the fill count
    // (a few flops), the data words load on the stream side. A spill register
    // puts `pl_trdy` on the load enable of a whole data word, which the
    // macro's clock-to-output leaves no time for. The read pointer is kept in
    // `NumRdPtrs` copies, each selecting a slice of the output word, so no
    // single flop drives the select of all of `lp_data` (the macro's lp_data
    // pins are next to the FIFO, so the select fanout is the delay that
    // remains). The copies must not be merged in synthesis. `valid_q` is
    // `cnt_q != 0` in a flop of its own, so `lp_valid` comes straight from a
    // register that sits at the pin instead of from the fill count's decode.
    logic [          1:0][DataWidth-1:0] mem_q;
    logic                                wr_ptr_q;
    logic [NumRdPtrs-1:0]                rd_ptr_q;
    logic [          1:0]                cnt_q;
    logic                                valid_q;
    logic push, pop;

    assign inp_ready_o = (cnt_q != 2'd2);
    assign rdi_valid   = valid_q;
    assign push        = inp_valid_i & inp_ready_o;
    assign pop         = rdi_valid & rdi_ready;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        mem_q    <= '0;
        wr_ptr_q <= 1'b0;
      end else if (push) begin
        mem_q[wr_ptr_q] <= inp_data_i;
        wr_ptr_q        <= ~wr_ptr_q;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rd_ptr_q <= '0;
        cnt_q    <= 2'd0;
      end else begin
        if (pop) rd_ptr_q <= ~rd_ptr_q;
        cnt_q <= cnt_q + 2'(push) - 2'(pop);
      end
    end

    // Not empty after this cycle: something is pushed, the FIFO is full, or it
    // holds one word that is not popped (`pl_trdy` only reaches the last term)
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= 1'b0;
      end else begin
        valid_q <= push | (cnt_q == 2'd2) | ((cnt_q == 2'd1) & ~pop);
      end
    end

    // Bit `i` of the output word is selected by copy `i * NumRdPtrs / DataWidth`
    always_comb begin
      for (int unsigned i = 0; i < DataWidth; i++) begin
        rdi_data[i] = mem_q[rd_ptr_q[(i*NumRdPtrs)/DataWidth]][i];
      end
    end
  end else begin : gen_no_cut
    assign rdi_data    = inp_data_i;
    assign rdi_valid   = inp_valid_i;
    assign inp_ready_o = rdi_ready;
  end

  // Send only while the link is ACTIVE
  assign lp_data_o  = rdi_data;
  assign lp_valid_o = rdi_valid & link_active_i;
  assign lp_irdy_o  = link_active_i;
  assign rdi_ready  = pl_trdy_i & link_active_i;

endmodule : stream2rdi
