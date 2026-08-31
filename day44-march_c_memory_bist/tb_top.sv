// Author: Asresh Kuricheti
// UVM top for commercial simulators with a built-in timeout and VCD dump.
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*; import march_c_bist_pkg::*;
  logic clk=0; always #5 clk=~clk;
  march_c_bist_if #(ADDR_W,DATA_W) intf(clk);
  march_c_bist #(.ADDR_W(ADDR_W),.DATA_W(DATA_W)) dut (
    .clk,.rst_n(intf.rst_n),.start(intf.start),.busy(intf.busy),.done(intf.done),.pass(intf.pass),.fail(intf.fail),
    .fail_addr(intf.fail_addr),.fail_expected(intf.fail_expected),.fail_actual(intf.fail_actual),
    .mem_valid(intf.mem_valid),.mem_ready(intf.mem_ready),.mem_write(intf.mem_write),.mem_addr(intf.mem_addr),
    .mem_wdata(intf.mem_wdata),.mem_rsp_valid(intf.mem_rsp_valid),.mem_rdata(intf.mem_rdata));
  initial begin intf.rst_n=0;intf.start=0;intf.mem_ready=0;intf.mem_rsp_valid=0;intf.mem_rdata='0;intf.inject_en=0;repeat(4)@(posedge clk);intf.rst_n<=1;end
  initial begin $dumpfile("march_c_bist_uvm.vcd");$dumpvars(0,tb_top);uvm_config_db#(vif_t)::set(null,"uvm_test_top.env.*","vif",intf);run_test("march_c_bist_test");end
  initial begin #200000;$fatal(1,"TIMEOUT: UVM March C- regression exceeded 200 us");end
endmodule
