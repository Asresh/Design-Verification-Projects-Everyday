// -----------------------------------------------------------------------------
// simt_stack.sv - GPU SIMT reconvergence (divergence) stack
//
// A GPU executes a "warp" of NLANES threads in lock-step (SIMT). When a data-
// dependent branch is taken by some lanes but not others, the warp *diverges*:
// the taken and not-taken lanes cannot run simultaneously, so the hardware runs
// one side, then the other, then RECONVERGES the whole warp at the branch's
// immediate post-dominator (the reconvergence PC). NVIDIA-class GPUs implement
// this with a hardware stack of {active-mask, PC} entries - the SIMT stack.
// The top-of-stack (TOS) entry names the lanes that execute next and the PC
// they execute from.
//
// This block is that stack. It accepts one control command per handshake and
// exposes the current TOS mask/PC and stack depth combinationally:
//
//   OP_INIT   : launch a warp - clear the stack and push {mask=in_mask, pc=fpc}
//   OP_DIVERGE: a branch at the TOS. Split the current active mask `cur` into
//                 t  = in_mask & cur      (lanes that take the branch)
//                 nt = cur & ~in_mask     (lanes that fall through)
//               * true divergence (t!=0 && nt!=0): the current entry becomes the
//                 RECONVERGENCE entry {mask=cur, pc=rpc}; push the fall-through
//                 path {nt, fpc}; push the taken path {t, tpc} as the new TOS.
//                 Depth grows by 2. Threads run taken -> fall-through -> (POP)
//                 -> the reunited warp resumes at rpc.
//               * uniform-taken     (nt==0): just retarget TOS pc = tpc.
//               * uniform-fallthru  (t==0) : just retarget TOS pc = fpc.
//   OP_POP    : a path reached its reconvergence point - pop the TOS, exposing
//               the next entry (the other divergent path, then the reunited
//               warp). Popping the last entry empties the stack (warp retired).
//
// The design is parameterized, reset-safe (all state cleared on rst_n), and
// lint-friendly. `full` blocks a diverge that would overflow the stack; `empty`
// marks a retired warp. Outputs are pure functions of registered state.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module simt_stack #(
    parameter int NLANES = 8,      // warp width (threads per warp)
    parameter int PC_W   = 16,     // program-counter width
    parameter int DEPTH  = 32      // max stack entries (nesting depth)
) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- control-command stream ----
    input  logic               cmd_valid,
    output logic               cmd_ready,
    input  logic [1:0]         op,        // OP_INIT / OP_DIVERGE / OP_POP
    input  logic [NLANES-1:0]  in_mask,   // INIT: warp mask;  DIVERGE: taken set
    input  logic [PC_W-1:0]    rpc,       // DIVERGE: reconvergence PC
    input  logic [PC_W-1:0]    tpc,       // DIVERGE: taken-path PC
    input  logic [PC_W-1:0]    fpc,       // DIVERGE: fall-through PC / INIT: entry PC

    // ---- top-of-stack view (combinational from state) ----
    output logic [NLANES-1:0]     tos_mask,  // lanes that execute next
    output logic [PC_W-1:0]       tos_pc,    // PC they execute from
    output logic [$clog2(DEPTH):0] sp,       // current stack depth (# valid entries)
    output logic                  empty,     // sp == 0  (warp retired)
    output logic                  full       // sp == DEPTH (cannot diverge further)
);

    // +1 so DEPTH itself is representable (matches the `sp` port width above).
    localparam int SP_W = $clog2(DEPTH) + 1;

    localparam logic [1:0] OP_INIT    = 2'd0;
    localparam logic [1:0] OP_DIVERGE = 2'd1;
    localparam logic [1:0] OP_POP     = 2'd2;

    // ---- storage: parallel mask / pc arrays, sp counts valid entries ----
    logic [NLANES-1:0] mask_st [DEPTH];
    logic [PC_W-1:0]   pc_st   [DEPTH];
    logic [SP_W-1:0]   sp_q;

    // Split of the current active mask for a DIVERGE command.
    logic [NLANES-1:0] cur, take_set, fall_set;
    always_comb begin
        cur      = (sp_q == 0) ? '0 : mask_st[sp_q-1];
        take_set = in_mask & cur;
        fall_set = cur & ~in_mask;
    end

    // Would this diverge push two new entries and overflow?
    logic diverge_grows;
    assign diverge_grows = (op == OP_DIVERGE) && (take_set != '0) && (fall_set != '0);

    // Accept a command unless it is a growing diverge that would overflow.
    assign cmd_ready = rst_n && !(diverge_grows && ((sp_q + 2) > DEPTH));

    // ---- combinational TOS view ----
    assign empty    = (sp_q == 0);
    assign full     = (sp_q == DEPTH);
    assign sp       = sp_q;
    assign tos_mask = empty ? '0 : mask_st[sp_q-1];
    assign tos_pc   = empty ? '0 : pc_st[sp_q-1];

    // ------------------------------------------------------------------------
    // Sequential update
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_q <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                mask_st[i] <= '0;
                pc_st[i]   <= '0;
            end
        end else if (cmd_valid && cmd_ready) begin
            unique case (op)
                OP_INIT: begin
                    mask_st[0] <= in_mask;
                    pc_st[0]   <= fpc;
                    sp_q       <= (in_mask == '0) ? '0 : 'd1;   // empty warp stays retired
                end

                OP_DIVERGE: begin
                    if (sp_q != 0) begin
                        if ((take_set != '0) && (fall_set != '0)) begin
                            // current entry -> reconvergence entry
                            mask_st[sp_q-1] <= cur;
                            pc_st[sp_q-1]   <= rpc;
                            // fall-through path
                            mask_st[sp_q]   <= fall_set;
                            pc_st[sp_q]     <= fpc;
                            // taken path (new TOS)
                            mask_st[sp_q+1] <= take_set;
                            pc_st[sp_q+1]   <= tpc;
                            sp_q            <= sp_q + 2;
                        end else if (take_set != '0) begin
                            // whole warp takes the branch - retarget in place
                            pc_st[sp_q-1] <= tpc;
                        end else begin
                            // whole warp falls through - retarget in place
                            pc_st[sp_q-1] <= fpc;
                        end
                    end
                end

                OP_POP: begin
                    if (sp_q != 0) sp_q <= sp_q - 1;
                end

                default: /* no-op */ ;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+SIMT_SVA)
    // ------------------------------------------------------------------------
`ifdef SIMT_SVA
    // Depth never exceeds the physical stack.
    a_sp_bound: assert property (@(posedge clk) disable iff (!rst_n)
        sp_q <= DEPTH[SP_W-1:0]);

    // A non-empty TOS always has at least one active lane.
    a_tos_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
        (!empty) |-> (tos_mask != '0));

    // empty is exactly sp==0.
    a_empty_iff: assert property (@(posedge clk) disable iff (!rst_n)
        empty == (sp_q == 0));

    // A true divergence grows the stack by exactly two entries.
    a_diverge_grows: assert property (@(posedge clk) disable iff (!rst_n)
        (cmd_valid && cmd_ready && (op == OP_DIVERGE) &&
         (take_set != '0) && (fall_set != '0)) |=> (sp_q == ($past(sp_q) + 2)));

    // A non-empty POP shrinks the stack by exactly one.
    a_pop_shrinks: assert property (@(posedge clk) disable iff (!rst_n)
        (cmd_valid && cmd_ready && (op == OP_POP) && (sp_q != 0)) |=>
            (sp_q == ($past(sp_q) - 1)));

    // Outputs are known whenever the warp is live.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        (!empty) |-> (!$isunknown({tos_mask, tos_pc, sp})));
`endif

endmodule

`default_nettype wire
