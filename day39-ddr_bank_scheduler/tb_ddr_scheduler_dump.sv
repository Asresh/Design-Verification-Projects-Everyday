// Author: Asresh Kuricheti
`timescale 1ns/1ps
// Portable independent checker used by Icarus for regression and real VCD capture.
module tb_ddr_scheduler_dump;
  localparam ACT=0,RD=1,WR=2,PRE=3,TRCD=2,TRP=2,TRAS=4;
  logic clk=0,rst_n=0;always #5 clk=~clk;logic req_valid,req_ready,req_write;logic[15:0]req_addr;logic[31:0]req_wdata;
  logic cmd_valid,cmd_ready;logic[1:0]cmd,cmd_bank;logic[7:0]cmd_row;logic[5:0]cmd_col;logic[31:0]cmd_wdata;logic req_done;
  ddr_bank_scheduler dut(.*);integer errors=0,checks=0,requests=0,i;logic exp_active,exp_write;logic[7:0]exp_row;logic[1:0]exp_bank;logic[5:0]exp_col;logic[31:0]exp_data;
  logic ref_open[4];logic[7:0]ref_row[4];integer ras[4],rcd[4],rp[4];
  task automatic issue(input logic w,input logic[7:0]row,input logic[1:0]bank,input logic[5:0]col,input logic[31:0]data);begin
    @(negedge clk);req_valid=1;req_write=w;req_addr={row,bank,col};req_wdata=data;while(!req_ready)@(negedge clk);@(negedge clk);req_valid=0;wait(req_done);requests++;@(negedge clk);
  end endtask
  always @(negedge clk)if(rst_n)cmd_ready=($urandom_range(0,3)!=0);
  always @(posedge clk)begin
    if(!rst_n)begin exp_active=0;foreach(ref_open[i])begin ref_open[i]=0;ras[i]=0;rcd[i]=0;rp[i]=TRP;end end
    else begin
      foreach(ref_open[i])if(ref_open[i])begin ras[i]++;rcd[i]++;end else rp[i]++;
      if(req_valid&&req_ready)begin exp_active=1;exp_write=req_write;exp_row=req_addr[15:8];exp_bank=req_addr[7:6];exp_col=req_addr[5:0];exp_data=req_wdata;end
      if(cmd_valid&&cmd_ready)begin checks++;
        if(!exp_active||cmd_bank!==exp_bank||cmd_row!==exp_row||cmd_col!==exp_col||cmd_wdata!==exp_data)begin $error("command/request mismatch");errors++;end
        case(cmd)
          ACT:if(ref_open[cmd_bank]||rp[cmd_bank]<TRP)begin $error("illegal ACT");errors++;end else begin ref_open[cmd_bank]=1;ref_row[cmd_bank]=cmd_row;ras[cmd_bank]=0;rcd[cmd_bank]=0;end
          PRE:if(!ref_open[cmd_bank]||ref_row[cmd_bank]==exp_row||ras[cmd_bank]<TRAS)begin $error("illegal PRE");errors++;end else begin ref_open[cmd_bank]=0;rp[cmd_bank]=0;end
          RD,WR:begin if(!ref_open[cmd_bank]||ref_row[cmd_bank]!=exp_row||rcd[cmd_bank]<TRCD||cmd!=(exp_write?WR:RD))begin $error("illegal RD/WR");errors++;end exp_active=0;end
          default:begin $error("unknown command");errors++;end
        endcase
      end
    end
  end
  initial begin $dumpfile("tb_ddr_scheduler_dump.vcd");$dumpvars(0,tb_ddr_scheduler_dump);req_valid=0;req_write=0;req_addr=0;req_wdata=0;cmd_ready=0;repeat(4)@(negedge clk);rst_n=1;
    issue(0,8'h10,0,1,32'h0);issue(1,8'h10,0,2,32'ha5a50001);issue(0,8'h20,0,3,32'h0);issue(1,8'h30,3,4,32'h55aa0002);
    repeat(60)issue($urandom_range(0,1),$urandom_range(0,15),$urandom_range(0,3),$urandom_range(0,63),$urandom);
    if(errors==0&&checks>requests)$display("RESULT: *** PASS *** (%0d requests, %0d commands checked)",requests,checks);else $display("RESULT: *** FAIL *** errors=%0d",errors);#20;$finish;
  end
  initial begin #2ms;$fatal(1,"timeout");end
endmodule
