// -----------------------------------------------------------------------------
// rate_limiter.sv - cut-through, fixed-latency TOKEN-BUCKET ORDER-RATE LIMITER
//                   ("exchange gateway throttle").
//
// Every exchange caps the rate at which a member firm may submit orders/messages
// (an orders-per-second / messages-per-window ceiling). Breaching it earns
// throttling, fines, or a disconnect, so the OUTBOUND path of an FPGA trading
// gateway must police its own send rate BEFORE a message leaves the wire - and it
// must do so at line rate without adding jitter. The textbook mechanism is a
// TOKEN BUCKET: tokens accrue at a fixed average rate up to a burst capacity
// BUCKET_MAX; each order admitted spends `cost` tokens; an order that cannot be
// paid for is THROTTLED (rejected / back-pressured) rather than sent. The bucket
// gives a firm a sustained rate REFILL_PER_TICK tokens/tick while still allowing
// a short burst up to the bucket depth.
//
// This DUT is a LAZY-REFILL token bucket: instead of a free-running refill timer,
// each request carries the current TIMESTAMP `ts` (a monotonically non-decreasing
// tick / microsecond counter). On each request the bucket first accrues the
// tokens earned since the previous request - elapsed = ts - last_ts, refill =
// elapsed * REFILL_PER_TICK, saturated at BUCKET_MAX - then the order is judged
// against the refilled level. This is exactly how a production software/hardware
// token bucket avoids a per-cycle adder, AND it makes the admission decision a
// PURE FUNCTION of the {ts, cost} request stream (independent of how many idle
// clock cycles the simulator inserts between requests) - which is what lets an
// independent golden model check the block transaction-by-transaction.
//
// Against the refilled available level `avail` the block emits, in STRICT
// PRIORITY, one of four reason codes and the grant flag:
//
//   0 GRANT     : cost in [1..BUCKET_MAX] and avail >= cost -> admit the order,
//                 spend the tokens (tokens := avail - cost).
//   1 THROTTLE  : cost in [1..BUCKET_MAX] but avail < cost  -> deny (rate
//                 exceeded); no tokens spent (tokens := avail).
//   2 ZEROCOST  : cost == 0 -> malformed request, reject; tokens := avail.
//   3 OVERSIZED : cost > BUCKET_MAX -> can NEVER be satisfied by this bucket;
//                 reject deterministically; tokens := avail.
//
// out_grant is high only on GRANT (reason 0). On every accepted request (any
// reason) the bucket absorbs the accrued refill (tokens := avail on a non-grant,
// avail-cost on a grant) and last_ts advances to this request's ts.
//
// STATE: {tokens, last_ts}. Because the decision depends on it and it can change
// every cycle, the refill + compare + update are done in the FIRST
// (combinational-then-registered) stage so back-to-back (zero-bubble) requests
// always see the up-to-date bucket; the decision and echoed request are then
// carried through PIPE further register stages purely for fixed latency / timing
// closure (LAT = PIPE + 1).
//
// Configuration: a cfg_load pulse resets the bucket to FULL (tokens := BUCKET_MAX)
// and sets last_ts := cfg_init_ts (session start-of-day). Hardware reset defaults
// tokens := BUCKET_MAX, last_ts := 0.
//
// The design is parameterized, reset-safe, fully registered, and lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module rate_limiter #(
    parameter int TSW            = 32,   // timestamp / tick width
    parameter int TOKW           = 16,   // token-count width
    parameter int COSTW          = 8,    // per-request cost width
    parameter int BUCKET_MAX     = 8,    // burst capacity (bucket depth)
    parameter int REFILL_PER_TICK= 1,    // tokens accrued per elapsed tick
    parameter int PIPE           = 2,    // extra echo/latency stages (LAT=PIPE+1)
    // derived (do not override)
    parameter int RSNW           = 2     // reason-code width (holds 0..3)
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---- session configuration (latched on cfg_load) ----
    input  logic              cfg_load,
    input  logic [TSW-1:0]    cfg_init_ts,     // session start timestamp

    // ---- inbound order/request stream (one per cycle, zero-bubble capable) ----
    input  logic              in_valid,
    input  logic [TSW-1:0]    in_ts,           // request timestamp (non-decreasing)
    input  logic [COSTW-1:0]  in_cost,         // tokens this order needs

    // ---- decision out (fixed latency LAT = PIPE+1) ----
    output logic              out_valid,
    output logic              out_grant,       // 1 = admit (reason 0 only)
    output logic [RSNW-1:0]   out_reason,      // 0 GRANT,1 THROTTLE,2 ZEROCOST,3 OVERSIZED
    output logic [TSW-1:0]    out_ts,          // echoed request timestamp
    output logic [COSTW-1:0]  out_cost,        // echoed request cost
    output logic [TOKW-1:0]   out_avail,       // tokens available AFTER refill (pre-spend)
    output logic [TOKW-1:0]   out_tokens       // tokens remaining AFTER this request
);

    localparam int LAT = PIPE + 1;

    // reason codes
    localparam logic [RSNW-1:0] R_GRANT   = 2'd0;
    localparam logic [RSNW-1:0] R_THROT   = 2'd1;
    localparam logic [RSNW-1:0] R_ZERO    = 2'd2;
    localparam logic [RSNW-1:0] R_OVER    = 2'd3;

    // -------------------------------------------------------------------------
    // Bucket state: current tokens + timestamp of the last accepted request.
    // -------------------------------------------------------------------------
    logic [TOKW-1:0] tokens_q;
    logic [TSW-1:0]  last_ts_q;

    // -------------------------------------------------------------------------
    // Combinational lazy refill + admission decision for the request this cycle.
    // -------------------------------------------------------------------------
    logic [TSW-1:0]  elapsed_c;
    logic [63:0]     refill_c;         // generous width; saturates below anyway
    logic [63:0]     avail_wide_c;
    logic [TOKW-1:0] avail_c;

    logic            zero_c, over_c, insuff_c, grant_c;
    logic [RSNW-1:0] reason_c;
    logic [TOKW-1:0] tokens_next_c;

    always_comb begin
        // ---- accrue tokens earned since the previous request (lazy refill) ----
        elapsed_c    = (in_ts >= last_ts_q) ? (in_ts - last_ts_q) : '0;
        refill_c     = elapsed_c * REFILL_PER_TICK;
        avail_wide_c = {{(64-TOKW){1'b0}}, tokens_q} + refill_c;
        if (avail_wide_c > BUCKET_MAX) avail_c = BUCKET_MAX[TOKW-1:0];
        else                           avail_c = avail_wide_c[TOKW-1:0];

        // ---- classify (strict priority) ----
        zero_c   = (in_cost == '0);
        over_c   = ({{(TOKW-COSTW){1'b0}}, in_cost} > BUCKET_MAX[TOKW-1:0]);
        insuff_c = (avail_c < {{(TOKW-COSTW){1'b0}}, in_cost});

        if (zero_c) begin
            reason_c = R_ZERO;  grant_c = 1'b0; tokens_next_c = avail_c;
        end else if (over_c) begin
            reason_c = R_OVER;  grant_c = 1'b0; tokens_next_c = avail_c;
        end else if (insuff_c) begin
            reason_c = R_THROT; grant_c = 1'b0; tokens_next_c = avail_c;
        end else begin
            reason_c = R_GRANT; grant_c = 1'b1;
            tokens_next_c = avail_c - {{(TOKW-COSTW){1'b0}}, in_cost};
        end
    end

    // -------------------------------------------------------------------------
    // Stage 0 : register the decision + echoed request, update bucket state.
    // -------------------------------------------------------------------------
    logic            s0_valid, s0_grant;
    logic [RSNW-1:0] s0_reason;
    logic [TSW-1:0]  s0_ts;
    logic [COSTW-1:0]s0_cost;
    logic [TOKW-1:0] s0_avail, s0_tokens;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tokens_q  <= BUCKET_MAX[TOKW-1:0];
            last_ts_q <= '0;
            s0_valid  <= 1'b0;
            s0_grant  <= 1'b0;
            s0_reason <= R_GRANT;
            s0_ts     <= '0;
            s0_cost   <= '0;
            s0_avail  <= '0;
            s0_tokens <= BUCKET_MAX[TOKW-1:0];
        end else begin
            if (cfg_load) begin
                // session (re)start: refill the bucket, anchor the clock
                tokens_q  <= BUCKET_MAX[TOKW-1:0];
                last_ts_q <= cfg_init_ts;
            end else if (in_valid) begin
                tokens_q  <= tokens_next_c;   // absorb refill / spend on any request
                last_ts_q <= in_ts;           // advance the bucket clock
            end
            s0_valid  <= in_valid;
            s0_grant  <= grant_c;
            s0_reason <= reason_c;
            s0_ts     <= in_ts;
            s0_cost   <= in_cost;
            s0_avail  <= avail_c;
            s0_tokens <= tokens_next_c;
        end
    end

    // -------------------------------------------------------------------------
    // Stages 1..PIPE : pure delay line carrying the decision to fixed latency.
    // -------------------------------------------------------------------------
    generate
        if (PIPE == 0) begin : g_no_pipe
            assign out_valid  = s0_valid;
            assign out_grant  = s0_grant;
            assign out_reason = s0_reason;
            assign out_ts     = s0_ts;
            assign out_cost   = s0_cost;
            assign out_avail  = s0_avail;
            assign out_tokens = s0_tokens;
        end else begin : g_pipe
            logic            v  [1:PIPE];
            logic            gr [1:PIPE];
            logic [RSNW-1:0] rs [1:PIPE];
            logic [TSW-1:0]  ts [1:PIPE];
            logic [COSTW-1:0]co [1:PIPE];
            logic [TOKW-1:0] av [1:PIPE];
            logic [TOKW-1:0] tk [1:PIPE];

            integer k;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (k = 1; k <= PIPE; k = k + 1) begin
                        v[k]  <= 1'b0;  gr[k] <= 1'b0;  rs[k] <= R_GRANT;
                        ts[k] <= '0;    co[k] <= '0;    av[k] <= '0;  tk[k] <= '0;
                    end
                end else begin
                    v[1]  <= s0_valid;  gr[1] <= s0_grant;  rs[1] <= s0_reason;
                    ts[1] <= s0_ts;     co[1] <= s0_cost;   av[1] <= s0_avail;
                    tk[1] <= s0_tokens;
                    for (k = 2; k <= PIPE; k = k + 1) begin
                        v[k]  <= v[k-1];  gr[k] <= gr[k-1]; rs[k] <= rs[k-1];
                        ts[k] <= ts[k-1]; co[k] <= co[k-1]; av[k] <= av[k-1];
                        tk[k] <= tk[k-1];
                    end
                end
            end

            assign out_valid  = v[PIPE];
            assign out_grant  = gr[PIPE];
            assign out_reason = rs[PIPE];
            assign out_ts     = ts[PIPE];
            assign out_cost   = co[PIPE];
            assign out_avail  = av[PIPE];
            assign out_tokens = tk[PIPE];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+RL_SVA)
    // ------------------------------------------------------------------------
`ifdef RL_SVA
    // Fixed pipeline latency: a valid request produces a decision exactly LAT later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // Reason code is always a legal value 0..3.
    a_reason_range: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_reason <= R_OVER));

    // out_grant is asserted exactly when the reason is GRANT.
    a_grant_iff: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_grant == (out_reason == R_GRANT)));

    // The remaining tokens never exceed the bucket depth (no over-refill).
    a_tokens_bound: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_tokens <= BUCKET_MAX[TOKW-1:0]));

    // On a grant the bucket must have held at least the cost that was spent.
    a_grant_paid: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_grant) |->
            (out_avail >= {{(TOKW-COSTW){1'b0}}, out_cost}));

    // Timestamps presented to the block are monotonically non-decreasing.
    a_ts_monotonic: assert property (@(posedge clk) disable iff (!rst_n)
        (in_valid ##1 in_valid) |-> ($past(in_ts) <= in_ts));

    // Decision / echoed request / state are always known while presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_grant, out_reason, out_ts, out_cost,
                                   out_avail, out_tokens}));
`endif

endmodule

`default_nettype wire
