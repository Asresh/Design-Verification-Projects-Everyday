// ============================================================================
// tb_fp32_add_dump.sv - portable, self-checking, module-based testbench for the
//                       IEEE-754 binary32 adder. Runs on Icarus Verilog (which
//                       does not implement the UVM class library or a
//                       constraint solver) and captures the committed waveform.
// ----------------------------------------------------------------------------
// This is the open-source companion to the UVM environment in fp32_add_pkg.sv.
// It carries the same three things the UVM flow relies on, in procedural form:
//
//   1. the SAME golden reference model - literally the same fp32_ref_pkg
//      function the UVM scoreboard calls, so the two flows cannot disagree
//      about what the right answer is;
//   2. a FIFO-pairing scoreboard - requests are queued as they are driven and
//      popped as results arrive, so nothing depends on knowing the latency;
//   3. procedural equivalents of the interface's concurrent SVA (fixed-latency
//      contract, causality, no-X, flag consistency, canonical NaN, and the
//      underflow-is-unreachable invariant).
//
// Phase order (the showcase runs first so the committed VCD is a short,
// readable window rather than thousands of cycles):
//
//   0  self-check the reference model against 48 numpy-generated KAT vectors
//   1  SHOWCASE      - 10 headline operations, zero-bubble  <-- the waveform
//   2  KAT replay    - the same 48 hardware-IEEE vectors, through the RTL
//   3  LANDMARKS     - 16 x 16 x {add,sub} = 512 directed operations
//   4  TIES          - round-to-nearest-EVEN half-ULP campaign
//   5  SUBNORMALS    - the exponent floor, where the hidden bit comes and goes
//   6  OVERFLOW      - the top of the range
//   7  RANDOM        - a shaped pseudo-random regression
//
// Prints "RESULT: *** PASS ***" only if every operation matched and every
// procedural checker stayed quiet.
// ============================================================================
`timescale 1ns/1ps

module tb_fp32_add_dump;

    import fp32_ref_pkg::*;

    localparam int unsigned CYC = 10;               // 100 MHz

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CYC/2) clk = ~clk;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg           in_valid = 1'b0;
    reg           in_sub   = 1'b0;
    reg  [W-1:0]  in_a     = {W{1'b0}};
    reg  [W-1:0]  in_b     = {W{1'b0}};

    wire          out_valid;
    wire [W-1:0]  out_z;
    wire          out_inv, out_ovf, out_unf, out_inx;

    // `mark` is a pure testbench annotation: it is high across the showcase
    // window so the waveform renderer can find that window in the VCD.
    reg           mark = 1'b0;

    fp32_add #(.EW(EW), .MW(MW)) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_sub    (in_sub),
        .in_a      (in_a),
        .in_b      (in_b),
        .out_valid (out_valid),
        .out_z     (out_z),
        .out_inv   (out_inv),
        .out_ovf   (out_ovf),
        .out_unf   (out_unf),
        .out_inx   (out_inx)
    );

    // ------------------------------------------------------------------
    // Scoreboard state: a small circular queue of in-flight requests.
    // Only LAT+1 operations can ever be outstanding, so 64 entries is
    // enormously generous; the queue exists so that NOTHING in the checker
    // depends on knowing what LAT is.
    // ------------------------------------------------------------------
    localparam int unsigned QD = 64;

    reg  [W-1:0] q_a   [0:QD-1];
    reg  [W-1:0] q_b   [0:QD-1];
    reg          q_sub [0:QD-1];
    reg  [W-1:0] q_z   [0:QD-1];
    reg  [3:0]   q_f   [0:QD-1];        // {inv, ovf, unf, inx}

    integer q_head = 0;                 // next slot to pop
    integer q_tail = 0;                 // next slot to fill
    integer q_cnt  = 0;

    integer n_driven   = 0;
    integer n_checked  = 0;
    integer n_err      = 0;

    // observation counters that become the end-of-test summary
    integer n_inexact  = 0;
    integer n_overflow = 0;
    integer n_invalid  = 0;
    integer n_sub_res  = 0;
    integer n_zero_res = 0;
    integer n_inf_res  = 0;
    integer n_nan_res  = 0;
    integer n_norm_res = 0;
    integer n_sub_arg  = 0;
    integer n_tie_ops  = 0;

    string  phase_name = "init";

    // ------------------------------------------------------------------
    // Driver: one request per posedge, zero bubble. Pushes the expected
    // result (from the shared golden model) as it drives.
    // ------------------------------------------------------------------
    task do_op (input logic [W-1:0] a, input logic [W-1:0] b, input logic sub);
        fp_res_t e;
        begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_a     <= a;
            in_b     <= b;
            in_sub   <= sub;

            e = fp_ref(a, b, sub);
            if (q_cnt >= QD) begin
                n_err = n_err + 1;
                $display("[%0t] FATAL: request queue overflow (%0d outstanding)", $time, q_cnt);
            end
            else begin
                q_a  [q_tail] = a;
                q_b  [q_tail] = b;
                q_sub[q_tail] = sub;
                q_z  [q_tail] = e.z;
                q_f  [q_tail] = {e.inv, e.ovf, e.unf, e.inx};
                q_tail = (q_tail + 1) % QD;
                q_cnt  = q_cnt + 1;
            end

            n_driven = n_driven + 1;
            if (fp_classify(a) == FPC_SUBNRM) n_sub_arg = n_sub_arg + 1;
            if (fp_classify(b) == FPC_SUBNRM) n_sub_arg = n_sub_arg + 1;
        end
    endtask

    // Stop driving and let the pipeline drain.
    task idle (input integer n);
        begin
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (n) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Checker / procedural SVA. Runs on the NEGEDGE, where every registered
    // signal driven at the posedge has settled - no sampling race, and no
    // need for clocking blocks that Icarus does not fully support.
    // ------------------------------------------------------------------
    reg  vsh [0:LAT];                   // in_valid history: vsh[k] = k cycles ago
    integer i;

    logic [W-1:0] xz;
    logic [3:0]   xf;
    fp_class_e    cz;

    always @(negedge clk) begin
        if (!rst_n) begin
            for (i = 0; i <= LAT; i = i + 1) vsh[i] = 1'b0;
        end
        else begin
            // ---- shift the in_valid history, newest first ----
            for (i = LAT; i > 0; i = i - 1) vsh[i] = vsh[i-1];
            vsh[0] = in_valid;

            // ---- SVA equivalent 1: the fixed-latency contract ----
            // out_valid this cycle must equal in_valid exactly LAT cycles ago.
            // This covers both directions at once: a missing result AND a
            // spurious one.
            if (out_valid !== vsh[LAT]) begin
                n_err = n_err + 1;
                $display("[%0t] ERROR latency contract: out_valid=%b but in_valid %0d cycles ago was %b",
                         $time, out_valid, LAT, vsh[LAT]);
            end

            if (out_valid === 1'b1) begin
                // ---- SVA equivalent 2: no X on the result ----
                // Each signal is tested on its own rather than as one concatenation:
                // Icarus mis-evaluates $isunknown() over a concatenation of a
                // vector port with single-bit ports, and reports a false X.
                if ($isunknown(out_z)   || $isunknown(out_inv) ||
                    $isunknown(out_ovf) || $isunknown(out_unf) || $isunknown(out_inx)) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR X on the result bus: z=%h flags=%b%b%b%b",
                             $time, out_z, out_inv, out_ovf, out_unf, out_inx);
                end

                cz = fp_classify(out_z);

                // ---- SVA equivalent 3: canonical NaN only ----
                if ((cz == FPC_NAN) && (out_z !== QNAN)) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR non-canonical NaN result %h", $time, out_z);
                end

                // ---- SVA equivalent 4: flag consistency ----
                if (out_ovf === 1'b1) begin
                    if (out_inx !== 1'b1) begin
                        n_err = n_err + 1;
                        $display("[%0t] ERROR out_ovf without out_inx", $time);
                    end
                    if (cz != FPC_INF) begin
                        n_err = n_err + 1;
                        $display("[%0t] ERROR out_ovf but result %h is not an infinity",
                                 $time, out_z);
                    end
                end
                if ((out_inv === 1'b1) && (out_z !== QNAN)) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR out_inv but result %h is not the canonical qNaN",
                             $time, out_z);
                end
                if ((cz == FPC_INF || cz == FPC_NAN) && (out_ovf !== 1'b1) && (out_inx === 1'b1)) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR inf/NaN result flagged inexact without overflow", $time);
                end

                // ---- SVA equivalent 5: underflow is unreachable ----
                // The exact sum of two binary32 values is always a multiple of
                // 2^-149, so it is exactly representable whenever it is
                // subnormal: add/sub can never round in the subnormal range.
                if (out_unf === 1'b1) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR out_unf asserted - underflow is unreachable for binary32 add/sub",
                             $time);
                end

                // ---- reference-model comparison, paired in arrival order ----
                if (q_cnt == 0) begin
                    n_err = n_err + 1;
                    $display("[%0t] ERROR result %h with no outstanding request", $time, out_z);
                end
                else begin
                    xz = q_z[q_head];
                    xf = q_f[q_head];
                    n_checked = n_checked + 1;
                    if ((out_z !== xz) ||
                        ({out_inv, out_ovf, out_unf, out_inx} !== xf)) begin
                        n_err = n_err + 1;
                        if (n_err < 25) begin
                            $display("[%0t] MISMATCH (%s) a=%h b=%h %s",
                                     $time, phase_name, q_a[q_head], q_b[q_head],
                                     q_sub[q_head] ? "sub" : "add");
                            $display("            %s %s %s",
                                     fp_str(q_a[q_head]), q_sub[q_head] ? "-" : "+",
                                     fp_str(q_b[q_head]));
                            $display("            got      z=%h (%s) flags=%b",
                                     out_z, fp_str(out_z),
                                     {out_inv, out_ovf, out_unf, out_inx});
                            $display("            expected z=%h (%s) flags=%b",
                                     xz, fp_str(xz), xf);
                        end
                    end
                    q_head = (q_head + 1) % QD;
                    q_cnt  = q_cnt - 1;
                end

                // ---- bookkeeping ----
                if (out_inx === 1'b1) n_inexact  = n_inexact  + 1;
                if (out_ovf === 1'b1) n_overflow = n_overflow + 1;
                if (out_inv === 1'b1) n_invalid  = n_invalid  + 1;
                case (cz)
                    FPC_NAN    : n_nan_res  = n_nan_res  + 1;
                    FPC_INF    : n_inf_res  = n_inf_res  + 1;
                    FPC_SUBNRM : n_sub_res  = n_sub_res  + 1;
                    FPC_ZERO   : n_zero_res = n_zero_res + 1;
                    default    : n_norm_res = n_norm_res + 1;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Shaped pseudo-random operand generation.
    // Icarus has no constraint solver, so the distribution the UVM
    // fp_txn constraints describe is reproduced here procedurally: uniform
    // 32-bit patterns are almost always big normals, which would leave the
    // interesting regions untouched.
    // ------------------------------------------------------------------
    localparam int unsigned MANT_MASK = (1 << MW) - 1;

    function automatic [W-1:0] mk_fp (input integer sgn, input integer e,
                                      input integer m);
        mk_fp = {sgn[0], e[EW-1:0], m[MW-1:0]};
    endfunction

    // Returns a shaped {a,b} pair for the given kind, packed as 2*W bits.
    function automatic [2*W-1:0] gen_pair (input integer kind);
        integer sa, sb, ea, eb, ma, mb, d;
        logic [W-1:0] a, b;
        begin
            sa = $urandom_range(1, 0);
            sb = $urandom_range(1, 0);
            ma = $urandom() & MANT_MASK;
            mb = $urandom() & MANT_MASK;
            case (kind)
                0 : begin                                   // ANY
                        ea = $urandom_range(255, 0);
                        eb = $urandom_range(255, 0);
                    end
                1 : begin                                   // NEAR: gap <= 2
                        ea = $urandom_range(254, 1);
                        d  = $urandom_range(2, 0);
                        eb = ($urandom_range(1, 0)) ? (ea + d) : (ea - d);
                        if (eb < 1)   eb = 1;
                        if (eb > 254) eb = 254;
                    end
                2 : begin                                   // SUBNORMAL floor
                        ea = $urandom_range(2, 0);
                        eb = $urandom_range(2, 0);
                    end
                3 : begin                                   // SPECIAL
                        ea = ($urandom_range(1, 0)) ? 0 : 255;
                        eb = $urandom_range(255, 0);
                        if ($urandom_range(1, 0)) begin     // swap which side
                            d  = ea; ea = eb; eb = d;
                        end
                    end
                4 : begin                                   // TIE: exact half ULP
                        ea = $urandom_range(254, MW + 2);
                        eb = ea - (MW + 1);
                        mb = 0;
                        n_tie_ops = n_tie_ops + 1;
                    end
                5 : begin                                   // HUGEDIFF: sticky only
                        ea = $urandom_range(254, 1);
                        eb = ($urandom_range(1, 0)) ? (ea + $urandom_range(120, 31))
                                                    : (ea - $urandom_range(120, 31));
                        if (eb < 1)   eb = 1;
                        if (eb > 254) eb = 254;
                    end
                6 : begin                                   // CANCEL: same exp,
                        ea = $urandom_range(254, 1);        // near-equal mantissa
                        eb = ea;
                        mb = ma + $urandom_range(8, 0) - 4;
                        if (mb < 0)         mb = 0;
                        if (mb > MANT_MASK) mb = MANT_MASK;
                    end
                default : begin                             // HUGE -> overflow
                        ea = $urandom_range(254, 250);
                        eb = $urandom_range(254, 250);
                    end
            endcase
            a = mk_fp(sa, ea, ma);
            b = mk_fp(sb, eb, mb);
            gen_pair = {a, b};
        end
    endfunction

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    logic [W-1:0] LM [0:15];            // the named landmarks
    logic [2*W-1:0] pair;
    integer k, j, s, e, eh, eq, kind, bad_kat;
    logic [W-1:0] va, vb, vhalf, vquarter, vthreeq;
    logic [MW-1:0] vm;

    initial begin
        $dumpfile("tb_fp32_add_dump.vcd");
        $dumpvars(0, tb_fp32_add_dump);

        LM[ 0] = FP_PZERO;  LM[ 1] = FP_NZERO;  LM[ 2] = FP_MINSUB;  LM[ 3] = FP_MAXSUB;
        LM[ 4] = FP_MINNRM; LM[ 5] = FP_ONE;    LM[ 6] = FP_MONE;    LM[ 7] = FP_TWO;
        LM[ 8] = FP_HALFLP; LM[ 9] = FP_ULP1;   LM[10] = FP_MAXNRM;  LM[11] = FP_NMAXNRM;
        LM[12] = FP_PINF;   LM[13] = FP_NINF;   LM[14] = FP_SNAN;    LM[15] = FP_QNAN;

        $display("================================================================");
        $display(" Day28 - IEEE-754 binary32 adder/subtractor : self-checking TB");
        $display("         EW=%0d MW=%0d  W=%0d  fixed latency LAT=%0d", EW, MW, W, LAT);
        $display("================================================================");

        // ---------------- phase 0 : pin the reference model ----------------
        // Before the model is allowed to judge the DUT, it has to reproduce
        // answers produced by the host CPU's own IEEE-754 hardware.
        kat_init();
        bad_kat = kat_selfcheck(0);
        if (bad_kat != 0) begin
            $display("FATAL: the reference model failed %0d of %0d Known-Answer vectors.",
                     bad_kat, KAT_N);
            $display("RESULT: *** FAIL ***");
            $finish;
        end
        $display("[phase 0] reference model reproduced all %0d numpy-generated KAT vectors",
                 KAT_N);

        // ---------------- release reset ----------------
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------- phase 1 : SHOWCASE (the committed waveform) ------
        phase_name = "showcase";
        mark = 1'b1;
        $display("[phase 1] showcase: 10 headline operations, back to back");
        do_op(FP_ONE,    FP_TWO,    1'b0);   // 1.0 + 2.0 = 3.0
        do_op(FP_ONE,    FP_ONE,    1'b1);   // exact cancellation -> +0
        do_op(FP_ONE,    FP_HALFLP, 1'b0);   // exact tie -> rounds to even (stays 1.0)
        do_op(FP_ONE,    FP_ULP1,   1'b0);   // one ULP -> exact
        do_op(FP_MAXSUB, FP_MINSUB, 1'b0);   // subnormal carries into the normals
        do_op(FP_MINNRM, FP_MINSUB, 1'b1);   // and drops back out again
        do_op(FP_MAXNRM, FP_MAXNRM, 1'b0);   // overflow -> +inf
        do_op(FP_PINF,   FP_NINF,   1'b0);   // inf - inf -> INVALID, qNaN
        do_op(FP_SNAN,   FP_ONE,    1'b0);   // sNaN -> INVALID, canonical qNaN
        do_op(FP_NZERO,  FP_NZERO,  1'b0);   // (-0) + (-0) = -0
        idle(LAT + 3);
        mark = 1'b0;

        // The committed PNG only needs this window; stopping the dump here
        // keeps the VCD small while remaining a genuine captured trace.
        $dumpoff;

        // ---------------- phase 2 : KAT replay through the RTL -------------
        phase_name = "kat";
        $display("[phase 2] KAT replay: %0d hardware-IEEE vectors through the RTL", KAT_N);
        for (k = 0; k < KAT_N; k = k + 1)
            do_op(KAT_A[k], KAT_B[k], KAT_S[k]);
        idle(LAT + 2);

        // ---------------- phase 3 : landmark cross-product -----------------
        phase_name = "landmarks";
        $display("[phase 3] landmarks: 16 x 16 x {add,sub} = 512 directed operations");
        for (k = 0; k < 16; k = k + 1)
            for (j = 0; j < 16; j = j + 1)
                for (s = 0; s < 2; s = s + 1)
                    do_op(LM[k], LM[j], s[0]);
        idle(LAT + 2);

        // ---------------- phase 4 : round-to-nearest-even ties -------------
        phase_name = "ties";
        $display("[phase 4] ties: exact half-ULP campaign (round-to-nearest-EVEN)");
        for (k = 0; k < 120; k = k + 1) begin
            e  = $urandom_range(254, MW + 2);
            eh = e - (MW + 1);                       // 0.5 ULP of a -> perfect tie
            eq = e - (MW + 2);                       // 0.25 ULP of a
            vm = $urandom() & MANT_MASK;
            vm[0] = k[0];                            // alternate even/odd LSB
            va       = mk_fp($urandom_range(1, 0), e,  vm);
            vhalf    = mk_fp($urandom_range(1, 0), eh, 0);
            vquarter = mk_fp($urandom_range(1, 0), eq, 0);
            vthreeq  = mk_fp($urandom_range(1, 0), eq, 1 << (MW-1));
            do_op(va, vhalf,    1'b0);
            do_op(va, vhalf,    1'b1);
            do_op(va, vquarter, 1'b0);
            do_op(va, vthreeq,  1'b0);
        end
        idle(LAT + 2);

        // ---------------- phase 5 : the exponent floor ---------------------
        phase_name = "subnormals";
        $display("[phase 5] subnormals: 700 operand pairs at the exponent floor");
        for (k = 0; k < 350; k = k + 1) begin
            pair = gen_pair(2);
            do_op(pair[2*W-1 -: W], pair[W-1:0], 1'b0);
            do_op(pair[2*W-1 -: W], pair[W-1:0], 1'b1);
        end
        // the exact boundary steps, deterministically
        do_op(FP_MAXSUB, FP_MINSUB, 1'b0);
        do_op(FP_MINNRM, FP_MINSUB, 1'b1);
        do_op(FP_MINNRM, FP_MAXSUB, 1'b1);
        do_op(FP_MINSUB, FP_MINSUB, 1'b1);
        do_op(FP_MAXSUB, FP_MAXSUB, 1'b0);
        idle(LAT + 2);

        // ---------------- phase 6 : the top of the range -------------------
        phase_name = "overflow";
        $display("[phase 6] overflow: 200 operand pairs near the largest finite");
        for (k = 0; k < 100; k = k + 1) begin
            pair = gen_pair(7);
            do_op(pair[2*W-1 -: W], pair[W-1:0], 1'b0);
            do_op(pair[2*W-1 -: W], pair[W-1:0], 1'b1);
        end
        do_op(FP_MAXNRM,  FP_MAXNRM, 1'b0);
        do_op(FP_NMAXNRM, FP_MAXNRM, 1'b1);
        do_op(FP_MAXNRM,  FP_MINSUB, 1'b0);
        idle(LAT + 2);

        // ---------------- phase 7 : shaped random regression --------------
        phase_name = "random";
        $display("[phase 7] random: 4000 shaped pseudo-random operations");
        for (k = 0; k < 4000; k = k + 1) begin
            kind = $urandom_range(7, 0);
            pair = gen_pair(kind);
            do_op(pair[2*W-1 -: W], pair[W-1:0], $urandom_range(1, 0));
        end
        idle(LAT + 6);

        // ---------------- report ------------------------------------------
        phase_name = "report";
        $display("================================================================");
        $display(" operations driven        : %0d", n_driven);
        $display(" operations checked       : %0d", n_checked);
        $display(" still in flight          : %0d", q_cnt);
        $display("----------------------------------------------------------------");
        $display(" inexact results          : %0d", n_inexact);
        $display(" overflow -> inf          : %0d", n_overflow);
        $display(" invalid  -> qNaN         : %0d", n_invalid);
        $display(" subnormal operands seen  : %0d", n_sub_arg);
        $display(" results  normal          : %0d", n_norm_res);
        $display(" results  subnormal       : %0d", n_sub_res);
        $display(" results  zero            : %0d", n_zero_res);
        $display(" results  infinity        : %0d", n_inf_res);
        $display(" results  NaN             : %0d", n_nan_res);
        $display(" underflow flags asserted : 0 (unreachable for binary32 add/sub)");
        $display("----------------------------------------------------------------");
        $display(" mismatches / check fails : %0d", n_err);
        $display("================================================================");

        if (n_driven != n_checked) begin
            n_err = n_err + 1;
            $display("ERROR: %0d operations driven but %0d checked", n_driven, n_checked);
        end
        if (q_cnt != 0) begin
            n_err = n_err + 1;
            $display("ERROR: %0d requests never produced a result", q_cnt);
        end

        if ((n_err == 0) && (n_checked > 0))
            $display("RESULT: *** PASS ***  (%0d operations checked against the reference model)",
                     n_checked);
        else
            $display("RESULT: *** FAIL ***  (%0d operations checked, %0d failures)",
                     n_checked, n_err);
        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------
    initial begin
        #2ms;
        $display("RESULT: *** FAIL *** (timeout in phase '%s' after %0d ops)",
                 phase_name, n_driven);
        $finish;
    end

endmodule
