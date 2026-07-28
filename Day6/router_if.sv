// -----------------------------------------------------------------------------
// router_if.sv  -  SystemVerilog interface for the packet router UVM env
//
// One input stream port and NUM_OUT flattened output stream ports, with three
// clocking blocks:
//   * in_drv_cb   - input-stream driver drives {valid,dest,data,last}, samples
//                   in_ready to honour FIFO-full backpressure
//   * out_drv_cb  - output backpressure driver drives the whole out_ready vector
//   * mon_cb      - passive monitors sample every signal
// -----------------------------------------------------------------------------
`ifndef ROUTER_IF_SV
`define ROUTER_IF_SV

interface router_if #(
    parameter int NUM_OUT = 4,
    parameter int DW      = 8,
    parameter int DEST_W  = (NUM_OUT > 1) ? $clog2(NUM_OUT) : 1
) (
    input logic clk,
    input logic rst_n
);
    // ---- input stream ----
    logic                    in_valid;
    logic                    in_ready;
    logic [DEST_W-1:0]       in_dest;
    logic [DW-1:0]           in_data;
    logic                    in_last;
    // ---- output streams (flattened) ----
    logic [NUM_OUT-1:0]      out_valid;
    logic [NUM_OUT-1:0]      out_ready;
    logic [NUM_OUT*DW-1:0]   out_data;
    logic [NUM_OUT-1:0]      out_last;

    // Input-stream driver: drive request signals, sample the grant (in_ready).
    clocking in_drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_dest, in_data, in_last;
        input  in_ready;
    endclocking

    // Output backpressure driver: drive the ready vector, observe valids.
    clocking out_drv_cb @(posedge clk);
        default input #1step output #1;
        output out_ready;
        input  out_valid, out_data, out_last;
    endclocking

    // Passive monitor: sample everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_ready, in_dest, in_data, in_last;
        input out_valid, out_ready, out_data, out_last;
    endclocking

    modport in_drv (clocking in_drv_cb,  input clk, rst_n);
    modport out_drv(clocking out_drv_cb, input clk, rst_n);
    modport mon    (clocking mon_cb,     input clk, rst_n);
endinterface
`endif
