// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;import ddr_scheduler_pkg::*;logic clk=0;always #5 clk=~clk;ddr_scheduler_if intf(clk);
  ddr_bank_scheduler dut(.clk,.rst_n(intf.rst_n),.req_valid(intf.req_valid),.req_ready(intf.req_ready),.req_write(intf.req_write),.req_addr(intf.req_addr),.req_wdata(intf.req_wdata),.cmd_valid(intf.cmd_valid),.cmd_ready(intf.cmd_ready),.cmd(intf.cmd),.cmd_bank(intf.cmd_bank),.cmd_row(intf.cmd_row),.cmd_col(intf.cmd_col),.cmd_wdata(intf.cmd_wdata),.req_done(intf.req_done));
  initial begin intf.rst_n=0;repeat(4)@(posedge clk);intf.rst_n=1;uvm_config_db#(virtual ddr_scheduler_if)::set(null,"*","vif",intf);run_test("ddr_regress_test");end
  initial begin #2ms;$fatal(1,"timeout");end
endmodule
