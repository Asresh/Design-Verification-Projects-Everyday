// -----------------------------------------------------------------------------
// risk_gate.sv - fully-pipelined, fixed-latency PRE-TRADE RISK CHECK GATE
//                (the "fat-finger" / order-validation gateway).
//
// This is the single first block an order crosses in a hardware (FPGA) trading
// gateway, and the most latency-critical safety element in the whole path: every
// outbound order must be validated against the firm's risk limits BEFORE it is
// allowed onto the wire to the exchange, and that decision has to be made at line
// rate - one order per clock, with a small, FIXED, deterministic latency, or the
// gate becomes the bottleneck the whole business was built to avoid. A software
// branch-heavy validator cannot meet that budget; the hardware answer is a flat,
// fully-registered check datapath that accepts a brand-new order EVERY cycle
// (zero-bubble) and emits the accept/reject verdict LAT cycles later.
//
// Each order carries {side (buy/sell), price, qty}. The gate applies, in strict
// priority order, the classic pre-trade checks and reports the HIGHEST-priority
// rule that fired as a compact reason code (0 = order accepted):
//
//   1 QTY_ZERO     : qty == 0                       (malformed / no-op order)
//   2 QTY_MAX      : qty > cfg_max_qty              (fat-finger size)
//   3 PRICE_BAND   : price < cfg_min_price ||       (price collar / away-market
//                    price > cfg_max_price           protection)
//   4 NOTIONAL_MAX : price*qty > cfg_max_notional   (fat-finger notional value)
//   5 POS_LIMIT    : |position after this order| >  (net inventory / exposure
//                    cfg_pos_limit                    limit)
//
// STATE: the gate maintains the running NET POSITION (signed): an ACCEPTED buy
// adds qty, an ACCEPTED sell subtracts qty; a rejected order never moves the
// book. The position check is evaluated against the PROJECTED position, so an
// order that would breach the inventory limit is blocked. Because that check
// depends on the current position and the position only advances on an accept,
// the decision + position update are computed in the FIRST (combinational-then-
// registered) stage, so back-to-back orders always see the up-to-date position;
// the verdict and the echoed order are then carried through PIPE further register
// stages purely for fixed latency / timing closure (LAT = PIPE + 1).
//
// Configuration (cfg_load pulse latches the limits into hold registers; limits
// are slow-changing risk parameters set by software and held stable during a
// trading burst). Reset opens the gate wide (max-permissive limits, flat book).
//
// The design is parameterized, reset-safe, fully registered, and lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module risk_gate #(
    parameter int PW   = 16,          // price width (unsigned ticks)
    parameter int QW   = 16,          // quantity width (unsigned)
    parameter int POSW = 32,          // signed net-position accumulator width
    parameter int PIPE = 2,           // extra echo/latency stages (LAT = PIPE+1)
    // derived (do not override)
    parameter int NW   = PW + QW,     // notional width (price*qty)
    parameter int RW   = 3            // reason-code width (holds 0..5)
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---- risk-limit configuration (latched on cfg_load) ----
    input  logic                cfg_load,
    input  logic [QW-1:0]       cfg_max_qty,
    input  logic [PW-1:0]       cfg_min_price,
    input  logic [PW-1:0]       cfg_max_price,
    input  logic [NW-1:0]       cfg_max_notional,
    input  logic [POSW-1:0]     cfg_pos_limit,      // magnitude ceiling for |pos|

    // ---- order stream in (one order per cycle, zero-bubble capable) ----
    input  logic                in_valid,
    input  logic                in_side,            // 0 = buy, 1 = sell
    input  logic [PW-1:0]       in_price,
    input  logic [QW-1:0]       in_qty,

    // ---- verdict out (fixed latency LAT = PIPE+1) ----
    output logic                out_valid,
    output logic                out_accept,         // 1 = passed all checks
    output logic [RW-1:0]       out_reason,         // 0 = accept, else 1..5
    output logic                out_side,           // echoed order (observability)
    output logic [PW-1:0]       out_price,
    output logic [QW-1:0]       out_qty,
    output logic signed [POSW-1:0] out_pos          // net position AFTER this order
);

    localparam int LAT = PIPE + 1;

    // reason codes
    localparam logic [RW-1:0] R_OK       = 3'd0;
    localparam logic [RW-1:0] R_QTY_ZERO = 3'd1;
    localparam logic [RW-1:0] R_QTY_MAX  = 3'd2;
    localparam logic [RW-1:0] R_BAND     = 3'd3;
    localparam logic [RW-1:0] R_NOTIONAL = 3'd4;
    localparam logic [RW-1:0] R_POSLIM   = 3'd5;

    // -------------------------------------------------------------------------
    // Configuration hold registers. Reset opens the gate wide so nothing is
    // spuriously blocked before software has programmed the limits.
    // -------------------------------------------------------------------------
    logic [QW-1:0]   lim_max_qty;
    logic [PW-1:0]   lim_min_price;
    logic [PW-1:0]   lim_max_price;
    logic [NW-1:0]   lim_max_notional;
    logic [POSW-1:0] lim_pos_limit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lim_max_qty      <= {QW{1'b1}};
            lim_min_price    <= '0;
            lim_max_price    <= {PW{1'b1}};
            lim_max_notional <= {NW{1'b1}};
            lim_pos_limit    <= {POSW{1'b1}};
        end else if (cfg_load) begin
            lim_max_qty      <= cfg_max_qty;
            lim_min_price    <= cfg_min_price;
            lim_max_price    <= cfg_max_price;
            lim_max_notional <= cfg_max_notional;
            lim_pos_limit    <= cfg_pos_limit;
        end
    end

    // -------------------------------------------------------------------------
    // Running net position (signed). Advances ONLY on an accepted valid order.
    // -------------------------------------------------------------------------
    logic signed [POSW-1:0] pos_q;

    // -------------------------------------------------------------------------
    // Combinational check datapath for the order presented this cycle.
    // Wider signed intermediates avoid negation / add overflow.
    // -------------------------------------------------------------------------
    logic [NW-1:0]            notional_c;
    logic signed [POSW+1:0]   pos_ext, delta, proj, plim;
    logic                     c_qty_zero, c_qty_max, c_band, c_notl, c_poslim;
    logic                     accept_c;
    logic [RW-1:0]            reason_c;
    logic signed [POSW-1:0]   pos_next_c;

    always_comb begin
        notional_c = in_price * in_qty;                         // PW+QW = NW bits

        pos_ext = pos_q;                                        // signed sign-extend
        delta   = in_side ? -$signed({2'b00, in_qty})           // sell : -qty
                          :  $signed({2'b00, in_qty});          // buy  : +qty
        proj    = pos_ext + delta;                              // projected position
        plim    = $signed({2'b00, lim_pos_limit});              // +limit (unsigned->signed)

        c_qty_zero = (in_qty == '0);
        c_qty_max  = (in_qty > lim_max_qty);
        c_band     = (in_price < lim_min_price) || (in_price > lim_max_price);
        c_notl     = (notional_c > lim_max_notional);
        c_poslim   = (proj > plim) || (proj < -plim);           // |proj| > limit

        // strict-priority reason encode (lowest number = highest priority)
        if      (c_qty_zero) reason_c = R_QTY_ZERO;
        else if (c_qty_max)  reason_c = R_QTY_MAX;
        else if (c_band)     reason_c = R_BAND;
        else if (c_notl)     reason_c = R_NOTIONAL;
        else if (c_poslim)   reason_c = R_POSLIM;
        else                 reason_c = R_OK;

        accept_c   = (reason_c == R_OK);
        // position after this order: advances only on an accept, else unchanged
        // (proj is bounded by +/-pos_limit on accept, so the truncation to POSW
        //  bits is lossless)
        pos_next_c = accept_c ? proj : pos_q;
    end

    // -------------------------------------------------------------------------
    // Stage 0 : register the verdict + echoed order, advance the position.
    // -------------------------------------------------------------------------
    logic                   s0_valid, s0_accept, s0_side;
    logic [RW-1:0]          s0_reason;
    logic [PW-1:0]          s0_price;
    logic [QW-1:0]          s0_qty;
    logic signed [POSW-1:0] s0_pos;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_q     <= '0;
            s0_valid  <= 1'b0;
            s0_accept <= 1'b0;
            s0_reason <= R_OK;
            s0_side   <= 1'b0;
            s0_price  <= '0;
            s0_qty    <= '0;
            s0_pos    <= '0;
        end else begin
            if (in_valid && accept_c) pos_q <= pos_next_c;      // book moves on accept
            s0_valid  <= in_valid;
            s0_accept <= accept_c;
            s0_reason <= reason_c;
            s0_side   <= in_side;
            s0_price  <= in_price;
            s0_qty    <= in_qty;
            s0_pos    <= pos_next_c;                            // position after order
        end
    end

    // -------------------------------------------------------------------------
    // Stages 1..PIPE : pure delay line carrying the verdict to a fixed latency.
    // -------------------------------------------------------------------------
    generate
        if (PIPE == 0) begin : g_no_pipe
            assign out_valid  = s0_valid;
            assign out_accept = s0_accept;
            assign out_reason = s0_reason;
            assign out_side   = s0_side;
            assign out_price  = s0_price;
            assign out_qty    = s0_qty;
            assign out_pos    = s0_pos;
        end else begin : g_pipe
            logic                   v  [1:PIPE];
            logic                   ac [1:PIPE];
            logic [RW-1:0]          rs [1:PIPE];
            logic                   sd [1:PIPE];
            logic [PW-1:0]          pr [1:PIPE];
            logic [QW-1:0]          qt [1:PIPE];
            logic signed [POSW-1:0] po [1:PIPE];

            integer k;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (k = 1; k <= PIPE; k = k + 1) begin
                        v[k]  <= 1'b0;  ac[k] <= 1'b0; rs[k] <= R_OK;
                        sd[k] <= 1'b0;  pr[k] <= '0;   qt[k] <= '0;  po[k] <= '0;
                    end
                end else begin
                    v[1]  <= s0_valid;  ac[1] <= s0_accept; rs[1] <= s0_reason;
                    sd[1] <= s0_side;   pr[1] <= s0_price;  qt[1] <= s0_qty;
                    po[1] <= s0_pos;
                    for (k = 2; k <= PIPE; k = k + 1) begin
                        v[k]  <= v[k-1];  ac[k] <= ac[k-1]; rs[k] <= rs[k-1];
                        sd[k] <= sd[k-1]; pr[k] <= pr[k-1]; qt[k] <= qt[k-1];
                        po[k] <= po[k-1];
                    end
                end
            end

            assign out_valid  = v[PIPE];
            assign out_accept = ac[PIPE];
            assign out_reason = rs[PIPE];
            assign out_side   = sd[PIPE];
            assign out_price  = pr[PIPE];
            assign out_qty    = qt[PIPE];
            assign out_pos    = po[PIPE];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+RISK_SVA)
    // ------------------------------------------------------------------------
`ifdef RISK_SVA
    // Fixed pipeline latency: a valid order produces a verdict exactly LAT later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // accept <=> reason 0 (the two verdict encodings never disagree).
    a_accept_reason: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_accept == (out_reason == R_OK)));

    // Reason code is always a legal value 0..5.
    a_reason_range: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_reason <= R_POSLIM));

    // Verdict / echoed order / position are always known while presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_accept, out_reason, out_side,
                                   out_price, out_qty, out_pos}));
`endif

endmodule

`default_nettype wire
