// ============================================================================
// fp32_add_if.sv - pin interface + concurrent SVA for the binary32 adder.
// ----------------------------------------------------------------------------
// Carries the request (in_valid / in_sub / in_a / in_b) and the result
// (out_valid / out_z / the four exception flags). The concurrent assertions
// below are compiled by the UVM flow (VCS / Questa / Verilator); the portable
// Icarus testbench (tb_fp32_add_dump.sv) carries equivalent procedural checkers
// because Icarus does not fully support these assertion forms.
// ============================================================================
`timescale 1ns/1ps

interface fp32_add_if #(
    parameter int unsigned EW  = 8,
    parameter int unsigned MW  = 23,
    parameter int unsigned LAT = 3
) (input logic clk, input logic rst_n);

    localparam int unsigned W = 1 + EW + MW;

    // ---- request ----
    logic         in_valid;
    logic         in_sub;
    logic [W-1:0] in_a;
    logic [W-1:0] in_b;

    // ---- result, LAT cycles later ----
    logic         out_valid;
    logic [W-1:0] out_z;
    logic         out_inv;
    logic         out_ovf;
    logic         out_unf;
    logic         out_inx;

    // clocking block for the driver (synchronous stimulus).
    clocking drv_cb @(posedge clk);
        default output #1;
        output in_valid, in_sub, in_a, in_b;
    endclocking

    // Race-free monitor sampling: #1step samples in the Preponed region, i.e.
    // the settled values of the cycle that is ending, so the monitor never
    // races the DUT's non-blocking register updates on the same edge. Requests
    // and results are sampled the same way, so the observed request->result
    // spacing is exactly LAT and the ordering the scoreboard pairs on is exact.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_sub, in_a, in_b;
        input out_valid, out_z, out_inv, out_ovf, out_unf, out_inx;
    endclocking

    modport drv (clocking drv_cb, input clk, input rst_n);
    modport mon (clocking mon_cb, input clk, input rst_n);

`ifndef SYNTHESIS
    localparam logic [EW-1:0] EMAX = {EW{1'b1}};
    localparam logic [W-1:0]  QNAN = {1'b0, EMAX, 1'b1, {MW-1{1'b0}}};

    // ------------------------------------------------------------------
    // 1. The fixed-latency, zero-bubble contract the whole environment
    //    (and the FIFO-pairing monitor in particular) is built on.
    // ------------------------------------------------------------------
    property p_lat;
        @(posedge clk) disable iff (!rst_n) in_valid |-> ##LAT out_valid;
    endproperty
    a_lat: assert property (p_lat)
        else $error("out_valid did not follow in_valid by exactly LAT=%0d cycles", LAT);

    // ...and nothing comes out that was not asked for.
    property p_cause;
        @(posedge clk) disable iff (!rst_n) out_valid |-> $past(in_valid, LAT);
    endproperty
    a_cause: assert property (p_cause)
        else $error("out_valid with no matching in_valid LAT cycles earlier");

    // ------------------------------------------------------------------
    // 2. Result well-formedness.
    // ------------------------------------------------------------------
    a_nox_z: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown(out_z))
        else $error("X on out_z while out_valid");

    a_nox_fl: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_inv, out_ovf, out_unf, out_inx}))
        else $error("X on the flag bus while out_valid");

    // Every NaN this DUT emits is the CANONICAL quiet NaN - it never produces a
    // signalling NaN, and it never propagates an input payload.
    a_canon_nan: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && (out_z[W-2 -: EW] == EMAX) && (out_z[MW-1:0] != '0))
          |-> (out_z == QNAN))
        else $error("non-canonical NaN result 0x%08h", out_z);

    // ------------------------------------------------------------------
    // 3. Flag consistency (the spec in the DUT / reference-package headers).
    // ------------------------------------------------------------------
    // Overflow always loses information, and always delivers an infinity.
    a_ovf_inx: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_ovf) |-> out_inx)
        else $error("out_ovf without out_inx");

    a_ovf_inf: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_ovf) |-> ((out_z[W-2 -: EW] == EMAX) && (out_z[MW-1:0] == '0)))
        else $error("out_ovf but the result 0x%08h is not an infinity", out_z);

    // Invalid always delivers the canonical quiet NaN.
    a_inv_nan: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_inv) |-> (out_z == QNAN))
        else $error("out_inv but the result 0x%08h is not the canonical qNaN", out_z);

    // A NaN or infinity result is never merely "inexact".
    a_spec_exact: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && (out_z[W-2 -: EW] == EMAX) && !out_ovf) |-> !out_inx)
        else $error("inf/NaN result flagged inexact without overflow");

    // ------------------------------------------------------------------
    // 4. The interesting invariant: UNDERFLOW IS UNREACHABLE.
    //
    // The exact sum of two binary32 values is always an integer multiple of
    // 2^-149 (the smaller operand's ULP is never finer than that), so whenever
    // the exact result is subnormal it is also exactly representable. Addition
    // therefore never rounds inside the subnormal range: out_unf must be 0 for
    // every operand pair. This is a genuine property of FP add/sub - it does
    // NOT hold for multiply or divide - and it is asserted here rather than
    // merely assumed, so an RTL change that started flagging underflow (or a
    // reference model that started expecting it) would fail immediately.
    // ------------------------------------------------------------------
    a_no_unf: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !out_unf)
        else $error("out_unf asserted - underflow is unreachable for binary32 add/sub");

    // ------------------------------------------------------------------
    // 5. Request well-formedness (a driver-side check).
    // ------------------------------------------------------------------
    a_nox_req: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> !$isunknown({in_sub, in_a, in_b}))
        else $error("X on the request bus while in_valid");
`endif

endinterface
