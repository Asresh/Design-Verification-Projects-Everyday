// =============================================================================
// Day32 - mesi_cache_if.sv
//
//   Three interfaces, because the MESI system has three genuinely different
//   wire boundaries and one agent should own each:
//
//     mesi_cpu_if   one per core - the request/response port an agent drives
//     mesi_mem_if   the backing-store port.  Its driver IS the memory, and
//                   its monitor is the scoreboard's only window onto what the
//                   caches actually pushed to DRAM.
//     mesi_bus_if   the shared snoop bus, plus the white-box coherence state.
//                   Passive: nothing drives it, the checker only watches.
//
//   The SVA is guarded by +define+MESI_SVA (Icarus implements no concurrent
//   assertions, so the portable target compiles without it).
// =============================================================================
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// One core's CPU port.
// -----------------------------------------------------------------------------
interface mesi_cpu_if #(parameter int DW = 32, parameter int AW = 8)
                       (input logic clk, input logic rst_n);

  logic          cpu_req;
  logic          cpu_we;
  logic [AW-1:0] cpu_addr;
  logic [DW-1:0] cpu_wdata;
  logic          cpu_ack;
  logic [DW-1:0] cpu_rdata;
  logic          cpu_hit;
  logic          cpu_busy;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output cpu_req, cpu_we, cpu_addr, cpu_wdata;
    input  cpu_ack, cpu_rdata, cpu_hit, cpu_busy;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input cpu_req, cpu_we, cpu_addr, cpu_wdata;
    input cpu_ack, cpu_rdata, cpu_hit, cpu_busy;
  endclocking

  modport drv (clocking drv_cb, input clk, rst_n);
  modport mon (clocking mon_cb, input clk, rst_n);

`ifdef MESI_SVA
  // A request must stay put until the cache takes it: the DUT latches
  // {we,addr,wdata} on the first idle edge, so a stimulus generator that
  // moves them underneath it is testing something nobody built.
  property p_req_stable;
    @(posedge clk) disable iff (!rst_n)
      (cpu_req && cpu_busy) |=> $stable({cpu_we, cpu_addr, cpu_wdata});
  endproperty
  a_req_stable: assert property (p_req_stable)
    else $error("[cpu_if] request payload moved while the cache was busy");

  // ack is a one-cycle pulse and only ever arrives against a live access
  property p_ack_pulse;
    @(posedge clk) disable iff (!rst_n) cpu_ack |=> !cpu_ack;
  endproperty
  a_ack_pulse: assert property (p_ack_pulse)
    else $error("[cpu_if] cpu_ack held for more than one cycle");

  property p_ack_needs_busy;
    @(posedge clk) disable iff (!rst_n) cpu_ack |-> cpu_busy;
  endproperty
  a_ack_needs_busy: assert property (p_ack_needs_busy)
    else $error("[cpu_if] cpu_ack asserted while the cache was idle");

  // a hit is by definition instantaneous relative to the bus
  property p_hit_implies_ack;
    @(posedge clk) disable iff (!rst_n) cpu_hit |-> cpu_ack;
  endproperty
  a_hit_implies_ack: assert property (p_hit_implies_ack)
    else $error("[cpu_if] cpu_hit asserted without cpu_ack");

  property p_no_x_resp;
    @(posedge clk) disable iff (!rst_n) cpu_ack |-> !$isunknown(cpu_rdata);
  endproperty
  a_no_x_resp: assert property (p_no_x_resp)
    else $error("[cpu_if] X on cpu_rdata at completion");

  // coverage of the response shapes we care about
  c_hit  : cover property (@(posedge clk) disable iff (!rst_n) cpu_ack &&  cpu_hit);
  c_miss : cover property (@(posedge clk) disable iff (!rst_n) cpu_ack && !cpu_hit);
  c_wr_hit: cover property (@(posedge clk) disable iff (!rst_n) cpu_ack && cpu_hit && cpu_we);
  c_b2b  : cover property (@(posedge clk) disable iff (!rst_n) cpu_ack ##1 cpu_req);
`endif

endinterface


// -----------------------------------------------------------------------------
// Backing-store port.
// -----------------------------------------------------------------------------
interface mesi_mem_if #(parameter int DW = 32, parameter int AW = 8)
                       (input logic clk, input logic rst_n);

  logic          mem_req;
  logic          mem_we;
  logic [AW-1:0] mem_addr;
  logic [DW-1:0] mem_wdata;
  logic          mem_gnt;
  logic          mem_rvalid;
  logic [DW-1:0] mem_rdata;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    input  mem_req, mem_we, mem_addr, mem_wdata;
    output mem_gnt, mem_rvalid, mem_rdata;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input mem_req, mem_we, mem_addr, mem_wdata, mem_gnt, mem_rvalid, mem_rdata;
  endclocking

  modport drv (clocking drv_cb, input clk, rst_n);
  modport mon (clocking mon_cb, input clk, rst_n);

`ifdef MESI_SVA
  // The fabric holds a request until it is granted, so the payload may not
  // move underneath a stalling memory - that is exactly the case a lazy
  // memory model would let slide.
  property p_req_held;
    @(posedge clk) disable iff (!rst_n)
      (mem_req && !mem_gnt) |=> (mem_req && $stable({mem_we, mem_addr, mem_wdata}));
  endproperty
  a_req_held: assert property (p_req_held)
    else $error("[mem_if] a stalled memory request changed or disappeared");

  property p_gnt_needs_req;
    @(posedge clk) disable iff (!rst_n) mem_gnt |-> mem_req;
  endproperty
  a_gnt_needs_req: assert property (p_gnt_needs_req)
    else $error("[mem_if] grant with no request");

  property p_no_x_rdata;
    @(posedge clk) disable iff (!rst_n) mem_rvalid |-> !$isunknown(mem_rdata);
  endproperty
  a_no_x_rdata: assert property (p_no_x_rdata)
    else $error("[mem_if] X on mem_rdata");

  c_stalled : cover property (@(posedge clk) disable iff (!rst_n) mem_req && !mem_gnt);
  c_wr      : cover property (@(posedge clk) disable iff (!rst_n) mem_req && mem_gnt && mem_we);
  c_rd      : cover property (@(posedge clk) disable iff (!rst_n) mem_req && mem_gnt && !mem_we);
`endif

endinterface


// -----------------------------------------------------------------------------
// Shared snoop bus + white-box coherence state.  Passive.
// -----------------------------------------------------------------------------
interface mesi_bus_if #(parameter int DW    = 32,
                        parameter int AW    = 8,
                        parameter int NSET  = 4,
                        parameter int NCORE = 2)
                       (input logic clk, input logic rst_n);

  logic                       bus_valid;
  logic [1:0]                 bus_cmd;
  logic [AW-1:0]              bus_addr;
  logic [$clog2(NCORE)-1:0]   bus_master;
  logic                       bus_fill;
  logic                       bus_fill_shared;
  logic [DW-1:0]              bus_fill_data;
  logic                       bus_c2c;
  logic                       bus_busy;

  // the coherence state itself - a checker for this protocol cannot work
  // from the pins alone, because SWMR is a statement about what the caches
  // are holding, not about anything that appears on a wire
  logic [NCORE*2*NSET-1:0]    dbg_state_f;
  logic [NCORE*AW*NSET-1:0]   dbg_tag_f;
  logic [NCORE*DW*NSET-1:0]   dbg_data_f;

  // convenience for the drivers' "system is idle" checks
  logic [NCORE-1:0]           cpu_busy;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input bus_valid, bus_cmd, bus_addr, bus_master;
    input bus_fill, bus_fill_shared, bus_fill_data, bus_c2c, bus_busy;
    input dbg_state_f, dbg_tag_f, dbg_data_f, cpu_busy;
  endclocking

  modport mon (clocking mon_cb, input clk, rst_n);

`ifdef MESI_SVA
  localparam logic [1:0] BUSRD   = 2'd0;
  localparam logic [1:0] BUSRDX  = 2'd1;
  localparam logic [1:0] BUSUPGR = 2'd2;
  localparam logic [1:0] BUSWB   = 2'd3;
  localparam logic [1:0] ST_I    = 2'd0;
  localparam logic [1:0] ST_S    = 2'd1;
  localparam logic [1:0] ST_E    = 2'd2;
  localparam logic [1:0] ST_M    = 2'd3;

  // The address phase is a single cycle and always opens a transaction that
  // eventually completes.
  property p_addr_pulse;
    @(posedge clk) disable iff (!rst_n) bus_valid |=> !bus_valid;
  endproperty
  a_addr_pulse: assert property (p_addr_pulse)
    else $error("[bus_if] address phase longer than one cycle");

  property p_addr_then_fill;
    @(posedge clk) disable iff (!rst_n) bus_valid |-> ##[1:64] bus_fill;
  endproperty
  a_addr_then_fill: assert property (p_addr_then_fill)
    else $error("[bus_if] a bus transaction never completed");

  property p_fill_needs_txn;
    @(posedge clk) disable iff (!rst_n) bus_fill |-> bus_busy;
  endproperty
  a_fill_needs_txn: assert property (p_fill_needs_txn)
    else $error("[bus_if] completion with no transaction in flight");

  // An upgrade moves no data, so it can never be served cache-to-cache.
  property p_upgr_no_data;
    @(posedge clk) disable iff (!rst_n)
      (bus_valid && (bus_cmd == BUSUPGR)) |-> ##[1:64] (bus_fill && !bus_c2c);
  endproperty
  a_upgr_no_data: assert property (p_upgr_no_data)
    else $error("[bus_if] a BusUpgr moved data");

  property p_no_x_bus;
    @(posedge clk) disable iff (!rst_n)
      bus_valid |-> (!$isunknown(bus_cmd) && !$isunknown(bus_addr) && !$isunknown(bus_master));
  endproperty
  a_no_x_bus: assert property (p_no_x_bus)
    else $error("[bus_if] X on the bus address phase");

  // ---- THE safety property, written directly as an assertion --------
  // For the two-core configuration this is small enough to state in full:
  // an exclusive copy in one cache forbids any copy in the other.
  genvar gs;
  generate
    for (gs = 0; gs < NSET; gs = gs + 1) begin : g_swmr
      property p_swmr;
        @(posedge clk) disable iff (!rst_n)
          ( (dbg_state_f[gs*2 +: 2] == ST_M) || (dbg_state_f[gs*2 +: 2] == ST_E) ) &&
          ( dbg_tag_f[gs*AW +: AW] == dbg_tag_f[(NSET+gs)*AW +: AW] )
          |-> (dbg_state_f[(NSET+gs)*2 +: 2] == ST_I);
      endproperty
      a_swmr: assert property (p_swmr)
        else $error("[bus_if] SWMR violated in set %0d: core0 exclusive while core1 valid", gs);

      property p_swmr_rev;
        @(posedge clk) disable iff (!rst_n)
          ( (dbg_state_f[(NSET+gs)*2 +: 2] == ST_M) || (dbg_state_f[(NSET+gs)*2 +: 2] == ST_E) ) &&
          ( dbg_tag_f[gs*AW +: AW] == dbg_tag_f[(NSET+gs)*AW +: AW] )
          |-> (dbg_state_f[gs*2 +: 2] == ST_I);
      endproperty
      a_swmr_rev: assert property (p_swmr_rev)
        else $error("[bus_if] SWMR violated in set %0d: core1 exclusive while core0 valid", gs);
    end
  endgenerate

  // ---- cover the interesting protocol events ----
  c_busrd   : cover property (@(posedge clk) disable iff (!rst_n) bus_valid && (bus_cmd == BUSRD));
  c_busrdx  : cover property (@(posedge clk) disable iff (!rst_n) bus_valid && (bus_cmd == BUSRDX));
  c_busupgr : cover property (@(posedge clk) disable iff (!rst_n) bus_valid && (bus_cmd == BUSUPGR));
  c_buswb   : cover property (@(posedge clk) disable iff (!rst_n) bus_valid && (bus_cmd == BUSWB));
  c_excl    : cover property (@(posedge clk) disable iff (!rst_n) bus_fill && !bus_fill_shared);
  c_shared  : cover property (@(posedge clk) disable iff (!rst_n) bus_fill &&  bus_fill_shared);
  c_c2c     : cover property (@(posedge clk) disable iff (!rst_n) bus_fill &&  bus_c2c);
  c_b2b_txn : cover property (@(posedge clk) disable iff (!rst_n) bus_fill ##1 bus_valid);
`endif

endinterface
