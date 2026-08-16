// Author: Asresh Kuricheti
module tb_top;
  import uvm_pkg::*;import chi_snoop_filter_pkg::*;logic clk=0;always #5 clk=~clk;chi_snoop_filter_if intf(clk);
  chi_snoop_filter dut(.clk,.rst_n(intf.rst_n),.req_valid(intf.req_valid),.req_ready(intf.req_ready),.req_node(intf.req_node),.req_addr(intf.req_addr),.req_op(intf.req_op),.rsp_valid(intf.rsp_valid),.rsp_ready(intf.rsp_ready),.dir_hit(intf.dir_hit),.old_sharers(intf.old_sharers),.snoop_valid(intf.snoop_valid),.snoop_mask(intf.snoop_mask),.snoop_invalidate(intf.snoop_invalidate),.new_sharers(intf.new_sharers));
  initial begin intf.rst_n=0;repeat(4)@(posedge clk);intf.rst_n=1;uvm_config_db#(virtual chi_snoop_filter_if)::set(null,"*","vif",intf);run_test("sf_regress_test");end
  initial begin #500us;$fatal(1,"timeout");end
endmodule
