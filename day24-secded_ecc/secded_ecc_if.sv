// -----------------------------------------------------------------------------
// secded_ecc_if.sv - SystemVerilog interface for the SECDED (72,64) Hamming ECC
// encoder/decoder UVM environment. Bundles the request ({valid, op, data, code})
// and the fixed-latency result ({valid, op, code, data, syndrome, sbe, dbe}),
// with clocking blocks for the stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface secded_ecc_if #(
    parameter int DW  = 64,
    parameter int HAM = 7,
    parameter int CW  = 72
) (input logic clk, input logic rst_n);

    // ---- request ----
    logic              in_valid;
    logic              in_op;       // 0 = ENCODE, 1 = DECODE
    logic [DW-1:0]     in_data;     // ENCODE input
    logic [CW-1:0]     in_code;     // DECODE input (received codeword)

    // ---- result (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_op;
    logic [CW-1:0]     out_code;
    logic [DW-1:0]     out_data;
    logic [HAM-1:0]    out_syndrome;
    logic              out_sbe;
    logic              out_dbe;

    // Stimulus driver: drives the request.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_op, in_data, in_code;
        input  out_valid, out_op, out_code, out_data, out_syndrome, out_sbe, out_dbe;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_op, in_data, in_code;
        input out_valid, out_op, out_code, out_data, out_syndrome, out_sbe, out_dbe;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
