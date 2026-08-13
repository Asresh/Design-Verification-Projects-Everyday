// -----------------------------------------------------------------------------
// arb_rr.sv  -  parameterized round-robin arbiter (design-under-test)
//
// A single shared resource is contested by NUM_REQ requesters.  Each cycle the
// arbiter grants the resource to at most one requester, chosen in round-robin
// order starting from a rotating priority pointer.  Fairness is the property
// under verification: no requester can be starved while it keeps asserting req.
//
//   * grant           - one-hot (or all-zero) grant vector, combinational
//   * grant_valid     - |grant  (a grant was issued this cycle)
//   * grant_idx       - index of the granted requester (valid when grant_valid)
//   * en              - grant-enable / downstream-ready backpressure; when low
//                       no grant is issued and the priority pointer HOLDS
//
// Round-robin rule: the winner is the first asserted requester at or after the
// priority pointer `ptr`, scanning circularly.  After a grant is *issued*
// (en & any req) the pointer advances to winner+1, so the just-served requester
// drops to lowest priority next cycle.  On a stall (en low) or an idle cycle
// (no req) the pointer is unchanged.
//
// Fully synchronous, single clock, active-low asynchronous reset, lint-friendly.
// Elaborates identically on Icarus, Verilator, VCS and Questa.
// -----------------------------------------------------------------------------
`ifndef ARB_RR_SV
`define ARB_RR_SV
`timescale 1ns/1ps

module arb_rr #(
    parameter int NUM_REQ = 4,
    parameter int PW      = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               en,        // grant enable / downstream ready
    input  logic [NUM_REQ-1:0] req,        // request vector
    output logic [NUM_REQ-1:0] grant,      // one-hot (or zero) grant
    output logic               grant_valid,// |grant
    output logic [PW-1:0]      grant_idx   // index of granted requester
);

    // ---- round-robin winner: first set bit of `r` at or after priority `p` ----
    function automatic logic [NUM_REQ-1:0] rr_pick(input logic [NUM_REQ-1:0] r,
                                                   input logic [PW-1:0]      p);
        logic [NUM_REQ-1:0] g;
        logic               found;
        int                 idx;
        g     = '0;
        found = 1'b0;
        for (int i = 0; i < NUM_REQ; i++) begin
            idx = (int'(p) + i) % NUM_REQ;   // circular scan from the pointer
            if (r[idx] && !found) begin
                g[idx] = 1'b1;
                found  = 1'b1;
            end
        end
        return g;
    endfunction

    // ---- index of the (one-hot) grant vector ----
    function automatic logic [PW-1:0] idx_of(input logic [NUM_REQ-1:0] g);
        logic [PW-1:0] k;
        k = '0;
        for (int i = 0; i < NUM_REQ; i++)
            if (g[i]) k = PW'(i);
        return k;
    endfunction

    logic [PW-1:0]      ptr;                 // rotating priority pointer
    logic [NUM_REQ-1:0] g_comb;
    logic [PW-1:0]      win;

    // Combinational grant: issue only when enabled and someone is requesting.
    assign g_comb      = (en && (|req)) ? rr_pick(req, ptr) : '0;
    assign grant       = g_comb;
    assign grant_valid = |g_comb;
    assign win         = idx_of(g_comb);
    assign grant_idx   = win;

    // Pointer advances to winner+1 only when a grant is actually issued.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ptr <= '0;
        else if (en && (|req))
            ptr <= (win == PW'(NUM_REQ-1)) ? '0 : win + PW'(1);
    end

    // -------------------------------------------------------------------------
    // Inline SVA (enabled by +define+ARB_RR_SVA on UVM-capable simulators).
    // -------------------------------------------------------------------------
`ifdef ARB_RR_SVA
    // grant is always one-hot-or-zero (never two grants at once)
    a_onehot0 : assert property (@(posedge clk) disable iff (!rst_n)
        $onehot0(grant));

    // a grant only ever goes to an actual requester
    a_grant_is_req : assert property (@(posedge clk) disable iff (!rst_n)
        (grant != '0) |-> ((grant & ~req) == '0));

    // no grant may be issued while the resource is disabled
    a_no_grant_when_disabled : assert property (@(posedge clk) disable iff (!rst_n)
        (!en) |-> (grant == '0));

    // grant_valid exactly mirrors "a grant happened"
    a_valid_matches : assert property (@(posedge clk) disable iff (!rst_n)
        grant_valid == (|grant));

    // if any request is pending and the resource is enabled, someone is granted
    a_progress : assert property (@(posedge clk) disable iff (!rst_n)
        (en && (|req)) |-> (grant != '0));
`endif

endmodule
`endif
