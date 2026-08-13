// -----------------------------------------------------------------------------
// tb_warp_scan_dump.sv - portable, module-based, SELF-CHECKING testbench for the
// GPU warp-level parallel prefix-sum (scan) engine. Runs on open-source Icarus
// Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - an INCLUSIVE scan of the ramp 1,2,...,8, so
//     the captured VCD tells the classic story: an 8-lane input vector streams
//     in and, LAT cycles later, the eight output lanes come out as the running
//     TRIANGULAR NUMBERS 1,3,6,10,15,21,28,36 (out[i] = sum of in[0..i]),
//   * runs DIRECTED CORNERS (exclusive scan of the same ramp -> 0,1,3,6,...,
//     all-zero, a single one, alternating +1/-1 that toggles the running sum,
//     large-positive lanes that force a modular 16-bit WRAPAROUND, large-negative
//     lanes, and a zero-bubble back-to-back stream that fills the pipeline),
//   * runs a CONSTRAINED-RANDOM regression of random lanes + random mode, while
//     a golden reference model independently scans each vector,
//   * checks every scanned output vector against the golden model lane-by-lane,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in warp_scan_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_warp_scan_dump;

    localparam int N   = 8;
    localparam int DW  = 16;
    localparam int L   = 3;          // log2(8)
    localparam int LAT = L + 2;      // 5-cycle latency

    logic              clk;
    logic              rst_n;
    logic              in_valid;
    logic              in_excl;
    logic [N*DW-1:0]   in_data;
    logic              out_valid;
    logic              out_excl;
    logic [N*DW-1:0]   out_data;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    warp_scan #(.N(N), .DW(DW)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_excl  (in_excl),
        .in_data  (in_data),
        .out_valid(out_valid),
        .out_excl (out_excl),
        .out_data (out_data)
    );

    // ---- per-lane views broken out for a readable waveform -------------------
    logic [DW-1:0] in0, in1, in2, in3, in4, in5, in6, in7;
    logic [DW-1:0] out0, out1, out2, out3, out4, out5, out6, out7;
    assign in0 = in_data[0*DW +: DW];
    assign in1 = in_data[1*DW +: DW];
    assign in2 = in_data[2*DW +: DW];
    assign in3 = in_data[3*DW +: DW];
    assign in4 = in_data[4*DW +: DW];
    assign in5 = in_data[5*DW +: DW];
    assign in6 = in_data[6*DW +: DW];
    assign in7 = in_data[7*DW +: DW];
    assign out0 = out_data[0*DW +: DW];
    assign out1 = out_data[1*DW +: DW];
    assign out2 = out_data[2*DW +: DW];
    assign out3 = out_data[3*DW +: DW];
    assign out4 = out_data[4*DW +: DW];
    assign out5 = out_data[5*DW +: DW];
    assign out6 = out_data[6*DW +: DW];
    assign out7 = out_data[7*DW +: DW];

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------- expected-output FIFO (golden scoreboard) -----
    logic [N*DW-1:0] exp_q  [$];
    logic            expe_q [$];
    string           expn_q [$];

    // Modular DW-bit inclusive/exclusive prefix sum golden reference.
    function automatic logic [N*DW-1:0] golden(input logic [N*DW-1:0] vec,
                                               input logic excl);
        logic [DW-1:0] acc;
        logic [DW-1:0] lane;
        logic [N*DW-1:0] o;
        acc = '0;
        o   = '0;
        for (int i = 0; i < N; i++) begin
            lane = vec[i*DW +: DW];
            if (excl) begin
                o[i*DW +: DW] = acc;
                acc           = acc + lane;
            end else begin
                acc           = acc + lane;
                o[i*DW +: DW] = acc;
            end
        end
        return o;
    endfunction

    // -------------------------------------------------------- driver task -----
    task automatic drive_vec(input logic [N*DW-1:0] vec, input logic excl,
                             input string nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_excl  <= excl;
        in_data  <= vec;
        exp_q.push_back(golden(vec, excl));
        expe_q.push_back(excl);
        expn_q.push_back(nm);
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // ------------------------------------------------ scoreboard (monitor) -----
    logic [N*DW-1:0] eexp;
    logic            eexcl;
    string           enm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (exp_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                eexp  = exp_q.pop_front();
                eexcl = expe_q.pop_front();
                enm   = expn_q.pop_front();
                checks = checks + 1;
                if (out_data !== eexp) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH (%s excl=%0d):", $time, enm, eexcl);
                    for (int i = 0; i < N; i++)
                        $display("    lane%0d got 0x%04h exp 0x%04h",
                                 i, out_data[i*DW +: DW], eexp[i*DW +: DW]);
                end else if (out_excl !== eexcl) begin
                    errors = errors + 1;
                    $display("[%0t] MODE MISMATCH (%s): got %0d exp %0d",
                             $time, enm, out_excl, eexcl);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic [N*DW-1:0] rvec;
    int trials;

    // build a vector from a per-lane function is inlined below
    initial begin
        $dumpfile("tb_warp_scan_dump.vcd");
        $dumpvars(0, tb_warp_scan_dump);

        in_valid = 1'b0;
        in_excl  = 1'b0;
        in_data  = '0;
        rst_n    = 1'b0;
        repeat (4) @(posedge clk);
        rst_n    = 1'b1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: inclusive scan of the ramp 1..8 ----
        // in lanes 1,2,3,4,5,6,7,8 -> inclusive out 1,3,6,10,15,21,28,36.
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = DW'(i + 1);
        drive_vec(rvec, 1'b0, "showcase_inclusive_ramp");
        repeat (LAT + 3) @(posedge clk);      // let it drain, keep window clean

        // ---- CORNER: exclusive scan of the same ramp -> 0,1,3,6,... ----
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = DW'(i + 1);
        drive_vec(rvec, 1'b1, "exclusive_ramp");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: all zero (inclusive) -> all zero ----
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = '0;
        drive_vec(rvec, 1'b0, "all_zero");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: single one in the middle, exclusive ----
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = '0;
        rvec[(N/2)*DW +: DW] = DW'(1);
        drive_vec(rvec, 1'b1, "single_one_excl");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: alternating +1/-1 (running sum toggles 1,0,1,0,...) ----
        for (int i = 0; i < N; i++)
            rvec[i*DW +: DW] = (i % 2 == 0) ? DW'(1) : {DW{1'b1}};  // -1
        drive_vec(rvec, 1'b0, "alt_plus_minus_one");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: large positive lanes -> modular 16-bit WRAPAROUND ----
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = 16'h4000;
        drive_vec(rvec, 1'b0, "wraparound_inclusive");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: large negative lanes (running sum goes negative) ----
        for (int i = 0; i < N; i++) rvec[i*DW +: DW] = 16'hC000;   // -16384
        drive_vec(rvec, 1'b1, "large_negative_excl");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: back-to-back stream (fills the pipeline, no bubbles) ----
        for (int t = 0; t < 6; t++) begin
            for (int i = 0; i < N; i++)
                rvec[i*DW +: DW] = DW'($urandom_range(0, 16'hFFFF));
            @(posedge clk);
            in_valid <= 1'b1;
            in_excl  <= t[0];
            in_data  <= rvec;
            exp_q.push_back(golden(rvec, t[0]));
            expe_q.push_back(t[0]);
            expn_q.push_back($sformatf("stream_%0d", t));
        end
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 3) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression ----
        trials = 200;
        for (int t = 0; t < trials; t++) begin
            logic excl;
            excl = $urandom_range(0, 1);
            if (t % 4 == 0) begin
                // small signed values near 0: many sign flips, rare wrap
                for (int i = 0; i < N; i++) begin
                    int sv;
                    sv = $urandom_range(0, 16) - 8;         // [-8,8]
                    rvec[i*DW +: DW] = DW'(sv);
                end
            end else begin
                for (int i = 0; i < N; i++)
                    rvec[i*DW +: DW] = DW'($urandom_range(0, 16'hFFFF));
            end
            drive_vec(rvec, excl, $sformatf("rand_%0d", t));
            // vary the gap so the pipeline sees both isolated and dense traffic
            if (t % 3 == 0) repeat (2) @(posedge clk);
        end
        repeat (LAT + 5) @(posedge clk);

        // -------------------------------------------------------- verdict ----
        if (exp_q.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected vectors never appeared", exp_q.size());
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
        #200000;   // 200 us global watchdog
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
