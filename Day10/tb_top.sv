// ============================================================================
// tb_top.sv - UVM top for the AXI4-Stream skid-buffer environment.
//
// Generates clock + reset, instantiates the DUT through axis_skid_if, publishes
// the virtual interface via the config DB, and launches the test selected by
// +UVM_TESTNAME (default axis_smoke_test).
//
//   make vcs     UVM_TESTNAME=axis_smoke_test
//   make questa  UVM_TESTNAME=axis_regress_test
//
// Concurrent SVA (module `axis_skid_sva`) is bound to the DUT under
// +define+AXIS_SVA and checks the AXI-Stream handshake invariants.
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import axis_skid_pkg::*;

    localparam int DATA_WIDTH = 8;
    localparam int KEEP_WIDTH = (DATA_WIDTH + 7) / 8;

    logic clk;
    logic rst_n;

    // ---- clock / reset ----
    initial clk = 1'b0;
    always #5 clk = ~clk;             // 10 ns

    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- interface + DUT ----
    axis_skid_if #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH))
        vif (.clk(clk), .rst_n(rst_n));

    axis_skid #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tvalid (vif.s_tvalid),
        .s_tready (vif.s_tready),
        .s_tdata  (vif.s_tdata),
        .s_tkeep  (vif.s_tkeep),
        .s_tlast  (vif.s_tlast),
        .m_tvalid (vif.m_tvalid),
        .m_tready (vif.m_tready),
        .m_tdata  (vif.m_tdata),
        .m_tkeep  (vif.m_tkeep),
        .m_tlast  (vif.m_tlast)
    );

`ifdef AXIS_SVA
    bind axis_skid axis_skid_sva #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH))
        u_sva (
            .clk(clk), .rst_n(rst_n),
            .s_tvalid(s_tvalid), .s_tready(s_tready),
            .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tlast(s_tlast),
            .m_tvalid(m_tvalid), .m_tready(m_tready),
            .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tlast(m_tlast)
        );
`endif

    // ---- publish vif + start test ----
    initial begin
        uvm_config_db#(virtual axis_skid_if)::set(null, "*", "vif", vif);
        run_test("axis_smoke_test");
    end

    // ---- global safety timeout + waveform ----
    initial begin
        #1ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
endmodule

// ----------------------------------------------------------------------------
// Concurrent SVA checker bound onto the DUT (enabled with +define+AXIS_SVA).
// Encodes the AXI4-Stream handshake contract the skid buffer must honor.
// ----------------------------------------------------------------------------
`ifdef AXIS_SVA
module axis_skid_sva #(parameter int DATA_WIDTH = 8, parameter int KEEP_WIDTH = 1) (
    input logic clk, input logic rst_n,
    input logic s_tvalid, input logic s_tready,
    input logic [DATA_WIDTH-1:0] s_tdata, input logic [KEEP_WIDTH-1:0] s_tkeep,
    input logic s_tlast,
    input logic m_tvalid, input logic m_tready,
    input logic [DATA_WIDTH-1:0] m_tdata, input logic [KEEP_WIDTH-1:0] m_tkeep,
    input logic m_tlast
);
    // Once M_TVALID is asserted it must remain asserted until M_TREADY - the
    // master may not retract a valid beat before it is accepted.
    a_mvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (m_tvalid && !m_tready) |=> m_tvalid)
        else $error("SVA: m_tvalid dropped before m_tready");

    // The master-side payload must be stable while stalled (valid && !ready).
    a_mpayload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (m_tvalid && !m_tready) |=> $stable({m_tdata, m_tkeep, m_tlast}))
        else $error("SVA: m_* payload changed while stalled");

    // No X on the output payload while a beat is valid.
    a_no_x_out: assert property (@(posedge clk) disable iff (!rst_n)
        m_tvalid |-> !$isunknown({m_tdata, m_tkeep, m_tlast}))
        else $error("SVA: X on output payload while m_tvalid");

    // s_tready is purely a function of internal state; it must never be X.
    a_no_x_sready: assert property (@(posedge clk) disable iff (!rst_n)
        !$isunknown(s_tready))
        else $error("SVA: s_tready is X");
endmodule
`endif
