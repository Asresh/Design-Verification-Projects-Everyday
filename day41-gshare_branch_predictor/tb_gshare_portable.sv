// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_gshare_portable;
  localparam int PC_WIDTH=32, GHIST_W=4, INDEX_W=4, ENTRIES=1<<INDEX_W;
  logic clk=0,rst_n=0; always #5 clk=~clk;
  logic pred_valid,pred_ready,pred_rsp_valid,pred_taken;
  logic [PC_WIDTH-1:0] pred_pc;
  logic [GHIST_W-1:0] pred_history,global_history,update_history;
  logic [INDEX_W-1:0] pred_index,update_index;
  logic update_valid,update_pred_taken,update_actual_taken,update_mispredict;
  logic [1:0] ref_pht[ENTRIES]; logic [GHIST_W-1:0] ref_ghr;
  integer checks,errors,pred_taken_bins,pred_nt_bins,correct_bins,miss_bins;
  integer inc_sat_bins,dec_sat_bins,idx_seen[ENTRIES]; integer i;

  gshare_branch_predictor #(.PC_WIDTH(PC_WIDTH),.GHIST_W(GHIST_W),.INDEX_W(INDEX_W)) dut(.*);

  task automatic do_branch(input logic[PC_WIDTH-1:0] pc,input logic actual);
    logic exp_pred; logic[INDEX_W-1:0] exp_idx; logic[GHIST_W-1:0] snap;
    begin
      @(negedge clk); pred_pc=pc; pred_valid=1;
      #1; exp_idx=pc[INDEX_W+1:2]^ref_ghr; exp_pred=ref_pht[exp_idx][1]; snap=ref_ghr;
      if (!pred_ready || !pred_rsp_valid || pred_index !== exp_idx ||
          pred_history !== snap || pred_taken !== exp_pred) begin
        $error("prediction mismatch pc=%h exp_idx=%0d got_idx=%0d exp=%0b got=%0b",pc,exp_idx,pred_index,exp_pred,pred_taken);errors=errors+1;
      end
      checks=checks+1;idx_seen[exp_idx]=1;if(exp_pred)pred_taken_bins=pred_taken_bins+1;else pred_nt_bins=pred_nt_bins+1;
      @(posedge clk); @(negedge clk); pred_valid=0;
      update_index=exp_idx;update_history=snap;update_pred_taken=exp_pred;update_actual_taken=actual;update_valid=1;
      #1;
      if (update_mispredict !== (exp_pred != actual)) begin
        $error("mispredict flag mismatch"); errors=errors+1;
      end
      if(exp_pred==actual)correct_bins=correct_bins+1;else miss_bins=miss_bins+1;
      if(actual)begin if(ref_pht[exp_idx]==2'b11)inc_sat_bins=inc_sat_bins+1;else ref_pht[exp_idx]=ref_pht[exp_idx]+1'b1;end
      else begin if(ref_pht[exp_idx]==2'b00)dec_sat_bins=dec_sat_bins+1;else ref_pht[exp_idx]=ref_pht[exp_idx]-1'b1;end
      ref_ghr={snap[GHIST_W-2:0],actual};
      @(posedge clk); #1;
      if (global_history !== ref_ghr) begin
        $error("history recovery mismatch exp=%h got=%h",ref_ghr,global_history); errors=errors+1;
      end
      checks=checks+1;@(negedge clk);update_valid=0;
    end
  endtask

  initial begin
    $dumpfile("gshare_branch_predictor.vcd");$dumpvars(0,tb_gshare_portable);
    pred_valid=0;pred_pc=0;update_valid=0;update_index=0;update_history=0;
    update_pred_taken=0;update_actual_taken=0;checks=0;errors=0;
    pred_taken_bins=0;pred_nt_bins=0;correct_bins=0;miss_bins=0;inc_sat_bins=0;dec_sat_bins=0;
    ref_ghr='0;for(i=0;i<ENTRIES;i=i+1)begin ref_pht[i]=2'b01;idx_seen[i]=0;end
    repeat(4)@(posedge clk);rst_n=1;

    // Directed: counter state transitions, saturation, history patterns, and aliasing.
    repeat(5)do_branch(32'h00001000,1'b1);
    repeat(5)do_branch(32'h00001000,1'b0);
    do_branch(32'h00001040,1'b1);do_branch(32'h00001000,1'b0);
    for(i=0;i<16;i=i+1)do_branch(32'h00001000+(i<<2),i[0]);

    // Constrained-random style: aligned finite address range and biased outcomes.
    for(i=0;i<240;i=i+1)
      do_branch(32'h00001000+(($urandom_range(0,63))<<2),($urandom_range(0,99)<62));

    if(pred_taken_bins==0||pred_nt_bins==0||correct_bins==0||miss_bins==0||inc_sat_bins==0||dec_sat_bins==0)begin
      $error("functional coverage hole predT=%0d predN=%0d correct=%0d miss=%0d incSat=%0d decSat=%0d",pred_taken_bins,pred_nt_bins,correct_bins,miss_bins,inc_sat_bins,dec_sat_bins);errors=errors+1;
    end
    for(i=0;i<ENTRIES;i=i+1) if(!idx_seen[i]) begin
      $error("PHT index %0d uncovered",i); errors=errors+1;
    end
    if(errors==0)$display("RESULT: *** PASS *** checks=%0d correct=%0d mispredict=%0d",checks,correct_bins,miss_bins);
    else $display("RESULT: *** FAIL *** errors=%0d",errors);
    $finish;
  end
  initial begin #2000000;$fatal(1,"portable testbench timeout");end
endmodule
