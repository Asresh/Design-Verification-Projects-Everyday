// -----------------------------------------------------------------------------
// tb_mac_dot_dump.sv - portable, module-based, SELF-CHECKING testbench for
// mac_dot. This is the companion TB that runs on open-source Icarus Verilog
// (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE dot product first
//     ( a=[3,5,-2,4] . b=[2,4,7,1] = 6+20-14+4 = 16 ) so the captured VCD
//     window tells a clean, readable story,
//   * runs a battery of DIRECTED CORNER cases (length-1, all-zero,
//     all-negative, most-negative-magnitude),
//   * runs a CONSTRAINED-RANDOM regression of many random-length vectors,
//   * checks every emitted result against an independent golden reference model
//     (signed dot product with ACC_W-width 2's-complement wraparound),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitors/scoreboard/coverage/virtual
// sequences + SVA) lives in mac_dot_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain. The current
// dot-product vector lives in module-scope fixed arrays (MAX_L deep) with a
// cur_len count, which keeps the driver portable across Icarus Verilog.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_mac_dot_dump;

    localparam int A_W   = 8;
    localparam int ACC_W = 32;
    localparam int MAX_L = 32;

    logic                      clk;
    logic                      rst_n;
    logic                      in_valid;
    logic signed [A_W-1:0]     in_a;
    logic signed [A_W-1:0]     in_b;
    logic                      in_last;
    logic                      out_valid;
    logic signed [ACC_W-1:0]   out_result;

    // Mirror of the DUT's internal accumulator so the waveform can show the
    // running sum build up element by element (dumped as a top-level bus).
    logic signed [ACC_W-1:0]   acc_mirror;
    assign acc_mirror = dut.acc;

    integer errors = 0;
    integer checks = 0;

    // Current vector under test (module scope fixed arrays -> Icarus-friendly).
    logic signed [A_W-1:0]   va [0:MAX_L-1];
    logic signed [A_W-1:0]   vb [0:MAX_L-1];
    integer                  cur_len;
    logic signed [ACC_W-1:0] exp_result;

    // ---------------------------------------------------------------- DUT ----
    mac_dot #(.A_W(A_W), .ACC_W(ACC_W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .in_a       (in_a),
        .in_b       (in_b),
        .in_last    (in_last),
        .out_valid  (out_valid),
        .out_result (out_result)
    );

    // -------------------------------------------------------------- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ------------------------------------------------- golden reference -------
    // Compute the signed dot product of va/vb[0:cur_len-1] into exp_result,
    // with ACC_W-width 2's-complement wraparound (matches the DUT exactly).
    task compute_golden;
        integer i;
        begin
            exp_result = '0;
            for (i = 0; i < cur_len; i = i + 1)
                exp_result = exp_result +
                    ($signed(va[i]) * $signed(vb[i]));
        end
    endtask

    // ---------------------------------- drive current vector and check --------
    // Drives va/vb element by element (one in_valid per clock), then waits for
    // the one-cycle out_valid pulse and compares against the golden model.
    task do_dot;
        integer i;
        begin
            compute_golden();
            for (i = 0; i < cur_len; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_a     = va[i];
                in_b     = vb[i];
                in_last  = (i == cur_len-1);
            end
            @(negedge clk);
            in_valid = 1'b0;
            in_last  = 1'b0;

            // out_valid pulses the cycle after in_last was accepted; sample it
            // on negedges (level check) so a one-cycle pulse is never missed.
            while (out_valid !== 1'b1) @(negedge clk);

            checks = checks + 1;
            if (out_result !== exp_result) begin
                errors = errors + 1;
                $display("[%0t] MISMATCH len=%0d : got=%0d exp=%0d",
                         $time, cur_len, out_result, exp_result);
            end else begin
                $display("[%0t] OK       len=%0d : result=%0d",
                         $time, cur_len, out_result);
            end
        end
    endtask

    // Helper: load a directed vector from literal arrays into va/vb.
    task load2(input integer a0, a1, b0, b1);
        begin cur_len=2; va[0]=a0; va[1]=a1; vb[0]=b0; vb[1]=b1; end
    endtask
    task load3(input integer a0, a1, a2, b0, b1, b2);
        begin cur_len=3; va[0]=a0; va[1]=a1; va[2]=a2; vb[0]=b0; vb[1]=b1; vb[2]=b2; end
    endtask

    // ------------------------------------------------------- stimulus --------
    integer i, j;

    initial begin
        in_valid = 1'b0;
        in_a     = '0;
        in_b     = '0;
        in_last  = 1'b0;
        rst_n    = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("==== DIRECTED SHOWCASE ====");
        cur_len = 4;
        va[0]= 3; va[1]= 5; va[2]=-2; va[3]= 4;
        vb[0]= 2; vb[1]= 4; vb[2]= 7; vb[3]= 1;   // 6+20-14+4 = 16 (waveform)
        do_dot();

        $display("==== DIRECTED CORNERS ====");
        cur_len = 1; va[0]=7;  vb[0]=6;  do_dot();          // length-1 : 42
        load3(0, 0, 0, 5, 9, 1);              do_dot();     // all zero : 0
        load3(-4, -3, -2, -5, -6, -7);        do_dot();     // all neg  : 52
        load2(-128, 127, -128, -128);         do_dot();     // mag stress: 128

        $display("==== CONSTRAINED-RANDOM REGRESSION ====");
        for (i = 0; i < 150; i = i + 1) begin
            cur_len = ($urandom_range(1, MAX_L));
            for (j = 0; j < cur_len; j = j + 1) begin
                va[j] = $urandom_range(0, 255);   // reinterpreted signed [-128,127]
                vb[j] = $urandom_range(0, 255);
            end
            do_dot();
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
        $dumpfile("tb_mac_dot_dump.vcd");
        $dumpvars(0, tb_mac_dot_dump);
    end

endmodule

`default_nettype wire
