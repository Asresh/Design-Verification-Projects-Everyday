// Author: Asresh Kuricheti
// Portable self-checking regression and VCD capture for Icarus.
`timescale 1ns/1ps
module tb_pcie_replay_dump;
  localparam DATA_W=32, SEQ_W=8, DEPTH=8;
  logic clk=0, rst_n=0, tx_valid=0, link_ready=1, ack_valid=0, nak_valid=0;
  logic [DATA_W-1:0] tx_data=0, link_data;
  logic [SEQ_W-1:0] link_seq, ack_seq=0, nak_seq=0;
  logic tx_ready, link_valid, replay_active, full, empty;
  logic [$clog2(DEPTH+1)-1:0] occupancy;
  logic [31:0] model_data [0:DEPTH-1];
  logic [7:0] model_seq [0:DEPTH-1];
  integer model_head=0, model_count=0, model_send=0, next_seq=0;
  integer checks=0, errors=0, i, burst, first_seq, last_seq;
  logic [31:0] hold_data; logic [7:0] hold_seq;
  always #5 clk=~clk;

  pcie_replay_buffer #(.DATA_W(DATA_W),.SEQ_W(SEQ_W),.DEPTH(DEPTH)) dut(.*);

  task fail(input [8*100-1:0] msg);
    begin $display("ERROR: %0s at %0t",msg,$time); errors=errors+1; end
  endtask
  task tick; begin @(posedge clk); #1; end endtask
  task model_push(input [31:0] data);
    integer idx; begin idx=(model_head+model_count)%DEPTH; model_data[idx]=data; model_seq[idx]=next_seq[7:0]; model_count=model_count+1; next_seq=(next_seq+1)&255; end
  endtask
  task send_one(input [31:0] data);
    begin
      link_ready=0;
      while(!tx_ready) tick();
      tx_data=data; tx_valid=1; tick(); tx_valid=0; model_push(data);
      if(occupancy!==model_count) fail("occupancy after enqueue");
    end
  endtask
  task expect_one;
    integer idx; begin
      #1;
      idx=(model_head+model_send)%DEPTH;
      while(!link_valid) tick();
      if(link_seq!==model_seq[idx] || link_data!==model_data[idx]) begin
        $display("expected seq=%0d data=%08x got seq=%0d data=%08x idx=%0d send=%0d head=%0d",model_seq[idx],model_data[idx],link_seq,link_data,idx,model_send,model_head);
        fail("link packet mismatch");
      end
      checks=checks+1; tick(); model_send=model_send+1;
    end
  endtask
  task do_nak(input integer seq);
    integer off, found; begin
      off=0; found=0;
      for(i=0;i<model_count;i=i+1) if(model_seq[(model_head+i)%DEPTH]===seq[7:0]) begin off=i; found=1; end
      nak_seq=seq[7:0]; nak_valid=1; tick(); nak_valid=0;
      if(found) model_send=off;
      if(found && !replay_active) fail("replay_active did not assert");
    end
  endtask
  task do_ack(input integer seq);
    integer n; begin
      n=0; for(i=0;i<model_count;i=i+1) if(model_seq[(model_head+i)%DEPTH]===seq[7:0]) n=i+1;
      ack_seq=seq[7:0]; ack_valid=1; tick(); ack_valid=0;
      if(n>0) begin model_head=(model_head+n)%DEPTH; model_count=model_count-n; model_send=0; end
      if(occupancy!==model_count) fail("occupancy after cumulative ACK");
    end
  endtask

  initial begin
    $dumpfile("tb_pcie_replay_dump.vcd"); $dumpvars(0,tb_pcie_replay_dump);
    repeat(3) tick(); rst_n=1; tick();
    if(!empty || occupancy!=0) fail("reset state");

    send_one(32'hA11C_E001); send_one(32'hA11C_E002); send_one(32'hA11C_E003);
    link_ready=0; tick();
    if(!link_valid) fail("valid during backpressure"); hold_data=link_data; hold_seq=link_seq;
    repeat(2) begin tick(); if(link_data!==hold_data || link_seq!==hold_seq) fail("stability while stalled"); end
    link_ready=1; expect_one(); expect_one(); expect_one();
    do_nak(1); expect_one(); expect_one();
    do_ack(1); do_nak(2); expect_one(); do_ack(2);
    if(!empty) fail("empty after final ACK");

    for(i=0;i<DEPTH;i=i+1) send_one(32'hF100_0000+i);
    if(!full || tx_ready) fail("full backpressure");
    link_ready=1;
    for(i=0;i<DEPTH;i=i+1) expect_one();
    do_ack(10);

    // Coverage-driven randomized bursts: enqueue, drain, sometimes replay, cumulative ACK.
    for(burst=0;burst<40;burst=burst+1) begin
      first_seq=next_seq; last_seq=next_seq+(burst%5);
      for(i=0;i<(burst%5)+1;i=i+1) send_one($urandom);
      link_ready=1;
      for(i=0;i<(burst%5)+1;i=i+1) expect_one();
      if((burst%3)==0) begin do_nak(first_seq); for(i=0;i<(burst%5)+1;i=i+1) expect_one(); end
      do_ack(last_seq&255);
    end
    if(model_count!=0 || occupancy!=0) fail("model/DUT not empty at end");
    if(errors==0) $display("RESULT: *** PASS *** (%0d packets checked)",checks);
    else $display("RESULT: *** FAIL *** errors=%0d",errors);
    #10; $finish;
  end
  initial begin #200000; $display("RESULT: *** FAIL *** timeout"); $finish; end
endmodule
