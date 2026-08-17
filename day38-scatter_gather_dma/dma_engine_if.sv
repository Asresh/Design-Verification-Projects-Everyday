// Author: Asresh Kuricheti
interface dma_engine_if #(parameter ADDR_W=16, DATA_W=32, LEN_W=8)(input logic clk);
  logic rst_n,desc_valid,desc_ready; logic[ADDR_W-1:0]desc_src,desc_dst; logic[LEN_W-1:0]desc_words;
  logic rd_valid,rd_ready; logic[ADDR_W-1:0]rd_addr; logic rd_data_valid,rd_error; logic[DATA_W-1:0]rd_data;
  logic wr_valid,wr_ready; logic[ADDR_W-1:0]wr_addr; logic[DATA_W-1:0]wr_data; logic wr_last;
  logic done,error; logic[LEN_W:0]words_moved;
  clocking desc_cb @(posedge clk);default input #1step output #1step;output desc_valid,desc_src,desc_dst,desc_words;input desc_ready;endclocking
  clocking mem_cb @(posedge clk);default input #1step output #1step;input rd_valid,rd_addr,wr_valid,wr_addr,wr_data,wr_last;output rd_ready,rd_data_valid,rd_data,rd_error,wr_ready;endclocking
  clocking mon_cb @(posedge clk);default input #1step;input rst_n,desc_valid,desc_ready,desc_src,desc_dst,desc_words,rd_valid,rd_ready,rd_addr,rd_data_valid,rd_data,rd_error,wr_valid,wr_ready,wr_addr,wr_data,wr_last,done,error,words_moved;endclocking
endinterface
