// -----------------------------------------------------------------------------
// tb_seq_divider_dump.sv - portable, module-based, SELF-CHECKING testbench for
// seq_divider. This is the companion TB that runs on open-source Icarus Verilog
// (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE division first (200 / 7 = 28 r4) so the
//     captured VCD window tells a clean story,
//   * runs a battery of DIRECTED CORNER cases (x/0, x/1, a<b, max/max, 0/x),
//   * runs a CONSTRAINED-RANDOM regression of many divisions,
//   * checks every result against an independent golden reference model
//     (SystemVerilog `/` and `%`, plus the explicit x/0 convention),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/sequences/virtual
// sequences + SVA) lives in seq_divider_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_seq_divider_dump;

    localparam int WIDTH = 8;

    logic              clk;
    logic              rst_n;
    logic              start;
    logic [WIDTH-1:0]  dividend;
    logic [WIDTH-1:0]  divisor;
    logic              busy;
    logic              done;
    logic [WIDTH-1:0]  quotient;
    logic [WIDTH-1:0]  remainder;
    logic              dbz;

    // convenient decimal mirrors for readable VCD text
    // (kept as separate nets so a waveform viewer shows them as buses)
    logic [WIDTH-1:0]  tx_data;   // = dividend (alias for the waveform script)
    logic [WIDTH-1:0]  rx_data;   // = quotient (alias for the waveform script)
    assign tx_data = dividend;
    assign rx_data = quotient;

    int unsigned errors = 0;
    int unsigned checks = 0;

    // ---------------------------------------------------------------- DUT ----
    seq_divider #(.WIDTH(WIDTH)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .dividend  (dividend),
        .divisor   (divisor),
        .busy      (busy),
        .done      (done),
        .quotient  (quotient),
        .remainder (remainder),
        .dbz       (dbz)
    );

    // -------------------------------------------------------------- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ------------------------------------------------- golden reference -------
    task automatic ref_divide(
        input  logic [WIDTH-1:0] a,
        input  logic [WIDTH-1:0] b,
        output logic [WIDTH-1:0] q,
        output logic [WIDTH-1:0] r,
        output logic             z
    );
        if (b == '0) begin
            z = 1'b1;
            q = '1;      // x/0 convention: all-ones quotient
            r = a;       // x/0 convention: remainder = dividend
        end else begin
            z = 1'b0;
            q = a / b;
            r = a % b;
        end
    endtask

    // ----------------------------------------- one full division + check -----
    task automatic do_div(input logic [WIDTH-1:0] a, input logic [WIDTH-1:0] b);
        logic [WIDTH-1:0] eq, er;
        logic             ez;

        ref_divide(a, b, eq, er, ez);

        // Drive a single-cycle start with operands, honoring the !busy rule.
        @(negedge clk);
        wait (!busy);
        dividend = a;
        divisor  = b;
        start    = 1'b1;
        @(negedge clk);
        start    = 1'b0;

        // Wait for the one-cycle done pulse.
        @(posedge done);
        #1;  // let registered outputs settle for sampling

        checks++;
        if (quotient !== eq || remainder !== er || dbz !== ez) begin
            errors++;
            $display("[%0t] MISMATCH  %0d / %0d : got q=%0d r=%0d dbz=%0b  exp q=%0d r=%0d dbz=%0b",
                     $time, a, b, quotient, remainder, dbz, eq, er, ez);
        end else begin
            $display("[%0t] OK        %0d / %0d = q=%0d r=%0d dbz=%0b",
                     $time, a, b, quotient, remainder, dbz);
        end
    endtask

    // ------------------------------------------------------- stimulus --------
    int unsigned i;
    logic [WIDTH-1:0] ra, rb;

    initial begin
        start    = 1'b0;
        dividend = '0;
        divisor  = '0;
        rst_n    = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("==== DIRECTED SHOWCASE ====");
        do_div(8'd200, 8'd7);     // 28 r4  <- captured in the waveform window

        $display("==== DIRECTED CORNERS ====");
        do_div(8'd0,   8'd5);     // 0 / x  = 0 r0
        do_div(8'd13,  8'd1);     // x / 1  = x r0
        do_div(8'd5,   8'd9);     // a < b  = 0 r5
        do_div(8'd255, 8'd255);   // max/max= 1 r0
        do_div(8'd255, 8'd1);     // max/1  = 255 r0
        do_div(8'd42,  8'd0);     // x / 0  -> dbz, q=255, r=42
        do_div(8'd128, 8'd0);     // x / 0  -> dbz, q=255, r=128

        $display("==== CONSTRAINED-RANDOM REGRESSION ====");
        for (i = 0; i < 200; i++) begin
            ra = $urandom_range(0, 255);
            // bias toward non-zero divisors, but keep ~1/16 zero to exercise dbz
            rb = ($urandom_range(0, 15) == 0) ? 8'd0 : $urandom_range(1, 255);
            do_div(ra, rb);
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
        #200000;  // 200 us global watchdog
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ---------------------------------------------------------- dump ----------
    initial begin
        $dumpfile("tb_seq_divider_dump.vcd");
        $dumpvars(0, tb_seq_divider_dump);
    end

endmodule

`default_nettype wire
