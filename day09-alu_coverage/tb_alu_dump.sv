// ============================================================================
// tb_alu_dump.sv - portable, self-checking module testbench for `alu`.
//
// WHY THIS EXISTS
//   Icarus Verilog (the open-source simulator this repo runs on) does not
//   implement the UVM class library, so it cannot elaborate alu_pkg.sv /
//   tb_top.sv. This companion testbench reproduces the SAME verification
//   intent - independent golden reference model, directed + constrained-random
//   stimulus, self-checking scoreboard, and a VCD dump - in plain synthesizable
//   -friendly SystemVerilog that runs everywhere.
//
// WHAT IT CHECKS
//   Every registered ALU response is compared, one cycle after issue, against a
//   golden model computed in this testbench from the same (opcode,a,b). Result
//   AND all four flags {zero,carry,overflow,negative} must match. Any mismatch
//   is fatal; the run ends with "RESULT: *** PASS ***" only if all checks pass.
//
// The front of the run is a DIRECTED showcase (reset, ADD carry-out, SUB
// borrow, signed overflow, logic ops, shifts, SLT, a zero result) so the
// committed waveform tells the design's story; a constrained-random regression
// follows to exercise the space.
// ============================================================================
`timescale 1ns/1ps
module tb_alu_dump;

    localparam int WIDTH = 8;
    localparam int SHW   = 3;   // $clog2(8)

    // Opcode encoding (mirrors the DUT).
    localparam logic [3:0] OP_ADD = 4'h0;
    localparam logic [3:0] OP_SUB = 4'h1;
    localparam logic [3:0] OP_AND = 4'h2;
    localparam logic [3:0] OP_OR  = 4'h3;
    localparam logic [3:0] OP_XOR = 4'h4;
    localparam logic [3:0] OP_SLL = 4'h5;
    localparam logic [3:0] OP_SRL = 4'h6;
    localparam logic [3:0] OP_SLT = 4'h7;

    logic             clk, rst_n;
    logic             in_valid;
    logic [3:0]       opcode;
    logic [WIDTH-1:0] a, b;
    logic             out_valid;
    logic [WIDTH-1:0] result;
    logic             zero, carry, overflow, negative;

    // ------------------------------------------------------------------ DUT
    alu #(.WIDTH(WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .opcode(opcode), .a(a), .b(b),
        .out_valid(out_valid), .result(result),
        .zero(zero), .carry(carry), .overflow(overflow), .negative(negative)
    );

    // ------------------------------------------------------------------ clock
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period

    // -------------------------------------------------- golden reference model
    // Independent re-implementation of the ALU specification. Returns the
    // expected result and packs the four flags into a bus {neg,ovf,cy,zero}.
    task automatic golden(input  logic [3:0]       op,
                          input  logic [WIDTH-1:0] ga,
                          input  logic [WIDTH-1:0] gb,
                          output logic [WIDTH-1:0] gres,
                          output logic             gzero,
                          output logic             gcarry,
                          output logic             govf,
                          output logic             gneg);
        logic [WIDTH:0] ext;
        gres = '0; gcarry = 1'b0; govf = 1'b0;
        case (op)
            OP_ADD: begin
                ext    = {1'b0, ga} + {1'b0, gb};
                gres   = ext[WIDTH-1:0];
                gcarry = ext[WIDTH];
                govf   = (ga[WIDTH-1] == gb[WIDTH-1]) &&
                         (gres[WIDTH-1] != ga[WIDTH-1]);
            end
            OP_SUB: begin
                ext    = {1'b0, ga} - {1'b0, gb};
                gres   = ext[WIDTH-1:0];
                gcarry = ext[WIDTH];
                govf   = (ga[WIDTH-1] != gb[WIDTH-1]) &&
                         (gres[WIDTH-1] != ga[WIDTH-1]);
            end
            OP_AND: gres = ga & gb;
            OP_OR:  gres = ga | gb;
            OP_XOR: gres = ga ^ gb;
            OP_SLL: gres = ga << gb[SHW-1:0];
            OP_SRL: gres = ga >> gb[SHW-1:0];
            OP_SLT: gres = ($signed(ga) < $signed(gb)) ? {{(WIDTH-1){1'b0}},1'b1} : '0;
            default: gres = '0;
        endcase
        gzero = (gres == '0);
        gneg  = gres[WIDTH-1];
    endtask

    // ------------------------------------------------------- scoreboard state
    // A decoupled expected-response FIFO (ring buffer). The stimulus pushes the
    // golden answer the instant a transaction is issued; the checker pops one
    // entry each cycle the DUT raises out_valid. This makes the scoreboard
    // independent of the exact pipeline latency - order and data are what
    // matter, exactly like a UVM analysis-FIFO scoreboard.
    localparam int QD = 1024;
    logic [WIDTH-1:0] q_res  [0:QD-1];
    logic             q_zero [0:QD-1];
    logic             q_carry[0:QD-1];
    logic             q_ovf  [0:QD-1];
    logic             q_neg  [0:QD-1];
    logic [3:0]       q_op   [0:QD-1];
    logic [WIDTH-1:0] q_a    [0:QD-1];
    logic [WIDTH-1:0] q_b    [0:QD-1];
    int wr_ptr = 0;
    int rd_ptr = 0;

    int checks = 0;
    int errors = 0;
    int op_hits[0:7];

    // Issue a transaction on the next posedge; push its golden answer now.
    task automatic issue(input logic [3:0] op,
                         input logic [WIDTH-1:0] va,
                         input logic [WIDTH-1:0] vb);
        logic [WIDTH-1:0] gr; logic gz, gc, go, gn;
        @(posedge clk);
        in_valid <= 1'b1; opcode <= op; a <= va; b <= vb;
        golden(op, va, vb, gr, gz, gc, go, gn);
        q_op[wr_ptr] = op; q_a[wr_ptr] = va; q_b[wr_ptr] = vb;
        q_res[wr_ptr] = gr; q_zero[wr_ptr] = gz; q_carry[wr_ptr] = gc;
        q_ovf[wr_ptr] = go; q_neg[wr_ptr] = gn;
        wr_ptr = (wr_ptr + 1) % QD;
        op_hits[op] = op_hits[op] + 1;
    endtask

    task automatic idle();
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // Checker: each cycle the DUT asserts out_valid, pop the oldest expected
    // response and compare result + all four flags.
    always @(posedge clk) begin
        if (rst_n && (out_valid === 1'b1)) begin
            checks++;
            if ((result   !== q_res[rd_ptr])  || (zero     !== q_zero[rd_ptr]) ||
                (carry    !== q_carry[rd_ptr])|| (overflow !== q_ovf[rd_ptr])  ||
                (negative !== q_neg[rd_ptr])) begin
                errors++;
                $display("[%0t] MISMATCH op=%0h a=%0h b=%0h : DUT res=%0h z=%b c=%b v=%b n=%b | EXP res=%0h z=%b c=%b v=%b n=%b",
                         $time, q_op[rd_ptr], q_a[rd_ptr], q_b[rd_ptr],
                         result, zero, carry, overflow, negative,
                         q_res[rd_ptr], q_zero[rd_ptr], q_carry[rd_ptr],
                         q_ovf[rd_ptr], q_neg[rd_ptr]);
            end
            rd_ptr = (rd_ptr + 1) % QD;
        end
    end

    // ------------------------------------------------------------- stimulus
    integer i;
    logic [3:0]       rop;
    logic [WIDTH-1:0] ra, rb;

    initial begin
        // init
        in_valid = 1'b0; opcode = '0; a = '0; b = '0;
        for (i = 0; i < 8; i++) op_hits[i] = 0;

        // ---- reset ----
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- DIRECTED showcase (drives the committed waveform window) ----
        issue(OP_ADD, 8'hF0, 8'h20);  // 0x110 -> res=0x10, carry=1
        issue(OP_SUB, 8'h10, 8'h20);  // borrow: res=0xF0, carry=1, neg=1
        issue(OP_ADD, 8'h50, 8'h50);  // signed overflow: +80++80 -> -96, ovf=1
        issue(OP_AND, 8'hF0, 8'h0F);  // 0x00 -> zero=1
        issue(OP_OR,  8'h81, 8'h12);  // 0x93, neg=1
        issue(OP_XOR, 8'hFF, 8'h0F);  // 0xF0, neg=1
        issue(OP_SLL, 8'h01, 8'h04);  // 0x10
        issue(OP_SRL, 8'h80, 8'h03);  // 0x10
        issue(OP_SLT, 8'hFF, 8'h01);  // signed(-1) < 1 -> res=1
        idle();

        // ---- constrained-random regression ----
        for (i = 0; i < 400; i++) begin
            rop = $random & 4'h7;       // opcodes 0..7 (masked, always in range)
            ra  = $random;
            rb  = $random;
            issue(rop, ra, rb);
        end
        idle();
        repeat (3) @(posedge clk);

        // ---- report ----
        $display("----------------------------------------------------------");
        $display(" checks=%0d  errors=%0d", checks, errors);
        $display(" opcode hits: ADD=%0d SUB=%0d AND=%0d OR=%0d XOR=%0d SLL=%0d SRL=%0d SLT=%0d",
                 op_hits[0], op_hits[1], op_hits[2], op_hits[3],
                 op_hits[4], op_hits[5], op_hits[6], op_hits[7]);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------------------------------------------------- SVA assertions
    // Concurrent SVA (Icarus does not implement `assert property`, so this
    // block is compiled only under a UVM-capable simulator via +define+ALU_SVA).
`ifdef ALU_SVA
    // negative flag must equal the MSB of the reported result when valid.
    property p_neg_is_msb;
        @(posedge clk) disable iff (!rst_n)
        out_valid |-> (negative == result[WIDTH-1]);
    endproperty
    a_neg_is_msb: assert property (p_neg_is_msb)
        else $error("negative flag != result MSB");

    // zero flag must be exactly (result == 0) when valid.
    property p_zero_iff_zero;
        @(posedge clk) disable iff (!rst_n)
        out_valid |-> (zero == (result == '0));
    endproperty
    a_zero_iff_zero: assert property (p_zero_iff_zero)
        else $error("zero flag inconsistent with result");
`endif

    // ------------------------------------------------------------- timeout
    initial begin
        #100000;   // 100 us hard cap
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ------------------------------------------------------------- VCD dump
    initial begin
        $dumpfile("tb_alu_dump.vcd");
        $dumpvars(0, tb_alu_dump);
    end

endmodule
