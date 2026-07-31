// -----------------------------------------------------------------------------
// tb_warp_bitonic_sort_dump.sv - portable, module-based, SELF-CHECKING testbench
// for the GPU warp-level bitonic sorting network. Runs on open-source Icarus
// Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - an ascending sort of a fully reverse-sorted
//     8-record warp, so the captured VCD tells the classic story: a jumbled
//     input vector streams in and, LAT cycles later, the eight output lanes come
//     out as a clean monotonic ramp (lane 0 smallest ... lane 7 largest),
//   * runs DIRECTED CORNERS (descending sort, already-sorted input, all-equal
//     keys with distinct tags to prove the tie-break, all-identical records,
//     min/max extremes, single large element, and a back-to-back stream that
//     fills the pipeline with no bubbles),
//   * runs a CONSTRAINED-RANDOM regression of random records + random direction,
//     including forced-duplicate-key vectors, while a golden reference model
//     independently sorts each vector,
//   * checks every sorted output vector against the golden model lane-by-lane
//     (which also proves it is a permutation of the input AND monotonic),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in warp_bitonic_sort_pkg.sv + tb_top.sv for a UVM-
// capable simulator; this file exists so the design can be genuinely simulated
// (and a real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_warp_bitonic_sort_dump;

    localparam int N      = 8;
    localparam int KEY_W  = 6;
    localparam int TAG_W  = 2;
    localparam int RW     = KEY_W + TAG_W;               // 8-bit records
    localparam int L      = 3;                           // log2(8)
    localparam int NSTAGE = (L * (L + 1)) / 2;           // 6 layers
    localparam int LAT    = NSTAGE + 1;                  // 7-cycle latency

    logic                clk;
    logic                rst_n;
    logic                in_valid;
    logic                in_dir;
    logic [N*RW-1:0]     in_data;
    logic                out_valid;
    logic                out_dir;
    logic [N*RW-1:0]     out_data;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    warp_bitonic_sort #(.N(N), .KEY_W(KEY_W), .TAG_W(TAG_W)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_dir   (in_dir),
        .in_data  (in_data),
        .out_valid(out_valid),
        .out_dir  (out_dir),
        .out_data (out_data)
    );

    // ---- per-lane views broken out for a readable waveform -------------------
    logic [RW-1:0] out0, out1, out2, out3, out4, out5, out6, out7;
    assign out0 = out_data[0*RW +: RW];
    assign out1 = out_data[1*RW +: RW];
    assign out2 = out_data[2*RW +: RW];
    assign out3 = out_data[3*RW +: RW];
    assign out4 = out_data[4*RW +: RW];
    assign out5 = out_data[5*RW +: RW];
    assign out6 = out_data[6*RW +: RW];
    assign out7 = out_data[7*RW +: RW];

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------- expected-output FIFO (golden scoreboard) -----
    // Each accepted vector pushes its golden-sorted packed vector + direction.
    logic [N*RW-1:0] exp_q   [$];
    logic            expd_q  [$];
    string           expn_q  [$];   // label for diagnostics

    // Insertion-sort golden reference over RW-bit records (dir: 0=asc,1=desc).
    function automatic logic [N*RW-1:0] golden(input logic [N*RW-1:0] vec,
                                               input logic dir);
        logic [RW-1:0] a [0:N-1];
        logic [RW-1:0] key;
        logic [N*RW-1:0] o;
        int j;
        for (int i = 0; i < N; i++) a[i] = vec[i*RW +: RW];
        for (int i = 1; i < N; i++) begin
            key = a[i];
            j = i - 1;
            while (j >= 0 && ((dir == 1'b0) ? (a[j] > key) : (a[j] < key))) begin
                a[j+1] = a[j];
                j = j - 1;
            end
            a[j+1] = key;
        end
        o = '0;
        for (int i = 0; i < N; i++) o[i*RW +: RW] = a[i];
        return o;
    endfunction

    // Build a record from a key + tag.
    function automatic logic [RW-1:0] rec(input int unsigned key, input int unsigned tag);
        return {key[KEY_W-1:0], tag[TAG_W-1:0]};
    endfunction

    // -------------------------------------------------------- driver task -----
    // Present one vector for a single cycle and enqueue its golden result.
    task automatic drive_vec(input logic [N*RW-1:0] vec, input logic dir, input string nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_dir   <= dir;
        in_data  <= vec;
        exp_q.push_back(golden(vec, dir));
        expd_q.push_back(dir);
        expn_q.push_back(nm);
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // ------------------------------------------------ scoreboard (monitor) -----
    // Sample outputs shortly after each rising edge; every out_valid pops the
    // FIFO front and compares lane-by-lane against the golden vector.
    logic [N*RW-1:0] eexp;
    logic            edir;
    string           enm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (exp_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                eexp = exp_q.pop_front();
                edir = expd_q.pop_front();
                enm  = expn_q.pop_front();
                checks = checks + 1;
                if (out_data !== eexp) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH (%s dir=%0d):", $time, enm, edir);
                    for (int i = 0; i < N; i++)
                        $display("    lane%0d got 0x%02h exp 0x%02h",
                                 i, out_data[i*RW +: RW], eexp[i*RW +: RW]);
                end else if (out_dir !== edir) begin
                    errors = errors + 1;
                    $display("[%0t] DIR MISMATCH (%s): got %0d exp %0d",
                             $time, enm, out_dir, edir);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic [N*RW-1:0] rvec;
    int trials;

    initial begin
        $dumpfile("tb_warp_bitonic_sort_dump.vcd");
        $dumpvars(0, tb_warp_bitonic_sort_dump);

        in_valid = 1'b0;
        in_dir   = 1'b0;
        in_data  = '0;
        rst_n    = 1'b0;
        repeat (4) @(posedge clk);
        rst_n    = 1'b1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: ascending sort of a reverse ramp ----
        // keys 0x1C,0x18,...,0x00 (tag 0) -> input lane0 largest, lane7 smallest
        // Ascending output = clean monotonic ramp 0x00,0x10,...,0x70 by lane.
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec((N-1-i)*4, 0);
        drive_vec(rvec, 1'b0, "showcase_asc_reverse_ramp");
        repeat (LAT + 3) @(posedge clk);      // let it drain, keep window clean

        // ---- CORNER: descending sort of an ascending ramp ----
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec(i*4, 0);
        drive_vec(rvec, 1'b1, "desc_of_ascending");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: already sorted ascending (identity) ----
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec(i*4, 0);
        drive_vec(rvec, 1'b0, "already_sorted");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: all-equal keys, distinct tags -> tie-break by tag ----
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec(6'h15, (N-1-i));
        drive_vec(rvec, 1'b0, "equal_keys_tie_break");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: all identical records ----
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec(6'h2A, 2'h1);
        drive_vec(rvec, 1'b0, "all_identical");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: min/max extremes interleaved ----
        for (int i = 0; i < N; i++)
            rvec[i*RW +: RW] = (i % 2 == 0) ? rec(6'h00, 0) : rec(6'h3F, 3);
        drive_vec(rvec, 1'b0, "min_max_extremes");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: single large element among zeros ----
        for (int i = 0; i < N; i++) rvec[i*RW +: RW] = rec(6'h00, 0);
        rvec[3*RW +: RW] = rec(6'h3F, 0);
        drive_vec(rvec, 1'b1, "single_large_desc");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: back-to-back stream (fills the pipeline, no bubbles) ----
        for (int t = 0; t < 6; t++) begin
            for (int i = 0; i < N; i++)
                rvec[i*RW +: RW] = rec($urandom_range(0, 63), $urandom_range(0, 3));
            @(posedge clk);
            in_valid <= 1'b1;
            in_dir   <= t[0];
            in_data  <= rvec;
            exp_q.push_back(golden(rvec, t[0]));
            expd_q.push_back(t[0]);
            expn_q.push_back($sformatf("stream_%0d", t));
        end
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 3) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression ----
        trials = 200;
        for (int t = 0; t < trials; t++) begin
            logic dir;
            dir = $urandom_range(0, 1);
            if (t % 5 == 0) begin
                // force duplicate keys: only 3 distinct key values
                for (int i = 0; i < N; i++)
                    rvec[i*RW +: RW] = rec(($urandom_range(0, 2) * 6'h14), $urandom_range(0, 3));
            end else begin
                for (int i = 0; i < N; i++)
                    rvec[i*RW +: RW] = rec($urandom_range(0, 63), $urandom_range(0, 3));
            end
            drive_vec(rvec, dir, $sformatf("rand_%0d", t));
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
