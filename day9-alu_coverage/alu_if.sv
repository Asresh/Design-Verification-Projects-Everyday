// ============================================================================
// alu_if.sv - SystemVerilog interface bundling the ALU pins for the UVM env.
//
// The driver wiggles the request side (in_valid/opcode/a/b); the monitor
// samples both request and response. A clocking-block-free interface keeps the
// example portable; the UVM driver/monitor sample on the posedge of `clk`.
// ============================================================================
interface alu_if #(parameter int WIDTH = 8) (input logic clk, input logic rst_n);
    logic             in_valid;
    logic [3:0]       opcode;
    logic [WIDTH-1:0] a;
    logic [WIDTH-1:0] b;

    logic             out_valid;
    logic [WIDTH-1:0] result;
    logic             zero;
    logic             carry;
    logic             overflow;
    logic             negative;
endinterface
