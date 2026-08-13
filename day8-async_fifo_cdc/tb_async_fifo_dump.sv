// ============================================================================
// tb_async_fifo_dump.sv - portable, open-source self-checking testbench
// ----------------------------------------------------------------------------
// Icarus Verilog does NOT implement the UVM class library, so this module-based
// companion testbench is what runs everywhere. It exercises the dual-clock
// async_fifo across three phases:
//
//   Phase A (fill)   : write domain streams words; read domain idle. The FIFO
//                      fills to DEPTH and wr_full asserts (write-side corner).
//   Phase B (drain)  : read domain streams; write domain idle. Words fall
//                      through in FIFO order and rd_empty asserts (read corner).
//   Phase C (random) : both domains run constrained-random enables concurrently
//                      across the clock-domain crossing.
//
// A single golden FIFO queue (pushed on every accepted write, checked+popped on
// every accepted read) is the reference model: it proves DATA INTEGRITY and
// ORDERING are preserved across the CDC. On success the TB prints
//   RESULT: *** PASS ***
//
// The two clocks use non-commensurate half-periods (5.0 ns and 6.5 ns) so their
// posedges never coincide -> the shared golden queue is updated deterministically
// (writes at integer times, reads at *.5 times).
//
// Run:  iverilog -g2012 -o simv_dump async_fifo.sv tb_async_fifo_dump.sv && vvp simv_dump
// ============================================================================
`timescale 1ns/1ps

module tb_async_fifo_dump;

    localparam int DW    = 8;
    localparam int AW    = 2;              // depth = 4 (small -> corners are fast)
    localparam int DEPTH = 1 << AW;

    // ---- write domain ----
    logic          wr_clk;
    logic          wr_rst_n;
    logic          wr_en;
    logic [DW-1:0] wr_data;
    logic          wr_full;

    // ---- read domain ----
    logic          rd_clk;
    logic          rd_rst_n;
    logic          rd_en;
    logic [DW-1:0] rd_data;
    logic          rd_empty;

    // DUT
    async_fifo #(.DW(DW), .AW(AW)) dut (
        .wr_clk (wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en),
        .wr_data(wr_data), .wr_full(wr_full),
        .rd_clk (rd_clk), .rd_rst_n(rd_rst_n), .rd_en(rd_en),
        .rd_data(rd_data), .rd_empty(rd_empty)
    );

    // ------------------------------------------------------------------
    // Clocks: 5.0 ns and 6.5 ns half-periods -> posedges never coincide.
    // ------------------------------------------------------------------
    initial begin wr_clk = 1'b0; forever #5.0 wr_clk = ~wr_clk; end
    initial begin rd_clk = 1'b0; forever #6.5 rd_clk = ~rd_clk; end

    // Resets (asynchronous assert, staggered release).
    initial begin
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;
        #23 wr_rst_n = 1'b1;
        #7  rd_rst_n = 1'b1;
    end

    // ------------------------------------------------------------------
    // Golden reference model + coverage counters
    // ------------------------------------------------------------------
    logic [DW-1:0] gq [$];                 // golden FIFO (order-preserving)
    int unsigned   n_wr, n_rd, n_err;
    int unsigned   cov_full_hit, cov_empty_hit, cov_wr_when_full,
                   cov_rd_when_empty, cov_simul_rw, cov_maxocc;
    bit            writes_done, drain_done;
    int unsigned   empty_run;

    // Accepted-write bookkeeping (write domain).
    always @(posedge wr_clk) begin
        if (wr_rst_n) begin
            if (wr_en && wr_full)  cov_wr_when_full++;    // backpressure exercised
            if (wr_en && !wr_full) begin
                gq.push_back(wr_data);
                n_wr++;
                if (gq.size() > cov_maxocc) cov_maxocc = gq.size();
            end
            if (wr_full) cov_full_hit++;
            if (wr_en && rd_en) cov_simul_rw++;
        end
    end

    // Accepted-read checking (read domain, FWFT: rd_data shows the head now).
    always @(posedge rd_clk) begin
        if (rd_rst_n) begin
            if (rd_en && rd_empty)  cov_rd_when_empty++;  // underflow guard exercised
            if (rd_empty)           cov_empty_hit++;
            if (rd_en && !rd_empty) begin
                if (gq.size() == 0) begin
                    n_err++;
                    $error("[%0t] READ but golden queue empty (spurious !rd_empty)", $time);
                end else begin
                    logic [DW-1:0] exp;
                    exp = gq.pop_front();
                    if (rd_data !== exp) begin
                        n_err++;
                        $error("[%0t] DATA MISMATCH: got 0x%02h expected 0x%02h",
                               $time, rd_data, exp);
                    end
                    n_rd++;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Stimulus - write domain
    // ------------------------------------------------------------------
    initial begin
        wr_en   = 1'b0;
        wr_data = '0;
        wait (wr_rst_n === 1'b1);

        // Phase A: fill. Stream 6 words into a depth-4 FIFO; the last two hit
        // wr_full and are dropped by the DUT's guard (and by the golden model).
        for (int i = 0; i < 6; i++) begin
            @(negedge wr_clk);
            wr_en   = 1'b1;
            wr_data = 8'hA0 + (i * 8'h11);          // A0,B1,C2,D3,E4,F5
        end
        @(negedge wr_clk) wr_en = 1'b0;

        // Idle through the drain phase.
        repeat (12) @(negedge wr_clk);

        // Phase C: constrained-random concurrent traffic.
        for (int i = 0; i < 60; i++) begin
            @(negedge wr_clk);
            wr_en   = $random;
            wr_data = $random;
        end
        @(negedge wr_clk) wr_en = 1'b0;
        writes_done = 1'b1;                          // no more writes after this
    end

    // ------------------------------------------------------------------
    // Stimulus - read domain
    // ------------------------------------------------------------------
    initial begin
        rd_en = 1'b0;
        wait (rd_rst_n === 1'b1);

        // Idle while the FIFO fills (let wr_full assert first).
        repeat (7) @(negedge rd_clk);

        // Phase B: drain. Stream reads; words fall through in order, then
        // rd_empty asserts.
        for (int i = 0; i < 8; i++) begin
            @(negedge rd_clk);
            rd_en = 1'b1;
        end
        @(negedge rd_clk) rd_en = 1'b0;

        // Phase C: constrained-random concurrent traffic.
        repeat (2) @(negedge rd_clk);
        for (int i = 0; i < 55; i++) begin
            @(negedge rd_clk);
            rd_en = $random;
        end
        @(negedge rd_clk) rd_en = 1'b0;

        // Phase D: deterministic final drain. Once writes have stopped, hold
        // rd_en high until rd_empty stays asserted for several cycles - this
        // forces the FIFO fully empty so the end-of-test can assert the golden
        // queue is drained (gq.size()==0). A FIFO that asserted rd_empty one
        // entry early would stop the reader here with residual words left,
        // failing the residency check - which is exactly the CDC bug class the
        // TB must catch.
        wait (writes_done === 1'b1);
        @(negedge rd_clk) rd_en = 1'b1;
        empty_run = 0;
        while (empty_run < 4) begin
            @(negedge rd_clk);
            if (rd_empty) empty_run = empty_run + 1;
            else          empty_run = 0;
        end
        @(negedge rd_clk) rd_en = 1'b0;
        drain_done = 1'b1;
    end

    // ------------------------------------------------------------------
    // End-of-test: drain remaining, report, and score.
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("tb_async_fifo_dump.vcd");
        $dumpvars(0, tb_async_fifo_dump);

        // Global timeout.
        fork
            begin : timeout
                #6000;
                $display("RESULT: *** FAIL *** (timeout)");
                $fatal(1, "timeout");
            end
            begin : run
                // Complete when the read side has drained the FIFO to empty.
                wait (drain_done === 1'b1);
                #50;
            end
        join_any
        disable timeout;

        $display("----------------------------------------------------------");
        $display("async_fifo CDC verification summary (Icarus, module TB)");
        $display("  writes accepted (golden pushes) : %0d", n_wr);
        $display("  reads  checked  (golden pops)   : %0d", n_rd);
        $display("  words left resident in FIFO     : %0d", gq.size());
        $display("  data/order mismatches           : %0d", n_err);
        $display("  coverage:");
        $display("    max occupancy observed        : %0d / %0d", cov_maxocc, DEPTH);
        $display("    cycles with wr_full asserted  : %0d", cov_full_hit);
        $display("    cycles with rd_empty asserted : %0d", cov_empty_hit);
        $display("    write-attempts while full     : %0d", cov_wr_when_full);
        $display("    read-attempts  while empty    : %0d", cov_rd_when_empty);
        $display("    simultaneous read+write edges : %0d", cov_simul_rw);
        $display("----------------------------------------------------------");

        // Coverage/health gate: no mismatches, real traffic in both directions,
        // both corners reached (full occupancy AND empty), AND every written
        // word was ultimately read out (residency drained to zero).
        if (n_err == 0 && n_wr > 0 && n_rd > 0 && n_wr == n_rd &&
            gq.size() == 0 && cov_maxocc == DEPTH &&
            cov_full_hit > 0 && cov_empty_hit > 0) begin
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (errors=%0d wr=%0d rd=%0d residual=%0d full=%0d empty=%0d maxocc=%0d)",
                     n_err, n_wr, n_rd, gq.size(), cov_full_hit, cov_empty_hit, cov_maxocc);
        end
        $finish;
    end

endmodule
