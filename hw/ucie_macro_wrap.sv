// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Gabriele Lodi <galodi@ethz.ch>
//
// Open-source behavioral model of the IKAIKA07_TOP UCIe macro (PHY + PCS),
// with exactly the macro's ports. It replaces the closed-source
// `ucie_macro_wrap` (target `ucie`) and only talks to another instance of
// itself, connected bump to bump:
// - Link-up: each side drives `txtrk` high once out of reset; the link is
//   ACTIVE when both sides are. `lp_state_req` is ignored.
// - Mainband: each 256-bit RDI word is sent bit-serially on the 8 data lanes
//   (32 bits per lane, LSB first) with `txvld` high, on the forwarded
//   `rdi_clk` (`txckp` / `txckn`).
// - RX: deserialized on the received clock (`rxckp`), then moved into
//   `rdi_clk` through a CDC FIFO onto `pl_data` / `pl_valid`.
// - Sideband, APB, I3C and the RDI config / error interfaces are tied off;
//   APB reads return 0.

module ucie_macro_wrap (
  output clk_1G_UCIe_rx_o,
  output clk_1G_UCIe_tx_o,
  input  rdi_clk,
  input  refclk,
  input  rst_async_n,
  output sb_rx_clk_100MHz,
  output sb_tx_clk_100MHz,
  output txckn,
  output txckp,
  output txdata0,
  output txdata1,
  output txdata2,
  output txdata3,
  output txdata4,
  output txdata5,
  output txdata6,
  output txdata7,
  output txtrk,
  output txvld,
  input  rxckn,
  input  rxckp,
  input  rxdata0,
  input  rxdata1,
  input  rxdata2,
  input  rxdata3,
  input  rxdata4,
  input  rxdata5,
  input  rxdata6,
  input  rxdata7,
  input  rxtrk,
  input  rxvld,
  input  rxclksb,
  input  rxdatasb,
  output txclksb,
  output txdatasb,
  output atest0,
  input  rref,
  output scl,
  inout  sda,
  input  [31:0] apb_s_paddr,
  input  apb_s_pclk,
  output apb_s_pcs_irq,
  input  apb_s_penable,
  output [31:0] apb_s_prdata,
  output apb_s_pready,
  input  apb_s_presetn,
  input  apb_s_psel,
  output apb_s_pslverr,
  input  [3:0] apb_s_pstrb,
  input  [31:0] apb_s_pwdata,
  input  apb_s_pwrite,
  output [31:0] apb_m_paddr,
  input  apb_m_pclk,
  input  apb_m_pcs_irq,
  output apb_m_penable,
  input  [31:0] apb_m_prdata,
  input  apb_m_pready,
  input  apb_m_presetn,
  output apb_m_psel,
  input  apb_m_pslverr,
  output [3:0] apb_m_pstrb,
  output [31:0] apb_m_pwdata,
  output apb_m_pwrite,
  input  [7:0] lp_cfg,
  input  lp_cfg_crd,
  input  lp_cfg_vld,
  input  lp_clk_ack,
  input  [255:0] lp_data,
  input  lp_irdy,
  input  lp_linkerror,
  input  lp_retimer_crd,
  input  lp_stallack,
  input  [3:0] lp_state_req,
  input  lp_valid,
  input  lp_wake_req,
  output pl_cerror,
  output [7:0] pl_cfg,
  output pl_cfg_crd,
  output pl_cfg_vld,
  output pl_clk_req,
  output [255:0] pl_data,
  output pl_error,
  output pl_inband_pres,
  output [2:0] pl_lnk_cfg,
  output pl_max_speedmode,
  output pl_nferror,
  output pl_phyinrecenter,
  output pl_retimer_crd,
  output [2:0] pl_speedmode,
  output pl_stallreq,
  output [3:0] pl_state_sts,
  output pl_trainerror,
  output pl_trdy,
  output pl_valid,
  output pl_wake_ack,
  inout  NC0,
  inout  NC1,
  inout  NC2,
  inout  NC3,
  inout  NC4,
  inout  NC5,
  inout  NC6,
  inout  NC7,
  inout  NC8,
  inout  NC9
`ifdef PG_PINS
  ,inout  VSS
  ,inout  VCCIO
  ,inout  vde
  ,inout  VDDQ
`endif
);

  ////////////////
  // Parameters //
  ////////////////

  localparam int unsigned RdiWidth = 256;
  localparam int unsigned NumLanes = 8;
  localparam int unsigned LaneBits = RdiWidth / NumLanes;
  localparam int unsigned CntWidth = $clog2(LaneBits);  // bit counter per word

  localparam logic [3:0] RdiReset  = 4'h0;
  localparam logic [3:0] RdiActive = 4'h1;

  typedef logic [RdiWidth-1:0]               word_t;
  typedef logic [NumLanes-1:0][LaneBits-1:0] lanes_t;

  /////////////
  // Link-up //
  /////////////

  logic req_q, peer_req, link_active;

  // Local side out of reset

  always_ff @(posedge rdi_clk or negedge rst_async_n) begin
    if (!rst_async_n) req_q <= 1'b0;
    else              req_q <= 1'b1;
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

  assign link_active    = req_q & peer_req;
  assign pl_state_sts   = link_active ? RdiActive : RdiReset;
  assign pl_inband_pres = peer_req;
  assign pl_wake_ack    = lp_wake_req;

  assign txtrk = req_q;

  ////////////
  // Clocks //
  ////////////

  // Mainband clock forwarded to the peer; the RX side runs on the peer's
  assign txckp            = rdi_clk;
  assign clk_1G_UCIe_tx_o = rdi_clk;
  assign clk_1G_UCIe_rx_o = rxckp;

  tc_clk_inverter i_txckn (
    .clk_i(rdi_clk),
    .clk_o(txckn)
  );

  // Sideband: clocks pass through, no sideband data
  assign txclksb          = refclk;
  assign txdatasb         = 1'b0;
  assign sb_tx_clk_100MHz = refclk;
  assign sb_rx_clk_100MHz = rxclksb;

  ////////
  // TX //
  ////////

  // One shift register per lane: a word takes LaneBits cycles to send
  lanes_t              tx_shift_q;
  logic                tx_busy_q;
  logic [CntWidth-1:0] tx_cnt_q;
  logic                tx_last, tx_fire;
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
  assign txvld = tx_busy_q;

  ////////
  // RX //
  ////////

  logic [NumLanes-1:0] rxdata;
  lanes_t              rx_shift_q, rx_shift_d;
  logic [CntWidth-1:0] rx_cnt_q;
  logic                rx_last;
  word_t               rx_word_q;
  logic                rx_push_q;

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
    .src_ready_o(  ),
    .dst_rst_ni (rst_async_n),
    .dst_clk_i  (rdi_clk),
    .dst_data_o (pl_data),
    .dst_valid_o(pl_valid),
    .dst_ready_i(1'b1)
  );

  //////////////
  // Tie-offs //
  //////////////

  // RDI handshakes, errors, config and retimer interfaces
  assign pl_clk_req       = 1'b0;
  assign pl_stallreq      = 1'b0;
  assign pl_error         = 1'b0;
  assign pl_cerror        = 1'b0;
  assign pl_nferror       = 1'b0;
  assign pl_trainerror    = 1'b0;
  assign pl_phyinrecenter = 1'b0;
  assign pl_speedmode     = '0;
  assign pl_max_speedmode = 1'b0;
  assign pl_lnk_cfg       = '0;
  assign pl_cfg           = '0;
  assign pl_cfg_vld       = 1'b0;
  assign pl_cfg_crd       = 1'b0;
  assign pl_retimer_crd   = 1'b0;

  // APB slave: no registers, reads return 0
  assign apb_s_pready  = 1'b1;
  assign apb_s_prdata  = '0;
  assign apb_s_pslverr = 1'b0;
  assign apb_s_pcs_irq = 1'b0;

  // APB master: idle
  assign apb_m_paddr   = '0;
  assign apb_m_psel    = 1'b0;
  assign apb_m_penable = 1'b0;
  assign apb_m_pwrite  = 1'b0;
  assign apb_m_pwdata  = '0;
  assign apb_m_pstrb   = '0;

  // Analog test and I3C pins
  assign atest0 = 1'bz;
  assign scl    = 1'b1;
  assign sda    = 1'bz;

endmodule : ucie_macro_wrap
