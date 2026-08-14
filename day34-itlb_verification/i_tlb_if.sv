// Author: Asresh Kuricheti
interface i_tlb_if #(parameter VA_W=32, PA_W=32, ASID_W=8, ENTRIES=8) (input logic clk);
    localparam IDX_W=(ENTRIES<=1)?1:$clog2(ENTRIES);
    logic rst_n;
    logic query_valid; logic [VA_W-1:0] query_vaddr; logic [ASID_W-1:0] query_asid;
    logic query_hit,query_exec_fault; logic [PA_W-1:0] query_paddr; logic [IDX_W-1:0] query_index;
    logic fill_valid; logic [VA_W-1:0] fill_vaddr; logic [PA_W-1:0] fill_paddr;
    logic [ASID_W-1:0] fill_asid; logic fill_global,fill_superpage,fill_exec;
    logic inv_valid,inv_all,inv_asid_valid; logic [ASID_W-1:0] inv_asid;
    logic inv_vaddr_valid; logic [VA_W-1:0] inv_vaddr;
    clocking drv_cb @(negedge clk); output query_valid,query_vaddr,query_asid,fill_valid,fill_vaddr,
        fill_paddr,fill_asid,fill_global,fill_superpage,fill_exec,inv_valid,inv_all,
        inv_asid_valid,inv_asid,inv_vaddr_valid,inv_vaddr; input query_hit,query_exec_fault,query_paddr,query_index; endclocking
    clocking mon_cb @(posedge clk); input rst_n,query_valid,query_vaddr,query_asid,query_hit,
        query_exec_fault,query_paddr,query_index,fill_valid,fill_vaddr,fill_paddr,fill_asid,
        fill_global,fill_superpage,fill_exec,inv_valid,inv_all,inv_asid_valid,inv_asid,
        inv_vaddr_valid,inv_vaddr; endclocking
endinterface
