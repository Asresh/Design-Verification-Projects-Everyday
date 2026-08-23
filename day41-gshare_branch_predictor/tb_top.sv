// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*; import gshare_pkg::*;
  logic clk=0; always #5 clk=~clk;
  gshare_if intf(clk);
  gshare_branch_predictor dut(
    .clk,.rst_n(intf.rst_n),.pred_valid(intf.pred_valid),.pred_ready(intf.pred_ready),
    .pred_pc(intf.pred_pc),.pred_rsp_valid(intf.pred_rsp_valid),.pred_taken(intf.pred_taken),
    .pred_history(intf.pred_history),.pred_index(intf.pred_index),
    .update_valid(intf.update_valid),.update_index(intf.update_index),
    .update_history(intf.update_history),.update_pred_taken(intf.update_pred_taken),
    .update_actual_taken(intf.update_actual_taken),.update_mispredict(intf.update_mispredict),
    .global_history(intf.global_history));
  initial begin
    intf.rst_n=0;repeat(5)@(posedge clk);intf.rst_n=1;
    uvm_config_db#(virtual gshare_if)::set(null,"*","vif",intf);
    run_test("gshare_regress_test");
  end
  initial begin #2ms;$fatal(1,"gshare UVM timeout");end
endmodule
