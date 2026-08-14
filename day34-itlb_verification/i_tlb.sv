// Author: Asresh Kuricheti
// Parameterized instruction TLB with ASIDs, global mappings, superpages, permissions, and invalidation.
`timescale 1ns/1ps
module i_tlb #(
    parameter int ENTRIES = 8,
    parameter int VA_W = 32,
    parameter int PA_W = 32,
    parameter int ASID_W = 8,
    localparam int IDX_W = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES),
    localparam int VPN_W = VA_W-12,
    localparam int PPN_W = PA_W-12
) (
    input  logic clk, rst_n,
    input  logic query_valid,
    input  logic [VA_W-1:0] query_vaddr,
    input  logic [ASID_W-1:0] query_asid,
    output logic query_hit,
    output logic query_exec_fault,
    output logic [PA_W-1:0] query_paddr,
    output logic [IDX_W-1:0] query_index,
    input  logic fill_valid,
    input  logic [VA_W-1:0] fill_vaddr,
    input  logic [PA_W-1:0] fill_paddr,
    input  logic [ASID_W-1:0] fill_asid,
    input  logic fill_global,
    input  logic fill_superpage,
    input  logic fill_exec,
    input  logic inv_valid,
    input  logic inv_all,
    input  logic inv_asid_valid,
    input  logic [ASID_W-1:0] inv_asid,
    input  logic inv_vaddr_valid,
    input  logic [VA_W-1:0] inv_vaddr
);
    logic valid_q [ENTRIES];
    logic [VPN_W-1:0] vpn_q [ENTRIES];
    logic [PPN_W-1:0] ppn_q [ENTRIES];
    logic [ASID_W-1:0] asid_q [ENTRIES];
    logic global_q [ENTRIES], super_q [ENTRIES], exec_q [ENTRIES];
    logic [IDX_W-1:0] replace_q;

    function automatic logic vpn_match(
        input logic [VPN_W-1:0] entry_vpn,
        input logic superpage,
        input logic [VA_W-1:0] vaddr
    );
        if (superpage) vpn_match = entry_vpn[VPN_W-1:9] == vaddr[VA_W-1:21];
        else           vpn_match = entry_vpn == vaddr[VA_W-1:12];
    endfunction

    always_comb begin
        query_hit = 1'b0;
        query_exec_fault = 1'b0;
        query_paddr = '0;
        query_index = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (!query_hit && valid_q[i] &&
                (global_q[i] || asid_q[i] == query_asid) &&
                vpn_match(vpn_q[i], super_q[i], query_vaddr)) begin
                query_hit = query_valid;
                query_exec_fault = query_valid && !exec_q[i];
                query_index = IDX_W'(i);
                if (super_q[i])
                    query_paddr = {ppn_q[i][PPN_W-1:9], query_vaddr[20:0]};
                else
                    query_paddr = {ppn_q[i], query_vaddr[11:0]};
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            replace_q <= '0;
            for (int i = 0; i < ENTRIES; i++) begin
                valid_q[i] <= 1'b0;
                vpn_q[i] <= '0; ppn_q[i] <= '0; asid_q[i] <= '0;
                global_q[i] <= 1'b0; super_q[i] <= 1'b0; exec_q[i] <= 1'b0;
            end
        end else begin
            if (inv_valid) begin
                for (int i = 0; i < ENTRIES; i++) begin
                    if (valid_q[i] &&
                        (inv_all ||
                         ((!inv_asid_valid || (!global_q[i] && asid_q[i] == inv_asid)) &&
                          (!inv_vaddr_valid || vpn_match(vpn_q[i], super_q[i], inv_vaddr)))))
                        valid_q[i] <= 1'b0;
                end
            end else if (fill_valid) begin
                logic [IDX_W-1:0] victim;
                logic found_invalid;
                victim = replace_q;
                found_invalid = 1'b0;
                for (int i = 0; i < ENTRIES; i++) begin
                    if (!found_invalid && !valid_q[i]) begin
                        victim = IDX_W'(i);
                        found_invalid = 1'b1;
                    end
                end
                valid_q[victim] <= 1'b1;
                vpn_q[victim] <= fill_vaddr[VA_W-1:12];
                ppn_q[victim] <= fill_paddr[PA_W-1:12];
                asid_q[victim] <= fill_asid;
                global_q[victim] <= fill_global;
                super_q[victim] <= fill_superpage;
                exec_q[victim] <= fill_exec;
                replace_q <= (victim == ENTRIES-1) ? '0 : victim + 1'b1;
            end
        end
    end

`ifdef TLB_SVA
    default clocking cb @(posedge clk); endclocking
    default disable iff (!rst_n);
    assert property (query_hit |-> query_valid);
    assert property (query_exec_fault |-> query_hit);
    assert property (query_hit |-> !$isunknown({query_paddr,query_index,query_exec_fault}));
    assert property (fill_superpage && fill_valid |-> fill_vaddr[20:0] == '0 && fill_paddr[20:0] == '0);
    assert property (!(fill_valid && inv_valid));
`endif
endmodule
