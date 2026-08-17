// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;import dma_engine_pkg::*;logic clk=0;always #5 clk=~clk;dma_engine_if intf(clk);
  dma_engine dut(.clk,.rst_n(intf.rst_n),.desc_valid(intf.desc_valid),.desc_ready(intf.desc_ready),.desc_src(intf.desc_src),.desc_dst(intf.desc_dst),.desc_words(intf.desc_words),.rd_valid(intf.rd_valid),.rd_ready(intf.rd_ready),.rd_addr(intf.rd_addr),.rd_data_valid(intf.rd_data_valid),.rd_data(intf.rd_data),.rd_error(intf.rd_error),.wr_valid(intf.wr_valid),.wr_ready(intf.wr_ready),.wr_addr(intf.wr_addr),.wr_data(intf.wr_data),.wr_last(intf.wr_last),.done(intf.done),.error(intf.error),.words_moved(intf.words_moved));
  initial begin intf.rst_n=0;repeat(4)@(posedge clk);intf.rst_n=1;uvm_config_db#(virtual dma_engine_if)::set(null,"*","vif",intf);run_test("dma_regress_test");end
  initial begin #2ms;$fatal(1,"timeout");end
endmodule
