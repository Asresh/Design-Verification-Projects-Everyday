// Author: Asresh Kuricheti
// Shared pin-level interface for request and out-of-order memory-response agents.
interface axi_read_reorder_if #(parameter ADDR_W=16, DATA_W=32, ID_W=2, DEPTH=8,
  TAG_W=$clog2(DEPTH)) (input logic clk);
  logic rst_n;
  logic ar_valid, ar_ready;
  logic [ID_W-1:0] ar_id;
  logic [ADDR_W-1:0] ar_addr;
  logic mem_req_valid, mem_req_ready;
  logic [TAG_W-1:0] mem_req_tag;
  logic [ID_W-1:0] mem_req_id;
  logic [ADDR_W-1:0] mem_req_addr;
  logic mem_rsp_valid;
  logic [TAG_W-1:0] mem_rsp_tag;
  logic [DATA_W-1:0] mem_rsp_data;
  logic mem_rsp_error;
  logic r_valid, r_ready;
  logic [ID_W-1:0] r_id;
  logic [DATA_W-1:0] r_data;
  logic r_error;
  logic [$clog2(DEPTH+1)-1:0] occupancy;

  clocking req_cb @(posedge clk);
    default input #1step output #1step;
    output ar_valid, ar_id, ar_addr;
    input ar_ready;
  endclocking
  clocking mem_cb @(posedge clk);
    default input #1step output #1step;
    output mem_req_ready, mem_rsp_valid, mem_rsp_tag, mem_rsp_data, mem_rsp_error, r_ready;
    input mem_req_valid, mem_req_tag, mem_req_id, mem_req_addr;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, ar_valid, ar_ready, ar_id, ar_addr, mem_req_valid, mem_req_ready,
      mem_req_tag, mem_req_id, mem_req_addr, mem_rsp_valid, mem_rsp_tag,
      mem_rsp_data, mem_rsp_error, r_valid, r_ready, r_id, r_data, r_error, occupancy;
  endclocking
endinterface
