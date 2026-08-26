// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import credit_link_pkg::*;
  logic clk=0; always #5 clk=~clk;
  credit_link_if #(DATA_W,MAX_CREDITS,CREDIT_W) intf(clk);
  credit_link_tx #(.DATA_W(DATA_W),.MAX_CREDITS(MAX_CREDITS)) dut (
    .clk, .rst_n(intf.rst_n), .cfg_valid(intf.cfg_valid), .cfg_credits(intf.cfg_credits),
    .req_valid(intf.req_valid), .req_ready(intf.req_ready), .req_data(intf.req_data), .req_last(intf.req_last),
    .credit_return(intf.credit_return), .link_valid(intf.link_valid), .link_data(intf.link_data), .link_last(intf.link_last),
    .credit_count(intf.credit_count), .credit_overflow(intf.credit_overflow));
  initial begin
    intf.rst_n=0; intf.cfg_valid=0; intf.cfg_credits='0; intf.req_valid=0; intf.req_data='0; intf.req_last=0; intf.credit_return='0;
    repeat(4) @(posedge clk); intf.rst_n<=1;
  end
  initial begin
    $dumpfile("credit_link.vcd"); $dumpvars(0,tb_top);
    uvm_config_db#(vif_t)::set(null,"uvm_test_top.env.*","vif",intf);
    run_test("credit_link_test");
  end
  initial begin #100000; $fatal(1,"TIMEOUT: credit-link test exceeded 100 us"); end
endmodule
