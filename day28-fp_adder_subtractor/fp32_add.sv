// ============================================================================
// fp32_add.sv - fully-pipelined IEEE-754 binary32 floating-point adder /
//               subtractor with round-to-nearest-even, subnormal support and
//               full special-case handling.
// ----------------------------------------------------------------------------
// The classic "hard" arithmetic block: every FPU, GPU shader core, DSP MAC and
// neural-net accumulator contains one. Its verification interest is not the
// happy path (1.0 + 2.0) but the enormous corner space around it:
//
//   * alignment      - a huge exponent difference must still contribute a
//                      STICKY bit, never silently vanish
//   * cancellation   - a - b with a ~= b loses almost every significand bit and
//                      needs a wide leading-zero normalise
//   * rounding       - round-to-nearest-EVEN needs {L,G,sticky}: exact-half
//                      ties round toward the even significand, and a round-up
//                      can carry all the way out of the significand (exponent++)
//   * subnormals     - denormal inputs have no hidden bit and a fixed effective
//                      exponent; a subnormal result must stop normalising at
//                      the exponent floor; a subnormal can ROUND UP into the
//                      smallest normal
//   * specials       - +-0 sign rules, x+(-x) = +0, inf arithmetic,
//                      (+inf)+(-inf) = invalid NaN, NaN propagation, overflow
//                      to inf
//
// -------- Pipeline (fixed latency LAT = 3, one result per cycle, zero bubble)
//   S1  unpack / classify -> magnitude compare+swap -> align the smaller
//       significand right by the exponent difference, collecting STICKY
//   S2  significand add (like signs) or subtract (unlike signs) -> renormalise
//       (right by 1 on carry-out, or left by the leading-zero count, clamped at
//       the subnormal exponent floor)
//   S3  round-to-nearest-even on {L,G,sticky} -> post-round carry -> pack,
//       overflow-to-infinity, exception flags
//
// -------- Interface contract
//   out_valid is exactly in_valid delayed LAT cycles. There is no back-pressure
//   and no stall: a new (in_a, in_b, in_sub) may be presented every cycle and
//   results emerge strictly in order.
//
// -------- Spec choices (frozen so an independent model can be bit-exact)
//   * NaN results are always the CANONICAL quiet NaN {0, EMAX, 1<<(MW-1)}
//     (0x7FC00000 in binary32); input NaN payloads are not propagated.
//   * out_inv (invalid)  = a signalling-NaN input, or (+inf) + (-inf)
//   * out_ovf (overflow) = rounded magnitude exceeded the largest finite value
//                          (result is forced to +-inf); implies out_inx
//   * out_unf (underflow)= the delivered result is subnormal-or-zero AND inexact
//   * out_inx (inexact)  = a nonzero guard/sticky was discarded, or overflow
//   Rounding mode is round-to-nearest, ties-to-even only (no mode input).
//
// Parameterised on EW/MW so the same datapath is a generic binary
// floating-point adder; the defaults (8, 23) are IEEE-754 binary32, which is
// the configuration the testbench verifies.
// ============================================================================
`timescale 1ns/1ps

module fp32_add #(
    parameter int unsigned EW = 8,                  // exponent width
    parameter int unsigned MW = 23                  // stored mantissa width
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---- request (one per cycle, no back-pressure) ----
    input  logic                in_valid,
    input  logic                in_sub,             // 0: a+b   1: a-b
    input  logic [EW+MW:0]      in_a,
    input  logic [EW+MW:0]      in_b,

    // ---- result, LAT cycles later ----
    output logic                out_valid,
    output logic [EW+MW:0]      out_z,
    output logic                out_inv,            // invalid operation
    output logic                out_ovf,            // overflow -> +-inf
    output logic                out_unf,            // underflow (tiny+inexact)
    output logic                out_inx             // inexact
);

    // ------------------------------------------------------------------
    // Derived geometry.
    // ------------------------------------------------------------------
    localparam int unsigned W    = 1 + EW + MW;     // 32
    localparam int unsigned SIG  = MW + 1;          // 24 : hidden bit + mantissa
    localparam int unsigned WS   = SIG + 3;         // 27 : SIG | guard | round | sticky
    localparam int unsigned XW   = EW + 2;          // 10 : exponent working width
    localparam logic [EW-1:0] EMAX = {EW{1'b1}};    // 255 : inf / NaN exponent
    localparam logic [MW-1:0] QNAN_M = {1'b1, {MW-1{1'b0}}};   // quiet-NaN payload

    localparam int unsigned LAT = 3;

    // ==================================================================
    // Stage 1 : unpack, classify, magnitude compare/swap, align
    // ==================================================================
    logic           s1_valid;
    logic           s1_sign;                // sign of the larger-magnitude term
    logic [XW-1:0]  s1_exp;                 // biased exponent of the larger term
    logic [WS-1:0]  s1_big, s1_sml;         // aligned operands (GRS in low 3 bits)
    logic           s1_like;                // 1: significand ADD, 0: SUBTRACT
    logic           s1_spec;                // stage-1 already knows the answer
    logic [W-1:0]   s1_spec_z;
    logic           s1_spec_inv;

    always @(*) begin : s1_comb
        // ---- unpack ----
        logic           sa, sb;
        logic [EW-1:0]  ea, eb;
        logic [MW-1:0]  ma, mb;
        logic           bs;                 // b's sign after applying in_sub
        logic           a_zero, b_zero, a_inf, b_inf, a_nan, b_nan, a_snan, b_snan;
        logic [SIG-1:0] siga, sigb;
        logic [XW-1:0]  efa, efb;
        logic           a_ge;               // |a| >= |b|
        logic           s_big, s_sml;
        logic [XW-1:0]  e_big, e_sml, ediff, dsh;
        logic [SIG-1:0] sig_big, sig_sml;
        logic [WS-1:0]  sml_f, sml_sh, lo_mask;
        logic           sticky;

        {sa, ea, ma} = in_a;
        {sb, eb, mb} = in_b;
        bs = sb ^ in_sub;                   // subtraction == add with b negated

        a_zero = (ea == '0)   && (ma == '0);
        b_zero = (eb == '0)   && (mb == '0);
        a_inf  = (ea == EMAX) && (ma == '0);
        b_inf  = (eb == EMAX) && (mb == '0);
        a_nan  = (ea == EMAX) && (ma != '0);
        b_nan  = (eb == EMAX) && (mb != '0);
        a_snan = a_nan && !ma[MW-1];        // MSB of payload clear => signalling
        b_snan = b_nan && !mb[MW-1];

        // Subnormals have no hidden bit and an effective exponent of 1.
        siga = {(ea != '0), ma};
        sigb = {(eb != '0), mb};
        efa  = (ea == '0) ? {{XW-1{1'b0}}, 1'b1} : {{XW-EW{1'b0}}, ea};
        efb  = (eb == '0) ? {{XW-1{1'b0}}, 1'b1} : {{XW-EW{1'b0}}, eb};

        // ---- special-case resolution (priority order matters) ----
        s1_spec     = 1'b1;
        s1_spec_inv = 1'b0;
        s1_spec_z   = {1'b0, EMAX, QNAN_M};
        if (a_nan || b_nan) begin
            s1_spec_inv = a_snan || b_snan;                   // sNaN raises invalid
        end
        else if (a_inf && b_inf) begin
            if (sa != bs) s1_spec_inv = 1'b1;                 // inf - inf = NaN
            else          s1_spec_z   = {sa, EMAX, {MW{1'b0}}};
        end
        else if (a_inf)  s1_spec_z = {sa, EMAX, {MW{1'b0}}};
        else if (b_inf)  s1_spec_z = {bs, EMAX, {MW{1'b0}}};
        else if (a_zero && b_zero)
                         s1_spec_z = {(sa & bs), {EW{1'b0}}, {MW{1'b0}}};
        else if (a_zero) s1_spec_z = {bs, eb, mb};
        else if (b_zero) s1_spec_z = {sa, ea, ma};
        else             s1_spec   = 1'b0;                    // real arithmetic

        // ---- magnitude compare and swap so "big" holds the larger term ----
        a_ge = (efa > efb) || ((efa == efb) && (siga >= sigb));
        s_big   = a_ge ? sa   : bs;
        s_sml   = a_ge ? bs   : sa;
        e_big   = a_ge ? efa  : efb;
        e_sml   = a_ge ? efb  : efa;
        sig_big = a_ge ? siga : sigb;
        sig_sml = a_ge ? sigb : siga;

        // ---- align: shift the smaller significand right, OR-ing out a sticky --
        // Any shift >= WS behaves identically (result 0, sticky = "was nonzero"),
        // so the shifter is clamped at WS.
        ediff = e_big - e_sml;
        dsh   = (ediff > XW'(WS)) ? XW'(WS) : ediff;

        sml_f   = {sig_sml, 3'b000};
        sml_sh  = sml_f >> dsh;
        lo_mask = ~({WS{1'b1}} << dsh);     // bits about to be shifted out
        sticky  = |(sml_f & lo_mask);

        s1_sign = s_big;
        s1_exp  = e_big;
        s1_big  = {sig_big, 3'b000};
        s1_sml  = sml_sh | {{WS-1{1'b0}}, sticky};
        s1_like = (s_big == s_sml);
    end

    logic           s1_q_valid, s1_q_sign, s1_q_like, s1_q_spec, s1_q_spec_inv;
    logic [XW-1:0]  s1_q_exp;
    logic [WS-1:0]  s1_q_big, s1_q_sml;
    logic [W-1:0]   s1_q_spec_z;

    always_ff @(posedge clk or negedge rst_n) begin : s1_reg
        if (!rst_n) begin
            s1_q_valid <= 1'b0;
        end
        else begin
            s1_q_valid    <= in_valid;
            s1_q_sign     <= s1_sign;
            s1_q_exp      <= s1_exp;
            s1_q_big      <= s1_big;
            s1_q_sml      <= s1_sml;
            s1_q_like     <= s1_like;
            s1_q_spec     <= s1_spec;
            s1_q_spec_z   <= s1_spec_z;
            s1_q_spec_inv <= s1_spec_inv;
        end
    end

    // ==================================================================
    // Stage 2 : significand add / subtract, renormalise
    // ==================================================================
    // Count leading zeros above the integer bit of a WS-wide significand,
    // i.e. how far left it must shift for bit WS-1 to become 1.
    function automatic [XW-1:0] lzc (input logic [WS-1:0] v);
        int i;
        begin
            lzc = XW'(WS);                  // all-zero => saturate
            // Scan upward from the LSB: the last hit is the most-significant
            // set bit, so no early exit is needed.
            for (i = 0; i < WS; i++)
                if (v[i]) lzc = XW'(WS-1-i);
        end
    endfunction

    logic           s2_valid, s2_sign, s2_zero;
    logic [XW-1:0]  s2_exp;
    logic [WS-1:0]  s2_sig;
    logic           s2_spec, s2_spec_inv;
    logic [W-1:0]   s2_spec_z;

    always @(*) begin : s2_comb
        logic [WS:0]   sum;                 // one extra bit for the carry-out
        logic [WS-1:0] nsig;
        logic [XW-1:0] nexp, nz, sh, room;

        s2_zero = 1'b0;
        if (s1_q_like) begin
            sum = {1'b0, s1_q_big} + {1'b0, s1_q_sml};
            if (sum[WS]) begin              // carried out: renormalise right by 1
                nsig = {1'b1, sum[WS-1:1]} | {{WS-1{1'b0}}, sum[0]};   // keep sticky
                nexp = s1_q_exp + 1'b1;
            end
            else begin
                nsig = sum[WS-1:0];
                nexp = s1_q_exp;
            end
        end
        else begin
            sum = {1'b0, s1_q_big} - {1'b0, s1_q_sml};   // >= 0 : big is the larger
            if (sum[WS-1:0] == '0) begin
                s2_zero = 1'b1;             // exact cancellation x + (-x)
                nsig    = '0;
                nexp    = s1_q_exp;
            end
            else begin
                // Left-normalise, but never below the subnormal exponent floor
                // (biased effective exponent 1) - that is how a subnormal
                // result keeps its leading zeros.
                nz   = lzc(sum[WS-1:0]);
                room = s1_q_exp - 1'b1;
                sh   = (nz > room) ? room : nz;
                nsig = sum[WS-1:0] << sh;
                nexp = s1_q_exp - sh;
            end
        end

        s2_sign     = s1_q_sign;
        s2_exp      = nexp;
        s2_sig      = nsig;
        s2_spec     = s1_q_spec;
        s2_spec_z   = s1_q_spec_z;
        s2_spec_inv = s1_q_spec_inv;
        s2_valid    = s1_q_valid;
    end

    logic           s2_q_valid, s2_q_sign, s2_q_zero, s2_q_spec, s2_q_spec_inv;
    logic [XW-1:0]  s2_q_exp;
    logic [WS-1:0]  s2_q_sig;
    logic [W-1:0]   s2_q_spec_z;

    always_ff @(posedge clk or negedge rst_n) begin : s2_reg
        if (!rst_n) begin
            s2_q_valid <= 1'b0;
        end
        else begin
            s2_q_valid    <= s2_valid;
            s2_q_sign     <= s2_sign;
            s2_q_exp      <= s2_exp;
            s2_q_sig      <= s2_sig;
            s2_q_zero     <= s2_zero;
            s2_q_spec     <= s2_spec;
            s2_q_spec_z   <= s2_spec_z;
            s2_q_spec_inv <= s2_spec_inv;
        end
    end

    // ==================================================================
    // Stage 3 : round-to-nearest-even, pack, flags
    // ==================================================================
    logic [W-1:0] s3_z;
    logic         s3_inv, s3_ovf, s3_unf, s3_inx;

    always @(*) begin : s3_comb
        logic          l, g, st, up;
        logic [SIG:0]  rnd;                 // one extra bit for the round carry
        logic [XW-1:0] rexp;
        logic          inx;

        l   = s2_q_sig[3];
        g   = s2_q_sig[2];
        st  = |s2_q_sig[1:0];
        inx = g | st;
        up  = g & (l | st);                 // ties-to-even

        rnd  = {1'b0, s2_q_sig[WS-1:3]} + {{SIG{1'b0}}, up};
        rexp = s2_q_exp;
        if (rnd[SIG]) begin                 // round carried out of the significand
            rnd  = rnd >> 1;
            rexp = rexp + 1'b1;
        end

        s3_inv = 1'b0;
        s3_ovf = 1'b0;
        s3_unf = 1'b0;
        s3_inx = 1'b0;

        if (s2_q_spec) begin
            s3_z   = s2_q_spec_z;
            s3_inv = s2_q_spec_inv;
        end
        else if (s2_q_zero) begin
            s3_z = {1'b0, {EW{1'b0}}, {MW{1'b0}}};       // x + (-x) = +0
        end
        else if (rnd[SIG-1:0] == '0) begin
            s3_z   = {s2_q_sign, {EW{1'b0}}, {MW{1'b0}}};
            s3_unf = inx;
            s3_inx = inx;
        end
        else if (rnd[SIG-1]) begin                       // normal (hidden bit set)
            if (rexp >= XW'(EMAX)) begin                 // overflow -> infinity
                s3_z   = {s2_q_sign, EMAX, {MW{1'b0}}};
                s3_ovf = 1'b1;
                s3_inx = 1'b1;
            end
            else begin
                s3_z   = {s2_q_sign, rexp[EW-1:0], rnd[MW-1:0]};
                s3_inx = inx;
            end
        end
        else begin                                       // subnormal result
            s3_z   = {s2_q_sign, {EW{1'b0}}, rnd[MW-1:0]};
            s3_unf = inx;
            s3_inx = inx;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : s3_reg
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_z     <= '0;
            out_inv   <= 1'b0;
            out_ovf   <= 1'b0;
            out_unf   <= 1'b0;
            out_inx   <= 1'b0;
        end
        else begin
            out_valid <= s2_q_valid;
            out_z     <= s3_z;
            out_inv   <= s3_inv;
            out_ovf   <= s3_ovf;
            out_unf   <= s3_unf;
            out_inx   <= s3_inx;
        end
    end

    // LAT is exported for the testbench's fixed-latency contract; it is a
    // structural property of the three register stages above.
    initial begin
        if (LAT != 3) $error("fp32_add: LAT localparam is out of step with the pipeline");
    end

endmodule
