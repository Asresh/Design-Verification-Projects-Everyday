// -----------------------------------------------------------------------------
// tb_cordic_rotation_dump.sv - portable, module-based, SELF-CHECKING testbench
// for the fully-pipelined ROTATION-MODE CORDIC engine. Runs on open-source
// Icarus Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - a sin/cos sweep (x_in = round(2^FRAC/K),
//     y_in = 0) across ten angles from -pi/2 up through 5*pi/6, back-to-back
//     (zero-bubble), so the captured VCD shows out_x tracking cos and out_y
//     tracking sin through every quadrant, including the >pi/2 QUADRANT-FOLD,
//   * runs DIRECTED CORNERS - zero angle (identity), +/-pi/2, angles just
//     beyond +/-pi/2 that exercise the fold, general (x_in, y_in) vector
//     rotations, and a min/max angle at +/-pi,
//   * runs a large CONSTRAINED-RANDOM campaign - random start vectors
//     (|x|,|y| <= 1.0) and random angles across the full [-pi, pi] range,
//   * for every accepted request an INDEPENDENT golden reference model computes
//     the expected rotation with real-valued math ($cos/$sin, times the CORDIC
//     gain K), and a fixed-latency in-order scoreboard checks the DUT's
//     {out_x, out_y} against it within a small fixed-point tolerance (the DUT
//     is a shift-add recurrence; the golden is language-level trig - genuinely
//     independent),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// TOLERANCE: a 16-bit, 16-iteration CORDIC with truncating shifts has a
// worst-case error of ~11 LSB (measured over 200k random rotations); the check
// uses TOL = 24 LSB (~0.003 of full scale) so it is comfortably above the
// finite-precision floor yet still catches any real functional break.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in cordic_rotation_pkg.sv + tb_top.sv for a
// UVM-capable simulator; this file exists so the design can be genuinely
// simulated (and a real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_cordic_rotation_dump;

    localparam int DW    = 16;
    localparam int AW    = 16;
    localparam int FRAC  = 13;
    localparam int NITER = 16;
    localparam int LAT   = NITER + 1;

    localparam real SCALE = 8192.0;               // 2^FRAC
    localparam real KGAIN = 1.6467602579;         // CORDIC processing gain
    localparam integer KINV = 4975;               // round(2^FRAC / K) -> cos/sin
    localparam integer TOL  = 24;                 // allowed |error| in LSB

    // angle landmarks in Q2.13 radians
    localparam integer A_0     = 0;
    localparam integer A_PI6   = 4289;            // pi/6
    localparam integer A_PI4   = 6434;            // pi/4
    localparam integer A_PI3   = 8578;            // pi/3
    localparam integer A_PI2   = 12868;           // pi/2
    localparam integer A_2PI3  = 17157;           // 2*pi/3  (folds)
    localparam integer A_3PI4  = 19302;           // 3*pi/4  (folds)
    localparam integer A_5PI6  = 21447;           // 5*pi/6  (folds)
    localparam integer A_PI    = 25736;           // pi

    logic                  clk;
    logic                  rst_n;
    logic                  in_valid;
    logic signed [DW-1:0]  in_x;
    logic signed [DW-1:0]  in_y;
    logic signed [AW-1:0]  in_angle;
    logic                  out_valid;
    logic signed [DW-1:0]  out_x;
    logic signed [DW-1:0]  out_y;
    logic signed [AW-1:0]  out_angle;

    integer errors = 0;
    integer checks = 0;

    // ----------------------------------------------------------------- DUT -----
    cordic_rotation #(.DW(DW), .AW(AW), .FRAC(FRAC), .NITER(NITER)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_x      (in_x),
        .in_y      (in_y),
        .in_angle  (in_angle),
        .out_valid (out_valid),
        .out_x     (out_x),
        .out_y     (out_y),
        .out_angle (out_angle)
    );

    // --------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;                          // 100 MHz, 10 ns period

    // ============================================================== GOLDEN =====
    // Independent real-valued rotation reference. The DUT is a fixed-point
    // shift-add recurrence; this model is language-level trig scaled by K.
    function automatic integer gexp_x(input integer xi, input integer yi,
                                      input integer ai);
        real a, xr, yr, v;
        begin
            a  = ai / SCALE;
            xr = xi / SCALE;
            yr = yi / SCALE;
            v  = KGAIN * (xr * $cos(a) - yr * $sin(a)) * SCALE;
            gexp_x = (v >= 0.0) ? $rtoi(v + 0.5) : $rtoi(v - 0.5);
        end
    endfunction

    function automatic integer gexp_y(input integer xi, input integer yi,
                                      input integer ai);
        real a, xr, yr, v;
        begin
            a  = ai / SCALE;
            xr = xi / SCALE;
            yr = yi / SCALE;
            v  = KGAIN * (xr * $sin(a) + yr * $cos(a)) * SCALE;
            gexp_y = (v >= 0.0) ? $rtoi(v + 0.5) : $rtoi(v - 0.5);
        end
    endfunction

    // --------------------------------------------- fixed-latency scoreboard ----
    // Zero-bubble, fixed-latency pipe -> a simple in-order expected FIFO built
    // from index counters (no SV queues, so it stays Icarus-portable).
    localparam integer MAXQ = 8192;
    integer exp_x  [0:MAXQ-1];
    integer exp_y  [0:MAXQ-1];
    integer exp_a  [0:MAXQ-1];
    integer wr_ptr = 0;
    integer rd_ptr = 0;

    // ----------------------------------------------------------- stimulus ------
    // Apply one request on the driving edge and enqueue its golden expectation.
    task automatic issue(input integer xi, input integer yi, input integer ai);
        begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_x     <= xi[DW-1:0];
            in_y     <= yi[DW-1:0];
            in_angle <= ai[AW-1:0];
            exp_x[wr_ptr % MAXQ] = gexp_x(xi, yi, ai);
            exp_y[wr_ptr % MAXQ] = gexp_y(xi, yi, ai);
            exp_a[wr_ptr % MAXQ] = ai;
            wr_ptr = wr_ptr + 1;
        end
    endtask

    task automatic idle(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                in_valid <= 1'b0;
            end
        end
    endtask

    // ------------------------------------------------------------- checker -----
    // Pop the expected FIFO in arrival order every time a result is presented.
    integer dx, dy, ex, ey, ea;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (rd_ptr >= wr_ptr) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD ERROR: unexpected out_valid (empty FIFO)", $time);
            end else begin
                ex = exp_x[rd_ptr % MAXQ];
                ey = exp_y[rd_ptr % MAXQ];
                ea = exp_a[rd_ptr % MAXQ];
                dx = $signed(out_x) - ex;
                dy = $signed(out_y) - ey;
                if (dx < 0) dx = -dx;
                if (dy < 0) dy = -dy;
                checks = checks + 1;
                if (dx > TOL || dy > TOL) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH #%0d angle=%0d: x got %0d exp %0d (|d|=%0d), y got %0d exp %0d (|d|=%0d)",
                             $time, rd_ptr, ea, $signed(out_x), ex, dx, $signed(out_y), ey, dy);
                end
                if ($signed(out_angle) !== ea) begin
                    errors = errors + 1;
                    $display("[%0t] ANGLE-ECHO MISMATCH #%0d: got %0d exp %0d",
                             $time, rd_ptr, $signed(out_angle), ea);
                end
                rd_ptr = rd_ptr + 1;
            end
        end
    end

    // ------------------------------------------------------------- driver ------
    integer i, ang, xr0, yr0;
    integer seed = 32'hC0FFEE05;
    initial begin
        in_valid = 1'b0; in_x = '0; in_y = '0; in_angle = '0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: sin/cos sweep (x=KINV, y=0), zero-bubble ----
        // out_x tracks cos, out_y tracks sin through all quadrants + the fold.
        issue(KINV, 0, -A_PI2);
        issue(KINV, 0, -A_PI4);
        issue(KINV, 0,  A_0  );
        issue(KINV, 0,  A_PI6);
        issue(KINV, 0,  A_PI4);
        issue(KINV, 0,  A_PI3);
        issue(KINV, 0,  A_PI2);
        issue(KINV, 0,  A_2PI3);   // folds
        issue(KINV, 0,  A_3PI4);   // folds
        issue(KINV, 0,  A_5PI6);   // folds
        idle(4);

        // ---- DIRECTED CORNERS ----
        issue(KINV, 0,  A_0);              // identity: x=cos0, y=sin0
        issue(KINV, 0,  A_PI);             // +pi
        issue(KINV, 0, -A_PI);             // -pi
        issue(8192, 0,  A_PI2);            // unit +x rotated +90 deg -> +y
        issue(0,    8192, A_PI2);          // unit +y rotated +90 deg -> -x
        issue(8192, 8192, A_PI4);          // general vector, +45 deg
        issue(-4096, 2048, -A_PI3);        // general negative vector
        issue(8192, -8192, A_5PI6);        // general vector into fold region
        idle(4);

        // ---- CONSTRAINED-RANDOM CAMPAIGN ----
        for (i = 0; i < 4000; i = i + 1) begin
            xr0 = $random(seed) % (8192 + 1);       // [-8192, 8192] = +/-1.0
            yr0 = $random(seed) % (8192 + 1);       // (signed % yields +/-range)
            ang = $random(seed) % (A_PI + 1);       // [-pi, pi]
            issue(xr0, yr0, ang);
        end
        idle(LAT + 8);

        // ---------------------------------------------------------- report -----
        if (rd_ptr !== wr_ptr) begin
            errors = errors + 1;
            $display("SCOREBOARD ERROR: %0d issued but %0d retired", wr_ptr, rd_ptr);
        end
        $display("-----------------------------------------------------------");
        $display("cordic_rotation: %0d transactions checked, %0d error(s)", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (%0d error(s))", errors);
        $display("-----------------------------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------ timeout ------
    initial begin
        #500000;
        $display("RESULT: *** FAIL ***  (global timeout)");
        $finish;
    end

    // --------------------------------------------------------------- dump ------
    initial begin
        $dumpfile("tb_cordic_rotation_dump.vcd");
        $dumpvars(0, tb_cordic_rotation_dump);
    end

endmodule

`default_nettype wire
