// Author: Asresh Kuricheti
//
//  clock/reset -> interface -> DUT
//                  ^          |
//                  +-- UVM ---+  (two active agents + scoreboard + coverage)
`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  import power_domain_pkg::*;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  power_domain_if intf(clk);
  power_domain_controller #(.TIMEOUT_CYCLES(8)) dut (
    .clk, .rst_n(intf.rst_n), .sleep_req(intf.sleep_req),
    .wake_req(intf.wake_req), .save_done(intf.save_done),
    .restore_done(intf.restore_done), .pwr_good(intf.pwr_good),
    .isolate_en(intf.isolate_en), .retention_save(intf.retention_save),
    .retention_restore(intf.retention_restore),
    .power_switch_en(intf.power_switch_en), .domain_clk_en(intf.domain_clk_en),
    .busy(intf.busy), .asleep(intf.asleep), .fault(intf.fault),
    .state_dbg(intf.state_dbg)
  );

  initial begin
    intf.rst_n = 0; intf.sleep_req = 0; intf.wake_req = 0;
    intf.save_done = 0; intf.restore_done = 0; intf.pwr_good = 1;
    repeat (4) @(posedge clk); intf.rst_n = 1;
    uvm_config_db#(virtual power_domain_if)::set(null, "*", "vif", intf);
    run_test("power_domain_regress_test");
  end
  initial begin #2ms; $fatal(1, "power-domain UVM timeout"); end
endmodule
