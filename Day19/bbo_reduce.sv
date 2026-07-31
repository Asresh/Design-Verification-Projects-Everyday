// -----------------------------------------------------------------------------
// bbo_reduce.sv - streaming Best-Bid / Best-Offer (BBO) top-of-book reduction
//                 tree: fixed-latency argmax + argmin over an N-level price
//                 ladder, with a deterministic lowest-index tie-break.
//
// TOP-OF-BOOK / BBO tracking is the single most latency-critical block in a
// hardware (FPGA) matching engine or a market-data handler for high-frequency
// trading: given the N resting price levels of an order book, every cycle you
// must know the BEST BID (highest price + which level) and the BEST OFFER /
// ASK (lowest price + which level). A software `for`-loop over N levels cannot
// keep up at line rate; the hardware answer is a balanced REDUCTION TREE that
// collapses N candidates to 1 in log2(N) compare layers, each layer registered,
// so the block has a FIXED latency LAT = log2(N)+2 and accepts a brand-new price
// vector EVERY cycle (zero-bubble, one book snapshot per clock).
//
// The same primitive is the generic hardware ARGMAX / ARGMIN reduction (max /
// min plus the index that produced it) behind priority selection, winner-take-
// all, nearest-neighbour, and top-1 selection datapaths on an FPGA/ASIC.
//
// Per level a per-lane VALID mask says which book levels are populated; an empty
// level never wins. If NO level is valid the book is empty and the outputs take
// their identities (max_val = 0, min_val = all-ones, indices = 0, any = 0).
//
// TIE-BREAK: on equal prices the LOWEST LANE INDEX wins (both for max and for
// min). The tree guarantees this because at every compare node the left child
// always carries strictly lower original indices than the right child, so a
// "keep left on a tie" rule at each node is globally lowest-index-wins.
//
// Interface (streaming, one price vector per cycle, zero-bubble):
//   in_valid   : a new N-level price vector is present this cycle
//   in_price   : N levels packed low-level-first, each DW-bit UNSIGNED price
//   in_mask    : N-bit populated-level mask (bit i = level i is a real order)
//   out_valid  : LAT cycles later, the BBO result for that vector is presented
//   out_any    : 1 = at least one level was valid (book non-empty)
//   out_max_val, out_max_idx : best bid  (highest price + its level index)
//   out_min_val, out_min_idx : best offer (lowest price + its level index)
//
// The design is parameterized (N a power of two), reset-safe, fully registered
// (every compare layer is a pipeline stage), and lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module bbo_reduce #(
    parameter int N  = 8,        // number of book price levels (power of two)
    parameter int DW = 16,       // price width in bits (unsigned)
    // derived (do not override): level-index width
    parameter int IW = (N > 1) ? $clog2(N) : 1
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              in_valid,
    input  logic [N*DW-1:0]   in_price,      // N unsigned prices, low level first
    input  logic [N-1:0]      in_mask,       // populated-level mask

    output logic              out_valid,
    output logic              out_any,        // book non-empty
    output logic [DW-1:0]     out_max_val,    // best bid  price
    output logic [IW-1:0]     out_max_idx,    // best bid  level index
    output logic [DW-1:0]     out_min_val,    // best offer price
    output logic [IW-1:0]     out_min_idx     // best offer level index
);

    localparam int L   = $clog2(N);          // number of reduction layers
    localparam int LAT = L + 2;              // leaf-reg + L layers + output-reg

    // -------------------------------------------------------------------------
    // Pipeline node arrays. Level 0 holds the N leaves (one per book level);
    // level l holds N>>l nodes; level L holds the single root. Each node carries
    // a validity flag plus the running max/min value and the ORIGINAL lane index
    // that produced each. vpipe carries the in_valid strobe in lock-step so
    // out_valid stays aligned to the fixed latency.
    //
    // Parallel arrays (rather than a struct) keep the design portable across the
    // widest set of simulators, matching the rest of this repo.
    // -------------------------------------------------------------------------
    logic            nd_vld [0:L][0:N-1];
    logic [DW-1:0]   nd_mxv [0:L][0:N-1];
    logic [IW-1:0]   nd_mxi [0:L][0:N-1];
    logic [DW-1:0]   nd_mnv [0:L][0:N-1];
    logic [IW-1:0]   nd_mni [0:L][0:N-1];
    logic            vpipe  [0:L];

    // ---- stage 0 : register the input vector as the leaf nodes ----
    integer i0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe[0] <= 1'b0;
            for (i0 = 0; i0 < N; i0 = i0 + 1) begin
                nd_vld[0][i0] <= 1'b0;
                nd_mxv[0][i0] <= '0;
                nd_mxi[0][i0] <= '0;
                nd_mnv[0][i0] <= '0;
                nd_mni[0][i0] <= '0;
            end
        end else begin
            vpipe[0] <= in_valid;
            for (i0 = 0; i0 < N; i0 = i0 + 1) begin
                nd_vld[0][i0] <= in_mask[i0];
                nd_mxv[0][i0] <= in_price[i0*DW +: DW];
                nd_mxi[0][i0] <= IW'(i0);
                nd_mnv[0][i0] <= in_price[i0*DW +: DW];
                nd_mni[0][i0] <= IW'(i0);
            end
        end
    end

    // ---- stages 1..L : one balanced reduction layer each ----
    // Node j at level gl combines children 2j (left, lower indices) and 2j+1
    // (right, higher indices) from level gl-1:
    //   valid = left.valid | right.valid
    //   max   : an invalid child never wins; on a tie the LEFT (lower-index)
    //           child is kept, so ties resolve to the lowest lane index.
    //   min   : symmetric (keep left on a tie).
    genvar gl, gj;
    generate
        for (gl = 1; gl <= L; gl = gl + 1) begin : g_layer
            localparam int NOUT = N >> gl;   // nodes produced by this layer
            // valid strobe shift for this layer
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) vpipe[gl] <= 1'b0;
                else        vpipe[gl] <= vpipe[gl-1];
            end
            for (gj = 0; gj < NOUT; gj = gj + 1) begin : g_node
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        nd_vld[gl][gj] <= 1'b0;
                        nd_mxv[gl][gj] <= '0;
                        nd_mxi[gl][gj] <= '0;
                        nd_mnv[gl][gj] <= '0;
                        nd_mni[gl][gj] <= '0;
                    end else begin
                        // children in the previous level
                        // left  = 2*gj , right = 2*gj+1
                        nd_vld[gl][gj] <= nd_vld[gl-1][2*gj] | nd_vld[gl-1][2*gj+1];

                        // ---- max (best bid) ----
                        if (!nd_vld[gl-1][2*gj]) begin
                            nd_mxv[gl][gj] <= nd_mxv[gl-1][2*gj+1];
                            nd_mxi[gl][gj] <= nd_mxi[gl-1][2*gj+1];
                        end else if (!nd_vld[gl-1][2*gj+1]) begin
                            nd_mxv[gl][gj] <= nd_mxv[gl-1][2*gj];
                            nd_mxi[gl][gj] <= nd_mxi[gl-1][2*gj];
                        end else if (nd_mxv[gl-1][2*gj+1] > nd_mxv[gl-1][2*gj]) begin
                            nd_mxv[gl][gj] <= nd_mxv[gl-1][2*gj+1];   // strictly greater -> right
                            nd_mxi[gl][gj] <= nd_mxi[gl-1][2*gj+1];
                        end else begin
                            nd_mxv[gl][gj] <= nd_mxv[gl-1][2*gj];     // tie or greater -> left
                            nd_mxi[gl][gj] <= nd_mxi[gl-1][2*gj];
                        end

                        // ---- min (best offer) ----
                        if (!nd_vld[gl-1][2*gj]) begin
                            nd_mnv[gl][gj] <= nd_mnv[gl-1][2*gj+1];
                            nd_mni[gl][gj] <= nd_mni[gl-1][2*gj+1];
                        end else if (!nd_vld[gl-1][2*gj+1]) begin
                            nd_mnv[gl][gj] <= nd_mnv[gl-1][2*gj];
                            nd_mni[gl][gj] <= nd_mni[gl-1][2*gj];
                        end else if (nd_mnv[gl-1][2*gj+1] < nd_mnv[gl-1][2*gj]) begin
                            nd_mnv[gl][gj] <= nd_mnv[gl-1][2*gj+1];   // strictly smaller -> right
                            nd_mni[gl][gj] <= nd_mni[gl-1][2*gj+1];
                        end else begin
                            nd_mnv[gl][gj] <= nd_mnv[gl-1][2*gj];     // tie or smaller -> left
                            nd_mni[gl][gj] <= nd_mni[gl-1][2*gj];
                        end
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output register from the root node. When the book is empty (root not
    // valid) the outputs take their identities so downstream logic reads a
    // well-defined "no top of book" (max=0, min=all-ones, indices=0).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid   <= 1'b0;
            out_any     <= 1'b0;
            out_max_val <= '0;
            out_max_idx <= '0;
            out_min_val <= {DW{1'b1}};
            out_min_idx <= '0;
        end else begin
            out_valid <= vpipe[L];
            out_any   <= nd_vld[L][0];
            if (nd_vld[L][0]) begin
                out_max_val <= nd_mxv[L][0];
                out_max_idx <= nd_mxi[L][0];
                out_min_val <= nd_mnv[L][0];
                out_min_idx <= nd_mni[L][0];
            end else begin
                out_max_val <= '0;
                out_max_idx <= '0;
                out_min_val <= {DW{1'b1}};
                out_min_idx <= '0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+BBO_SVA)
    // ------------------------------------------------------------------------
`ifdef BBO_SVA
    // Fixed pipeline latency: a valid input produces a valid output exactly LAT
    // cycles later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // When the book is non-empty the best bid is never below the best offer.
    a_max_ge_min: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_any) |-> (out_max_val >= out_min_val));

    // Reported indices are always in range.
    a_idx_range: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_any) |->
            ((out_max_idx < N) && (out_min_idx < N)));

    // Outputs are always known while a BBO result is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_any, out_max_val, out_max_idx,
                                   out_min_val, out_min_idx}));
`endif

endmodule

`default_nettype wire
