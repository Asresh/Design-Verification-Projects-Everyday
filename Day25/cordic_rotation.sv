// -----------------------------------------------------------------------------
// cordic_rotation.sv - Fully-pipelined ROTATION-MODE CORDIC engine.
//
// The canonical "shift-and-add" vector rotator behind every hardware sin/cos
// generator, polar<->rectangular converter, phase rotator (DDS / QAM modem /
// software-defined radio), and FFT twiddle-multiply. Given a start vector
// (x_in, y_in) and a rotation angle z (radians, signed fixed-point), it emits
//
//     x_out ~= K * ( x_in*cos(z) - y_in*sin(z) )
//     y_out ~= K * ( x_in*sin(z) + y_in*cos(z) )
//
// using ONLY adders, subtracters and hard-wired shifts - no multiplier and no
// lookup of sin/cos. Each micro-rotation i turns the vector by +/-atan(2^-i);
// summing the elementary angles drives the angle accumulator z toward 0, at
// which point the residual (x,y) is the input rotated by the requested angle,
// magnified by the fixed CORDIC processing gain
//
//     K = prod_{i=0}^{NITER-1} sqrt(1 + 2^-2i)  ~= 1.64676   (gain-uncompensated).
//
// To read cos/sin directly, preload x_in = round(2^FRAC / K) (= 4975 for the
// defaults) and y_in = 0; then x_out ~= cos(z)*2^FRAC, y_out ~= sin(z)*2^FRAC.
//
// Rotation-mode CORDIC only converges for |z| <= sum atan(2^-i) ~= 1.7433 rad,
// so a combinational QUADRANT-FOLD pre-stage maps any angle in [-pi, pi] into
// [-pi/2, pi/2] (< 1.5708 < 1.7433) by rotating an extra +/-pi and negating the
// start vector (rotating by pi negates a 2-D vector). The result is a full
// [-pi, pi] rotator.
//
// FORM: fixed-latency, fully-pipelined, ZERO-BUBBLE. One transaction may be
// accepted every cycle; a request presented with in_valid=1 produces its result
// LAT = NITER+1 cycles later with out_valid=1 (1 input/fold register + NITER
// pipelined micro-rotation stages). in_angle is echoed to out_angle so a
// latency-independent monitor can pair each result with its stimulus.
//
// All datapaths are two's-complement signed fixed-point. x/y are Q(int).FRAC
// with FRAC=13 (range +/-4.0); the angle is radians in Q2.13 (range +/-4.0,
// which covers +/-pi). Internal x/y carry XYW=DW+4 guard bits so no
// intermediate micro-rotation overflows. Reset is synchronous, active-low, and
// only clears the valid pipeline (data is don't-care until valid).
//
// Parameters
//   DW    - x/y word width (signed, Q(DW-FRAC-... ).FRAC)          default 16
//   AW    - angle word width (signed radians, Q2.FRAC)             default 16
//   FRAC  - fractional bits shared by x/y and angle                default 13
//   NITER - number of CORDIC micro-rotation stages (= pipe depth)  default 16
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module cordic_rotation #(
    parameter int DW    = 16,
    parameter int AW    = 16,
    parameter int FRAC  = 13,
    parameter int NITER = 16
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     in_valid,
    input  wire signed [DW-1:0]     in_x,
    input  wire signed [DW-1:0]     in_y,
    input  wire signed [AW-1:0]     in_angle,
    output wire                     out_valid,
    output wire signed [DW-1:0]     out_x,
    output wire signed [DW-1:0]     out_y,
    output wire signed [AW-1:0]     out_angle
);

    localparam int LAT = NITER + 1;           // fixed pipeline latency (cycles)
    localparam int XYW = DW + 4;              // internal x/y width (guard bits)

    // pi and pi/2 in Q2.FRAC (FRAC=13: pi=25736, pi/2=12868).
    localparam signed [AW-1:0] PI_Q   = 25736;
    localparam signed [AW-1:0] HALFPI = 12868;

    // Elementary rotation angles atan(2^-i) in Q2.FRAC (FRAC=13), rounded.
    // (i>=14 rounds below the LSB; the extra stages still refine x/y.) Provided
    // as a constant function rather than an unpacked-array parameter so the DUT
    // elaborates on every simulator (Icarus included).
    function automatic signed [AW-1:0] atan_lut(input int i);
        case (i)
            0:  atan_lut = 16'sd6434;
            1:  atan_lut = 16'sd3798;
            2:  atan_lut = 16'sd2007;
            3:  atan_lut = 16'sd1019;
            4:  atan_lut = 16'sd511;
            5:  atan_lut = 16'sd256;
            6:  atan_lut = 16'sd128;
            7:  atan_lut = 16'sd64;
            8:  atan_lut = 16'sd32;
            9:  atan_lut = 16'sd16;
            10: atan_lut = 16'sd8;
            11: atan_lut = 16'sd4;
            12: atan_lut = 16'sd2;
            13: atan_lut = 16'sd1;
            default: atan_lut = 16'sd0;
        endcase
    endfunction

    // ------------------------------------------------- combinational fold -----
    // Fold any in_angle in [-pi,pi] into [-pi/2,pi/2] so the iteration converges.
    wire signed [XYW-1:0] sx = $signed(in_x);   // sign-extend to internal width
    wire signed [XYW-1:0] sy = $signed(in_y);
    reg  signed [XYW-1:0] fx, fy;
    reg  signed [AW-1:0]  fz;
    always @* begin
        if (in_angle > HALFPI) begin            // second quadrant -> subtract pi
            fz = in_angle - PI_Q;  fx = -sx;  fy = -sy;
        end else if (in_angle < -HALFPI) begin  // third quadrant -> add pi
            fz = in_angle + PI_Q;  fx = -sx;  fy = -sy;
        end else begin                          // already in convergence range
            fz = in_angle;         fx = sx;   fy = sy;
        end
    end

    // ---------------------------------------------------- pipeline arrays -----
    // xs[0]/ys[0]/zs[0] = folded input registered (1-cycle input stage);
    // xs[k]..zs[k] (k=1..NITER) = state after k micro-rotations, registered.
    reg  signed [XYW-1:0] xs   [0:NITER];
    reg  signed [XYW-1:0] ys   [0:NITER];
    reg  signed [AW-1:0]  zs   [0:NITER];
    reg  signed [AW-1:0]  angp [0:NITER];      // original angle, pipeline-delayed
    reg                   vld  [0:NITER];

    // Stage 0: register the folded request (and the original angle to echo).
    always @(posedge clk) begin
        if (!rst_n) begin
            vld[0] <= 1'b0;
        end else begin
            vld[0]  <= in_valid;
            xs[0]   <= fx;
            ys[0]   <= fy;
            zs[0]   <= fz;
            angp[0] <= in_angle;
        end
    end

    // Stages 1..NITER: one registered CORDIC micro-rotation each.
    genvar g;
    generate
        for (g = 0; g < NITER; g = g + 1) begin : stage
            always @(posedge clk) begin
                if (!rst_n) begin
                    vld[g+1] <= 1'b0;
                end else begin
                    vld[g+1]  <= vld[g];
                    angp[g+1] <= angp[g];
                    if (zs[g] >= 0) begin       // rotate by +atan(2^-g)
                        xs[g+1] <= xs[g] - (ys[g] >>> g);
                        ys[g+1] <= ys[g] + (xs[g] >>> g);
                        zs[g+1] <= zs[g] - atan_lut(g);
                    end else begin              // rotate by -atan(2^-g)
                        xs[g+1] <= xs[g] + (ys[g] >>> g);
                        ys[g+1] <= ys[g] - (xs[g] >>> g);
                        zs[g+1] <= zs[g] + atan_lut(g);
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------- output -----
    assign out_valid = vld[NITER];
    assign out_x     = xs[NITER][DW-1:0];
    assign out_y     = ys[NITER][DW-1:0];
    assign out_angle = angp[NITER];

    // -------------------------------------------------------------- SVA --------
    // synthesis translate_off
`ifdef CORDIC_SVA
    // Fixed-latency contract: a request appears as a result exactly LAT later.
    property p_fixed_latency;
        @(posedge clk) disable iff (!rst_n)
        in_valid |-> ##LAT out_valid;
    endproperty
    a_fixed_latency: assert property (p_fixed_latency)
        else $error("CORDIC: out_valid not asserted LAT cycles after in_valid");

    // No X on the outputs while a result is presented.
    property p_no_x;
        @(posedge clk) disable iff (!rst_n)
        out_valid |-> (!$isunknown({out_x, out_y, out_angle}));
    endproperty
    a_no_x: assert property (p_no_x)
        else $error("CORDIC: X detected on output while out_valid=1");
`endif
    // synthesis translate_on

endmodule

`default_nettype wire
