// ============================================================================
// alu.sv - parameterized, registered arithmetic/logic unit (DUT)
//
// A clean, synthesizable, reset-safe ALU with a one-cycle valid handshake:
//   * `in_valid` presents (opcode, a, b) on a clock edge.
//   * The operation is computed combinationally and REGISTERED, so the result
//     and flags appear one clock later together with `out_valid`.
//
// Eight operations are supported (see the OP_* localparams). The flag set is
// the classic {zero, carry, overflow, negative}:
//   * zero     : result == 0
//   * carry    : ADD carry-out; SUB unsigned borrow (a < b); 0 for logic/shift
//   * overflow : signed two's-complement overflow for ADD/SUB; 0 otherwise
//   * negative : MSB of result (sign bit)
//
// The flag semantics here ARE the specification the testbench's golden
// reference model re-implements independently.
// ============================================================================
module alu #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             in_valid,
    input  logic [3:0]       opcode,
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic             out_valid,
    output logic [WIDTH-1:0] result,
    output logic             zero,
    output logic             carry,
    output logic             overflow,
    output logic             negative
);

    // ---- Opcode encoding ----------------------------------------------------
    localparam logic [3:0] OP_ADD = 4'h0;  // a + b
    localparam logic [3:0] OP_SUB = 4'h1;  // a - b
    localparam logic [3:0] OP_AND = 4'h2;  // a & b
    localparam logic [3:0] OP_OR  = 4'h3;  // a | b
    localparam logic [3:0] OP_XOR = 4'h4;  // a ^ b
    localparam logic [3:0] OP_SLL = 4'h5;  // a << b[$clog2(WIDTH)-1:0]
    localparam logic [3:0] OP_SRL = 4'h6;  // a >> b[$clog2(WIDTH)-1:0]
    localparam logic [3:0] OP_SLT = 4'h7;  // signed(a) < signed(b) ? 1 : 0

    localparam int SHW = (WIDTH > 1) ? $clog2(WIDTH) : 1;

    // ---- Combinational datapath ---------------------------------------------
    logic [WIDTH:0]     add_ext, sub_ext;   // one extra bit to capture carry
    logic [WIDTH-1:0]   comb_result;
    logic               comb_carry;
    logic               comb_overflow;

    always_comb begin
        add_ext = {1'b0, a} + {1'b0, b};
        sub_ext = {1'b0, a} - {1'b0, b};

        comb_result   = '0;
        comb_carry    = 1'b0;
        comb_overflow = 1'b0;

        unique case (opcode)
            OP_ADD: begin
                comb_result   = add_ext[WIDTH-1:0];
                comb_carry    = add_ext[WIDTH];
                // signed overflow: operands same sign, result differs
                comb_overflow = (a[WIDTH-1] == b[WIDTH-1]) &&
                                (comb_result[WIDTH-1] != a[WIDTH-1]);
            end
            OP_SUB: begin
                comb_result   = sub_ext[WIDTH-1:0];
                comb_carry    = sub_ext[WIDTH];          // unsigned borrow (a<b)
                // signed overflow: operands differ in sign, result != minuend
                comb_overflow = (a[WIDTH-1] != b[WIDTH-1]) &&
                                (comb_result[WIDTH-1] != a[WIDTH-1]);
            end
            OP_AND: comb_result = a & b;
            OP_OR:  comb_result = a | b;
            OP_XOR: comb_result = a ^ b;
            OP_SLL: comb_result = a << b[SHW-1:0];
            OP_SRL: comb_result = a >> b[SHW-1:0];
            OP_SLT: comb_result = ($signed(a) < $signed(b))
                                  ? {{(WIDTH-1){1'b0}}, 1'b1} : '0;
            default: comb_result = '0;
        endcase
    end

    // ---- Registered output stage --------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            result    <= '0;
            zero      <= 1'b0;
            carry     <= 1'b0;
            overflow  <= 1'b0;
            negative  <= 1'b0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                result   <= comb_result;
                zero     <= (comb_result == '0);
                carry    <= comb_carry;
                overflow <= comb_overflow;
                negative <= comb_result[WIDTH-1];
            end
        end
    end

endmodule
