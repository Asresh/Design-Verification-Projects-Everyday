// -----------------------------------------------------------------------------
// mac_dot.sv - GPU tensor-core-style signed multiply-accumulate (MAC) dot-product
// accumulation engine.
//
// This is the fundamental reduction primitive at the heart of every GPU GEMM /
// tensor-core lane: a stream of signed operand pairs (a, b) is multiplied and
// accumulated; the element flagged with `in_last` terminates the current dot
// product and the running sum is emitted on `out_result` with a one-cycle
// `out_valid` pulse. The accumulator then restarts cleanly for the next vector,
// so an unbounded stream of variable-length dot products can be issued back to
// back with no bubble between them.
//
//   result_k = sum_{i=0..L_k-1} a_i * b_i            (signed, 2's-complement)
//
// The design is fully registered, reset-safe, parameterized in operand and
// accumulator width, and lint-friendly (no latches, no unsized literals, no
// combinational feedback). Accumulation uses SystemVerilog signed arithmetic so
// the reference model in the testbench matches it bit-exactly, including
// 2's-complement wraparound if a caller ever overflows ACC_W.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module mac_dot #(
    parameter int A_W   = 8,    // signed operand width (bits) for in_a / in_b
    parameter int ACC_W = 32    // signed accumulator / result width (bits)
) (
    input  wire                     clk,
    input  wire                     rst_n,      // active-low synchronous-release reset

    // ---- input operand stream (always accepted; no backpressure) ----
    input  wire                     in_valid,   // this cycle presents a valid (a,b) pair
    input  wire signed [A_W-1:0]    in_a,       // first operand
    input  wire signed [A_W-1:0]    in_b,       // second operand
    input  wire                     in_last,    // (a,b) is the final element of the dot product

    // ---- result stream ----
    output logic                    out_valid,  // one-cycle pulse: out_result is valid
    output logic signed [ACC_W-1:0] out_result  // completed dot-product value
);

    // Full-precision signed product of the current operand pair.
    logic signed [2*A_W-1:0] prod;
    assign prod = in_a * in_b;

    // Running accumulator, and a flag that forces a fresh start on the first
    // element of each new dot product (set the cycle after a `last`, and at reset).
    logic signed [ACC_W-1:0] acc;
    logic                    start_new;

    // Base term for this cycle: zero when beginning a new dot product.
    logic signed [ACC_W-1:0] base;
    logic signed [ACC_W-1:0] sum;
    assign base = start_new ? {ACC_W{1'b0}} : acc;
    assign sum  = base + $signed({{(ACC_W-2*A_W){prod[2*A_W-1]}}, prod});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc        <= '0;
            start_new  <= 1'b1;
            out_valid  <= 1'b0;
            out_result <= '0;
        end else begin
            out_valid <= 1'b0;              // default: no result this cycle
            if (in_valid) begin
                acc <= sum;                 // absorb this element
                if (in_last) begin
                    out_valid  <= 1'b1;     // emit the completed dot product
                    out_result <= sum;
                    start_new  <= 1'b1;     // next element begins a new vector
                end else begin
                    start_new  <= 1'b0;     // keep accumulating
                end
            end
        end
    end

`ifdef MAC_SVA
    // ---------------------------------------------------------------- SVA ----
    // out_valid is a strict one-cycle pulse (it is only ever asserted for a
    // single cycle because it defaults to 0 and is re-driven per in_valid&in_last).
    property p_out_valid_pulse;
        @(posedge clk) disable iff (!rst_n)
            out_valid |=> !out_valid;
    endproperty
    a_out_valid_pulse: assert property (p_out_valid_pulse)
        else $error("out_valid held for more than one cycle");

    // A result is only produced in response to an in_valid&in_last one cycle earlier.
    property p_result_needs_last;
        @(posedge clk) disable iff (!rst_n)
            out_valid |-> $past(in_valid && in_last);
    endproperty
    a_result_needs_last: assert property (p_result_needs_last)
        else $error("out_valid without a preceding in_valid&in_last");

    // The result bus is never X while valid.
    property p_no_x_result;
        @(posedge clk) disable iff (!rst_n)
            out_valid |-> !$isunknown(out_result);
    endproperty
    a_no_x_result: assert property (p_no_x_result)
        else $error("out_result is X while out_valid asserted");
`endif

endmodule

`default_nettype wire
