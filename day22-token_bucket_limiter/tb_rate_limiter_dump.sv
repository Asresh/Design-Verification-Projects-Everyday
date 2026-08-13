// -----------------------------------------------------------------------------
// tb_rate_limiter_dump.sv - portable, module-based, SELF-CHECKING testbench for
// the TOKEN-BUCKET ORDER-RATE LIMITER. Runs on open-source Icarus Verilog (which
// does not implement the UVM class library). It:
//
//   * programs the session initial timestamp (init_ts = 0, bucket full = 8),
//   * drives a DIRECTED SHOWCASE - eight BACK-TO-BACK requests (zero-bubble) that
//     walk through every reason code, a burst drain, a same-tick refill=0, a
//     refill-and-recover, and both malformed rejects, so the captured VCD tells
//     the classic throttle story:
//         1 ts=10 cost=3 -> GRANT     avail=8 tokens=5
//         2 ts=10 cost=4 -> GRANT     avail=5 tokens=1
//         3 ts=10 cost=2 -> THROTTLE  avail=1 tokens=1
//         4 ts=10 cost=1 -> GRANT     avail=1 tokens=0
//         5 ts=10 cost=1 -> THROTTLE  avail=0 tokens=0
//         6 ts=13 cost=2 -> GRANT     avail=3 tokens=1   (+3 refill)
//         7 ts=13 cost=0 -> ZEROCOST  avail=1 tokens=1
//         8 ts=20 cost=9 -> OVERSIZED avail=8 tokens=8   (+7 refill sat 8)
//   * runs DIRECTED CORNERS (full saturation, exact-boundary grant, one-over
//     throttle, single-shot full drain, oversized, zerocost, long-idle refill)
//     on the continuous session,
//   * runs a CONSTRAINED-RANDOM regression - a monotonically advancing timestamp
//     with random small inter-arrival gaps and costs squeezed toward the bucket
//     depth - while an independent STATEFUL golden token-bucket reference model
//     computes the decision + running {tokens, last_ts} for each request,
//   * checks every decision against the golden model (grant + reason + echoed
//     ts/cost + available + remaining tokens),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in rate_limiter_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_rate_limiter_dump;

    localparam int TSW             = 32;
    localparam int TOKW            = 16;
    localparam int COSTW           = 8;
    localparam int RSNW            = 2;
    localparam int BUCKET_MAX      = 8;
    localparam int REFILL_PER_TICK = 1;
    localparam int PIPE            = 2;
    localparam int LAT             = PIPE + 1;   // 3-cycle latency

    // reason codes
    localparam int R_GRANT = 0;
    localparam int R_THROT = 1;
    localparam int R_ZERO  = 2;
    localparam int R_OVER  = 3;

    localparam int unsigned INIT_TS = 0;

    logic              clk;
    logic              rst_n;
    logic              cfg_load;
    logic [TSW-1:0]    cfg_init_ts;
    logic              in_valid;
    logic [TSW-1:0]    in_ts;
    logic [COSTW-1:0]  in_cost;
    logic              out_valid;
    logic              out_grant;
    logic [RSNW-1:0]   out_reason;
    logic [TSW-1:0]    out_ts;
    logic [COSTW-1:0]  out_cost;
    logic [TOKW-1:0]   out_avail;
    logic [TOKW-1:0]   out_tokens;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    rate_limiter #(.TSW(TSW), .TOKW(TOKW), .COSTW(COSTW),
                   .BUCKET_MAX(BUCKET_MAX), .REFILL_PER_TICK(REFILL_PER_TICK),
                   .PIPE(PIPE)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cfg_load    (cfg_load),
        .cfg_init_ts (cfg_init_ts),
        .in_valid    (in_valid),
        .in_ts       (in_ts),
        .in_cost     (in_cost),
        .out_valid   (out_valid),
        .out_grant   (out_grant),
        .out_reason  (out_reason),
        .out_ts      (out_ts),
        .out_cost    (out_cost),
        .out_avail   (out_avail),
        .out_tokens  (out_tokens)
    );

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------------------------- golden reference (stateful)
    // Independent re-model: lazy refill + strict-priority admission + running
    // {tokens, last_ts}.
    longint unsigned g_tokens;
    longint unsigned g_last_ts;

    // expected-output FIFO (golden scoreboard)
    integer            ersn_q [$];   // expected reason
    integer            egr_q  [$];   // expected grant flag
    longint unsigned   eav_q  [$];   // expected available (post-refill)
    longint unsigned   etk_q  [$];   // expected remaining tokens
    longint unsigned   ets_q  [$];   // expected echoed ts
    longint unsigned   eco_q  [$];   // expected echoed cost
    string             enm_q  [$];

    // Evaluate one request, push the expected decision, update {tokens,last_ts}.
    task automatic model_push(input logic [TSW-1:0] t, input logic [COSTW-1:0] c,
                              input string nm);
        longint unsigned elapsed, refill, av;
        integer          reason, grant;
        elapsed = (t >= g_last_ts) ? (t - g_last_ts) : 0;
        refill  = elapsed * REFILL_PER_TICK;
        av      = g_tokens + refill;
        if (av > BUCKET_MAX) av = BUCKET_MAX;

        if (c == 0) begin
            reason = R_ZERO;  grant = 0; g_tokens = av;
        end else if (c > BUCKET_MAX) begin
            reason = R_OVER;  grant = 0; g_tokens = av;
        end else if (av < c) begin
            reason = R_THROT; grant = 0; g_tokens = av;
        end else begin
            reason = R_GRANT; grant = 1; g_tokens = av - c;
        end
        g_last_ts = t;

        ersn_q.push_back(reason);
        egr_q .push_back(grant);
        eav_q .push_back(av);
        etk_q .push_back(g_tokens);
        ets_q .push_back(t);
        eco_q .push_back(c);
        enm_q .push_back(nm);
    endtask

    // -------------------------------------------------------- driver task -----
    task automatic drive_req(input logic [TSW-1:0] t, input logic [COSTW-1:0] c,
                             input string nm);
        model_push(t, c, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_ts    <= t;
        in_cost  <= c;
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // back-to-back variant: hold in_valid high across consecutive requests (used
    // for the zero-bubble showcase stream).
    task automatic drive_stream(input logic [TSW-1:0] t, input logic [COSTW-1:0] c,
                                input string nm);
        model_push(t, c, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_ts    <= t;
        in_cost  <= c;
    endtask

    // ------------------------------------------------ scoreboard (monitor) -----
    integer xrsn, xgr; longint unsigned xav, xtk, xts, xco; string xnm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (ersn_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                xrsn = ersn_q.pop_front();
                xgr  = egr_q .pop_front();
                xav  = eav_q .pop_front();
                xtk  = etk_q .pop_front();
                xts  = ets_q .pop_front();
                xco  = eco_q .pop_front();
                xnm  = enm_q .pop_front();
                checks = checks + 1;
                if ((out_ts !== xts[TSW-1:0]) || (out_cost !== xco[COSTW-1:0])) begin
                    errors = errors + 1;
                    $display("[%0t] ECHO MISMATCH (%s): got ts=%0d cost=%0d exp ts=%0d cost=%0d",
                             $time, xnm, out_ts, out_cost, xts, xco);
                end
                if ((int'(out_reason) !== xrsn) || (out_grant !== xgr[0])) begin
                    errors = errors + 1;
                    $display("[%0t] DECISION MISMATCH (%s): got reason=%0d grant=%0d exp reason=%0d grant=%0d",
                             $time, xnm, out_reason, out_grant, xrsn, xgr);
                end
                if (out_avail !== xav[TOKW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] AVAIL MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_avail, xav);
                end
                if (out_tokens !== xtk[TOKW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] TOKENS MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_tokens, xtk);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic [TSW-1:0]   rts;
    integer           gap, sel;
    logic [COSTW-1:0] rc;
    int trials;

    initial begin
        $dumpfile("tb_rate_limiter_dump.vcd");
        $dumpvars(0, tb_rate_limiter_dump);

        cfg_load = 1'b0; cfg_init_ts = '0;
        in_valid = 1'b0; in_ts = '0; in_cost = '0;
        g_tokens = BUCKET_MAX; g_last_ts = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- program the session initial timestamp (bucket -> full) ----
        cfg_load    <= 1'b1;
        cfg_init_ts <= INIT_TS[TSW-1:0];
        @(posedge clk);
        cfg_load <= 1'b0;
        g_tokens = BUCKET_MAX;                     // golden model tracks the DUT
        g_last_ts = INIT_TS;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: eight zero-bubble requests (see header) ------
        drive_stream(32'd10, 8'd3, "1_grant");
        drive_stream(32'd10, 8'd4, "2_grant");
        drive_stream(32'd10, 8'd2, "3_throttle");
        drive_stream(32'd10, 8'd1, "4_grant");
        drive_stream(32'd10, 8'd1, "5_throttle_empty");
        drive_stream(32'd13, 8'd2, "6_grant_refill");
        drive_stream(32'd13, 8'd0, "7_zerocost");
        drive_stream(32'd20, 8'd9, "8_oversized");
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 4) @(posedge clk);           // drain, keep the window clean

        // ---- CORNERS: walked on the CONTINUOUS session ------------------------
        //   c1 ts=100 cost=8 -> GRANT     tokens=0  (long idle saturates to 8)
        //   c2 ts=100 cost=1 -> THROTTLE  tokens=0  (same tick, empty)
        //   c3 ts=104 cost=4 -> GRANT     tokens=0  (+4 refill, exact boundary)
        //   c4 ts=105 cost=2 -> THROTTLE  tokens=1  (+1 refill, one over)
        //   c5 ts=113 cost=8 -> GRANT     tokens=0  (+8 refill sat 8)
        //   c6 ts=113 cost=9 -> OVERSIZED tokens=0
        //   c7 ts=113 cost=0 -> ZEROCOST  tokens=0
        //   c8 ts=200 cost=1 -> GRANT     tokens=7  (long idle saturate)
        drive_req(32'd100, 8'd8, "c1_saturate");   repeat (LAT + 2) @(posedge clk);
        drive_req(32'd100, 8'd1, "c2_empty");      repeat (LAT + 2) @(posedge clk);
        drive_req(32'd104, 8'd4, "c3_boundary");   repeat (LAT + 2) @(posedge clk);
        drive_req(32'd105, 8'd2, "c4_one_over");   repeat (LAT + 2) @(posedge clk);
        drive_req(32'd113, 8'd8, "c5_full_drain"); repeat (LAT + 2) @(posedge clk);
        drive_req(32'd113, 8'd9, "c6_oversized");  repeat (LAT + 2) @(posedge clk);
        drive_req(32'd113, 8'd0, "c7_zerocost");   repeat (LAT + 2) @(posedge clk);
        drive_req(32'd200, 8'd1, "c8_idle");       repeat (LAT + 2) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression -----------------------------------
        rts = 32'd1000;                            // arbitrary continuation point
        trials = 300;
        for (int t = 0; t < trials; t++) begin
            gap = $urandom_range(0, 4);            // 0 -> same-tick burst
            rts = rts + gap[TSW-1:0];
            sel = $urandom_range(0, 9);
            if (sel == 0)      rc = 8'd0;                                        // zerocost
            else if (sel == 1) rc = BUCKET_MAX[COSTW-1:0] + $urandom_range(1,4); // oversized
            else               rc = $urandom_range(1, BUCKET_MAX);              // normal
            drive_req(rts, rc, $sformatf("r%0d", t));
            if (t % 3 == 0) repeat (1) @(posedge clk);   // vary the gap between reqs
        end
        repeat (LAT + 5) @(posedge clk);

        // -------------------------------------------------------- verdict ----
        if (ersn_q.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected decisions never appeared", ersn_q.size());
        end
        $display("--------------------------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errors);
        if (errors == 0 && checks > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $display("--------------------------------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------- timeout ----
    initial begin
        #400000;   // 400 us global watchdog
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
