// Author: Asresh Kuricheti
// UVM top: connects the DUT, configures both agents, applies reset, and enforces timeout.
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import axi_read_reorder_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  axi_read_reorder_if intf(clk);
  axi_read_reorder dut(
    .clk(clk), .rst_n(intf.rst_n), .ar_valid(intf.ar_valid), .ar_ready(intf.ar_ready),
    .ar_id(intf.ar_id), .ar_addr(intf.ar_addr), .mem_req_valid(intf.mem_req_valid),
    .mem_req_ready(intf.mem_req_ready), .mem_req_tag(intf.mem_req_tag),
    .mem_req_id(intf.mem_req_id), .mem_req_addr(intf.mem_req_addr),
    .mem_rsp_valid(intf.mem_rsp_valid), .mem_rsp_tag(intf.mem_rsp_tag),
    .mem_rsp_data(intf.mem_rsp_data), .mem_rsp_error(intf.mem_rsp_error),
    .r_valid(intf.r_valid), .r_ready(intf.r_ready), .r_id(intf.r_id),
    .r_data(intf.r_data), .r_error(intf.r_error), .occupancy(intf.occupancy));
  initial begin intf.rst_n=0; repeat(5) @(posedge clk); intf.rst_n=1; end
  initial begin
    uvm_config_db#(virtual axi_read_reorder_if)::set(null,"*","vif",intf);
    run_test("axi_reorder_regress_test");
  end
  initial begin #500000; $fatal(1,"Timeout: AXI reorder regression did not finish"); end
endmodule
