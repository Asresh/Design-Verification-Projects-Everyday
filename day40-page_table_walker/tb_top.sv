// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*; import ptw_pkg::*;
  logic clk=0; always #5 clk=~clk;
  ptw_if intf(clk);
  page_table_walker dut(
    .clk,.rst_n(intf.rst_n),.root_ppn(intf.root_ppn),
    .req_valid(intf.req_valid),.req_ready(intf.req_ready),.req_vaddr(intf.req_vaddr),.req_access(intf.req_access),.req_user(intf.req_user),
    .mem_req_valid(intf.mem_req_valid),.mem_req_ready(intf.mem_req_ready),.mem_req_addr(intf.mem_req_addr),
    .mem_rsp_valid(intf.mem_rsp_valid),.mem_rsp_pte(intf.mem_rsp_pte),
    .rsp_valid(intf.rsp_valid),.rsp_ready(intf.rsp_ready),.rsp_paddr(intf.rsp_paddr),
    .rsp_fault(intf.rsp_fault),.rsp_fault_code(intf.rsp_fault_code),.rsp_leaf_level(intf.rsp_leaf_level));
  initial begin
    intf.rst_n=0;intf.root_ppn=ROOT_PPN;repeat(5)@(posedge clk);intf.rst_n=1;
    uvm_config_db#(virtual ptw_if)::set(null,"*","vif",intf);
    run_test("ptw_regress_test");
  end
  initial begin #2ms;$fatal(1,"PTW UVM timeout");end
endmodule
