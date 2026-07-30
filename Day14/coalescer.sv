// -----------------------------------------------------------------------------
// coalescer.sv - GPU memory-coalescing unit (warp load/store address coalescer)
//
// On a GPU, a single SIMT instruction issues one memory access per active lane
// (a "warp" of NLANES threads). The memory subsystem does not issue NLANES
// independent requests; instead a *coalescing unit* groups the per-lane byte
// addresses that fall in the same cache line into a single line transaction.
// The number of line transactions a warp generates is the classic
// memory-efficiency metric: NLANES accesses that all hit one line coalesce to a
// single transaction (best case), while NLANES accesses to NLANES distinct
// lines produce NLANES transactions (worst case / fully uncoalesced).
//
// This block accepts one warp request at a time:
//     lane_addr[i] : byte address for lane i   (NLANES lanes, flattened bus)
//     lane_en[i]   : active mask for lane i     (predicated-off lanes ignored)
// and streams out, one per cycle, the set of UNIQUE cache lines touched by the
// active lanes together with a per-line lane mask. Lines are emitted in
// first-seen lane-index order; each transaction carries the lanes it serves and
// txn_last marks the final line of the warp.
//
//   line id of lane i = lane_addr[i][ADDR_W-1:OFF_W]   (LINE_BYTES = 2**OFF_W)
//
// Handshakes:
//   request stream : req_valid / req_ready  (one warp of addresses)
//   line stream    : txn_valid / txn_ready  (one cache-line transaction / beat)
//
// The design is parameterized, reset-safe (synchronous outputs gated by state),
// lint-friendly, and supports full back-pressure on the line stream. An
// all-disabled warp (lane_en == 0) is consumed and produces zero transactions.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module coalescer #(
    parameter int NLANES = 8,     // warp width (lanes per request)
    parameter int ADDR_W = 32,    // byte-address width
    parameter int OFF_W  = 7      // cache-line offset bits (LINE_BYTES = 128)
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---- warp request (per-lane byte addresses + active mask) ----
    input  logic                     req_valid,
    output logic                     req_ready,
    input  logic [NLANES*ADDR_W-1:0] lane_addr,
    input  logic [NLANES-1:0]        lane_en,

    // ---- coalesced cache-line transaction stream ----
    output logic                     txn_valid,
    input  logic                     txn_ready,
    output logic [ADDR_W-OFF_W-1:0]  txn_line,   // cache-line id (addr >> OFF_W)
    output logic [NLANES-1:0]        txn_mask,   // lanes served by this line
    output logic                     txn_last    // final line of this warp
);

    localparam int LINE_W = ADDR_W - OFF_W;

    typedef enum logic {S_IDLE, S_EMIT} state_e;
    state_e state;

    // Latched warp: per-lane address, active mask, and which lanes are done.
    logic [ADDR_W-1:0] addr_q [NLANES];
    logic [NLANES-1:0] en_q;
    logic [NLANES-1:0] served_q;

    // Lanes still awaiting a transaction.
    logic [NLANES-1:0] pending;
    assign pending = en_q & ~served_q;

    // ------------------------------------------------------------------------
    // Combinationally pick the next cache line to emit: the line of the lowest
    // still-pending lane, and the mask of every pending lane that shares it.
    // ------------------------------------------------------------------------
    logic [LINE_W-1:0] sel_line;
    logic [NLANES-1:0] cur_mask;
    logic              found;

    always_comb begin
        sel_line = '0;
        cur_mask = '0;
        found    = 1'b0;
        // first-seen leader (lowest pending lane) sets the target line
        for (int i = 0; i < NLANES; i++) begin
            if (pending[i] && !found) begin
                found    = 1'b1;
                sel_line = addr_q[i][ADDR_W-1:OFF_W];
            end
        end
        // gather every pending lane that hits the same line
        for (int k = 0; k < NLANES; k++) begin
            if (pending[k] && (addr_q[k][ADDR_W-1:OFF_W] == sel_line))
                cur_mask[k] = 1'b1;
        end
    end

    logic [NLANES-1:0] remaining_after;
    assign remaining_after = pending & ~cur_mask;

    // ---- stream outputs ----
    assign req_ready = (state == S_IDLE);
    assign txn_valid = (state == S_EMIT);
    assign txn_line  = sel_line;
    assign txn_mask  = cur_mask;
    assign txn_last  = (remaining_after == '0);

    // ------------------------------------------------------------------------
    // Control / datapath registers
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            en_q     <= '0;
            served_q <= '0;
            for (int i = 0; i < NLANES; i++) addr_q[i] <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    served_q <= '0;
                    if (req_valid) begin
                        en_q <= lane_en;
                        for (int i = 0; i < NLANES; i++)
                            addr_q[i] <= lane_addr[i*ADDR_W +: ADDR_W];
                        // an all-disabled warp is consumed with no transactions
                        if (|lane_en) state <= S_EMIT;
                        else          state <= S_IDLE;
                    end
                end
                S_EMIT: begin
                    if (txn_valid && txn_ready) begin
                        served_q <= served_q | cur_mask;
                        if (txn_last) state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+COAL_SVA)
    // ------------------------------------------------------------------------
`ifdef COAL_SVA
    // A live transaction must always serve at least one lane.
    a_mask_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
        txn_valid |-> (txn_mask != '0));

    // VALID must be held with stable payload until READY (streaming contract).
    a_valid_held: assert property (@(posedge clk) disable iff (!rst_n)
        (txn_valid && !txn_ready) |=>
            (txn_valid && $stable(txn_line) && $stable(txn_mask) && $stable(txn_last)));

    // No lane is ever served by two transactions of the same warp.
    a_disjoint: assert property (@(posedge clk) disable iff (!rst_n)
        (txn_valid && txn_ready) |-> ((cur_mask & served_q) == '0));

    // Outputs are known (no X/Z) whenever a transaction is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        txn_valid |-> (!$isunknown({txn_line, txn_mask, txn_last})));

    // txn_last is asserted exactly when this beat drains the last pending lanes.
    a_last_drains: assert property (@(posedge clk) disable iff (!rst_n)
        (txn_valid && txn_last) |-> (remaining_after == '0));
`endif

endmodule

`default_nettype wire
