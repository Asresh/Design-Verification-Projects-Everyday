// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*; import i_tlb_pkg::*;
    logic clk=0; always #5 clk=~clk;
    i_tlb_if intf(clk);
    i_tlb dut(.clk,.rst_n(intf.rst_n),.query_valid(intf.query_valid),.query_vaddr(intf.query_vaddr),.query_asid(intf.query_asid),
      .query_hit(intf.query_hit),.query_exec_fault(intf.query_exec_fault),.query_paddr(intf.query_paddr),.query_index(intf.query_index),
      .fill_valid(intf.fill_valid),.fill_vaddr(intf.fill_vaddr),.fill_paddr(intf.fill_paddr),.fill_asid(intf.fill_asid),
      .fill_global(intf.fill_global),.fill_superpage(intf.fill_superpage),.fill_exec(intf.fill_exec),.inv_valid(intf.inv_valid),
      .inv_all(intf.inv_all),.inv_asid_valid(intf.inv_asid_valid),.inv_asid(intf.inv_asid),.inv_vaddr_valid(intf.inv_vaddr_valid),.inv_vaddr(intf.inv_vaddr));
    initial begin intf.rst_n=0;repeat(4)@(posedge clk);intf.rst_n=1;end
    initial begin uvm_config_db#(virtual i_tlb_if)::set(null,"*","vif",intf);run_test();end
    initial begin #200000ns;$fatal(1,"UVM timeout");end
endmodule
