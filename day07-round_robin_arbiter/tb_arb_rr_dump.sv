// -----------------------------------------------------------------------------
// tb_arb_rr_dump.sv  -  portable, self-checking companion testbench for arb_rr
//
// Icarus Verilog does not implement the UVM class library, so this module-based
// testbench is the one that really runs in the open-source flow.  It:
//   * drives a DIRECTED "showcase" (round-robin rotation, a backpressure stall,
//     sparse requests with a circular skip, and an idle cycle) so the committed
//     waveform is clean and illustrative, then
//   * drives many CONSTRAINED-RANDOM cycles for coverage of the state space,
//   * checks every cycle against an INDEPENDENT golden round-robin reference
//     model (its own pointer, re-derived from scratch - NOT the DUT's logic),
//   * prints "RESULT: *** PASS ***" on success, and
//   * dumps a VCD (tb_arb_rr_dump.vcd) that docs/make_waveform.py renders.
//
//   iverilog -g2012 -o simv_dump arb_rr.sv tb_arb_rr_dump.sv && vvp simv_dump
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_arb_rr_dump;

    localparam int NUM_REQ = 4;
    localparam int PW      = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1;

    logic               clk = 1'b0;
    logic               rst_n;
    logic               en;
    logic [NUM_REQ-1:0] req;
    logic [NUM_REQ-1:0] grant;
    logic               grant_valid;
    logic [PW-1:0]      grant_idx;

    // 100 MHz clock: posedge at 5 + 10k ns.
    always #5 clk = ~clk;

    // DUT.
    arb_rr #(.NUM_REQ(NUM_REQ)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .req        (req),
        .grant      (grant),
        .grant_valid(grant_valid),
        .grant_idx  (grant_idx)
    );

    // -------------------------------------------------------------------------
    // Independent golden reference model.
    //   `m_ptr` is the model's own priority pointer; the reference winner is the
    //   first requester at or after m_ptr scanning circularly.  This is written
    //   from scratch so a copy-paste bug in the DUT cannot hide behind an
    //   identical checker.
    // -------------------------------------------------------------------------
    logic [PW-1:0]      m_ptr;

    function automatic logic [NUM_REQ-1:0] ref_pick(input logic [NUM_REQ-1:0] r,
                                                    input logic [PW-1:0]      p);
        logic [NUM_REQ-1:0] g;
        int                 j;
        g = '0;
        for (int k = 0; k < NUM_REQ; k++) begin
            j = (int'(p) + k) % NUM_REQ;
            if (r[j] && g == '0)   // take the first hit in circular order
                g[j] = 1'b1;
        end
        return g;
    endfunction

    function automatic logic [PW-1:0] ref_idx(input logic [NUM_REQ-1:0] g);
        logic [PW-1:0] k;
        k = '0;
        for (int i = 0; i < NUM_REQ; i++)
            if (g[i]) k = PW'(i);
        return k;
    endfunction

    // -------------------------------------------------------------------------
    // Checker + coverage (sampled at posedge, in lockstep with the DUT).
    // -------------------------------------------------------------------------
    int unsigned checks;
    int unsigned errors;
    int unsigned grant_count;
    int unsigned idle_count;
    int unsigned stall_count;
    int unsigned served [NUM_REQ];   // fairness histogram: grants per requester

    logic [NUM_REQ-1:0] exp_grant;
    logic [PW-1:0]      exp_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_ptr <= '0;
        end
        else begin
            // Reference decision for THIS cycle, using the current req/en/m_ptr.
            exp_grant = (en && (|req)) ? ref_pick(req, m_ptr) : '0;
            exp_idx   = ref_idx(exp_grant);

            checks++;

            // 1) grant vector matches the reference
            if (grant !== exp_grant) begin
                errors++;
                $display("[%0t] MISMATCH grant: req=%b en=%b m_ptr=%0d  dut=%b exp=%b",
                         $time, req, en, m_ptr, grant, exp_grant);
            end
            // 2) grant_valid consistency
            if (grant_valid !== (|grant)) begin
                errors++;
                $display("[%0t] grant_valid inconsistent: gv=%b grant=%b",
                         $time, grant_valid, grant);
            end
            // 3) grant_idx correct when a grant occurred
            if ((grant != '0) && (grant_idx !== exp_idx)) begin
                errors++;
                $display("[%0t] grant_idx wrong: dut=%0d exp=%0d",
                         $time, grant_idx, exp_idx);
            end
            // 4) one-hot-or-zero
            if (!$onehot0(grant)) begin
                errors++;
                $display("[%0t] grant not one-hot0: %b", $time, grant);
            end

            // coverage / fairness bookkeeping
            if (grant != '0) begin
                grant_count++;
                served[exp_idx]++;
            end
            else if (en == 1'b0)
                stall_count++;
            else
                idle_count++;

            // advance the model pointer with the same rule as the DUT
            if (en && (|req))
                m_ptr <= (exp_idx == PW'(NUM_REQ-1)) ? '0 : exp_idx + PW'(1);
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus: drive on the negedge so req/en are settled before each posedge.
    // -------------------------------------------------------------------------
    task automatic drive(input logic [NUM_REQ-1:0] r, input logic e);
        @(negedge clk);
        req = r;
        en  = e;
    endtask

    int unsigned lfsr;

    initial begin
        // init
        req    = '0;
        en     = 1'b0;
        checks = 0; errors = 0;
        grant_count = 0; idle_count = 0; stall_count = 0;
        for (int i = 0; i < NUM_REQ; i++) served[i] = 0;
        lfsr = 32'hACE1_2468;

        // reset: hold low for 4 posedges (matches the UVM tb_top)
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // ---- DIRECTED SHOWCASE (drives the committed waveform) --------------
        drive(4'b1111, 1'b1);   // C1: all request        -> grant idx0
        drive(4'b1111, 1'b1);   // C2: all request        -> grant idx1
        drive(4'b1111, 1'b1);   // C3: all request        -> grant idx2
        drive(4'b1111, 1'b0);   // C4: en low  (STALL)     -> grant 0, ptr holds
        drive(4'b1111, 1'b1);   // C5: all request        -> grant idx3
        drive(4'b1111, 1'b1);   // C6: all request (wrap)  -> grant idx0
        drive(4'b0110, 1'b1);   // C7: ptr=1, req{1,2}     -> grant idx1
        drive(4'b1000, 1'b1);   // C8: ptr=2, req{3} only  -> grant idx3 (skip/wrap)
        drive(4'b0000, 1'b1);   // C9: no request (IDLE)   -> grant 0
        drive(4'b0101, 1'b1);   // C10: ptr=0, req{0,2}    -> grant idx0

        // ---- CONSTRAINED-RANDOM PHASE ---------------------------------------
        // xorshift LFSR: random request vectors and a mostly-enabled resource
        // (occasional stalls) to sweep pointer positions and request densities.
        for (int c = 0; c < 240; c++) begin
            lfsr = lfsr ^ (lfsr << 13);
            lfsr = lfsr ^ (lfsr >> 17);
            lfsr = lfsr ^ (lfsr << 5);
            drive(lfsr[NUM_REQ-1:0], (lfsr[8:6] != 3'b000));  // ~1/8 stalls
        end

        // let the last driven cycle be checked, then wind down
        @(negedge clk);
        req = '0; en = 1'b0;
        repeat (2) @(posedge clk);

        // ---- REPORT ---------------------------------------------------------
        $display("--------------------------------------------------------------");
        $display("arb_rr checks=%0d  grants=%0d  stalls=%0d  idle=%0d  errors=%0d",
                 checks, grant_count, stall_count, idle_count, errors);
        $display("fairness histogram (grants per requester):");
        for (int i = 0; i < NUM_REQ; i++)
            $display("    requester[%0d] served %0d time(s)", i, served[i]);

        // every requester must have won at least once (no starvation observed)
        begin
            logic starved;
            starved = 1'b0;
            for (int i = 0; i < NUM_REQ; i++)
                if (served[i] == 0) starved = 1'b1;
            if (starved) begin
                errors++;
                $display("COVERAGE HOLE: at least one requester was never served");
            end
        end

        if (errors == 0 && checks > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (errors=%0d checks=%0d)", errors, checks);
        $display("--------------------------------------------------------------");
        $finish;
    end

    // waveform dump
    initial begin
        $dumpfile("tb_arb_rr_dump.vcd");
        $dumpvars(0, tb_arb_rr_dump);
    end

    // global timeout safety net
    initial begin
        #50000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule
