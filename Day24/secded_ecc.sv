// -----------------------------------------------------------------------------
// secded_ecc.sv - parameterized SINGLE-ERROR-CORRECT / DOUBLE-ERROR-DETECT
//                 (SECDED) EXTENDED-HAMMING ECC ENCODER + DECODER.
//
// SECDED is the integrity guard that sits INSIDE memory: every ECC DRAM DIMM,
// L2/L3 cache line, register-file, and on-die SRAM stores a few extra check
// bits with each word so that a single flipped bit (cosmic ray, retention
// failure, weak cell) is transparently CORRECTED, and any double-bit error is
// at least DETECTED (flagged uncorrectable) rather than silently returned as
// good data. Where a CRC (see Day23) only DETECTS corruption on a wire, an ECC
// code CORRECTS it in place - this DUT is that block.
//
// CODE: extended Hamming SECDED. For DW data bits we add HAM Hamming parity
// bits (smallest HAM with 2^HAM >= DW+HAM+1) plus one overall parity bit, for a
// codeword of CW = DW+HAM+1 bits. The classic memory geometry is (72,64):
// DW=64 -> HAM=7 -> CW=72 (eight check bits per 64-bit word).
//
// CONSTRUCTION (textbook, so an independent golden model is bit-exact):
//   * Base Hamming positions are numbered 1..NBASE (NBASE = DW+HAM). Positions
//     that are powers of two (1,2,4,8,...) hold the HAM Hamming parity bits;
//     every other position holds a data bit (data bits assigned in increasing
//     position order). Hamming parity i (at position 2^i) is the XOR of all
//     positions whose index has bit i set.
//   * One extra OVERALL parity bit is the XOR of the whole base codeword; it is
//     what upgrades plain Hamming (SEC) to SECDED. The packed codeword is
//     out_code[0] = overall parity, out_code[p] = base position p (1..NBASE).
//
// DECODE (extended-Hamming syndrome decode):
//   * Recompute the HAM syndrome bits over the received word -> S (0..2^HAM-1),
//     and the overall parity P over ALL CW bits.
//   * P==0, S==0 : no error.
//   * P==1       : an odd number of errors -> a SINGLE-bit error. If S==0 the
//                  flipped bit is the overall-parity bit itself (position 0);
//                  otherwise position S is flipped. Correct it, assert out_sbe.
//   * P==0, S!=0 : an even (>0) number of errors -> DOUBLE-bit error, NOT
//                  correctable. Assert out_dbe and leave the data uncorrected.
//   The corrected data is then extracted from the (corrected) codeword.
//
// PER-TRANSACTION OP (one operation per accepted cycle, zero-bubble capable):
//   * in_op==ENCODE(0): in_data is the DW-bit word -> out_code is its codeword,
//                       out_data echoes the data, syndrome/sbe/dbe are 0.
//   * in_op==DECODE(1): in_code is a received (possibly-corrupted) codeword ->
//                       out_data is the corrected data, out_syndrome/out_sbe/
//                       out_dbe report the diagnosis, out_code is the corrected
//                       codeword.
//
// LATENCY: the encode/decode datapath is combinational, then carried through
// PIPE output-register stages for fixed latency / timing closure; out_valid
// pulses exactly LAT = PIPE cycles after an accepted in_valid.
//
// The design is parameterized, reset-safe, fully registered at its outputs, and
// lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

// ---- compilation-unit-scope code-geometry helpers -------------------------
// (defined before the module so they can size the ANSI parameter list / ports)
//
// HAM = smallest r with 2^r >= DW + r + 1 (Hamming bound including the SECDED
// bit); is_pow2 marks the parity positions of the base Hamming code.
function automatic int ham_bits(input int k);
    int r;
    begin
        r = 0;
        while ((1 << r) < (k + r + 1)) r = r + 1;
        ham_bits = r;
    end
endfunction

function automatic bit secded_is_pow2(input int p);
    secded_is_pow2 = (p != 0) && ((p & (p - 1)) == 0);
endfunction

module secded_ecc #(
    parameter int DW    = 64,                 // data-word width (K)
    parameter int PIPE  = 2,                  // output latency in cycles (>=1)
    // ---- derived code geometry (do not override) ----
    parameter int HAM   = ham_bits(DW),       // number of Hamming parity bits
    parameter int NBASE = DW + HAM,           // base Hamming length (positions 1..NBASE)
    parameter int CW    = NBASE + 1           // codeword width (+ overall parity)
) (
    input  wire                clk,
    input  wire                rst_n,

    // request
    input  wire                in_valid,   // operation present this cycle
    input  wire                in_op,      // 0 = ENCODE, 1 = DECODE
    input  wire [DW-1:0]       in_data,    // ENCODE: the data word
    input  wire [CW-1:0]       in_code,    // DECODE: the received codeword

    // result (fixed latency LAT = PIPE after the request)
    output wire                out_valid,  // 1-cycle strobe: a result is valid
    output wire                out_op,     // echoed op
    output wire [CW-1:0]       out_code,   // ENCODE: codeword ; DECODE: corrected word
    output wire [DW-1:0]       out_data,   // ENCODE: echoed data ; DECODE: corrected data
    output wire [HAM-1:0]      out_syndrome, // DECODE: raw Hamming syndrome
    output wire                out_sbe,    // DECODE: single-bit error corrected
    output wire                out_dbe     // DECODE: double-bit error detected
);

    localparam int LAT = PIPE;

    // ===========================================================================
    // ENCODE datapath (combinational)
    // ===========================================================================
    logic [NBASE:1] enc_base;   // base codeword positions 1..NBASE
    logic [CW-1:0]  enc_code;
    integer         di, p, i;
    logic           acc, ovp;

    always_comb begin
        // place data bits into the non-power-of-two positions, low positions first
        di = 0;
        for (p = 1; p <= NBASE; p++) begin
            if (secded_is_pow2(p)) enc_base[p] = 1'b0;   // parity placeholder
            else begin
                enc_base[p] = in_data[di];
                di = di + 1;
            end
        end
        // compute each Hamming parity as XOR over covered positions
        for (i = 0; i < HAM; i++) begin
            acc = 1'b0;
            for (p = 1; p <= NBASE; p++)
                if (p != (1 << i) && ((p >> i) & 1)) acc = acc ^ enc_base[p];
            enc_base[1 << i] = acc;
        end
        // overall parity over the whole base codeword
        ovp = 1'b0;
        for (p = 1; p <= NBASE; p++) ovp = ovp ^ enc_base[p];
        // pack: bit0 = overall parity, bits[NBASE:1] = base positions
        enc_code = '0;
        enc_code[0] = ovp;
        for (p = 1; p <= NBASE; p++) enc_code[p] = enc_base[p];
    end

    // ===========================================================================
    // DECODE datapath (combinational)
    // ===========================================================================
    logic [HAM-1:0] synd;
    integer         Sval;
    logic           par_all;
    logic [CW-1:0]  corr_code;
    logic [DW-1:0]  dec_data;
    logic           sbe_c, dbe_c;
    integer         dj, di2, k;
    logic           sacc;

    always_comb begin
        // recompute the HAM syndrome bits over the received codeword
        for (i = 0; i < HAM; i++) begin
            sacc = 1'b0;
            for (p = 1; p <= NBASE; p++)
                if ((p >> i) & 1) sacc = sacc ^ in_code[p];
            synd[i] = sacc;
        end
        Sval = 0;
        for (k = 0; k < HAM; k++) if (synd[k]) Sval = Sval | (1 << k);

        // overall parity over ALL codeword bits (including the overall bit)
        par_all = ^in_code;

        // classify and correct
        corr_code = in_code;
        sbe_c = 1'b0;
        dbe_c = 1'b0;
        if (par_all) begin
            sbe_c = 1'b1;                     // odd # of errors -> single-bit
            if (Sval == 0)          corr_code[0]    = corr_code[0]    ^ 1'b1;
            else if (Sval <= NBASE) corr_code[Sval] = corr_code[Sval] ^ 1'b1;
        end else begin
            if (Sval != 0) dbe_c = 1'b1;      // even (>0) # of errors -> double-bit
        end

        // extract the (corrected) data bits
        dec_data = '0;
        di2 = 0;
        for (p = 1; p <= NBASE; p++)
            if (!secded_is_pow2(p)) begin
                dec_data[di2] = corr_code[p];
                di2 = di2 + 1;
            end
    end

    // ===========================================================================
    // Stage-0 result selection (by op) + fixed-latency output pipeline
    // ===========================================================================
    wire            s0_valid = in_valid;
    wire            s0_op    = in_op;
    wire [CW-1:0]   s0_code  = in_op ? corr_code : enc_code;
    wire [DW-1:0]   s0_data  = in_op ? dec_data  : in_data;
    wire [HAM-1:0]  s0_synd  = in_op ? synd      : '0;
    wire            s0_sbe   = in_op ? sbe_c      : 1'b0;
    wire            s0_dbe   = in_op ? dbe_c      : 1'b0;

    logic [PIPE-1:0]   v_pipe;
    logic [PIPE-1:0]   op_pipe;
    logic [CW-1:0]     code_pipe [PIPE-1:0];
    logic [DW-1:0]     data_pipe [PIPE-1:0];
    logic [HAM-1:0]    synd_pipe [PIPE-1:0];
    logic [PIPE-1:0]   sbe_pipe;
    logic [PIPE-1:0]   dbe_pipe;

    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_pipe   <= '0;
            op_pipe  <= '0;
            sbe_pipe <= '0;
            dbe_pipe <= '0;
            for (s = 0; s < PIPE; s++) begin
                code_pipe[s] <= '0;
                data_pipe[s] <= '0;
                synd_pipe[s] <= '0;
            end
        end else begin
            v_pipe[0]    <= s0_valid;
            op_pipe[0]   <= s0_op;
            code_pipe[0] <= s0_code;
            data_pipe[0] <= s0_data;
            synd_pipe[0] <= s0_synd;
            sbe_pipe[0]  <= s0_sbe;
            dbe_pipe[0]  <= s0_dbe;
            for (s = 1; s < PIPE; s++) begin
                v_pipe[s]    <= v_pipe[s-1];
                op_pipe[s]   <= op_pipe[s-1];
                code_pipe[s] <= code_pipe[s-1];
                data_pipe[s] <= data_pipe[s-1];
                synd_pipe[s] <= synd_pipe[s-1];
                sbe_pipe[s]  <= sbe_pipe[s-1];
                dbe_pipe[s]  <= dbe_pipe[s-1];
            end
        end
    end

    assign out_valid    = v_pipe[PIPE-1];
    assign out_op       = op_pipe[PIPE-1];
    assign out_code     = code_pipe[PIPE-1];
    assign out_data     = data_pipe[PIPE-1];
    assign out_syndrome = synd_pipe[PIPE-1];
    assign out_sbe      = sbe_pipe[PIPE-1];
    assign out_dbe      = dbe_pipe[PIPE-1];

    // ===========================================================================
    // Assertion-based verification (enable with +define+SECDED_SVA on a UVM sim).
    // ===========================================================================
`ifdef SECDED_SVA
    // A result appears exactly LAT cycles after an accepted request.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##LAT out_valid)
        else $error("result did not appear LAT=%0d cycles after in_valid", LAT);

    // A result strobe must trace back to a request LAT cycles earlier.
    a_valid_caused: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> $past(in_valid, LAT))
        else $error("out_valid with no in_valid LAT cycles earlier");

    // sbe and dbe are mutually exclusive.
    a_excl: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !(out_sbe && out_dbe))
        else $error("out_sbe and out_dbe asserted together");

    // ENCODE never reports an error.
    a_encode_clean: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && !out_op) |-> (!out_sbe && !out_dbe))
        else $error("error flag asserted in ENCODE mode");

    // Result buses are fully defined whenever a result is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (!$isunknown({out_op, out_code, out_data,
                                    out_syndrome, out_sbe, out_dbe})))
        else $error("X/Z on result bus while out_valid");
`endif

endmodule

`default_nettype wire
