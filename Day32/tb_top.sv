// =============================================================================
// Day32 - tb_top.sv
//
//   UVM top level for the MESI snooping coherence system.  Instantiates one
//   mesi_cpu_if per core, the memory interface, the passive bus interface,
//   and wires them to mesi_system's flattened ports.
//
//   Run with:
//     +UVM_TESTNAME=mesi_smoke_test
//     +UVM_TESTNAME=mesi_regress_test
// =============================================================================
`timescale 1ns/1ps

module tb_top;

  import uvm_pkg::*;
  import mesi_ref_pkg::*;
  import mesi_cache_pkg::*;
`include "uvm_macros.svh"

  localparam int CLKP = 10;

  logic clk = 1'b0;
  logic rst_n;
  always #(CLKP/2) clk = ~clk;

  // ---------------------------------------------------------------------
  // interfaces
  // ---------------------------------------------------------------------
  mesi_cpu_if #(.DW(DW), .AW(AW))                            cpu_if [NCORE] (clk, rst_n);
  mesi_mem_if #(.DW(DW), .AW(AW))                            mem_if         (clk, rst_n);
  mesi_bus_if #(.DW(DW), .AW(AW), .NSET(NSET), .NCORE(NCORE)) bus_if        (clk, rst_n);

  // ---------------------------------------------------------------------
  // flatten the per-core interfaces into the DUT's packed ports
  // ---------------------------------------------------------------------
  logic [NCORE-1:0]    cpu_req, cpu_we, cpu_ack, cpu_hit, cpu_busy;
  logic [NCORE*AW-1:0] cpu_addr_f;
  logic [NCORE*DW-1:0] cpu_wdata_f, cpu_rdata_f;

  genvar c;
  generate
    for (c = 0; c < NCORE; c = c + 1) begin : g_flat
      assign cpu_req[c]              = cpu_if[c].cpu_req;
      assign cpu_we [c]              = cpu_if[c].cpu_we;
      assign cpu_addr_f [c*AW +: AW] = cpu_if[c].cpu_addr;
      assign cpu_wdata_f[c*DW +: DW] = cpu_if[c].cpu_wdata;

      assign cpu_if[c].cpu_ack   = cpu_ack[c];
      assign cpu_if[c].cpu_hit   = cpu_hit[c];
      assign cpu_if[c].cpu_busy  = cpu_busy[c];
      assign cpu_if[c].cpu_rdata = cpu_rdata_f[c*DW +: DW];
    end
  endgenerate

  // ---------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------
  mesi_system #(.DW(DW), .AW(AW), .NSET(NSET), .NCORE(NCORE)) dut (
    .clk            (clk),
    .rst_n          (rst_n),

    .cpu_req        (cpu_req),
    .cpu_we         (cpu_we),
    .cpu_addr_f     (cpu_addr_f),
    .cpu_wdata_f    (cpu_wdata_f),
    .cpu_ack        (cpu_ack),
    .cpu_rdata_f    (cpu_rdata_f),
    .cpu_hit        (cpu_hit),
    .cpu_busy       (cpu_busy),

    .mem_req        (mem_if.mem_req),
    .mem_we         (mem_if.mem_we),
    .mem_addr       (mem_if.mem_addr),
    .mem_wdata      (mem_if.mem_wdata),
    .mem_gnt        (mem_if.mem_gnt),
    .mem_rvalid     (mem_if.mem_rvalid),
    .mem_rdata      (mem_if.mem_rdata),

    .bus_valid      (bus_if.bus_valid),
    .bus_cmd        (bus_if.bus_cmd),
    .bus_addr       (bus_if.bus_addr),
    .bus_master     (bus_if.bus_master),
    .bus_fill       (bus_if.bus_fill),
    .bus_fill_shared(bus_if.bus_fill_shared),
    .bus_fill_data  (bus_if.bus_fill_data),
    .bus_c2c        (bus_if.bus_c2c),
    .bus_busy       (bus_if.bus_busy),

    .dbg_state_f    (bus_if.dbg_state_f),
    .dbg_tag_f      (bus_if.dbg_tag_f),
    .dbg_data_f     (bus_if.dbg_data_f)
  );

  assign bus_if.cpu_busy = cpu_busy;

  // ---------------------------------------------------------------------
  // reset
  // ---------------------------------------------------------------------
  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------
  // config + run
  // ---------------------------------------------------------------------
  initial begin
    uvm_config_db#(virtual mesi_cpu_if)::set(null, "uvm_test_top.env.cpu0*", "vif", cpu_if[0]);
    uvm_config_db#(virtual mesi_cpu_if)::set(null, "uvm_test_top.env.cpu1*", "vif", cpu_if[1]);
    uvm_config_db#(virtual mesi_mem_if)::set(null, "uvm_test_top.env.memg*", "vif", mem_if);
    uvm_config_db#(virtual mesi_bus_if)::set(null, "uvm_test_top.env.busg*", "vif", bus_if);
    uvm_config_db#(virtual mesi_bus_if)::set(null, "uvm_test_top.env.sb",    "vif", bus_if);

    $dumpfile("tb_top.vcd");
    $dumpvars(0, tb_top);

    run_test();
  end

  // ---------------------------------------------------------------------
  // watchdog
  // ---------------------------------------------------------------------
  initial begin
    #3ms;
    `uvm_fatal("TIMEOUT", "the system stopped making progress")
  end

endmodule
