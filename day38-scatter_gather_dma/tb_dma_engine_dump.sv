// Author: Asresh Kuricheti
`timescale 1ns/1ps
// Portable self-checking directed/random harness used for open-source simulation and VCD capture.
module tb_dma_engine_dump;
  logic clk=0,rst_n=0;always #5 clk=~clk;
  logic desc_valid,desc_ready;logic[15:0]desc_src,desc_dst;logic[7:0]desc_words;
  logic rd_valid,rd_ready;logic[15:0]rd_addr;logic rd_data_valid,rd_error;logic[31:0]rd_data;
  logic wr_valid,wr_ready;logic[15:0]wr_addr;logic[31:0]wr_data;logic wr_last,done,error;logic[8:0]words_moved;
  logic[31:0]mem[0:2047];integer i,errors=0,checks=0;
  logic [15:0] exp_src,exp_dst,pending_addr; logic [7:0] exp_words;
  integer exp_idx,pending_delay; logic pending_read,exp_inject;
  dma_engine dut(.*);
  task automatic send_desc(
    input logic [15:0] s,
    input logic [15:0] d,
    input logic [7:0] n,
    input logic inject_err
  );
    integer idx;
    begin
      @(negedge clk);
      exp_src=s; exp_dst=d; exp_words=n; exp_idx=0; exp_inject=inject_err;
      desc_src=s; desc_dst=d; desc_words=n; desc_valid=1;
      while(!desc_ready) @(negedge clk);
      @(negedge clk); desc_valid=0; idx=0;
      wait(done); @(negedge clk); idx=exp_idx;
      if(error!==inject_err || words_moved!==(inject_err?1:n)) begin
        $error("completion mismatch"); errors++;
      end
    end
  endtask
  always @(negedge clk) begin
    if(!rst_n) begin
      rd_ready=0; wr_ready=0; rd_data_valid=0; rd_error=0;
      pending_read=0; pending_delay=0;
    end else begin
      rd_ready=($urandom_range(0,3)!=0) && !pending_read;
      wr_ready=($urandom_range(0,3)!=0);
      rd_data_valid=0; rd_error=0;
      if(pending_read) begin
        if(pending_delay==0) begin
          rd_data=mem[pending_addr>>2]; rd_error=exp_inject&&(exp_idx==1);
          rd_data_valid=1; pending_read=0;
        end else pending_delay=pending_delay-1;
      end
      if(rd_valid&&rd_ready&&!pending_read) begin
        pending_addr=rd_addr; pending_delay=$urandom_range(1,3); pending_read=1;
      end
      if(wr_valid&&wr_ready) begin
        if(wr_addr!==exp_dst+4*exp_idx || wr_data!==mem[(exp_src>>2)+exp_idx] || wr_last!==(exp_idx==exp_words-1)) begin
          $error("write mismatch idx=%0d",exp_idx); errors++;
        end
        checks++; exp_idx++;
      end
    end
  end
  initial begin $dumpfile("tb_dma_engine_dump.vcd");$dumpvars(0,tb_dma_engine_dump);foreach(mem[i])mem[i]=32'hcafe0000+i;desc_valid=0;rd_ready=0;wr_ready=0;rd_data_valid=0;rd_error=0;pending_read=0;exp_src=0;exp_dst=0;exp_words=0;exp_idx=0;exp_inject=0;repeat(4)@(negedge clk);rst_n=1;
    send_desc(16'h0040,16'h1040,1,0);send_desc(16'h0080,16'h1080,4,0);send_desc(16'h00c0,16'h10c0,5,1);
    repeat(20)begin send_desc(($urandom_range(0,255)<<2),16'h1200+($urandom_range(0,255)<<2),$urandom_range(1,8),0);end
    if(errors==0)$display("RESULT: *** PASS *** (%0d words checked)",checks);else $display("RESULT: *** FAIL *** errors=%0d",errors);#20;$finish;end
  initial begin #2ms;$fatal(1,"timeout");end
endmodule
