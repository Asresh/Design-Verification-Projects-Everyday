// -----------------------------------------------------------------------------
// smem_bank_arb_if.sv - SystemVerilog interface for the GPU shared-memory
// bank-conflict serializer UVM environment. Bundles the warp-request handshake
// and the serialized phase-output stream, with clocking blocks for the request
// driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface smem_bank_arb_if #(
    parameter int NLANES = 8,
    parameter int NBANKS = 8,
    parameter int ADDR_W = 16
) (input logic clk, input logic rst_n);

    localparam int PH_W = $clog2(NLANES + 1);

    // ---- warp request ----
    logic                     req_valid;
    logic                     req_ready;
    logic [NLANES-1:0]        req_mask;
    logic [NLANES*ADDR_W-1:0] req_addr;

    // ---- serialized phase stream ----
    logic                     ph_valid;
    logic [NLANES-1:0]        ph_served;
    logic [NBANKS-1:0]        ph_bank_use;
    logic                     ph_last;
    logic [PH_W-1:0]          ph_index;
    logic                     busy;

    // Request driver: drives the request, samples req_ready + the phase stream.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output req_valid, req_mask, req_addr;
        input  req_ready, ph_valid, ph_served, ph_bank_use, ph_last, ph_index, busy;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_valid, req_ready, req_mask, req_addr;
        input ph_valid, ph_served, ph_bank_use, ph_last, ph_index, busy;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
