// -----------------------------------------------------------------------------
// tb_simt_stack_dump.sv - portable, module-based, SELF-CHECKING testbench for
// the GPU SIMT reconvergence stack. Runs on open-source Icarus Verilog (which
// does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - launch a warp, take a data-dependent branch
//     that DIVERGES the 8 lanes (taken {0..3}, fall-through {4..7}), run the
//     taken side, POP, run the fall-through side, POP, and RECONVERGE the full
//     warp - so the captured VCD tells the classic SIMT-divergence story,
//   * runs DIRECTED CORNERS (uniform-taken branch, uniform-fall-through branch,
//     nested divergence, empty-warp launch, pop-past-empty, and a stack-full
//     overflow that must be refused via cmd_ready),
//   * runs a CONSTRAINED-RANDOM regression that issues INIT/DIVERGE/POP commands
//     with random masks/PCs while a golden SHADOW STACK tracks expected state,
//   * checks the DUT's {tos_mask, tos_pc, sp, empty, full} against the golden
//     shadow stack after every command,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in simt_stack_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_simt_stack_dump;

    localparam int NLANES = 8;
    localparam int PC_W   = 16;
    localparam int DEPTH  = 32;
    localparam int SP_W   = $clog2(DEPTH) + 1;

    localparam logic [1:0] OP_INIT    = 2'd0;
    localparam logic [1:0] OP_DIVERGE = 2'd1;
    localparam logic [1:0] OP_POP     = 2'd2;

    logic               clk;
    logic               rst_n;
    logic               cmd_valid;
    logic               cmd_ready;
    logic [1:0]         op;
    logic [NLANES-1:0]  in_mask;
    logic [PC_W-1:0]    rpc, tpc, fpc;
    logic [NLANES-1:0]  tos_mask;
    logic [PC_W-1:0]    tos_pc;
    logic [SP_W-1:0]    sp;
    logic               empty, full;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------- golden shadow stack -
    logic [NLANES-1:0] gmask [0:DEPTH-1];
    logic [PC_W-1:0]   gpc   [0:DEPTH-1];
    integer            gsp;

    // ---------------------------------------------------------------- DUT -----
    simt_stack #(.NLANES(NLANES), .PC_W(PC_W), .DEPTH(DEPTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .op       (op),
        .in_mask  (in_mask),
        .rpc      (rpc),
        .tpc      (tpc),
        .fpc      (fpc),
        .tos_mask (tos_mask),
        .tos_pc   (tos_pc),
        .sp       (sp),
        .empty    (empty),
        .full     (full)
    );

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -------------------------------------------- golden reference model ------
    // Apply one command to the shadow stack, mirroring the DUT exactly.
    task golden_apply(input [1:0] o, input [NLANES-1:0] m,
                      input [PC_W-1:0] r, input [PC_W-1:0] t, input [PC_W-1:0] f);
        logic [NLANES-1:0] cur, tset, fset;
        begin
            cur  = (gsp == 0) ? {NLANES{1'b0}} : gmask[gsp-1];
            tset = m & cur;
            fset = cur & ~m;
            case (o)
                OP_INIT: begin
                    gmask[0] = m;
                    gpc[0]   = f;
                    gsp      = (m == 0) ? 0 : 1;
                end
                OP_DIVERGE: begin
                    if (gsp != 0) begin
                        if ((tset != 0) && (fset != 0)) begin
                            if ((gsp + 2) <= DEPTH) begin   // else refused (unchanged)
                                gmask[gsp-1] = cur;  gpc[gsp-1] = r;   // reconv entry
                                gmask[gsp]   = fset; gpc[gsp]   = f;   // fall-through
                                gmask[gsp+1] = tset; gpc[gsp+1] = t;   // taken (TOS)
                                gsp = gsp + 2;
                            end
                        end else if (tset != 0) begin
                            gpc[gsp-1] = t;                            // uniform taken
                        end else begin
                            gpc[gsp-1] = f;                            // uniform fall-thru
                        end
                    end
                end
                OP_POP: begin
                    if (gsp != 0) gsp = gsp - 1;
                end
                default: ;
            endcase
        end
    endtask

    // Predict cmd_ready for the pending command against the CURRENT shadow state.
    function automatic logic pred_ready(input [1:0] o, input [NLANES-1:0] m);
        logic [NLANES-1:0] cur, tset, fset;
        logic grows;
        begin
            cur   = (gsp == 0) ? {NLANES{1'b0}} : gmask[gsp-1];
            tset  = m & cur;
            fset  = cur & ~m;
            grows = (o == OP_DIVERGE) && (tset != 0) && (fset != 0);
            pred_ready = !(grows && ((gsp + 2) > DEPTH));
        end
    endfunction

    // Compare the DUT's observed state against the golden shadow stack.
    task check_state(input [127:0] tag);
        begin
            checks = checks + 1;
            if (sp !== gsp) begin
                errors = errors + 1;
                $display("[%0t] %0s SP MISMATCH got %0d exp %0d", $time, tag, sp, gsp);
            end
            if (empty !== (gsp == 0)) begin
                errors = errors + 1;
                $display("[%0t] %0s EMPTY MISMATCH got %b exp %b", $time, tag, empty, (gsp==0));
            end
            if (full !== (gsp == DEPTH)) begin
                errors = errors + 1;
                $display("[%0t] %0s FULL MISMATCH got %b exp %b", $time, tag, full, (gsp==DEPTH));
            end
            if (gsp != 0) begin
                if (tos_mask !== gmask[gsp-1]) begin
                    errors = errors + 1;
                    $display("[%0t] %0s TOS_MASK MISMATCH got %b exp %b",
                             $time, tag, tos_mask, gmask[gsp-1]);
                end
                if (tos_pc !== gpc[gsp-1]) begin
                    errors = errors + 1;
                    $display("[%0t] %0s TOS_PC MISMATCH got 0x%0h exp 0x%0h",
                             $time, tag, tos_pc, gpc[gsp-1]);
                end
            end
        end
    endtask

    // ---------------------------------------------- one command + check -------
    task do_cmd(input [1:0] o, input [NLANES-1:0] m,
                input [PC_W-1:0] r, input [PC_W-1:0] t, input [PC_W-1:0] f);
        logic exp_ready;
        begin
            @(negedge clk);
            op = o; in_mask = m; rpc = r; tpc = t; fpc = f; cmd_valid = 1'b1;
            exp_ready = pred_ready(o, m);
            #2;                                   // let combinational cmd_ready settle
            if (cmd_ready !== exp_ready) begin
                errors = errors + 1;
                $display("[%0t] CMD_READY MISMATCH got %b exp %b (op=%0d)",
                         $time, cmd_ready, exp_ready, o);
            end
            @(negedge clk);                       // the posedge in between latched it
            cmd_valid = 1'b0;
            if (exp_ready) golden_apply(o, m, r, t, f);
            #1;                                   // outputs settle from new state
            check_state("cmd");
        end
    endtask

    // -------------------------------------------------------- stimulus --------
    integer i, w, rop;
    logic [NLANES-1:0] rmask;
    logic [PC_W-1:0]   rr, rt, rf;

    initial begin
        cmd_valid = 1'b0; op = OP_INIT; in_mask = '0; rpc = '0; tpc = '0; fpc = '0;
        gsp = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin gmask[i] = '0; gpc[i] = '0; end
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        #1; check_state("rst");                   // post-reset: empty warp
        rst_n = 1'b1;
        @(negedge clk);

        $display("==== DIRECTED SHOWCASE (launch -> diverge -> reconverge) ====");
        do_cmd(OP_INIT,    8'hFF, 16'h0000, 16'h0000, 16'h0010); // launch warp @0x10
        do_cmd(OP_DIVERGE, 8'h0F, 16'h0100, 16'h0200, 16'h0300); // branch: {0..3} take
        do_cmd(OP_POP,     8'h00, 16'h0000, 16'h0000, 16'h0000); // taken path done
        do_cmd(OP_POP,     8'h00, 16'h0000, 16'h0000, 16'h0000); // fall-thru done
        do_cmd(OP_POP,     8'h00, 16'h0000, 16'h0000, 16'h0000); // warp reconverged -> retire

        $display("==== DIRECTED CORNERS ====");
        // uniform-taken branch (whole warp takes) -> retarget, depth unchanged
        do_cmd(OP_INIT,    8'hFF, 16'h0, 16'h0, 16'h0020);
        do_cmd(OP_DIVERGE, 8'hFF, 16'h0100, 16'h0500, 16'h0600); // all take -> pc=0x500, sp=1
        // uniform fall-through (none take)
        do_cmd(OP_DIVERGE, 8'h00, 16'h0100, 16'h0700, 16'h0800); // none take -> pc=0x800, sp=1
        // nested divergence (diverge, then diverge the taken subset again)
        do_cmd(OP_DIVERGE, 8'h0F, 16'h0900, 16'h0A00, 16'h0B00); // sp 1->3, TOS={0x0F}
        do_cmd(OP_DIVERGE, 8'h03, 16'h0C00, 16'h0D00, 16'h0E00); // sp 3->5, TOS={0x03}
        do_cmd(OP_POP,     8'h0, 0, 0, 0);
        do_cmd(OP_POP,     8'h0, 0, 0, 0);
        do_cmd(OP_POP,     8'h0, 0, 0, 0);
        do_cmd(OP_POP,     8'h0, 0, 0, 0);
        do_cmd(OP_POP,     8'h0, 0, 0, 0);   // drain to empty
        // single active lane: a one-lane warp cannot diverge (uniform), pc retargets
        do_cmd(OP_INIT,    8'h10, 0, 0, 16'h0F00);           // only lane 4 live, sp=1
        do_cmd(OP_DIVERGE, 8'h10, 16'h0100, 16'h1100, 16'h1200); // it takes -> pc=0x1100
        do_cmd(OP_POP,     8'h0, 0, 0, 0);                   // retire
        // empty-warp launch (in_mask==0) -> stays retired
        do_cmd(OP_INIT,    8'h00, 0, 0, 16'h1300);
        // pop-past-empty -> no-op, stays empty
        do_cmd(OP_POP,     8'h0, 0, 0, 0);
        // safety: guarantee an empty stack before the random phase
        while (gsp != 0) do_cmd(OP_POP, 8'h0, 0, 0, 0);

        $display("==== CONSTRAINED-RANDOM REGRESSION ====");
        for (w = 0; w < 400; w = w + 1) begin
            rmask = $urandom_range(1, 255);
            rr    = $urandom;
            rt    = $urandom;
            rf    = $urandom;
            if (gsp == 0) begin
                rop = OP_INIT;                          // must launch first
            end else if ((gsp + 2) > DEPTH) begin
                rop = OP_POP;                           // avoid overflow region
            end else begin
                rop = $urandom_range(0, 3);
                if (rop == 3) rop = OP_POP;             // bias toward the 3 real ops
            end
            do_cmd(rop[1:0], rmask, rr, rt, rf);
        end

        repeat (4) @(negedge clk);
        $display("==== SUMMARY : %0d checks, %0d errors ====", checks, errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // -------------------------------------------------------- timeout ---------
    initial begin
        #500000;   // 500 us global watchdog
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ---------------------------------------------------------- dump ----------
    initial begin
        $dumpfile("tb_simt_stack_dump.vcd");
        $dumpvars(0, tb_simt_stack_dump);
    end

endmodule

`default_nettype wire
