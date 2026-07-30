// -----------------------------------------------------------------------------
// tb_coalescer_dump.sv - portable, module-based, SELF-CHECKING testbench for the
// GPU memory-coalescing unit. Runs on open-source Icarus Verilog (which does not
// implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE warp whose 8 lanes coalesce into 2 cache lines
//     ( lines 0x20 and 0x40 ), so the captured VCD tells a clean story,
//   * runs DIRECTED CORNERS (all-same -> 1 line, per-lane stride -> 8 lines,
//     partial active mask, all-disabled -> 0 lines, single lane),
//   * runs a CONSTRAINED-RANDOM regression (random addresses in a small window,
//     random active mask) with random back-pressure on the line stream,
//   * checks every emitted transaction (line, mask, last) against an independent
//     golden coalescing reference model,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agents/monitors/scoreboard/coverage/virtual
// sequences + SVA) lives in coalescer_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_coalescer_dump;

    localparam int NLANES = 8;
    localparam int ADDR_W = 32;
    localparam int OFF_W  = 7;
    localparam int LINE_W = ADDR_W - OFF_W;

    logic                     clk;
    logic                     rst_n;
    logic                     req_valid;
    logic                     req_ready;
    logic [NLANES*ADDR_W-1:0] lane_addr;
    logic [NLANES-1:0]        lane_en;
    logic                     txn_valid;
    logic                     txn_ready;
    logic [LINE_W-1:0]        txn_line;
    logic [NLANES-1:0]        txn_mask;
    logic                     txn_last;

    integer errors = 0;
    integer checks = 0;

    // Current warp (module-scope arrays -> Icarus-friendly).
    logic [ADDR_W-1:0] va [0:NLANES-1];
    logic [NLANES-1:0] ven;

    // Golden expected-transaction lists for the current warp.
    logic [LINE_W-1:0] exp_line [0:NLANES-1];
    logic [NLANES-1:0] exp_mask [0:NLANES-1];
    logic              exp_last [0:NLANES-1];
    integer            exp_n;

    // ---------------------------------------------------------------- DUT ----
    coalescer #(.NLANES(NLANES), .ADDR_W(ADDR_W), .OFF_W(OFF_W)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (req_valid),
        .req_ready (req_ready),
        .lane_addr (lane_addr),
        .lane_en   (lane_en),
        .txn_valid (txn_valid),
        .txn_ready (txn_ready),
        .txn_line  (txn_line),
        .txn_mask  (txn_mask),
        .txn_last  (txn_last)
    );

    // -------------------------------------------------------------- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ------------------------------------------------- golden reference -------
    // Reproduce the coalescing algorithm: emit unique lines in first-seen lane
    // order, each with the mask of the pending lanes that share the line.
    task compute_golden;
        integer i, k, leader;
        logic [NLANES-1:0] served, pending, mask;
        logic [LINE_W-1:0] sel;
        begin
            exp_n  = 0;
            served = '0;
            forever begin
                pending = ven & ~served;
                if (pending == '0) break;
                leader = -1;
                for (i = 0; i < NLANES; i = i + 1)
                    if (pending[i] && leader < 0) leader = i;
                sel  = va[leader][ADDR_W-1:OFF_W];
                mask = '0;
                for (k = 0; k < NLANES; k = k + 1)
                    if (pending[k] && (va[k][ADDR_W-1:OFF_W] == sel)) mask[k] = 1'b1;
                served = served | mask;
                exp_line[exp_n] = sel;
                exp_mask[exp_n] = mask;
                exp_last[exp_n] = ((ven & ~served) == '0);
                exp_n = exp_n + 1;
            end
        end
    endtask

    // Pack va[]/ven onto the request bus and present the request handshake.
    task drive_request;
        integer i;
        begin
            @(negedge clk);
            for (i = 0; i < NLANES; i = i + 1)
                lane_addr[i*ADDR_W +: ADDR_W] = va[i];
            lane_en   = ven;
            req_valid = 1'b1;
            // wait until accepted
            @(negedge clk);
            while (req_ready !== 1'b1) @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    // Collect the emitted transactions (with occasional back-pressure) and
    // compare against the golden lists. Handles the zero-transaction warp.
    task collect_and_check(input integer bp);
        integer idx;
        begin
            idx = 0;
            if (exp_n == 0) begin
                // no lines expected; make sure none are (briefly) produced
                repeat (3) begin
                    @(negedge clk);
                    if (txn_valid === 1'b1) begin
                        errors = errors + 1;
                        $display("[%0t] UNEXPECTED txn on empty warp", $time);
                    end
                end
                checks = checks + 1;
                $display("[%0t] OK   empty warp : 0 transactions", $time);
                return;
            end
            while (idx < exp_n) begin
                // optionally stall the sink to exercise back-pressure
                if (bp && ((idx % 2) == 1)) begin
                    txn_ready = 1'b0;
                    repeat (2) @(negedge clk);
                end
                txn_ready = 1'b1;
                @(negedge clk);
                if (txn_valid === 1'b1 && txn_ready === 1'b1) begin
                    checks = checks + 1;
                    if (txn_line !== exp_line[idx] ||
                        txn_mask !== exp_mask[idx] ||
                        txn_last !== exp_last[idx]) begin
                        errors = errors + 1;
                        $display("[%0t] MISMATCH #%0d got line=0x%0h mask=%b last=%0b  exp line=0x%0h mask=%b last=%0b",
                                 $time, idx, txn_line, txn_mask, txn_last,
                                 exp_line[idx], exp_mask[idx], exp_last[idx]);
                    end else begin
                        $display("[%0t] OK   #%0d line=0x%0h mask=%b last=%0b",
                                 $time, idx, txn_line, txn_mask, txn_last);
                    end
                    idx = idx + 1;
                end
            end
        end
    endtask

    task do_warp(input integer bp);
        begin
            compute_golden();
            fork
                drive_request();
                collect_and_check(bp);
            join
        end
    endtask

    // ------------------------------------------------------- stimulus --------
    integer i, j, w;

    initial begin
        req_valid = 1'b0;
        lane_addr = '0;
        lane_en   = '0;
        txn_ready = 1'b1;
        rst_n     = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("==== DIRECTED SHOWCASE (8 lanes -> 2 cache lines) ====");
        ven   = 8'hFF;
        va[0] = 32'h0000_1000;  // line 0x20
        va[1] = 32'h0000_1004;  // line 0x20
        va[2] = 32'h0000_1040;  // line 0x20
        va[3] = 32'h0000_2000;  // line 0x40
        va[4] = 32'h0000_2010;  // line 0x40
        va[5] = 32'h0000_1078;  // line 0x20
        va[6] = 32'h0000_2044;  // line 0x40
        va[7] = 32'h0000_1008;  // line 0x20
        do_warp(0);             // expect: line 0x20 mask=10100111, line 0x40 mask=01011000(last)

        $display("==== DIRECTED CORNERS ====");
        // all lanes same address -> 1 fully coalesced line
        for (i = 0; i < NLANES; i = i + 1) va[i] = 32'h0000_4000;
        ven = 8'hFF; do_warp(0);
        // per-lane stride -> 8 distinct lines (fully uncoalesced)
        for (i = 0; i < NLANES; i = i + 1) va[i] = 32'h0000_8000 + (i << OFF_W);
        ven = 8'hFF; do_warp(1);
        // partial active mask (lanes 0..3), two lines
        for (i = 0; i < NLANES; i = i + 1) va[i] = 32'h0000_C000 + ((i & 1) << OFF_W);
        ven = 8'h0F; do_warp(0);
        // all-disabled warp -> 0 transactions
        for (i = 0; i < NLANES; i = i + 1) va[i] = 32'h0000_E000;
        ven = 8'h00; do_warp(0);
        // single active lane -> one one-hot transaction
        for (i = 0; i < NLANES; i = i + 1) va[i] = 32'h0000_F000;
        ven = 8'h20; do_warp(0);

        $display("==== CONSTRAINED-RANDOM REGRESSION (random back-pressure) ====");
        for (w = 0; w < 120; w = w + 1) begin
            ven = $urandom_range(1, 255);                 // at least one active lane
            for (j = 0; j < NLANES; j = j + 1)
                // small window (4 lines * 128B) so warps mix coalesced/scattered
                va[j] = 32'h0001_0000 + ($urandom_range(0, 3) << OFF_W)
                                       + $urandom_range(0, (1<<OFF_W)-1);
            do_warp(w & 1);
        end

        repeat (4) @(negedge clk);
        $display("==== SUMMARY : %0d checks, %0d errors ====", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // -------------------------------------------------------- timeout ---------
    initial begin
        #500000;  // 500 us global watchdog
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ---------------------------------------------------------- dump ----------
    initial begin
        $dumpfile("tb_coalescer_dump.vcd");
        $dumpvars(0, tb_coalescer_dump);
    end

endmodule

`default_nettype wire
