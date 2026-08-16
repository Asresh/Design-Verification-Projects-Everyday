// Author: Asresh Kuricheti
interface chi_snoop_filter_if(input logic clk);
  logic rst_n, req_valid, req_ready, rsp_valid, rsp_ready, dir_hit;
  logic [1:0] req_node, req_op;
  logic [15:0] req_addr;
  logic [3:0] old_sharers, snoop_mask, new_sharers;
  logic snoop_valid, snoop_invalidate;
  clocking req_cb @(posedge clk); default input #1step output #1step;
    output req_valid,req_node,req_addr,req_op; input req_ready;
  endclocking
  clocking flow_cb @(posedge clk); default input #1step output #1step; output rsp_ready; input rsp_valid; endclocking
  clocking mon_cb @(posedge clk); default input #1step;
    input rst_n,req_valid,req_ready,req_node,req_addr,req_op,rsp_valid,rsp_ready,dir_hit,old_sharers,snoop_valid,snoop_mask,snoop_invalidate,new_sharers;
  endclocking
endinterface
