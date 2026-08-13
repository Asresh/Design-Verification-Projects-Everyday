// ============================================================================
// cache_ctrl_if.sv - the pin-level interface for the cache-controller
// environment, plus the clocking blocks that keep every UVM component a
// defined distance from the clock edge.
// ----------------------------------------------------------------------------
// Three separate views, because three different things look at these wires:
//
//   cpu_cb   the CPU-side driver: it drives the request channel and samples
//            the response channel.
//   mem_cb   the memory-side responder: it drives ready and read data, and
//            samples the request the cache makes.  Note that this is a
//            RESPONDER, not a driver in the usual sense - it models the slave.
//   mon_cb   both monitors: inputs only, so a monitor can never accidentally
//            become a driver.  This is worth the duplication.
//
// rst_n is deliberately NOT in a clocking block.  It is asynchronous, and one
// of the properties under test is what a reset does to a cache full of dirty
// lines - which means the driver has to be able to assert it between edges.
// ============================================================================
`timescale 1ns/1ps

interface cache_ctrl_if (input logic clk);

    localparam int ADDR_W = 32;
    localparam int DATA_W = 32;
    localparam int BYTES  = DATA_W/8;

    // asynchronous reset, driven by the CPU-side driver
    logic              rst_n;

    // ---- CPU request / response -------------------------------------------
    logic              cpu_req_valid;
    logic              cpu_req_ready;
    logic [ADDR_W-1:0] cpu_req_addr;
    logic              cpu_req_we;
    logic [DATA_W-1:0] cpu_req_wdata;
    logic [BYTES-1:0]  cpu_req_wstrb;

    logic              cpu_rsp_valid;
    logic [DATA_W-1:0] cpu_rsp_rdata;
    logic              cpu_rsp_hit;

    // ---- maintenance -------------------------------------------------------
    logic              flush_req;
    logic              flush_busy;
    logic              flush_done;

    // ---- backing memory ----------------------------------------------------
    logic              mem_req_valid;
    logic              mem_req_ready;
    logic              mem_req_we;
    logic [ADDR_W-1:0] mem_req_addr;
    logic [DATA_W-1:0] mem_req_wdata;
    logic              mem_rsp_valid;
    logic [DATA_W-1:0] mem_rsp_rdata;

    // ---- observability -----------------------------------------------------
    logic [3:0]        state;
    logic              stat_hit;
    logic              stat_miss;
    logic              stat_wb;

    // ========================================================================
    // CPU-side driver view
    // ========================================================================
    clocking cpu_cb @(posedge clk);
        default input #1step output #1ns;
        output cpu_req_valid, cpu_req_addr, cpu_req_we, cpu_req_wdata,
               cpu_req_wstrb, flush_req;
        input  cpu_req_ready, cpu_rsp_valid, cpu_rsp_rdata, cpu_rsp_hit,
               flush_busy, flush_done;
    endclocking

    // ========================================================================
    // Memory-side responder view
    // ========================================================================
    clocking mem_cb @(posedge clk);
        default input #1step output #1ns;
        output mem_req_ready, mem_rsp_valid, mem_rsp_rdata;
        input  mem_req_valid, mem_req_we, mem_req_addr, mem_req_wdata;
    endclocking

    // ========================================================================
    // Monitor view - inputs only, on purpose
    // ========================================================================
    clocking mon_cb @(posedge clk);
        default input #1step;
        input cpu_req_valid, cpu_req_ready, cpu_req_addr, cpu_req_we,
              cpu_req_wdata, cpu_req_wstrb,
              cpu_rsp_valid, cpu_rsp_rdata, cpu_rsp_hit,
              flush_req, flush_busy, flush_done,
              mem_req_valid, mem_req_ready, mem_req_we, mem_req_addr,
              mem_req_wdata, mem_rsp_valid, mem_rsp_rdata,
              state, stat_hit, stat_miss, stat_wb;
    endclocking

    modport cpu_drv (clocking cpu_cb, output rst_n, input clk);
    modport mem_drv (clocking mem_cb, input clk, input rst_n);
    modport mon     (clocking mon_cb, input clk, input rst_n);

`ifdef CACHE_SVA
    // ------------------------------------------------------------------
    // Interface-level protocol assertions.  These belong here rather than in
    // the DUT because they constrain BOTH sides of the wire: the testbench is
    // just as capable of breaking the handshake as the design is, and a
    // testbench bug that looks like a DUT bug costs more to debug than either.
    // ------------------------------------------------------------------

    // The CPU request payload must not move while the request is waiting to
    // be accepted.
    p_cpu_req_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (cpu_req_valid && !cpu_req_ready) |=>
            (cpu_req_valid && $stable(cpu_req_addr) && $stable(cpu_req_we)
             && $stable(cpu_req_wdata) && $stable(cpu_req_wstrb)));

    // A small tracker, so "one access in flight" and "no unsolicited
    // response" can both be stated as plain arithmetic instead of as a
    // sequence with an unbounded window.
    int unsigned outstanding_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) outstanding_q <= 0;
        else        outstanding_q <= outstanding_q
                                     + int'(cpu_req_valid && cpu_req_ready)
                                     - int'(cpu_rsp_valid);
    end

    // Only one access may be in flight.
    p_one_outstanding: assert property (@(posedge clk) disable iff (!rst_n)
        (cpu_req_valid && cpu_req_ready) |-> (outstanding_q == 0));

    // A response must answer a request that is actually outstanding.
    p_rsp_needs_req: assert property (@(posedge clk) disable iff (!rst_n)
        cpu_rsp_valid |-> (outstanding_q != 0));

    // Read data returned by the memory model must be known.
    p_mem_rdata_known: assert property (@(posedge clk) disable iff (!rst_n)
        mem_rsp_valid |-> !$isunknown(mem_rsp_rdata));

    // The address the cache puts on the memory port is always word aligned.
    p_mem_addr_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        mem_req_valid |-> (mem_req_addr[1:0] == 2'b00));

    // flush_busy must fall only after flush_done, never on its own.
    p_flush_busy_ends: assert property (@(posedge clk) disable iff (!rst_n)
        $fell(flush_busy) |-> $past(flush_done) || flush_done);
`endif

endinterface : cache_ctrl_if
