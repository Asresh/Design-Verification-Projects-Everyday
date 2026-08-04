// ============================================================================
// scrambler.sv - parameterized WIDTH-bit-parallel SELF-SYNCHRONIZING
//                (multiplicative) scrambler / descrambler.
// ----------------------------------------------------------------------------
// This is the physical-layer data-whitening block used on serial links: the
// IEEE 802.3 10GBASE-R PCS scrambles the 64B/66B payload with the generator
//
//        G(x) = 1 + x^39 + x^58        (58-bit state, taps at 39 and 58)
//
// to guarantee enough transitions for clock recovery and to spread the signal
// spectrum. It is *multiplicative* (a.k.a. self-synchronizing): the shift
// register is fed by the bit that travels on the wire (the scrambled bit), so
//
//     scramble  : y_n = d_n ^ y_{n-39} ^ y_{n-58}   (output feeds the register)
//     descramble: d_n = y_n ^ y_{n-39} ^ y_{n-58}   (input  feeds the register)
//
// Because the descrambler's register is driven purely by the received bits, it
// re-derives the transmitter's state after LFSR_W received bits *regardless of
// its own reset seed* - it self-synchronizes. That recovery is the headline
// property this project verifies.
//
// The datapath is WIDTH bits/cycle: the WIDTH serial steps are unrolled in
// always_comb (the classic "parallelize the LFSR" exercise - a rich source of
// tap-index / shift-direction / off-by-one bugs that the independent serial
// golden model is there to catch). Bit 0 of a word is processed first.
//
// A single module covers both directions via MODE_DESCRAMBLE; only the choice
// of which bit is shifted into the register differs. Output is registered, so
// out_valid is in_valid delayed one cycle (fixed latency 1).
// ----------------------------------------------------------------------------
// Synthesizable, reset-safe, lint-friendly. No UVM here - see scrambler_pkg.sv
// (UVM) and tb_scrambler_dump.sv (portable Icarus TB).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module scrambler #(
    parameter int unsigned WIDTH           = 8,          // bits per cycle
    parameter int unsigned LFSR_W          = 58,         // state width (x^58)
    parameter int unsigned TAP_A           = 39,         // x^39 feedback tap
    parameter int unsigned TAP_B           = 58,         // x^58 feedback tap
    parameter bit          MODE_DESCRAMBLE = 1'b0,        // 0=scramble 1=descramble
    parameter logic [LFSR_W-1:0] SEED      = {LFSR_W{1'b1}}
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    in_valid,
    input  wire  [WIDTH-1:0]       in_data,
    output logic                   out_valid,
    output logic [WIDTH-1:0]       out_data,
    // observation: the live LFSR state (post-word), handy for monitors/SVA
    output logic [LFSR_W-1:0]      state_o
);

    // state[i] holds the bit that was fed into the register i+1 words-bits ago,
    // so the "fed TAP_A bits ago" tap is state[TAP_A-1] and "TAP_B ago" is
    // state[TAP_B-1] (state[LFSR_W-1], the bit about to shift out).
    logic [LFSR_W-1:0] state;

    // ------------------------------------------------------------------
    // Combinational WIDTH-step unroll of the serial recurrence.
    // ------------------------------------------------------------------
    logic [WIDTH-1:0]  out_comb;
    logic [LFSR_W-1:0] next_state;

    always_comb begin
        logic [LFSR_W-1:0] cur;
        logic              fb, ob, fed;
        cur = state;
        for (int unsigned j = 0; j < WIDTH; j++) begin
            fb        = cur[TAP_A-1] ^ cur[TAP_B-1];
            ob        = in_data[j] ^ fb;                 // the recovered/scrambled bit
            fed       = MODE_DESCRAMBLE ? in_data[j]     // descramble: received bit feeds
                                        : ob;            // scramble  : output bit feeds
            out_comb[j] = ob;
            cur       = {cur[LFSR_W-2:0], fed};          // shift new bit into [0]
        end
        next_state = cur;
    end

    // ------------------------------------------------------------------
    // Registered outputs (fixed 1-cycle latency, valid-qualified state).
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= SEED;
            out_data  <= '0;
            out_valid <= 1'b0;
        end else if (in_valid) begin
            state     <= next_state;
            out_data  <= out_comb;
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;                           // out_data holds
        end
    end

    assign state_o = state;

endmodule

`default_nettype wire
