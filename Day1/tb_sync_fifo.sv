// -----------------------------------------------------------------------------
// tb_sync_fifo.sv
// Self-checking, class-based testbench for sync_fifo.
//
// Verification strategy
//   * Reference model : a SystemVerilog queue ($ dynamic queue) mirrors the
//     ideal FIFO. Every accepted write pushes into the queue; every accepted
//     read pops from it and is compared against the DUT rd_data (scoreboard).
//   * Stimulus        : a directed phase (fill-to-full, drain-to-empty,
//     simultaneous read+write) followed by a long constrained-random phase.
//   * Coverage        : covergroup over the {wr_en,rd_en} cross plus full/empty
//     corner states, so we can see we exercised overflow/underflow pressure.
//   * Assertions      : SVA immediate/concurrent checks on the status flags and
//     the count bounds (overflow / underflow can never be observed).
//   * Safety          : a global timeout guards against a hang; VCD is dumped.
//
// Prints "RESULT: *** PASS ***" only if zero mismatches and zero assertion
// failures were seen.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_sync_fifo;

    // ----------------------- Parameters ------------------------------------
    localparam int WIDTH = 8;
    localparam int DEPTH = 8;
    localparam int N_TRANS = 2000;   // random transactions to attempt

    // ----------------------- DUT hookup -------------------------------------
    logic                   clk;
    logic                   rst_n;
    logic                   wr_en;
    logic [WIDTH-1:0]       wr_data;
    logic                   rd_en;
    logic [WIDTH-1:0]       rd_data;
    logic                   full;
    logic                   empty;
    logic [$clog2(DEPTH):0] count;

    sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_data(wr_data),
        .rd_en(rd_en), .rd_data(rd_data),
        .full(full), .empty(empty), .count(count)
    );

    // ----------------------- Clock ------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ----------------------- Bookkeeping ------------------------------------
    int unsigned errors     = 0;
    int unsigned writes_done = 0;
    int unsigned reads_done  = 0;

    // Reference model: golden ordered store.
    logic [WIDTH-1:0] ref_q [$];

    // ----------------------- Functional coverage ----------------------------
    logic sample_en;
    covergroup fifo_cg @(posedge clk iff sample_en);
        option.per_instance = 1;
        cp_op : coverpoint {wr_en, rd_en} {
            bins idle       = {2'b00};
            bins read_only  = {2'b01};
            bins write_only = {2'b10};
            bins rd_wr_both = {2'b11};
        }
        cp_full  : coverpoint full  { bins lo = {0}; bins hi = {1}; }
        cp_empty : coverpoint empty { bins lo = {0}; bins hi = {1}; }
        // Cross: did we push writes while full, and reads while empty (backpressure)?
        x_op_full  : cross cp_op, cp_full;
        x_op_empty : cross cp_op, cp_empty;
    endgroup
    fifo_cg cg = new();

    // ----------------------- Assertions (SVA) --------------------------------
    // count must never exceed DEPTH nor wrap below 0.
    property p_count_bound;
        @(posedge clk) disable iff (!rst_n) (count <= DEPTH);
    endproperty
    a_count_bound : assert property (p_count_bound)
        else begin errors++; $error("count exceeded DEPTH: %0d", count); end

    // full and empty are mutually exclusive whenever DEPTH>0.
    property p_full_empty_excl;
        @(posedge clk) disable iff (!rst_n) !(full && empty);
    endproperty
    a_full_empty_excl : assert property (p_full_empty_excl)
        else begin errors++; $error("full and empty asserted simultaneously"); end

    // flag/count consistency
    property p_empty_iff;
        @(posedge clk) disable iff (!rst_n) (empty == (count == 0));
    endproperty
    a_empty_iff : assert property (p_empty_iff)
        else begin errors++; $error("empty flag inconsistent with count"); end

    property p_full_iff;
        @(posedge clk) disable iff (!rst_n) (full == (count == DEPTH));
    endproperty
    a_full_iff : assert property (p_full_iff)
        else begin errors++; $error("full flag inconsistent with count"); end

    // ----------------------- Scoreboard task ---------------------------------
    // Called every cycle in the same clocked region as the DUT update so the
    // reference model tracks acceptance identically to the RTL.
    task automatic drive_and_check(input logic w, input logic [WIDTH-1:0] wd,
                                   input logic r);
        logic do_wr, do_rd;
        logic [WIDTH-1:0] exp;
        // Predict acceptance using pre-edge status (combinational flags).
        do_wr = w & ~full;
        do_rd = r & ~empty;

        // For a read, capture expected value BEFORE the clock consumes it.
        if (do_rd) exp = ref_q[0];

        // Apply stimulus and advance one clock.
        wr_en   = w;
        wr_data = wd;
        rd_en   = r;
        @(posedge clk);
        #1; // let combinational rd_data settle after the edge

        // Update reference model to match what the DUT accepted.
        if (do_wr) begin ref_q.push_back(wd); writes_done++; end
        if (do_rd) begin
            reads_done++;
            // rd_data was valid combinationally *before* the pop advanced rd_ptr;
            // compare against the value captured pre-edge.
            if (rd_data !== exp) begin
                errors++;
                $error("[%0t] SCOREBOARD MISMATCH: got 0x%02h expected 0x%02h",
                       $time, rd_data, exp);
            end
            void'(ref_q.pop_front());
        end

        // Occupancy cross-check against the golden model.
        if (count !== ref_q.size()) begin
            errors++;
            $error("[%0t] COUNT MISMATCH: dut=%0d ref=%0d", $time, count, ref_q.size());
        end
    endtask

    // ----------------------- Stimulus ----------------------------------------
    initial begin
        // Waveform dump
        $dumpfile("sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);

        // Init + reset
        sample_en = 0;
        wr_en = 0; rd_en = 0; wr_data = '0;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        sample_en = 1;

        // -------- Directed phase --------
        // 1) Fill to full, attempt one overflow write (must be dropped).
        for (int i = 0; i < DEPTH; i++)
            drive_and_check(1'b1, WIDTH'(8'hA0 + i), 1'b0);
        assert (full) else begin errors++; $error("FIFO not full after DEPTH writes"); end
        drive_and_check(1'b1, 8'hFF, 1'b0);   // overflow attempt, should be ignored

        // 2) Drain to empty, attempt one underflow read (must be dropped).
        for (int i = 0; i < DEPTH; i++)
            drive_and_check(1'b0, 8'h00, 1'b1);
        assert (empty) else begin errors++; $error("FIFO not empty after DEPTH reads"); end
        drive_and_check(1'b0, 8'h00, 1'b1);   // underflow attempt, should be ignored

        // 3) Simultaneous read+write while partially filled.
        drive_and_check(1'b1, 8'h11, 1'b0);
        drive_and_check(1'b1, 8'h22, 1'b0);
        repeat (4) drive_and_check(1'b1, WIDTH'($urandom), 1'b1);

        // -------- Constrained-random phase --------
        for (int i = 0; i < N_TRANS; i++) begin
            logic w, r;
            logic [WIDTH-1:0] d;
            // Constraint: bias toward keeping the FIFO exercised near both
            // corners. ~60% write attempt, ~55% read attempt (independent),
            // producing a healthy mix of idle/read/write/both.
            w = ($urandom_range(0, 99) < 60);
            r = ($urandom_range(0, 99) < 55);
            d = WIDTH'($urandom);
            drive_and_check(w, d, r);
        end

        // Drain whatever remains so the model empties cleanly.
        while (ref_q.size() > 0)
            drive_and_check(1'b0, 8'h00, 1'b1);

        sample_en = 0;
        wr_en = 0; rd_en = 0;
        repeat (2) @(posedge clk);

        // ----------------------- Verdict ------------------------------------
        $display("----------------------------------------------------------");
        $display("Transactions: writes=%0d reads=%0d", writes_done, reads_done);
        $display("Functional coverage: %0.2f%%", cg.get_inst_coverage());
        $display("Errors: %0d", errors);
        if (errors == 0) begin
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        end
        $display("----------------------------------------------------------");
        $finish;
    end

    // ----------------------- Timeout watchdog --------------------------------
    initial begin
        #500000; // 500 us hard cap
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $fatal(1, "Global timeout reached");
    end

endmodule
