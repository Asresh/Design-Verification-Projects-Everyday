// ============================================================================
// tb_scrambler_dump.sv - portable, self-checking testbench for the
// self-synchronizing scrambler / descrambler LINK (Icarus / open-source flow).
// ----------------------------------------------------------------------------
// Icarus Verilog does not implement the UVM class library, so this module-based
// testbench performs the SAME verification job as the UVM env (scrambler_pkg.sv
// + tb_top.sv), on a chained TX->wire->RX link:
//
//        in_data --> [ scrambler  SEED_TX ] --scr--> (X inject) --> [ descrambler SEED_RX ] --> des
//
//   * an INDEPENDENT bit-serial golden model (a different implementation from
//     the RTL's parallel unroll) computes, for every driven word, the expected
//     scrambled word and the expected descrambled word - fed the SAME (possibly
//     error-injected) wire the DUT descrambler sees, so it stays bit-exact even
//     through the corruption corner,
//   * a Python-derived Known-Answer vector (SCR_* below) pins the golden's
//     scramble output to an implementation-independent oracle in the directed
//     phases,
//   * the headline SELF-SYNCHRONIZATION property: the descrambler is reset to a
//     DIFFERENT seed than the scrambler yet the recovered stream equals the
//     original payload from word ceil(LFSR_W/WIDTH) onward (58 received bits),
//   * directed showcase (all-zero whitening, mixed payload, recovery) + an
//     error-injection corner (single wire-bit flip -> bounded error burst ->
//     re-lock) + a large constrained-random regression,
//   * functional-coverage counters, pipeline / no-X SVA, a global timeout, and
//     a VCD dump for the committed waveform.
//
// Prints "RESULT: *** PASS ***" only if every check passed.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scrambler_dump;

    // ------------------------------------------------------------------
    // Parameters (must match the DUT instances below and the KAT vectors).
    // ------------------------------------------------------------------
    localparam int unsigned WIDTH  = 8;
    localparam int unsigned LFSR_W = 58;
    localparam int unsigned TAP_A  = 39;
    localparam int unsigned TAP_B  = 58;
    localparam logic [LFSR_W-1:0] SEED_TX = {LFSR_W{1'b1}};   // transmitter seed
    localparam logic [LFSR_W-1:0] SEED_RX = '0;               // DIFFERENT rx seed
    localparam int unsigned LOCK_WORDS = (LFSR_W + WIDTH - 1) / WIDTH; // ceil = 8

    // ------------------------------------------------------------------
    // Python-generated Known-Answer vectors (independent oracle).
    // seed = all-ones, WIDTH=8, LSB-first, G(x)=1+x^39+x^58.
    // ------------------------------------------------------------------
    localparam int unsigned NZ = 16;
    logic [7:0] SCR_ALLZERO [0:NZ-1];
    localparam int unsigned NM = 12;
    logic [7:0] PAY_MIX [0:NM-1];
    logic [7:0] SCR_MIX [0:NM-1];

    initial begin
        SCR_ALLZERO = '{8'h00,8'h00,8'h00,8'h00,8'h80,8'hFF,8'hFF,8'h03,
                        8'h00,8'hC0,8'hFF,8'hFF,8'hFF,8'hFF,8'hEF,8'hFF};
        PAY_MIX     = '{8'h00,8'hFF,8'hA5,8'h5A,8'h01,8'h80,
                        8'h12,8'h34,8'h56,8'h78,8'h9A,8'hBC};
        SCR_MIX     = '{8'h00,8'hFF,8'hA5,8'h5A,8'h81,8'hFF,
                        8'h12,8'h65,8'h07,8'h2F,8'h8F,8'h30};
    end

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    // ------------------------------------------------------------------
    // DUT link
    // ------------------------------------------------------------------
    logic              in_valid;
    logic [WIDTH-1:0]  in_data;

    wire               scr_valid;
    wire  [WIDTH-1:0]  scr_data;
    wire  [LFSR_W-1:0] scr_state;

    // error-injection: XOR mask applied to the wire between TX and RX. The mask
    // is captured on the same edge that latches the word into the scrambler, so
    // it lines up with the (registered, 1-cycle-later) scrambled word it should
    // corrupt - matching the golden's drive-time link_exp = y_exp ^ inj.
    logic [WIDTH-1:0]  inject_mask = '0;
    logic [WIDTH-1:0]  inject_mask_q;
    always @(posedge clk)
        inject_mask_q <= (rst_n && in_valid) ? inject_mask : '0;
    wire  [WIDTH-1:0]  link_data   = scr_data ^ inject_mask_q;

    wire               des_valid;
    wire  [WIDTH-1:0]  des_data;
    wire  [LFSR_W-1:0] des_state;

    scrambler #(.WIDTH(WIDTH), .LFSR_W(LFSR_W), .TAP_A(TAP_A), .TAP_B(TAP_B),
                .MODE_DESCRAMBLE(1'b0), .SEED(SEED_TX)) u_scr (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(scr_valid), .out_data(scr_data), .state_o(scr_state));

    scrambler #(.WIDTH(WIDTH), .LFSR_W(LFSR_W), .TAP_A(TAP_A), .TAP_B(TAP_B),
                .MODE_DESCRAMBLE(1'b1), .SEED(SEED_RX)) u_des (
        .clk(clk), .rst_n(rst_n),
        .in_valid(scr_valid), .in_data(link_data),
        .out_valid(des_valid), .out_data(des_data), .state_o(des_state));

    // ------------------------------------------------------------------
    // Independent bit-serial golden model (state passed by ref).
    // A separate implementation from the RTL parallel unroll.
    // ------------------------------------------------------------------
    task automatic gser(
            inout  logic [LFSR_W-1:0] st,
            input  logic [WIDTH-1:0]  din,
            input  bit                descramble,
            output logic [WIDTH-1:0]  o);
        logic [LFSR_W-1:0] cur;
        logic              fb, ob, fed;
        cur = st;
        for (int unsigned j = 0; j < WIDTH; j++) begin
            fb  = cur[TAP_A-1] ^ cur[TAP_B-1];
            ob  = din[j] ^ fb;
            fed = descramble ? din[j] : ob;
            o[j] = ob;
            cur = {cur[LFSR_W-2:0], fed};
        end
        st = cur;
    endtask

    logic [LFSR_W-1:0] g_tx = SEED_TX;          // golden transmit state
    logic [LFSR_W-1:0] g_rx = SEED_RX;          // golden receive  state

    // Expectation FIFOs (computed at drive time, popped by the monitors).
    logic [WIDTH-1:0] scr_exp_q [$];            // expected scrambled word
    logic [WIDTH-1:0] des_exp_q [$];            // expected descrambled word
    logic [WIDTH-1:0] orig_q    [$];            // original payload word
    bit               lock_q    [$];            // expected "locked" (recovery valid)

    // ------------------------------------------------------------------
    // Bookkeeping / coverage
    // ------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;
    int unsigned drive_idx = 0;                 // words driven since reset

    logic        mark = 1'b0;                    // waveform-window marker
    int unsigned cov_zero, cov_ff, cov_mid;     // payload data-class
    int unsigned cov_locked, cov_unlocked;      // recovery lock state seen
    int unsigned cov_inject;                    // error-injected words

    task automatic chk(input string what, input logic [WIDTH-1:0] got,
                                          input logic [WIDTH-1:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $error("[%0t] %s mismatch: got 0x%02h exp 0x%02h", $time, what, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // Drive one payload word. Computes golden expectations up front (the
    // golden RX is fed the SAME possibly-corrupted wire the DUT RX sees).
    // ------------------------------------------------------------------
    task automatic send(input logic [WIDTH-1:0] d, input logic [WIDTH-1:0] inj = '0);
        logic [WIDTH-1:0] y_exp, link_exp, d_exp;
        bit               locked;
        // "locked" is a PRE-word property: if the rx state already matches the
        // tx state entering this word AND no error is injected on this word,
        // there is no differing bit anywhere in the rx register, so this word's
        // recovered output is guaranteed == the original payload.
        locked   = (g_rx == g_tx) && (inj == '0);
        // golden scramble
        gser(g_tx, d, 1'b0, y_exp);
        link_exp = y_exp ^ inj;                 // same corruption the DUT sees
        // golden descramble of the (corrupted) wire
        gser(g_rx, link_exp, 1'b1, d_exp);
        scr_exp_q.push_back(y_exp);
        des_exp_q.push_back(d_exp);
        orig_q.push_back(d);
        lock_q.push_back(locked);
        // data-class coverage
        if (d == '0)        cov_zero++;
        else if (d == '1)   cov_ff++;
        else                cov_mid++;
        if (inj != '0)      cov_inject++;
        // apply stimulus
        @(negedge clk);
        in_valid    = 1'b1;
        in_data     = d;
        inject_mask = inj;
        @(posedge clk);
        #1 in_valid = 1'b0;
        drive_idx++;
    endtask

    task automatic idle(input int n = 1);
        repeat (n) begin
            @(negedge clk);
            in_valid = 1'b0;
            inject_mask = '0;
        end
    endtask

    // ------------------------------------------------------------------
    // Monitors: pop expectations on the DUT's registered valids.
    // ------------------------------------------------------------------
    int unsigned scr_seen = 0;
    always @(posedge clk) if (rst_n && scr_valid) begin
        logic [WIDTH-1:0] e;
        if (scr_exp_q.size() == 0) begin
            errors++; $error("[%0t] scr_valid with empty expect FIFO", $time);
        end else begin
            e = scr_exp_q.pop_front();
            chk("scramble", scr_data, e);
        end
        scr_seen++;
    end

    int unsigned des_seen = 0;
    always @(posedge clk) if (rst_n && des_valid) begin
        logic [WIDTH-1:0] de, og;
        bit               lk;
        if (des_exp_q.size() == 0) begin
            errors++; $error("[%0t] des_valid with empty expect FIFO", $time);
        end else begin
            de = des_exp_q.pop_front();
            og = orig_q.pop_front();
            lk = lock_q.pop_front();
            chk("descramble", des_data, de);
            // headline property: once locked & clean, recovered == original.
            if (lk) begin
                chk("recovery", des_data, og);
                cov_locked++;
            end else begin
                cov_unlocked++;
            end
        end
        des_seen++;
    end

    // ------------------------------------------------------------------
    // Golden self-test vs the Python Known-Answer vectors (ties the SV
    // golden to an implementation-independent oracle). Runs a private copy
    // of the serial scramble so it does not disturb the live g_tx.
    // ------------------------------------------------------------------
    task automatic kat_selftest;
        logic [LFSR_W-1:0] s;
        logic [WIDTH-1:0]  y;
        s = SEED_TX;
        for (int i = 0; i < NZ; i++) begin
            gser(s, 8'h00, 1'b0, y);
            chk("KAT-allzero", y, SCR_ALLZERO[i]);
        end
        s = SEED_TX;
        for (int i = 0; i < NM; i++) begin
            gser(s, PAY_MIX[i], 1'b0, y);
            chk("KAT-mix", y, SCR_MIX[i]);
        end
        $display("[%0t] KAT self-test done (%0d vectors)", $time, NZ + NM);
    endtask

    // ------------------------------------------------------------------
    // Stimulus program
    // ------------------------------------------------------------------
    int unsigned rpt;
    logic [WIDTH-1:0] rd, rinj;
    initial begin
        in_valid    = 1'b0;
        in_data     = '0;
        inject_mask = '0;

        // reset
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        @(negedge clk);

        // 0) independent Python KAT self-test of the golden
        kat_selftest();

        // 1) DIRECTED + CAPTURED WAVEFORM: mixed payload driven FIRST, straight
        //    out of reset while the descrambler is still at its (wrong) SEED_RX.
        //    This is the headline self-synchronization: the first LOCK_WORDS=8
        //    recovered words are the transient (rx state not yet re-derived);
        //    from word 8 on, des_data reproduces in_data exactly. Sent twice so
        //    the sustained post-lock recovery is clearly visible in the window.
        @(negedge clk) mark = 1'b1;
        for (int i = 0; i < NM; i++) send(PAY_MIX[i]);
        for (int i = 0; i < NM; i++) send(PAY_MIX[i]);
        @(negedge clk) mark = 1'b0;

        // 2) DIRECTED: all-zero payload whitening (the classic PRBS line data -
        //    an all-zero payload still produces a high-transition scrambled
        //    stream).
        for (int i = 0; i < NZ; i++) send(8'h00);

        // 3) A valid gap (out_valid must drop, data must hold) then continue.
        idle(3);
        for (int i = 0; i < NM; i++) send(PAY_MIX[NM-1-i]);

        // 4) CORNER: single wire-bit flip mid-stream. A self-synchronizing
        //    descrambler multiplies the error by the tap count, so a lone flip
        //    produces a BOUNDED error burst (at offsets 0/39/58 bits) and then
        //    re-locks. The golden is fed the same corrupted wire, so it stays
        //    bit-exact; recovery resumes automatically afterwards.
        send(8'hC3, 8'h04);                     // corrupt one bit of this word
        for (int i = 0; i < 12; i++) send($urandom & 8'hFF);  // let it re-lock

        // 5) CORNER: all-ones payload burst.
        for (int i = 0; i < 8; i++) send(8'hFF);

        // 6) Large constrained-random regression, zero-bubble, occasionally
        //    sprinkling single-bit wire errors to exercise re-lock.
        rpt = 4000;
        for (int i = 0; i < rpt; i++) begin
            rd = $urandom & 8'hFF;
            // ~1% of words get a single-bit wire error injected
            if (($urandom % 100) == 0) rinj = (8'h1 << ($urandom % WIDTH));
            else                       rinj = 8'h00;
            send(rd, rinj);
        end

        // drain the pipeline
        idle(6);

        // ------------------------------------------------------------------
        // Final report
        // ------------------------------------------------------------------
        $display("--------------------------------------------------------------");
        $display("scrambler/descrambler link verification summary");
        $display("  words driven          : %0d", drive_idx);
        $display("  scramble words checked : %0d", scr_seen);
        $display("  descramble words check : %0d", des_seen);
        $display("  total checks           : %0d", checks);
        $display("  data-class cov  zero/ff/mid : %0d / %0d / %0d",
                 cov_zero, cov_ff, cov_mid);
        $display("  recovery  locked/unlocked   : %0d / %0d",
                 cov_locked, cov_unlocked);
        $display("  error-injected words        : %0d", cov_inject);
        if (scr_exp_q.size() != 0 || des_exp_q.size() != 0) begin
            errors++;
            $display("  ERROR: expectation FIFOs not drained (scr=%0d des=%0d)",
                     scr_exp_q.size(), des_exp_q.size());
        end
        $display("  errors                 : %0d", errors);
        if (errors == 0 && checks > 0 &&
            cov_zero > 0 && cov_ff > 0 && cov_mid > 0 &&
            cov_locked > 0 && cov_unlocked > 0 && cov_inject > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (errors=%0d checks=%0d)", errors, checks);
        $display("--------------------------------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------------
    // Global watchdog
    // ------------------------------------------------------------------
    initial begin
        #2ms;
        $display("RESULT: *** FAIL ***  (TIMEOUT)");
        $fatal(1, "global watchdog fired");
    end

    // ------------------------------------------------------------------
    // VCD dump
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("tb_scrambler_dump.vcd");
        $dumpvars(0, tb_scrambler_dump);
    end

    // ------------------------------------------------------------------
    // Procedural "checker-style" assertions (the forms Icarus supports; the
    // equivalent concurrent SVA lives in scrambler_if.sv for the UVM flow).
    // ------------------------------------------------------------------
    logic in_valid_d, scr_valid_d;
    always @(posedge clk) begin
        in_valid_d  <= rst_n ? in_valid  : 1'b0;
        scr_valid_d <= rst_n ? scr_valid : 1'b0;
    end

    // fixed-latency pipeline contract: out_valid == prev in_valid.
    always @(posedge clk) if (rst_n) begin
        if (scr_valid !== in_valid_d) begin
            errors++;
            $display("  [%0t] FAIL SVA: scr_valid(%b) != prev in_valid(%b)",
                     $time, scr_valid, in_valid_d);
        end
        if (des_valid !== scr_valid_d) begin
            errors++;
            $display("  [%0t] FAIL SVA: des_valid(%b) != prev scr_valid(%b)",
                     $time, des_valid, scr_valid_d);
        end
        // no-X on payloads while valid.
        if (scr_valid && $isunknown(scr_data)) begin
            errors++; $display("  [%0t] FAIL SVA: X on scr_data", $time);
        end
        if (des_valid && $isunknown(des_data)) begin
            errors++; $display("  [%0t] FAIL SVA: X on des_data", $time);
        end
    end

endmodule

`default_nettype wire
