// -----------------------------------------------------------------------------
// seq_divider.sv - parameterized multi-cycle UNSIGNED sequential divider.
//
// Implements the classic RESTORING division algorithm: one iteration per clock,
// WIDTH iterations per division, producing an exact integer quotient and
// remainder such that
//
//     dividend == quotient * divisor + remainder,   0 <= remainder < divisor
//
// A start/busy/done handshake frames each operation:
//     * assert `start` for one cycle (only accepted while !busy) to latch the
//       operands and begin,
//     * `busy` is high for the whole computation,
//     * `done` pulses high for exactly one cycle when the result is valid,
//     * `quotient`/`remainder` are registered and hold until the next result.
//
// Divide-by-zero is detected and reported on `dbz` (valid with `done`). The
// x/0 convention here matches common RISC hardware: quotient = all-ones
// (2**WIDTH - 1) and remainder = dividend.
//
// The design is synthesizable, fully reset-safe (synchronous outputs, async
// active-low reset), parameterized on WIDTH, and lint-friendly.
// -----------------------------------------------------------------------------
`default_nettype none

module seq_divider #(
    parameter int WIDTH = 8
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,       // pulse to begin a division (ignored while busy)
    input  wire  [WIDTH-1:0] dividend,
    input  wire  [WIDTH-1:0] divisor,
    output logic             busy,        // high while a division is in progress
    output logic             done,        // one-cycle pulse: result valid this cycle
    output logic [WIDTH-1:0] quotient,
    output logic [WIDTH-1:0] remainder,
    output logic             dbz          // divide-by-zero flag (valid with done)
);

    localparam int CW = $clog2(WIDTH + 1);

    typedef enum logic [1:0] {S_IDLE, S_CALC, S_DONE} state_t;
    state_t          state;

    logic [CW-1:0]   cnt;       // remaining iterations
    logic [WIDTH:0]  p;         // partial remainder (one guard bit)
    logic [WIDTH-1:0] a;        // dividend register; becomes quotient bit-by-bit
    logic [WIDTH-1:0] b;        // divisor latch
    logic [WIDTH-1:0] divd_q;   // original dividend (for the x/0 remainder convention)
    logic            dbz_q;     // divide-by-zero sticky flag for this operation

    // ---- combinational one-step restoring iteration on the shifted {p,a} ----
    logic [WIDTH:0]   p_shift;
    logic [WIDTH-1:0] a_shift;
    logic [WIDTH:0]   p_sub;

    always_comb begin
        // Shift the {partial-remainder, dividend} pair left by one bit; the new
        // low bit of `a` is a placeholder overwritten by the quotient bit below.
        {p_shift, a_shift} = {p[WIDTH-1:0], a, 1'b0};
        // Trial subtraction of the divisor from the shifted partial remainder.
        p_sub              = p_shift - {1'b0, b};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            dbz       <= 1'b0;
            dbz_q     <= 1'b0;
            cnt       <= '0;
            p         <= '0;
            a         <= '0;
            b         <= '0;
            divd_q    <= '0;
            quotient  <= '0;
            remainder <= '0;
        end else begin
            done <= 1'b0;  // default: single-cycle pulse

            unique case (state)
                // -----------------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        b      <= divisor;
                        p      <= '0;
                        a      <= dividend;
                        divd_q <= dividend;
                        cnt    <= CW'(WIDTH);
                        dbz_q  <= (divisor == '0);
                        busy   <= 1'b1;
                        state  <= S_CALC;
                    end
                end

                // -----------------------------------------------------------------
                S_CALC: begin
                    if (p_sub[WIDTH] == 1'b0) begin   // p_shift >= divisor: keep, set bit
                        p <= p_sub;
                        a <= {a_shift[WIDTH-1:1], 1'b1};
                    end else begin                    // p_shift <  divisor: restore, clear bit
                        p <= p_shift;
                        a <= {a_shift[WIDTH-1:1], 1'b0};
                    end
                    cnt <= cnt - 1'b1;
                    if (cnt == CW'(1)) state <= S_DONE;
                end

                // -----------------------------------------------------------------
                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    dbz  <= dbz_q;
                    if (dbz_q) begin
                        quotient  <= '1;          // x/0 -> all-ones quotient
                        remainder <= divd_q;      // x/0 -> remainder = dividend
                    end else begin
                        quotient  <= a;
                        remainder <= p[WIDTH-1:0];
                    end
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
