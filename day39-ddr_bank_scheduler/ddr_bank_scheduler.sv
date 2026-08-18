// Author: Asresh Kuricheti
`timescale 1ns/1ps
// Single-entry, open-page DDR bank scheduler. Address = {row, bank, column}.
module ddr_bank_scheduler #(
  parameter int ROW_W=8, BANK_W=2, COL_W=6, DATA_W=32,
  parameter int TRCD=2, TRP=2, TRAS=4
) (
  input logic clk,input logic rst_n,
  input logic req_valid,output logic req_ready,input logic req_write,
  input logic [ROW_W+BANK_W+COL_W-1:0] req_addr,input logic [DATA_W-1:0] req_wdata,
  output logic cmd_valid,input logic cmd_ready,output logic [1:0] cmd,
  output logic [BANK_W-1:0] cmd_bank,output logic [ROW_W-1:0] cmd_row,
  output logic [COL_W-1:0] cmd_col,output logic [DATA_W-1:0] cmd_wdata,
  output logic req_done
);
  localparam logic [1:0] CMD_ACT=2'd0,CMD_RD=2'd1,CMD_WR=2'd2,CMD_PRE=2'd3;
  localparam int NBANKS=1<<BANK_W, AGE_W=16;
  logic pending,p_write;logic [ROW_W-1:0]p_row;logic[BANK_W-1:0]p_bank;
  logic[COL_W-1:0]p_col;logic[DATA_W-1:0]p_wdata;
  logic bank_open[NBANKS];logic[ROW_W-1:0]open_row[NBANKS];
  logic[AGE_W-1:0]ras_age[NBANKS],rcd_age[NBANKS],rp_age[NBANKS];
  integer i;
  assign req_ready=!pending;
  always_comb begin
    cmd_valid=0;cmd=CMD_ACT;cmd_bank=p_bank;cmd_row=p_row;cmd_col=p_col;cmd_wdata=p_wdata;
    if(pending) begin
      if(!bank_open[p_bank] && rp_age[p_bank]>=TRP) begin cmd_valid=1;cmd=CMD_ACT;end
      else if(bank_open[p_bank] && open_row[p_bank]==p_row && rcd_age[p_bank]>=TRCD) begin cmd_valid=1;cmd=p_write?CMD_WR:CMD_RD;end
      else if(bank_open[p_bank] && open_row[p_bank]!=p_row && ras_age[p_bank]>=TRAS) begin cmd_valid=1;cmd=CMD_PRE;end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      pending<=0;req_done<=0;p_write<=0;p_row<='0;p_bank<='0;p_col<='0;p_wdata<='0;
      for(i=0;i<NBANKS;i++)begin bank_open[i]<=0;open_row[i]<='0;ras_age[i]<='0;rcd_age[i]<='0;rp_age[i]<=TRP;end
    end else begin
      req_done<=0;
      for(i=0;i<NBANKS;i++)begin
        if(bank_open[i])begin if(ras_age[i]!=16'hffff)ras_age[i]<=ras_age[i]+1'b1;if(rcd_age[i]!=16'hffff)rcd_age[i]<=rcd_age[i]+1'b1;end
        else if(rp_age[i]!=16'hffff)rp_age[i]<=rp_age[i]+1'b1;
      end
      if(req_valid&&req_ready)begin
        pending<=1;p_write<=req_write;p_row<=req_addr[ROW_W+BANK_W+COL_W-1 -: ROW_W];
        p_bank<=req_addr[COL_W +: BANK_W];p_col<=req_addr[COL_W-1:0];p_wdata<=req_wdata;
      end
      if(cmd_valid&&cmd_ready)begin
        case(cmd)
          CMD_ACT:begin bank_open[cmd_bank]<=1;open_row[cmd_bank]<=cmd_row;ras_age[cmd_bank]<='0;rcd_age[cmd_bank]<='0;end
          CMD_PRE:begin bank_open[cmd_bank]<=0;rp_age[cmd_bank]<='0;end
          CMD_RD,CMD_WR:begin pending<=0;req_done<=1;end
          default:;
        endcase
      end
    end
  end
`ifdef DDR_SVA
  property p_stable_stall;@(posedge clk)disable iff(!rst_n)cmd_valid&&!cmd_ready|=>cmd_valid&&$stable({cmd,cmd_bank,cmd_row,cmd_col,cmd_wdata});endproperty
  assert property(p_stable_stall);
  assert property(@(posedge clk)disable iff(!rst_n)req_done|=>!req_done);
  assert property(@(posedge clk)disable iff(!rst_n)cmd_valid&&(cmd inside {CMD_RD,CMD_WR})|->bank_open[cmd_bank]&&open_row[cmd_bank]==cmd_row&&rcd_age[cmd_bank]>=TRCD);
  assert property(@(posedge clk)disable iff(!rst_n)cmd_valid&&cmd==CMD_PRE|->bank_open[cmd_bank]&&ras_age[cmd_bank]>=TRAS);
`endif
endmodule
