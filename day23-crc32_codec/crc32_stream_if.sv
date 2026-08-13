// -----------------------------------------------------------------------------
// crc32_stream_if.sv - SystemVerilog interface for the STREAMING CRC-32
// (Ethernet FCS) generator/checker UVM environment. Bundles the byte-stream
// input ({valid, sop, eop, mode, data}) and the fixed-latency frame result
// ({valid, crc, mode, ok}), with clocking blocks for the stimulus driver and the
// passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface crc32_stream_if #(
    parameter int DW   = 8,
    parameter int CRCW = 32
) (input logic clk, input logic rst_n);

    // ---- streaming byte input ----
    logic              in_valid;
    logic              in_sop;
    logic              in_eop;
    logic              in_mode;
    logic [DW-1:0]     in_data;

    // ---- frame result (fixed pipeline latency) ----
    logic              out_valid;
    logic [CRCW-1:0]   out_crc;
    logic              out_mode;
    logic              out_ok;

    // Stimulus driver: streams the byte input.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_sop, in_eop, in_mode, in_data;
        input  out_valid, out_crc, out_mode, out_ok;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_sop, in_eop, in_mode, in_data;
        input out_valid, out_crc, out_mode, out_ok;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
