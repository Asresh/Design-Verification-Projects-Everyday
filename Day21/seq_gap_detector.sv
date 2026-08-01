// -----------------------------------------------------------------------------
// seq_gap_detector.sv - cut-through, fixed-latency MARKET-DATA SEQUENCE GAP
//                       DETECTOR & DUPLICATE SUPPRESSOR (feed-handler front end).
//
// This is the FIRST block a market-data message crosses inside a hardware (FPGA)
// feed handler / ticker plant, and one of the most latency-critical elements in
// the whole ingest path. Exchanges publish an identical, monotonically-numbered
// message stream on TWO redundant multicast feeds (the "A" and "B" lines) so a
// dropped UDP datagram on one line can be recovered from the other. Downstream
// order-book logic must see each sequence number EXACTLY ONCE, IN ORDER, and must
// be told the instant a message is MISSING FROM BOTH lines (a real gap) so a
// retransmit / recovery request can be fired. Doing that arbitration and gap
// bookkeeping in software cannot keep up at line rate; the hardware answer is a
// flat, fully-registered, cut-through sanitizer that accepts a brand-new message
// EVERY cycle (zero-bubble) and emits its decision LAT cycles later.
//
// Each inbound message carries {seq, data}. Against the running NEXT-EXPECTED
// sequence number the block emits one of three actions:
//
//   0 PASS : seq == expected -> the next in-order message. FORWARD it downstream
//            and advance expected := seq + 1.
//   1 DUP  : seq <  expected -> a duplicate (the B-line copy of a seq already
//            forwarded) or a stale late retransmit. DROP it; expected unchanged.
//   2 GAP  : seq >  expected -> one or more sequence numbers are missing. Report
//            gap = seq - expected (the count of missing messages, for the
//            retransmit request), then FORWARD this message and RESYNC
//            expected := seq + 1. (This is a detector/sanitizer, not a reorder
//            buffer: it flags the loss and keeps the stream moving at line rate.)
//
// out_fwd is high on PASS and GAP (a message goes downstream) and low on DUP.
//
// STATE: the running next-expected sequence number. It advances only on a
// forwarded message (PASS or GAP) and is frozen on a duplicate. Because the
// decision depends on it and it can change every cycle, the compare + update are
// done in the FIRST (combinational-then-registered) stage so back-to-back
// messages always see the up-to-date value; the decision and the echoed message
// are then carried through PIPE further register stages purely for fixed latency
// / timing closure (LAT = PIPE + 1).
//
// Configuration: a cfg_load pulse latches cfg_init_seq, the first expected
// sequence number of the session (e.g. the start-of-day / session-reset seq).
// Reset defaults expected to 0.
//
// The design is parameterized, reset-safe, fully registered, and lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module seq_gap_detector #(
    parameter int SEQW = 32,          // sequence-number width
    parameter int DW   = 64,          // message payload width
    parameter int PIPE = 2,           // extra echo/latency stages (LAT = PIPE+1)
    // derived (do not override)
    parameter int ACTW = 2            // action-code width (holds 0..2)
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---- session configuration (latched on cfg_load) ----
    input  logic              cfg_load,
    input  logic [SEQW-1:0]   cfg_init_seq,       // first expected seq of session

    // ---- inbound message stream (one message per cycle, zero-bubble capable) --
    input  logic              in_valid,
    input  logic [SEQW-1:0]   in_seq,
    input  logic [DW-1:0]     in_data,

    // ---- decision out (fixed latency LAT = PIPE+1) ----
    output logic              out_valid,
    output logic              out_fwd,            // 1 = forward downstream (PASS/GAP)
    output logic [ACTW-1:0]   out_action,         // 0 PASS, 1 DUP, 2 GAP
    output logic [SEQW-1:0]   out_seq,            // echoed message sequence
    output logic [DW-1:0]     out_data,           // echoed payload (valid on out_fwd)
    output logic [SEQW-1:0]   out_gap,            // # missing seqs (0 unless GAP)
    output logic [SEQW-1:0]   out_expected        // next-expected AFTER this message
);

    localparam int LAT = PIPE + 1;

    // action codes
    localparam logic [ACTW-1:0] A_PASS = 2'd0;
    localparam logic [ACTW-1:0] A_DUP  = 2'd1;
    localparam logic [ACTW-1:0] A_GAP  = 2'd2;

    // -------------------------------------------------------------------------
    // Running next-expected sequence number. Advances only on a forwarded
    // message (PASS or GAP); frozen on a duplicate.
    // -------------------------------------------------------------------------
    logic [SEQW-1:0] expected_q;

    // -------------------------------------------------------------------------
    // Combinational decision for the message presented this cycle.
    // -------------------------------------------------------------------------
    logic            is_pass, is_gap, is_dup, fwd_c;
    logic [ACTW-1:0] action_c;
    logic [SEQW-1:0] gap_c;
    logic [SEQW-1:0] expected_next_c;

    always_comb begin
        is_pass = (in_seq == expected_q);
        is_gap  = (in_seq >  expected_q);
        is_dup  = (in_seq <  expected_q);

        // gap = number of missing sequence numbers (only meaningful on GAP)
        gap_c   = is_gap ? (in_seq - expected_q) : '0;

        if      (is_pass) action_c = A_PASS;
        else if (is_gap)  action_c = A_GAP;
        else              action_c = A_DUP;

        fwd_c = !is_dup;                         // forward on PASS or GAP

        // next-expected: resync to seq+1 on a forwarded message, hold on a dup
        expected_next_c = is_dup ? expected_q : (in_seq + {{(SEQW-1){1'b0}}, 1'b1});
    end

    // -------------------------------------------------------------------------
    // Stage 0 : register the decision + echoed message, advance expected.
    // -------------------------------------------------------------------------
    logic            s0_valid, s0_fwd;
    logic [ACTW-1:0] s0_action;
    logic [SEQW-1:0] s0_seq, s0_gap, s0_expected;
    logic [DW-1:0]   s0_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expected_q  <= '0;
            s0_valid    <= 1'b0;
            s0_fwd      <= 1'b0;
            s0_action   <= A_PASS;
            s0_seq      <= '0;
            s0_data     <= '0;
            s0_gap      <= '0;
            s0_expected <= '0;
        end else begin
            if (cfg_load) begin
                // session (re)start: program the first expected sequence number
                expected_q <= cfg_init_seq;
            end else if (in_valid && fwd_c) begin
                expected_q <= expected_next_c;   // advance only on a forward
            end
            s0_valid    <= in_valid;
            s0_fwd      <= fwd_c;
            s0_action   <= action_c;
            s0_seq      <= in_seq;
            s0_data     <= in_data;
            s0_gap      <= gap_c;
            s0_expected <= expected_next_c;      // expected AFTER this message
        end
    end

    // -------------------------------------------------------------------------
    // Stages 1..PIPE : pure delay line carrying the decision to a fixed latency.
    // -------------------------------------------------------------------------
    generate
        if (PIPE == 0) begin : g_no_pipe
            assign out_valid    = s0_valid;
            assign out_fwd      = s0_fwd;
            assign out_action   = s0_action;
            assign out_seq      = s0_seq;
            assign out_data     = s0_data;
            assign out_gap      = s0_gap;
            assign out_expected = s0_expected;
        end else begin : g_pipe
            logic            v  [1:PIPE];
            logic            fw [1:PIPE];
            logic [ACTW-1:0] ac [1:PIPE];
            logic [SEQW-1:0] sq [1:PIPE];
            logic [DW-1:0]   da [1:PIPE];
            logic [SEQW-1:0] gp [1:PIPE];
            logic [SEQW-1:0] ex [1:PIPE];

            integer k;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (k = 1; k <= PIPE; k = k + 1) begin
                        v[k]  <= 1'b0;  fw[k] <= 1'b0; ac[k] <= A_PASS;
                        sq[k] <= '0;    da[k] <= '0;   gp[k] <= '0;  ex[k] <= '0;
                    end
                end else begin
                    v[1]  <= s0_valid;  fw[1] <= s0_fwd;    ac[1] <= s0_action;
                    sq[1] <= s0_seq;    da[1] <= s0_data;   gp[1] <= s0_gap;
                    ex[1] <= s0_expected;
                    for (k = 2; k <= PIPE; k = k + 1) begin
                        v[k]  <= v[k-1];  fw[k] <= fw[k-1]; ac[k] <= ac[k-1];
                        sq[k] <= sq[k-1]; da[k] <= da[k-1]; gp[k] <= gp[k-1];
                        ex[k] <= ex[k-1];
                    end
                end
            end

            assign out_valid    = v[PIPE];
            assign out_fwd      = fw[PIPE];
            assign out_action   = ac[PIPE];
            assign out_seq      = sq[PIPE];
            assign out_data     = da[PIPE];
            assign out_gap      = gp[PIPE];
            assign out_expected = ex[PIPE];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+SGD_SVA)
    // ------------------------------------------------------------------------
`ifdef SGD_SVA
    // Fixed pipeline latency: a valid message produces a decision exactly LAT later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // Action code is always a legal value 0..2.
    a_action_range: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_action <= A_GAP));

    // out_fwd is asserted exactly when the action is not a duplicate.
    a_fwd_action: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (out_fwd == (out_action != A_DUP)));

    // A non-zero gap count appears exactly on a GAP action (and only then).
    a_gap_iff: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> ((out_gap != 0) == (out_action == A_GAP)));

    // Decision / echoed message / state are always known while presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_fwd, out_action, out_seq,
                                   out_gap, out_expected}));
`endif

endmodule

`default_nettype wire
