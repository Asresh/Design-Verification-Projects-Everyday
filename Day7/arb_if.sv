// -----------------------------------------------------------------------------
// arb_if.sv  -  SystemVerilog interface for the round-robin arbiter UVM env
//
// Two clocking blocks:
//   * req_drv_cb - the request driver drives {req, en} and samples the grant
//   * mon_cb     - passive monitors sample every signal
// -----------------------------------------------------------------------------
`ifndef ARB_IF_SV
`define ARB_IF_SV

interface arb_if #(
    parameter int NUM_REQ = 4,
    parameter int PW      = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1
) (
    input logic clk,
    input logic rst_n
);
    logic [NUM_REQ-1:0] req;
    logic               en;
    logic [NUM_REQ-1:0] grant;
    logic               grant_valid;
    logic [PW-1:0]      grant_idx;

    // Request driver: drive stimulus, sample the arbiter's decision.
    clocking req_drv_cb @(posedge clk);
        default input #1step output #1;
        output req, en;
        input  grant, grant_valid, grant_idx;
    endclocking

    // Passive monitor: sample everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input req, en, grant, grant_valid, grant_idx;
    endclocking

    modport req_drv(clocking req_drv_cb, input clk, rst_n);
    modport mon    (clocking mon_cb,     input clk, rst_n);
endinterface
`endif
