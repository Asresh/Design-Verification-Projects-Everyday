// ============================================================================
// scrambler_if.sv - pin interface + concurrent SVA for the scrambler link.
// ----------------------------------------------------------------------------
// Carries the transmit request (in_valid/in_data), the optional wire error
// mask (inject_mask), and the observation taps at both the scrambled midpoint
// (scr_valid/scr_data) and the recovered endpoint (des_valid/des_data). The
// concurrent SVA here is compiled by the UVM flow (VCS / Questa / Verilator);
// the portable Icarus TB (tb_scrambler_dump.sv) carries equivalent procedural
// checkers because Icarus does not fully support these assertion forms.
// ============================================================================
`timescale 1ns/1ps

interface scrambler_if #(
    parameter int unsigned WIDTH = 8
) (input logic clk, input logic rst_n);

    logic               in_valid;
    logic [WIDTH-1:0]   in_data;
    logic [WIDTH-1:0]   inject_mask;   // wire-error XOR mask (0 = clean)

    logic               scr_valid;
    logic [WIDTH-1:0]   scr_data;

    logic               des_valid;
    logic [WIDTH-1:0]   des_data;

    // clocking block for the driver (synchronous stimulus).
    clocking drv_cb @(posedge clk);
        default output #1;
        output in_valid, in_data, inject_mask;
    endclocking

    modport drv (clocking drv_cb, input clk, input rst_n);

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // Pipeline / protocol SVA (LAT=1 per stage).
    // ------------------------------------------------------------------
    // scrambler valid is in_valid delayed exactly one cycle.
    property p_scr_lat;
        @(posedge clk) disable iff (!rst_n) in_valid |=> scr_valid;
    endproperty
    a_scr_lat: assert property (p_scr_lat)
        else $error("scr_valid did not follow in_valid by 1 cycle");

    // no scr_valid without a prior in_valid.
    property p_scr_src;
        @(posedge clk) disable iff (!rst_n) scr_valid |-> $past(in_valid);
    endproperty
    a_scr_src: assert property (p_scr_src)
        else $error("scr_valid without a prior in_valid");

    // descrambler valid is scr_valid delayed one cycle.
    property p_des_lat;
        @(posedge clk) disable iff (!rst_n) scr_valid |=> des_valid;
    endproperty
    a_des_lat: assert property (p_des_lat)
        else $error("des_valid did not follow scr_valid by 1 cycle");

    // no X on payloads while valid.
    a_scr_nox: assert property (@(posedge clk) disable iff (!rst_n)
        scr_valid |-> !$isunknown(scr_data))
        else $error("X on scr_data while valid");
    a_des_nox: assert property (@(posedge clk) disable iff (!rst_n)
        des_valid |-> !$isunknown(des_data))
        else $error("X on des_data while valid");
`endif

endinterface
