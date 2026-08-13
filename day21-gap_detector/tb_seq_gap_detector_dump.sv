// -----------------------------------------------------------------------------
// tb_seq_gap_detector_dump.sv - portable, module-based, SELF-CHECKING testbench
// for the MARKET-DATA SEQUENCE GAP DETECTOR & DUPLICATE SUPPRESSOR. Runs on
// open-source Icarus Verilog (which does not implement the UVM class library). It:
//
//   * programs the session initial sequence number (init_seq = 100),
//   * drives a DIRECTED SHOWCASE - eight BACK-TO-BACK messages (zero-bubble) that
//     walk through every action and both duplicate flavours, so the captured VCD
//     tells the classic feed-handler story:
//         1 seq 100 -> PASS   exp 101
//         2 seq 101 -> PASS   exp 102
//         3 seq 101 -> DUP    exp 102  (B-line duplicate copy)
//         4 seq 102 -> PASS   exp 103
//         5 seq 105 -> GAP=2  exp 106  (103,104 missing -> forward 105, resync)
//         6 seq 106 -> PASS   exp 107
//         7 seq 104 -> DUP    exp 107  (stale late retransmit, 104 < 107)
//         8 seq 107 -> PASS   exp 108
//   * runs DIRECTED CORNERS (resume, immediate duplicate, minimal gap-of-1,
//     large gap, far-behind stale, resync-and-continue) on the continuous
//     session,
//   * runs a CONSTRAINED-RANDOM regression - a random walk around the expected
//     sequence mixing advances / duplicates / gaps / stale retransmits - while an
//     independent STATEFUL golden reference model computes the decision + running
//     next-expected for each message,
//   * checks every decision against the golden model (fwd + action + gap count +
//     echoed seq + next-expected),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in seq_gap_detector_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_seq_gap_detector_dump;

    localparam int SEQW = 32;
    localparam int DW   = 64;
    localparam int ACTW = 2;
    localparam int PIPE = 2;
    localparam int LAT  = PIPE + 1;      // 3-cycle latency

    // action codes
    localparam int A_PASS = 0;
    localparam int A_DUP  = 1;
    localparam int A_GAP  = 2;

    localparam int unsigned INIT_SEQ = 100;

    logic              clk;
    logic              rst_n;
    logic              cfg_load;
    logic [SEQW-1:0]   cfg_init_seq;
    logic              in_valid;
    logic [SEQW-1:0]   in_seq;
    logic [DW-1:0]     in_data;
    logic              out_valid;
    logic              out_fwd;
    logic [ACTW-1:0]   out_action;
    logic [SEQW-1:0]   out_seq;
    logic [DW-1:0]     out_data;
    logic [SEQW-1:0]   out_gap;
    logic [SEQW-1:0]   out_expected;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    seq_gap_detector #(.SEQW(SEQW), .DW(DW), .PIPE(PIPE)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .cfg_load     (cfg_load),
        .cfg_init_seq (cfg_init_seq),
        .in_valid     (in_valid),
        .in_seq       (in_seq),
        .in_data      (in_data),
        .out_valid    (out_valid),
        .out_fwd      (out_fwd),
        .out_action   (out_action),
        .out_seq      (out_seq),
        .out_data     (out_data),
        .out_gap      (out_gap),
        .out_expected (out_expected)
    );

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------------------------- golden reference (stateful)
    // Independent re-model: compare / dedup / gap classification + running
    // next-expected that advances only on a forwarded message.
    longint unsigned g_exp;   // running next-expected

    // expected-output FIFO (golden scoreboard)
    integer            eact_q [$];   // expected action
    integer            efwd_q [$];   // expected forward flag
    longint unsigned   egap_q [$];   // expected gap count
    longint unsigned   eexp_q [$];   // expected next-expected after
    longint unsigned   esq_q  [$];   // expected echoed seq
    string             enm_q  [$];

    // Evaluate one message, push the expected decision, advance g_exp on forward.
    task automatic model_push(input logic [SEQW-1:0] s, input string nm);
        integer          action;
        logic            fwd;
        longint unsigned gap;
        if (s == g_exp) begin
            action = A_PASS; gap = 0; fwd = 1'b1; g_exp = s + 1;
        end else if (s > g_exp) begin
            action = A_GAP;  gap = s - g_exp; fwd = 1'b1; g_exp = s + 1;
        end else begin
            action = A_DUP;  gap = 0; fwd = 1'b0;   // expected unchanged
        end
        eact_q.push_back(action);
        efwd_q.push_back(fwd);
        egap_q.push_back(gap);
        eexp_q.push_back(g_exp);
        esq_q .push_back(s);
        enm_q .push_back(nm);
    endtask

    // -------------------------------------------------------- driver task -----
    task automatic drive_msg(input logic [SEQW-1:0] s, input logic [DW-1:0] d,
                             input string nm);
        model_push(s, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_seq   <= s;
        in_data  <= d;
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // back-to-back variant: hold in_valid high across consecutive messages (used
    // for the zero-bubble showcase stream).
    task automatic drive_stream(input logic [SEQW-1:0] s, input logic [DW-1:0] d,
                                input string nm);
        model_push(s, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_seq   <= s;
        in_data  <= d;
    endtask

    // ------------------------------------------------ scoreboard (monitor) -----
    integer xact, xfwd; longint unsigned xgap, xexp, xsq; string xnm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (eact_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                xact = eact_q.pop_front();
                xfwd = efwd_q.pop_front();
                xgap = egap_q.pop_front();
                xexp = eexp_q.pop_front();
                xsq  = esq_q .pop_front();
                xnm  = enm_q .pop_front();
                checks = checks + 1;
                if (out_seq !== xsq[SEQW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] SEQ-ECHO MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_seq, xsq);
                end
                if ((int'(out_action) !== xact) || (out_fwd !== xfwd[0])) begin
                    errors = errors + 1;
                    $display("[%0t] DECISION MISMATCH (%s): got action=%0d fwd=%0d exp action=%0d fwd=%0d",
                             $time, xnm, out_action, out_fwd, xact, xfwd);
                end
                if (out_gap !== xgap[SEQW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] GAP MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_gap, xgap);
                end
                if (out_expected !== xexp[SEQW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] EXPECTED MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_expected, xexp);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic [SEQW-1:0] nseq, lseq;
    integer          mode, skip, back;
    int trials;

    initial begin
        $dumpfile("tb_seq_gap_detector_dump.vcd");
        $dumpvars(0, tb_seq_gap_detector_dump);

        cfg_load = 1'b0; cfg_init_seq = '0;
        in_valid = 1'b0; in_seq = '0; in_data = '0;
        g_exp = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- program the session initial sequence ----
        cfg_load     <= 1'b1;
        cfg_init_seq <= INIT_SEQ[SEQW-1:0];
        @(posedge clk);
        cfg_load <= 1'b0;
        g_exp = INIT_SEQ;                          // golden model tracks the DUT
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: eight zero-bubble messages (see header) ------
        drive_stream(32'd100, 64'hA000_0000_0000_0064, "1_pass");
        drive_stream(32'd101, 64'hA000_0000_0000_0065, "2_pass");
        drive_stream(32'd101, 64'hB000_0000_0000_0065, "3_dup_copy");
        drive_stream(32'd102, 64'hA000_0000_0000_0066, "4_pass");
        drive_stream(32'd105, 64'hA000_0000_0000_0069, "5_gap2");
        drive_stream(32'd106, 64'hA000_0000_0000_006A, "6_pass");
        drive_stream(32'd104, 64'hC000_0000_0000_0068, "7_dup_stale");
        drive_stream(32'd107, 64'hA000_0000_0000_006B, "8_pass");
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 4) @(posedge clk);           // drain, keep the window clean

        // ---- CORNERS: walked on the CONTINUOUS session (expected == 108) ------
        //   c1 seq 108 -> PASS  exp 109  (resume)
        //   c2 seq 108 -> DUP   exp 109  (immediate duplicate)
        //   c3 seq 110 -> GAP=1 exp 111  (109 missing, minimal gap)
        //   c4 seq 111 -> PASS  exp 112
        //   c5 seq 200 -> GAP=88 exp 201 (112..199 missing, large gap)
        //   c6 seq 150 -> DUP   exp 201  (far-behind stale)
        //   c7 seq 201 -> PASS  exp 202  (resync-and-continue)
        //   c8 seq 202 -> PASS  exp 203
        drive_msg(32'd108, 64'd108, "c1_resume");     repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd108, 64'd108, "c2_imm_dup");    repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd110, 64'd110, "c3_gap1");       repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd111, 64'd111, "c4_pass");       repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd200, 64'd200, "c5_biggap");     repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd150, 64'd150, "c6_stale");      repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd201, 64'd201, "c7_resync");     repeat (LAT + 2) @(posedge clk);
        drive_msg(32'd202, 64'd202, "c8_pass");       repeat (LAT + 2) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression -----------------------------------
        nseq = 32'd600;                            // arbitrary continuation point
        lseq = nseq;
        // resync the DUT + model to this point via a single forwarded message
        drive_msg(nseq, {32'hDA7A_0000, nseq}, "seed"); repeat (LAT + 2) @(posedge clk);
        nseq = nseq + 1; lseq = nseq - 1;

        trials = 300;
        for (int t = 0; t < trials; t++) begin
            mode = $urandom_range(0, 9);
            if (mode <= 5) begin                   // 60% in-order advance -> PASS
                lseq = nseq;
                drive_msg(nseq, {32'hDA7A_0000, nseq}, $sformatf("r%0d_pass", t));
                nseq = nseq + 1;
            end else if (mode <= 6) begin           // 10% duplicate of last -> DUP
                drive_msg(lseq, {32'hDA7A_0000, lseq}, $sformatf("r%0d_dup", t));
            end else if (mode <= 8) begin           // 20% gap -> GAP
                skip = $urandom_range(1, 12);
                nseq = nseq + skip[SEQW-1:0];
                lseq = nseq;
                drive_msg(nseq, {32'hDA7A_0000, nseq}, $sformatf("r%0d_gap", t));
                nseq = nseq + 1;
            end else begin                          // 10% stale far-behind -> DUP
                back = $urandom_range(1, 20);
                drive_msg((nseq > back[SEQW-1:0]) ? (nseq - back[SEQW-1:0]) : 32'd0,
                          64'hDEAD_BEEF_DEAD_BEEF, $sformatf("r%0d_stale", t));
            end
            if (t % 3 == 0) repeat (1) @(posedge clk);   // vary the gap between msgs
        end
        repeat (LAT + 5) @(posedge clk);

        // -------------------------------------------------------- verdict ----
        if (eact_q.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected decisions never appeared", eact_q.size());
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
