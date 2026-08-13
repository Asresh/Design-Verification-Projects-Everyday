// ============================================================================
// fp32_ref_pkg.sv - the INDEPENDENT golden reference model for the Day28
//                   IEEE-754 binary32 adder, shared by the UVM environment
//                   and the portable Icarus testbench.
// ----------------------------------------------------------------------------
// Why this lives in its own package
//   The scoreboard, the functional-coverage model and the portable Icarus
//   testbench must all agree on exactly one definition of "the right answer".
//   Keeping that definition in one non-UVM package means the same model text
//   is used by every flow, and means the model can be self-checked before it is
//   ever pointed at the DUT.
//
// How the model is kept honest
//   fp_ref() is written as a flat, sequential, wide-integer software algorithm
//   with early returns - deliberately NOT structured like the DUT's three-stage
//   register pipeline, so a datapath mistake in one is unlikely to be mirrored
//   in the other. On top of that it is PINNED: kat_selfcheck() replays 48
//   Known-Answer vectors whose result words were produced by numpy float32,
//   i.e. by the host CPU's own IEEE-754 hardware (see docs/gen_kat.py, which
//   regenerates the table and re-verifies it, and docs/fp32_kat.txt). Every
//   testbench in this project runs kat_selfcheck() BEFORE it checks the DUT,
//   so a broken reference model fails loudly on its own rather than quietly
//   blessing broken RTL.
//
// Spec (mirrors the DUT header):
//   round-to-nearest-ties-to-even; subnormal inputs and outputs; canonical
//   quiet NaN 0x7FC00000 on every NaN result; flags
//     inv = sNaN input or (+inf)+(-inf)
//     ovf = rounded magnitude exceeded the largest finite value (-> +-inf)
//     unf = delivered result is subnormal-or-zero AND inexact
//     inx = a nonzero guard/sticky was dropped, or overflow
// ============================================================================
`timescale 1ns/1ps

package fp32_ref_pkg;

    // ---- geometry (IEEE-754 binary32) ----
    parameter int unsigned EW   = 8;                    // exponent width
    parameter int unsigned MW   = 23;                   // stored mantissa width
    parameter int unsigned W    = 1 + EW + MW;          // 32
    parameter int unsigned SIG  = MW + 1;               // 24
    parameter int unsigned WS   = SIG + 3;              // 27 = SIG | G | R | S
    parameter int unsigned XW   = EW + 2;               // 10
    parameter int unsigned BIAS = (1 << (EW-1)) - 1;    // 127

    parameter logic [EW-1:0] EMAX   = {EW{1'b1}};       // 255
    parameter logic [W-1:0]  QNAN   = {1'b0, EMAX, 1'b1, {MW-1{1'b0}}};   // 0x7FC00000

    // ---- the DUT's fixed pipeline latency (out_valid == in_valid delayed LAT) ----
    parameter int unsigned LAT = 3;

    // ---- named binary32 landmarks, used by the directed sequences and the KAT --
    parameter logic [W-1:0] FP_PZERO  = 32'h0000_0000;
    parameter logic [W-1:0] FP_NZERO  = 32'h8000_0000;
    parameter logic [W-1:0] FP_MINSUB = 32'h0000_0001;  // 2^-149, smallest subnormal
    parameter logic [W-1:0] FP_MAXSUB = 32'h007F_FFFF;  // largest subnormal
    parameter logic [W-1:0] FP_MINNRM = 32'h0080_0000;  // 2^-126, smallest normal
    parameter logic [W-1:0] FP_ONE    = 32'h3F80_0000;  //  1.0
    parameter logic [W-1:0] FP_MONE   = 32'hBF80_0000;  // -1.0
    parameter logic [W-1:0] FP_TWO    = 32'h4000_0000;  //  2.0
    parameter logic [W-1:0] FP_HALFLP = 32'h3380_0000;  // 2^-24, the exact tie vs 1.0
    parameter logic [W-1:0] FP_ULP1   = 32'h3400_0000;  // 2^-23, one ULP of 1.0
    parameter logic [W-1:0] FP_MAXNRM = 32'h7F7F_FFFF;  // largest finite
    parameter logic [W-1:0] FP_NMAXNRM= 32'hFF7F_FFFF;
    parameter logic [W-1:0] FP_PINF   = 32'h7F80_0000;
    parameter logic [W-1:0] FP_NINF   = 32'hFF80_0000;
    parameter logic [W-1:0] FP_SNAN   = 32'h7F80_0001;  // signalling NaN
    parameter logic [W-1:0] FP_QNAN   = 32'h7FC0_0000;

    // ------------------------------------------------------------------
    // Result of one operation: the packed word plus the four flags.
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [W-1:0] z;
        logic         inv;
        logic         ovf;
        logic         unf;
        logic         inx;
    } fp_res_t;

    // ------------------------------------------------------------------
    // Operand classification - drives functional coverage and the log text.
    // ------------------------------------------------------------------
    typedef enum bit [2:0] {
        FPC_ZERO   = 3'd0,
        FPC_SUBNRM = 3'd1,
        FPC_NORMAL = 3'd2,
        FPC_INF    = 3'd3,
        FPC_NAN    = 3'd4
    } fp_class_e;

    function automatic fp_class_e fp_classify (input logic [W-1:0] x);
        logic [EW-1:0] e;
        logic [MW-1:0] m;
        begin
            e = x[W-2 -: EW];
            m = x[MW-1:0];
            if (e == EMAX) begin
                if (m != '0) fp_classify = FPC_NAN;
                else         fp_classify = FPC_INF;
            end
            else if (e == '0) begin
                if (m != '0) fp_classify = FPC_SUBNRM;
                else         fp_classify = FPC_ZERO;
            end
            else fp_classify = FPC_NORMAL;
        end
    endfunction

    function automatic string fp_class_name (input fp_class_e c);
        case (c)
            FPC_ZERO   : return "ZERO";
            FPC_SUBNRM : return "SUBNORMAL";
            FPC_NORMAL : return "NORMAL";
            FPC_INF    : return "INF";
            default    : return "NAN";
        endcase
    endfunction

    function automatic bit fp_is_snan (input logic [W-1:0] x);
        fp_is_snan = (fp_classify(x) == FPC_NAN) && !x[MW-1];
    endfunction

    // Compact "1.0", "+inf", "2^-149"-style rendering for readable logs.
    function automatic string fp_str (input logic [W-1:0] x);
        fp_class_e c;
        begin
            c = fp_classify(x);
            case (c)
                FPC_NAN  : return fp_is_snan(x) ? "sNaN" : "qNaN";
                FPC_INF  : return x[W-1] ? "-inf" : "+inf";
                FPC_ZERO : return x[W-1] ? "-0"   : "+0";
                default  : return $sformatf("%s0x%06h*2^%0d",
                                            x[W-1] ? "-" : "+",
                                            {(c == FPC_NORMAL), x[MW-1:0]},
                                            (c == FPC_NORMAL)
                                              ? (int'(x[W-2 -: EW]) - int'(BIAS) - int'(MW))
                                              : (1 - int'(BIAS) - int'(MW)));
            endcase
        end
    endfunction

    // ==================================================================
    // The golden model.
    // ==================================================================
    function automatic fp_res_t fp_ref (input logic [W-1:0] a,
                                        input logic [W-1:0] b,
                                        input logic         sub);
        logic           sa, sb, bs;
        logic [EW-1:0]  ea, eb;
        logic [MW-1:0]  ma, mb;
        logic           a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
        logic [SIG-1:0] siga, sigb, sig_big, sig_sml;
        logic [XW-1:0]  efa, efb, e_big, e_sml, d, expo;
        logic           s_big, s_sml, a_ge;
        logic [63:0]    big_w, sml_f, sml_w, s;      // roomy: a behavioural model
        logic           l, g, st, up, inx;
        logic [SIG:0]   rnd;                         // 25 bits: round can carry out
        fp_res_t        r;
        begin
            r.z = '0; r.inv = 1'b0; r.ovf = 1'b0; r.unf = 1'b0; r.inx = 1'b0;

            sa = a[W-1];  ea = a[W-2 -: EW];  ma = a[MW-1:0];
            sb = b[W-1];  eb = b[W-2 -: EW];  mb = b[MW-1:0];
            bs = sb ^ sub;                      // a - b  ==  a + (-b)

            a_zero = (ea == '0)   && (ma == '0);
            b_zero = (eb == '0)   && (mb == '0);
            a_inf  = (ea == EMAX) && (ma == '0);
            b_inf  = (eb == EMAX) && (mb == '0);
            a_nan  = (ea == EMAX) && (ma != '0);
            b_nan  = (eb == EMAX) && (mb != '0);

            // ---------------- special cases, in priority order ----------------
            if (a_nan || b_nan) begin
                r.z   = QNAN;
                r.inv = fp_is_snan(a) || fp_is_snan(b);
                return r;
            end
            if (a_inf && b_inf) begin
                if (sa != bs) begin r.z = QNAN; r.inv = 1'b1; end
                else                r.z = {sa, EMAX, {MW{1'b0}}};
                return r;
            end
            if (a_inf) begin r.z = {sa, EMAX, {MW{1'b0}}}; return r; end
            if (b_inf) begin r.z = {bs, EMAX, {MW{1'b0}}}; return r; end
            if (a_zero && b_zero) begin
                r.z = {(sa & bs), {EW{1'b0}}, {MW{1'b0}}};   // -0 only if both are -0
                return r;
            end
            if (a_zero) begin r.z = {bs, eb, mb}; return r; end
            if (b_zero) begin r.z = {sa, ea, ma}; return r; end

            // ---------------- both operands finite and nonzero -----------------
            // A subnormal contributes no hidden bit and behaves as exponent 1.
            siga = {(ea != '0), ma};
            sigb = {(eb != '0), mb};
            efa  = (ea == '0) ? XW'(1) : XW'(ea);
            efb  = (eb == '0) ? XW'(1) : XW'(eb);

            a_ge    = (efa > efb) || ((efa == efb) && (siga >= sigb));
            s_big   = a_ge ? sa   : bs;    s_sml   = a_ge ? bs   : sa;
            e_big   = a_ge ? efa  : efb;   e_sml   = a_ge ? efb  : efa;
            sig_big = a_ge ? siga : sigb;  sig_sml = a_ge ? sigb : siga;

            // Align, keeping a sticky OR of everything shifted past the end.
            // Any distance >= WS is indistinguishable, so it is clamped there.
            d     = ((e_big - e_sml) > XW'(WS)) ? XW'(WS) : (e_big - e_sml);
            big_w = {36'b0, sig_big, 3'b000};
            sml_f = {36'b0, sig_sml, 3'b000};
            sml_w = (sml_f >> d) | (((sml_f & ((64'd1 << d) - 64'd1)) != '0) ? 64'd1 : 64'd0);

            expo = e_big;
            if (s_big == s_sml) begin
                s = big_w + sml_w;
                if (s[WS] != 1'b0) begin        // carried out of the significand
                    s    = (s >> 1) | (s & 64'd1);
                    expo = expo + 1'b1;
                end
            end
            else begin
                s = big_w - sml_w;              // >= 0 : "big" really is the larger
                if (s == '0) begin
                    r.z = '0;                   // x + (-x) is exactly +0
                    return r;
                end
                // Left-normalise, but never past the subnormal exponent floor;
                // that floor is exactly how a subnormal result keeps its zeros.
                while ((s[WS-1] == 1'b0) && (expo > XW'(1))) begin
                    s    = s << 1;
                    expo = expo - 1'b1;
                end
            end

            // ---------------- round to nearest, ties to even -------------------
            l   = s[3];
            g   = s[2];
            st  = (s[1] | s[0]);
            inx = g | st;
            up  = g & (l | st);
            rnd = {1'b0, s[WS-1:3]} + {{SIG{1'b0}}, up};
            if (rnd[SIG] != 1'b0) begin         // round carried out
                rnd  = rnd >> 1;
                expo = expo + 1'b1;
            end

            // ---------------- pack ---------------------------------------------
            if (rnd[SIG-1:0] == '0) begin
                r.z   = {s_big, {EW{1'b0}}, {MW{1'b0}}};
                r.unf = inx;
                r.inx = inx;
            end
            else if (rnd[SIG-1] != 1'b0) begin  // hidden bit set => normal
                if (expo >= XW'(EMAX)) begin    // beyond the largest finite
                    r.z   = {s_big, EMAX, {MW{1'b0}}};
                    r.ovf = 1'b1;
                    r.inx = 1'b1;
                end
                else begin
                    r.z   = {s_big, expo[EW-1:0], rnd[MW-1:0]};
                    r.inx = inx;
                end
            end
            else begin                          // no hidden bit => subnormal
                r.z   = {s_big, {EW{1'b0}}, rnd[MW-1:0]};
                r.unf = inx;
                r.inx = inx;
            end
            return r;
        end
    endfunction

    // ==================================================================
    // Known-Answer Table (regenerate with `python3 docs/gen_kat.py`).
    // Result words are numpy float32 - the host CPU's IEEE-754 unit.
    // ==================================================================
    parameter int unsigned KAT_MAX = 64;

    logic [W-1:0] KAT_A [0:KAT_MAX-1];
    logic [W-1:0] KAT_B [0:KAT_MAX-1];
    logic         KAT_S [0:KAT_MAX-1];
    logic [W-1:0] KAT_Z [0:KAT_MAX-1];
    logic [3:0]   KAT_F [0:KAT_MAX-1];       // {inv, ovf, unf, inx}
    string        KAT_D [0:KAT_MAX-1];
    int           KAT_N = 0;

    function automatic void kat_add (input logic [W-1:0] a, input logic [W-1:0] b,
                                     input logic s, input logic [W-1:0] z,
                                     input logic [3:0] f, input string note);
        begin
            KAT_A[KAT_N] = a; KAT_B[KAT_N] = b; KAT_S[KAT_N] = s;
            KAT_Z[KAT_N] = z; KAT_F[KAT_N] = f; KAT_D[KAT_N] = note;
            KAT_N = KAT_N + 1;
        end
    endfunction

    function automatic void kat_init ();
        begin
            KAT_N = 0;
            kat_add(32'h3F800000, 32'h40000000, 1'b0, 32'h40400000, 4'b0000,
                    "1.0 + 2.0 = 3.0");
            kat_add(32'h3F800000, 32'h3F800000, 1'b1, 32'h00000000, 4'b0000,
                    "1.0 - 1.0 = +0 (exact cancellation)");
            kat_add(32'h80000000, 32'h80000000, 1'b0, 32'h80000000, 4'b0000,
                    "(-0) + (-0) = -0");
            kat_add(32'h00000000, 32'h80000000, 1'b0, 32'h00000000, 4'b0000,
                    "(+0) + (-0) = +0");
            kat_add(32'h00000000, 32'h00000000, 1'b1, 32'h00000000, 4'b0000,
                    "(+0) - (+0) = +0");
            kat_add(32'h80000000, 32'h00000000, 1'b1, 32'h80000000, 4'b0000,
                    "(-0) - (+0) = -0");
            kat_add(32'h3F800000, 32'h33800000, 1'b0, 32'h3F800000, 4'b0001,
                    "1.0 + 2^-24 : exact tie, LSB even -> stays 1.0");
            kat_add(32'h3F800001, 32'h33800000, 1'b0, 32'h3F800002, 4'b0001,
                    "(1.0+1ulp) + 2^-24 : exact tie, LSB odd -> rounds up");
            kat_add(32'h3F800000, 32'h34000000, 1'b0, 32'h3F800001, 4'b0000,
                    "1.0 + 2^-23 : exactly one ULP, exact");
            kat_add(32'h3F800000, 32'h33C00000, 1'b0, 32'h3F800001, 4'b0001,
                    "1.0 + 1.5*2^-24 : above the tie -> rounds up");
            kat_add(32'h3F800000, 32'h33800000, 1'b1, 32'h3F7FFFFF, 4'b0000,
                    "1.0 - 2^-24 : subtractive round, needs guard bit");
            kat_add(32'h71800000, 32'h0D800000, 1'b0, 32'h71800000, 4'b0001,
                    "2^100 + 2^-100 : 200-bit alignment, sticky only");
            kat_add(32'h71800000, 32'h0D800000, 1'b1, 32'h71800000, 4'b0001,
                    "2^100 - 2^-100 : sticky forces round-down");
            kat_add(32'h7F7FFFFF, 32'h00000001, 1'b0, 32'h7F7FFFFF, 4'b0001,
                    "maxfinite + minsubnormal : sticky, no change");
            kat_add(32'h3F800000, 32'h3F7FFFFF, 1'b1, 32'h33800000, 4'b0000,
                    "1.0 - (1.0-1ulp) : 23-bit cancellation");
            kat_add(32'h40000000, 32'h3FFFFFFF, 1'b1, 32'h34000000, 4'b0000,
                    "2.0 - nextbelow(2.0) : full left normalise");
            kat_add(32'h00000001, 32'h00000001, 1'b0, 32'h00000002, 4'b0000,
                    "minsub + minsub = 2*minsub");
            kat_add(32'h007FFFFF, 32'h00000001, 1'b0, 32'h00800000, 4'b0000,
                    "maxsub + minsub = minnormal (carries into normal)");
            kat_add(32'h00800000, 32'h00000001, 1'b1, 32'h007FFFFF, 4'b0000,
                    "minnormal - minsub = maxsubnormal (drops out of normal)");
            kat_add(32'h00000001, 32'h00000001, 1'b1, 32'h00000000, 4'b0000,
                    "minsub - minsub = +0");
            kat_add(32'h00800000, 32'h00800000, 1'b1, 32'h00000000, 4'b0000,
                    "minnormal - minnormal = +0");
            kat_add(32'h00800001, 32'h00800000, 1'b1, 32'h00000001, 4'b0000,
                    "(minnormal+1ulp) - minnormal = minsubnormal (drops out of normal)");
            kat_add(32'h24000000, 32'hA3FFFFFF, 1'b0, 32'h18000000, 4'b0000,
                    "near-cancelling normals -> 24-bit left normalise, exact");
            kat_add(32'h007FFFFF, 32'h007FFFFF, 1'b0, 32'h00FFFFFE, 4'b0000,
                    "maxsub + maxsub : two subnormals carry into a normal");
            kat_add(32'h00400000, 32'h00400000, 1'b0, 32'h00800000, 4'b0000,
                    "midsub + midsub : subnormal doubling stays subnormal");
            kat_add(32'h00800000, 32'h007FFFFF, 1'b1, 32'h00000001, 4'b0000,
                    "minnormal - maxsub : smallest subnormal step");
            kat_add(32'h7F7FFFFF, 32'h7F7FFFFF, 1'b0, 32'h7F800000, 4'b0101,
                    "maxfinite + maxfinite = +inf (overflow)");
            kat_add(32'h7F7FFFFF, 32'h7F7FFFFF, 1'b1, 32'h00000000, 4'b0000,
                    "maxfinite - maxfinite = +0");
            kat_add(32'hFF7FFFFF, 32'h7F7FFFFF, 1'b0, 32'h00000000, 4'b0000,
                    "-maxfinite + maxfinite = +0");
            kat_add(32'h7F7FFFFF, 32'h73000000, 1'b0, 32'h7F800000, 4'b0101,
                    "maxfinite + 2^103 : rounds up over the top -> inf");
            kat_add(32'h7F7FFFFE, 32'h73000000, 1'b0, 32'h7F7FFFFE, 4'b0001,
                    "just below maxfinite + 2^103 : rounds up, stays finite");
            kat_add(32'h3FFFFFFF, 32'h33000000, 1'b0, 32'h3FFFFFFF, 4'b0001,
                    "nextbelow(2.0) + 2^-25 : round-up carries into exp++");
            kat_add(32'h7F800000, 32'hFF800000, 1'b0, 32'h7FC00000, 4'b1000,
                    "(+inf) + (-inf) = qNaN, INVALID");
            kat_add(32'h7F800000, 32'h7F800000, 1'b1, 32'h7FC00000, 4'b1000,
                    "(+inf) - (+inf) = qNaN, INVALID");
            kat_add(32'h7F800000, 32'h7F800000, 1'b0, 32'h7F800000, 4'b0000,
                    "(+inf) + (+inf) = +inf");
            kat_add(32'h7F800000, 32'h3F800000, 1'b0, 32'h7F800000, 4'b0000,
                    "(+inf) + 1.0 = +inf");
            kat_add(32'h3F800000, 32'hFF800000, 1'b0, 32'hFF800000, 4'b0000,
                    "1.0 + (-inf) = -inf");
            kat_add(32'hFF800000, 32'h3F800000, 1'b1, 32'hFF800000, 4'b0000,
                    "(-inf) - 1.0 = -inf");
            kat_add(32'h7F800000, 32'h00000000, 1'b0, 32'h7F800000, 4'b0000,
                    "(+inf) + 0 = +inf");
            kat_add(32'h7FC00000, 32'h3F800000, 1'b0, 32'h7FC00000, 4'b0000,
                    "qNaN + 1.0 = qNaN, no flags");
            kat_add(32'h3F800000, 32'h7FC00000, 1'b1, 32'h7FC00000, 4'b0000,
                    "1.0 - qNaN = qNaN, no flags");
            kat_add(32'h7F800001, 32'h3F800000, 1'b0, 32'h7FC00000, 4'b1000,
                    "sNaN + 1.0 = qNaN, INVALID");
            kat_add(32'h7F800001, 32'h7F800000, 1'b0, 32'h7FC00000, 4'b1000,
                    "sNaN + inf = qNaN, INVALID");
            kat_add(32'h7FC00000, 32'h7F800000, 1'b0, 32'h7FC00000, 4'b0000,
                    "qNaN + inf = qNaN (NaN wins over inf)");
            kat_add(32'h00000000, 32'h3F800000, 1'b0, 32'h3F800000, 4'b0000,
                    "0 + 1.0 = 1.0");
            kat_add(32'h3F800000, 32'h00000000, 1'b1, 32'h3F800000, 4'b0000,
                    "1.0 - 0 = 1.0");
            kat_add(32'h00000000, 32'h3F800000, 1'b1, 32'hBF800000, 4'b0000,
                    "0 - 1.0 = -1.0");
            kat_add(32'hBF800000, 32'h00000000, 1'b0, 32'hBF800000, 4'b0000,
                    "-1.0 + 0 = -1.0");
        end
    endfunction

    // Replay the table through fp_ref(). Returns the number of failures, so
    // every testbench can refuse to trust the model before trusting the DUT.
    function automatic int kat_selfcheck (input bit verbose = 0);
        fp_res_t r;
        int      bad;
        int      i;
        begin
            if (KAT_N == 0) kat_init();
            bad = 0;
            for (i = 0; i < KAT_N; i++) begin
                r = fp_ref(KAT_A[i], KAT_B[i], KAT_S[i]);
                if ((r.z !== KAT_Z[i]) || ({r.inv, r.ovf, r.unf, r.inx} !== KAT_F[i])) begin
                    bad = bad + 1;
                    $display("  KAT FAIL [%0d] %s", i, KAT_D[i]);
                    $display("      a=%h b=%h %s  model z=%h f=%b  expected z=%h f=%b",
                             KAT_A[i], KAT_B[i], KAT_S[i] ? "-" : "+",
                             r.z, {r.inv, r.ovf, r.unf, r.inx}, KAT_Z[i], KAT_F[i]);
                end
                else if (verbose) begin
                    $display("  KAT ok   [%20d] %s", i, KAT_D[i]);
                end
            end
            return bad;
        end
    endfunction

endpackage
