// -----------------------------------------------------------------------------
// smem_bank_arb.sv - GPU shared-memory bank-conflict serializer
//
// A GPU streaming multiprocessor executes a warp of NLANES threads in lock-step
// (SIMT). Their on-chip SHARED MEMORY is split into NBANKS equal-width banks
// (word address -> bank = addr % NBANKS). Each bank can service exactly ONE
// word address per cycle, so a single warp-wide shared-memory access completes
// in as many cycles ("phases") as the worst-case number of DISTINCT addresses
// mapped to any one bank:
//
//   * different banks              -> served IN PARALLEL, same phase
//   * same bank, SAME address      -> BROADCAST: all those lanes served together
//                                     in one access (NVIDIA's broadcast/multicast
//                                     optimization - no conflict)
//   * same bank, DIFFERENT address -> BANK CONFLICT: the accesses SERIALIZE,
//                                     one distinct address per phase
//
// The number of phases is the "conflict degree": 1 = conflict-free, up to
// NLANES = a fully serialized NLANES-way conflict. This is the block that turns
// a warp request into that serialized phase stream.
//
// Contract (one request at a time):
//   IDLE : req_ready=1. On req_valid&req_ready the warp request {req_mask,
//          req_addr[]} is latched.
//   RUN  : one phase is emitted per cycle (ph_valid=1). Each phase asserts
//          ph_served (the lanes satisfied this cycle), ph_bank_use (the banks
//          that did an access), and ph_index (0-based phase number). The final
//          phase asserts ph_last, after which the block returns to IDLE.
//   An all-inactive request (req_mask==0) emits exactly one empty phase
//          (ph_served=0, ph_bank_use=0, ph_last=1) so that EVERY accepted
//          request produces at least one ph_last - a uniform, easy-to-check
//          streaming contract.
//
// Per phase, per bank, the winner is the LOWEST-INDEX still-pending lane in that
// bank; every pending lane in that bank sharing the winner's address is served
// (broadcast). This drains one distinct address per bank per phase in first-seen
// lane order. The design is parameterized, reset-safe, and lint-friendly; all
// outputs are registered. NBANKS is expected to be a power of two.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module smem_bank_arb #(
    parameter int NLANES = 8,       // warp width (threads per warp)
    parameter int NBANKS = 8,       // shared-memory banks (power of two)
    parameter int ADDR_W = 16       // per-lane word-address width
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- warp shared-memory request ----
    input  logic                       req_valid,
    output logic                       req_ready,
    input  logic [NLANES-1:0]          req_mask,   // active lanes
    input  logic [NLANES*ADDR_W-1:0]   req_addr,   // packed per-lane word address

    // ---- serialized phase output stream ----
    output logic                       ph_valid,    // a phase beat is present
    output logic [NLANES-1:0]          ph_served,   // lanes satisfied this phase
    output logic [NBANKS-1:0]          ph_bank_use, // banks that did an access
    output logic                       ph_last,     // final phase of the request
    output logic [$clog2(NLANES+1)-1:0] ph_index,   // 0-based phase number

    output logic                       busy         // request in flight
);

    localparam int PH_W   = $clog2(NLANES + 1);   // 0..NLANES phases representable

    // ---- latched request state ----
    logic [ADDR_W-1:0] addr_q [NLANES];
    logic [NLANES-1:0] pend_q;      // lanes still awaiting service
    logic              run_q;       // a request is being drained
    logic [PH_W-1:0]   idx_q;       // next phase index

    // ------------------------------------------------------------------------
    // Combinational phase engine: from the currently-pending lanes, pick one
    // distinct address per bank (lowest-index pending lane wins) and serve every
    // pending lane in that bank that shares the winning address (broadcast).
    // ------------------------------------------------------------------------
    logic [NBANKS-1:0] bank_hit_c;              // bank has a winner this phase
    logic [ADDR_W-1:0] bank_waddr_c [NBANKS];   // winning address per bank
    logic [NLANES-1:0] serve_c;                 // lanes served this phase
    logic [NLANES-1:0] next_pend_c;             // pending after this phase
    logic              last_c;                  // this phase drains the request

    always_comb begin
        int bnk;
        bank_hit_c = '0;
        for (int b = 0; b < NBANKS; b++) bank_waddr_c[b] = '0;

        // winner = lowest-index pending lane in each bank (first-seen address)
        for (int l = 0; l < NLANES; l++) begin
            if (pend_q[l]) begin
                bnk = addr_q[l] % NBANKS;
                if (!bank_hit_c[bnk]) begin
                    bank_hit_c[bnk]   = 1'b1;
                    bank_waddr_c[bnk] = addr_q[l];
                end
            end
        end

        // serve every pending lane matching its bank's winning address (broadcast)
        serve_c = '0;
        for (int l = 0; l < NLANES; l++) begin
            bnk = addr_q[l] % NBANKS;
            if (pend_q[l] && bank_hit_c[bnk] && (addr_q[l] == bank_waddr_c[bnk]))
                serve_c[l] = 1'b1;
        end

        next_pend_c = pend_q & ~serve_c;
        last_c      = (next_pend_c == '0);
    end

    // ---- status ----
    assign busy      = run_q;
    assign req_ready = rst_n && !run_q;

    // ------------------------------------------------------------------------
    // Sequential control + registered outputs
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend_q      <= '0;
            run_q       <= 1'b0;
            idx_q       <= '0;
            ph_valid    <= 1'b0;
            ph_served   <= '0;
            ph_bank_use <= '0;
            ph_last     <= 1'b0;
            ph_index    <= '0;
            for (int l = 0; l < NLANES; l++) addr_q[l] <= '0;
        end else begin
            ph_valid <= 1'b0;    // default: no beat this cycle

            if (!run_q) begin
                // ---- IDLE: accept a new warp request ----
                if (req_valid && req_ready) begin
                    for (int l = 0; l < NLANES; l++)
                        addr_q[l] <= req_addr[l*ADDR_W +: ADDR_W];
                    pend_q <= req_mask;
                    run_q  <= 1'b1;
                    idx_q  <= '0;
                end
            end else begin
                // ---- RUN: emit one phase per cycle ----
                ph_valid    <= 1'b1;
                ph_served   <= serve_c;
                ph_bank_use <= bank_hit_c;
                ph_last     <= last_c;
                ph_index    <= idx_q;

                pend_q <= next_pend_c;
                idx_q  <= idx_q + PH_W'(1);
                if (last_c) run_q <= 1'b0;   // request drained -> back to IDLE
            end
        end
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+SMEM_SVA)
    // ------------------------------------------------------------------------
`ifdef SMEM_SVA
    // req_ready is exactly "not busy" once out of reset.
    a_ready_iff_idle: assert property (@(posedge clk) disable iff (!rst_n)
        req_ready == !busy);

    // ph_last only ever asserts alongside a valid phase beat.
    a_last_needs_valid: assert property (@(posedge clk) disable iff (!rst_n)
        ph_last |-> ph_valid);

    // A phase beat only appears while a request is in flight.
    a_valid_needs_busy: assert property (@(posedge clk) disable iff (!rst_n)
        ph_valid |-> busy);

    // Progress: if any bank did an access this phase, at least one lane is served.
    a_progress: assert property (@(posedge clk) disable iff (!rst_n)
        (ph_valid && (ph_bank_use != '0)) |-> (ph_served != '0));

    // The phase stream is contiguous: a non-last beat is followed by another beat.
    a_stream_contiguous: assert property (@(posedge clk) disable iff (!rst_n)
        (ph_valid && !ph_last) |=> ph_valid);

    // ...and the phase index increments by one across that contiguous stream.
    a_index_step: assert property (@(posedge clk) disable iff (!rst_n)
        (ph_valid && !ph_last) |=> (ph_index == ($past(ph_index) + PH_W'(1))));

    // Outputs are always known while a beat is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        ph_valid |-> !$isunknown({ph_served, ph_bank_use, ph_last, ph_index}));
`endif

endmodule

`default_nettype wire
