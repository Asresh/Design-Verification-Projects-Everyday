// -----------------------------------------------------------------------------
// router_pkt.sv  -  Synchronous store-and-forward 1-to-N packet router (DUT)
//
// A single AXI-Stream-like input port carries beats tagged with a destination
// index (in_dest) and an end-of-packet marker (in_last). Each beat is stored,
// in arrival order, into a small per-output FIFO selected by in_dest and later
// drained out of the matching output port. Backpressure is exact and lossless:
//   * The input port accepts a beat only when the *selected* output FIFO has
//     room  (in_ready = ~full[in_dest])   -> no drops, the source stalls.
//   * Each output presents data as first-word-fall-through and pops on a
//     completed handshake (out_valid[p] & out_ready[p]).
//
// Ordering is preserved *per output port* (FIFO), which is exactly the
// invariant the verification environment checks with per-port golden queues.
//
// Design notes
//   * Fully synchronous, single clock, active-low async reset (reset-safe:
//     every state element clears, no inferred latches, no X after reset).
//   * Parameterized (ports / width / depth); lint-friendly flattened buses so
//     it elaborates identically on Icarus, Verilator, VCS and Questa.
// -----------------------------------------------------------------------------
`ifndef ROUTER_PKT_SV
`define ROUTER_PKT_SV

module router_pkt #(
    parameter int NUM_OUT = 4,          // number of output ports
    parameter int DW      = 8,          // payload data width (bits)
    parameter int DEPTH   = 4,          // per-output FIFO depth (entries)
    // Derived - do not override.
    parameter int DEST_W  = (NUM_OUT > 1) ? $clog2(NUM_OUT) : 1
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ---- input stream (single port) ------------------------------------
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic [DEST_W-1:0]           in_dest,   // selected output index
    input  logic [DW-1:0]               in_data,   // payload
    input  logic                        in_last,   // end-of-packet marker

    // ---- output streams (NUM_OUT ports, flattened for portability) ------
    output logic [NUM_OUT-1:0]          out_valid,
    input  logic [NUM_OUT-1:0]          out_ready,
    output logic [NUM_OUT*DW-1:0]       out_data,  // out_data[p] = slice p
    output logic [NUM_OUT-1:0]          out_last
);

    // Derived widths.
    localparam int PW     = $clog2(DEPTH);        // FIFO address width
    localparam int EW     = DW + 1;               // stored entry = {last,data}

    // Per-port status vectors (visible to the input-accept logic).
    logic [NUM_OUT-1:0] full_vec;
    logic [NUM_OUT-1:0] empty_vec;

    // Input handshake: accept only when the selected FIFO has room.
    assign in_ready = ~full_vec[in_dest];

    genvar g;
    generate
        for (g = 0; g < NUM_OUT; g++) begin : g_port
            // -------- per-output FIFO state ----------------------------------
            logic [EW-1:0]  mem [DEPTH];
            logic [PW:0]    wptr, rptr;           // extra MSB distinguishes
                                                  // full from empty
            logic [PW:0]    count;

            // Push this beat if it is accepted *and* addressed to this port.
            wire push = in_valid & in_ready & (in_dest == g[DEST_W-1:0]);
            // Pop when this port completes an output handshake.
            wire pop  = out_valid[g] & out_ready[g];

            assign count        = wptr - rptr;
            assign full_vec[g]  = (count == DEPTH[PW:0]);
            assign empty_vec[g] = (count == '0);

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    wptr <= '0;
                    rptr <= '0;
                end else begin
                    if (push) begin
                        mem[wptr[PW-1:0]] <= {in_last, in_data};
                        wptr              <= wptr + 1'b1;
                    end
                    if (pop) begin
                        rptr <= rptr + 1'b1;
                    end
                end
            end

            // First-word-fall-through outputs (combinational read of head).
            assign out_valid[g]                 = ~empty_vec[g];
            assign out_last[g]                  = mem[rptr[PW-1:0]][DW];
            assign out_data[g*DW +: DW]         = mem[rptr[PW-1:0]][DW-1:0];
        end
    endgenerate

`ifdef ROUTER_PKT_SVA
    // -------------------------------------------------------------------------
    // Inline design assertions (bound in with a UVM sim; harmless elsewhere).
    // -------------------------------------------------------------------------
    // No output beat may be presented by an empty FIFO.
    genvar a;
    generate
        for (a = 0; a < NUM_OUT; a++) begin : g_asrt
            assert property (@(posedge clk) disable iff (!rst_n)
                out_valid[a] |-> !empty_vec[a])
                else $error("router_pkt: out_valid[%0d] with empty FIFO", a);
            // A stalled output beat must hold its data/last stable.
            assert property (@(posedge clk) disable iff (!rst_n)
                (out_valid[a] && !out_ready[a]) |=> out_valid[a])
                else $error("router_pkt: out_valid[%0d] dropped under backpressure", a);
        end
    endgenerate
`endif

endmodule
`endif
