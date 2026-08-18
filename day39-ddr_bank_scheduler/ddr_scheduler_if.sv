// Author: Asresh Kuricheti
interface ddr_scheduler_if(input logic clk);
  logic rst_n,req_valid,req_ready,req_write;logic[15:0]req_addr;logic[31:0]req_wdata;
  logic cmd_valid,cmd_ready;logic[1:0]cmd,cmd_bank;logic[7:0]cmd_row;logic[5:0]cmd_col;logic[31:0]cmd_wdata;logic req_done;
  clocking req_cb@(posedge clk);default input #1step output #1step;output req_valid,req_write,req_addr,req_wdata;input req_ready;endclocking
  clocking sink_cb@(posedge clk);default input #1step output #1step;output cmd_ready;input cmd_valid,cmd,cmd_bank,cmd_row,cmd_col,cmd_wdata,req_done;endclocking
  clocking mon_cb@(posedge clk);default input #1step;input rst_n,req_valid,req_ready,req_write,req_addr,req_wdata,cmd_valid,cmd_ready,cmd,cmd_bank,cmd_row,cmd_col,cmd_wdata,req_done;endclocking
endinterface
