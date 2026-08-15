// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*; import pcie_replay_pkg::*;
  logic clk=0; always #5 clk=~clk;
  pcie_replay_if intf(clk);
  pcie_replay_buffer dut(.clk(clk),.rst_n(intf.rst_n),.tx_valid(intf.tx_valid),.tx_ready(intf.tx_ready),
    .tx_data(intf.tx_data),.link_valid(intf.link_valid),.link_ready(intf.link_ready),.link_data(intf.link_data),
    .link_seq(intf.link_seq),.ack_valid(intf.ack_valid),.ack_seq(intf.ack_seq),.nak_valid(intf.nak_valid),
    .nak_seq(intf.nak_seq),.replay_active(intf.replay_active),.full(intf.full),.empty(intf.empty),.occupancy(intf.occupancy));
  initial begin intf.rst_n=0; repeat(4) @(posedge clk); intf.rst_n=1; end
  initial begin uvm_config_db#(virtual pcie_replay_if)::set(null,"*","vif",intf); run_test("replay_regress_test"); end
  initial begin #200000; $fatal(1,"Timeout"); end
endmodule
