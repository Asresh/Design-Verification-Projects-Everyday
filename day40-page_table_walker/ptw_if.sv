// Author: Asresh Kuricheti
`timescale 1ns/1ps
interface ptw_if(input logic clk);
  logic rst_n;
  logic [21:0] root_ppn;
  logic req_valid, req_ready;
  logic [31:0] req_vaddr;
  logic [1:0] req_access;
  logic req_user;
  logic mem_req_valid, mem_req_ready;
  logic [33:0] mem_req_addr;
  logic mem_rsp_valid;
  logic [31:0] mem_rsp_pte;
  logic rsp_valid, rsp_ready;
  logic [33:0] rsp_paddr;
  logic rsp_fault;
  logic [1:0] rsp_fault_code;
  logic rsp_leaf_level;

  clocking req_cb @(posedge clk);
    default input #1step output #1ns;
    output req_valid, req_vaddr, req_access, req_user, rsp_ready;
    input req_ready, rsp_valid, rsp_paddr, rsp_fault, rsp_fault_code, rsp_leaf_level;
  endclocking
  clocking mem_cb @(posedge clk);
    default input #1step output #1ns;
    input mem_req_valid, mem_req_addr;
    output mem_req_ready, mem_rsp_valid, mem_rsp_pte;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, root_ppn, req_valid, req_ready, req_vaddr, req_access, req_user;
    input mem_req_valid, mem_req_ready, mem_req_addr, mem_rsp_valid, mem_rsp_pte;
    input rsp_valid, rsp_ready, rsp_paddr, rsp_fault, rsp_fault_code, rsp_leaf_level;
  endclocking
endinterface
