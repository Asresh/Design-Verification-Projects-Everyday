// Author: Asresh Kuricheti
//
// command agent ---> sleep_req/wake_req ---> DUT ---> isolation/power/clock
// ack agent ------> save/restore/pwr_good --^  \--> state/status monitor
`timescale 1ns/1ps

interface power_domain_if(input logic clk);
  logic rst_n;
  logic sleep_req, wake_req;
  logic save_done, restore_done, pwr_good;
  logic isolate_en, retention_save, retention_restore;
  logic power_switch_en, domain_clk_en, busy, asleep, fault;
  logic [2:0] state_dbg;

`ifdef POWER_DOMAIN_SVA
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);
  ap_off_is_safe: assert property (!power_switch_en |-> isolate_en && !domain_clk_en);
  ap_restore_is_isolated: assert property (retention_restore |-> isolate_en && power_switch_en);
  ap_save_is_powered: assert property (retention_save |-> power_switch_en && domain_clk_en);
  ap_asleep_contract: assert property (asleep |-> !power_switch_en && isolate_en && !busy);
  ap_fault_is_safe: assert property (fault |-> isolate_en && power_switch_en && !domain_clk_en);
  ap_no_save_restore_overlap: assert property (!(retention_save && retention_restore));
  ap_outputs_known: assert property (!$isunknown({isolate_en,retention_save,
    retention_restore,power_switch_en,domain_clk_en,busy,asleep,fault,state_dbg}));
`endif
endinterface
