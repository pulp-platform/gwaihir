// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Gabriele Lodi <galodi@ethz.ch>
//
// Open-source behavioral model of the UCIe macro (PHY + PCS).
//

module ucie_macro_wrap (
  input          rdi_clk,
  input          refclk,
  input          rst_async_n,
  output         txckn,
  output         txckp,
  output         txdata0,
  output         txdata1,
  output         txdata2,
  output         txdata3,
  output         txdata4,
  output         txdata5,
  output         txdata6,
  output         txdata7,
  output         txtrk,
  output         txvld,
  input          rxckn,
  input          rxckp,
  input          rxdata0,
  input          rxdata1,
  input          rxdata2,
  input          rxdata3,
  input          rxdata4,
  input          rxdata5,
  input          rxdata6,
  input          rxdata7,
  input          rxtrk,
  input          rxvld,
  input          rxclksb,
  input          rxdatasb,
  output         txclksb,
  output         txdatasb,
  input  [ 31:0] apb_s_paddr,
  input          apb_s_pclk,
  input          apb_s_penable,
  output [ 31:0] apb_s_prdata,
  output         apb_s_pready,
  input          apb_s_presetn,
  input          apb_s_psel,
  output         apb_s_pslverr,
  input  [  3:0] apb_s_pstrb,
  input  [ 31:0] apb_s_pwdata,
  input          apb_s_pwrite,
  input  [255:0] lp_data,
  input          lp_irdy,
  input  [  3:0] lp_state_req,
  input          lp_valid,
  output [255:0] pl_data,
  output [  3:0] pl_state_sts,
  output         pl_trdy,
  output         pl_valid
);

  ////////////////
  // Parameters //
  ////////////////

  localparam int unsigned RdiWidth = 256;
  localparam int unsigned NumLanes = 8;
  localparam int unsigned LaneBits = RdiWidth / NumLanes;
  localparam int unsigned CntWidth = $clog2(LaneBits);  // bit counter per word

  localparam logic [3:0] RdiReset = 4'h0;
  localparam logic [3:0] RdiActive = 4'h1;

  typedef logic [RdiWidth-1:0] word_t;
  typedef logic [NumLanes-1:0][LaneBits-1:0] lanes_t;

  /////////////
  // Link-up //
  /////////////

  logic req_q, peer_req, link_active;

  // Local side out of reset

  always_ff @(posedge rdi_clk or negedge rst_async_n) begin
    if (!rst_async_n) req_q <= 1'b0;
    else req_q <= 1'b1;
  end

  // Peer side out of reset, received on the track lane
  tc_sync #(
    .Stages(2)
  ) i_sync_peer_req (
    .clk_i   (rdi_clk),
    .rst_ni  (rst_async_n),
    .serial_i(rxtrk),
    .serial_o(peer_req)
  );

  assign link_active  = req_q & peer_req;
  assign pl_state_sts = link_active ? RdiActive : RdiReset;

  assign txtrk = req_q;

  ////////////
  // Clocks //
  ////////////

  // Mainband clock forwarded to the peer; the RX side runs on the peer's
  // forwarded clock (`rxckp`)
  assign txckp = rdi_clk;

  tc_clk_inverter i_txckn (
    .clk_i(rdi_clk),
    .clk_o(txckn)
  );

  // Sideband: clock only, no sideband data
  assign txclksb  = refclk;
  assign txdatasb = 1'b0;

  ////////
  // TX //
  ////////

  // One shift register per lane: a word takes LaneBits cycles to send
  lanes_t                tx_shift_q;
  logic                  tx_busy_q;
  logic   [CntWidth-1:0] tx_cnt_q;
  logic tx_last, tx_fire;
  logic [NumLanes-1:0] txdata;

  assign tx_last = tx_busy_q && (tx_cnt_q == CntWidth'(LaneBits - 1));

  // Ready for a new word when idle or on the last bit of the current one, so
  // back-to-back words go out without a gap
  assign pl_trdy = link_active && (!tx_busy_q || tx_last);
  assign tx_fire = lp_valid && lp_irdy && pl_trdy;

  always_ff @(posedge rdi_clk or negedge rst_async_n) begin
    if (!rst_async_n) begin
      tx_shift_q <= '0;
      tx_busy_q  <= 1'b0;
      tx_cnt_q   <= '0;
    end else if (tx_fire) begin
      tx_shift_q <= lanes_t'(lp_data);
      tx_busy_q  <= 1'b1;
      tx_cnt_q   <= '0;
    end else if (tx_busy_q) begin
      for (int unsigned l = 0; l < NumLanes; l++) begin
        tx_shift_q[l] <= tx_shift_q[l] >> 1;
      end
      tx_busy_q <= !tx_last;
      tx_cnt_q  <= tx_cnt_q + 1;
    end
  end

  // LSB first; `txvld` frames the word
  for (genvar l = 0; l < NumLanes; l++) begin : gen_tx_lane
    assign txdata[l] = tx_shift_q[l][0];
  end
  assign {txdata7, txdata6, txdata5, txdata4, txdata3, txdata2, txdata1, txdata0} = txdata;
  assign txvld                                                                    = tx_busy_q;

  ////////
  // RX //
  ////////

  logic [NumLanes-1:0] rxdata;
  lanes_t rx_shift_q, rx_shift_d;
  logic  [CntWidth-1:0] rx_cnt_q;
  logic                 rx_last;
  word_t                rx_word_q;
  logic                 rx_push_q;

  assign rxdata  = {rxdata7, rxdata6, rxdata5, rxdata4, rxdata3, rxdata2, rxdata1, rxdata0};
  assign rx_last = rxvld && (rx_cnt_q == CntWidth'(LaneBits - 1));

  // Shift in from the MSB side, so the first (LSB) bit ends at position 0
  for (genvar l = 0; l < NumLanes; l++) begin : gen_rx_lane
    assign rx_shift_d[l] = {rxdata[l], rx_shift_q[l][LaneBits-1:1]};
  end

  // Deserialize on the received clock; a word is complete after LaneBits
  // valid cycles. The bit counter restarts whenever `rxvld` drops.
  always_ff @(posedge rxckp or negedge rst_async_n) begin
    if (!rst_async_n) begin
      rx_shift_q <= '0;
      rx_cnt_q   <= '0;
      rx_word_q  <= '0;
      rx_push_q  <= 1'b0;
    end else begin
      rx_push_q <= rx_last;
      if (rxvld) begin
        rx_shift_q <= rx_shift_d;
        rx_cnt_q   <= rx_last ? '0 : rx_cnt_q + 1;
        if (rx_last) rx_word_q <= word_t'(rx_shift_d);
      end else begin
        rx_cnt_q <= '0;
      end
    end
  end

  // Into `rdi_clk`. RDI RX has no backpressure, and the peer TX sends at most
  // one word every LaneBits cycles, so the FIFO never fills.
  cc_cdc_fifo_gray #(
    .data_t  (word_t),
    .LogDepth(2)
  ) i_rx_cdc_fifo (
    .src_rst_ni (rst_async_n),
    .src_clk_i  (rxckp),
    .src_data_i (rx_word_q),
    .src_valid_i(rx_push_q),
    .src_ready_o(),
    .dst_rst_ni (rst_async_n),
    .dst_clk_i  (rdi_clk),
    .dst_data_o (pl_data),
    .dst_valid_o(pl_valid),
    .dst_ready_i(1'b1)
  );

  //////////////
  // Tie-offs //
  //////////////

  // APB slave: no registers, reads return 0
  assign apb_s_pready  = 1'b1;
  assign apb_s_prdata  = '0;
  assign apb_s_pslverr = 1'b0;

endmodule : ucie_macro_wrap
