// Author: Asresh Kuricheti
// Interface shared by the BIST control agent, SRAM responder agent, and monitors.
interface march_c_bist_if #(parameter int ADDR_W=4, DATA_W=8) (input logic clk);
  logic rst_n, start, busy, done, pass, fail;
  logic [ADDR_W-1:0] fail_addr;
  logic [DATA_W-1:0] fail_expected, fail_actual;
  logic mem_valid, mem_ready, mem_write;
  logic [ADDR_W-1:0] mem_addr;
  logic [DATA_W-1:0] mem_wdata, mem_rdata;
  logic mem_rsp_valid;
  logic inject_en;
  logic [ADDR_W-1:0] inject_addr;
  logic inject_stuck_value;

  clocking ctrl_cb @(posedge clk);
    output start, inject_en, inject_addr, inject_stuck_value;
    input busy, done, pass, fail, fail_addr, fail_expected, fail_actual;
  endclocking
  clocking mem_cb @(posedge clk);
    input mem_valid, mem_write, mem_addr, mem_wdata;
    output mem_ready, mem_rsp_valid, mem_rdata;
  endclocking
endinterface
