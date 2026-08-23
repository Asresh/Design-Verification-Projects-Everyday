// Author: Asresh Kuricheti
`timescale 1ns/1ps

interface gshare_if #(parameter int PC_WIDTH=32, GHIST_W=4, INDEX_W=4)
                    (input logic clk);
  logic rst_n;
  logic pred_valid, pred_ready;
  logic [PC_WIDTH-1:0] pred_pc;
  logic pred_rsp_valid, pred_taken;
  logic [GHIST_W-1:0] pred_history;
  logic [INDEX_W-1:0] pred_index;
  logic update_valid;
  logic [INDEX_W-1:0] update_index;
  logic [GHIST_W-1:0] update_history;
  logic update_pred_taken, update_actual_taken, update_mispredict;
  logic [GHIST_W-1:0] global_history;

`ifdef GSHARE_SVA
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);
  ap_prediction_is_immediate: assert property (pred_valid |->
    pred_rsp_valid && pred_ready);
  ap_index_is_gshare: assert property (pred_valid |->
    pred_index == (pred_pc[INDEX_W+1:2] ^ global_history[INDEX_W-1:0]));
  ap_mispredict_exact: assert property (update_valid |->
    update_mispredict == (update_pred_taken != update_actual_taken));
  ap_no_spurious_mispredict: assert property (!update_valid |-> !update_mispredict);
  ap_known_prediction: assert property (pred_rsp_valid |->
    !$isunknown({pred_taken,pred_history,pred_index}));
  ap_history_recovery: assert property (update_valid |=>
    global_history == {$past(update_history[GHIST_W-2:0]),$past(update_actual_taken)});
`endif
endinterface
