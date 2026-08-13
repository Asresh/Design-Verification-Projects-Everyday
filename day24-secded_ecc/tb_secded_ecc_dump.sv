// -----------------------------------------------------------------------------
// tb_secded_ecc_dump.sv - portable, module-based, SELF-CHECKING testbench for
// the SECDED (72,64) EXTENDED-HAMMING ECC ENCODER/DECODER. Runs on open-source
// Icarus Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - ENCODE a known 64-bit word into its 72-bit
//     codeword, DECODE it clean (no error -> sbe=0,dbe=0, data restored), then
//     inject a SINGLE-bit flip (-> sbe=1, corrected data restored) and a
//     DOUBLE-bit flip (-> dbe=1, uncorrectable) so the captured VCD shows the
//     full detect/correct story,
//   * runs DIRECTED CORNERS (all-zero word, all-ones word, a flip in a Hamming
//     parity bit, a flip in the overall-parity bit, a data-bit flip, and a
//     back-to-back zero-bubble encode/decode pair),
//   * runs a large CONSTRAINED-RANDOM fault campaign - random data, random op,
//     and for DECODE a fair mix of 0 / 1 / 2 injected bit flips at random
//     positions,
//   * for every operation an independent GOLDEN reference model (a second,
//     structurally-independent extended-Hamming SECDED implementation over a
//     module-level bit buffer) computes the expected {out_code, out_data,
//     out_syndrome, out_sbe, out_dbe}, which a FIFO scoreboard checks against
//     the DUT output in arrival order,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// NOTE ON STYLE: Icarus Verilog does not accept queue/dynamic-array arguments to
// functions/tasks, so the codeword under test lives in a module-level bit buffer
// and the golden helpers take only scalar args - keeping the file fully
// Icarus-portable. The DUT builds its parity via covered-position loops; the
// golden model below builds an explicit per-position coverage test independently,
// so agreement across the whole fault campaign is a real cross-check.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in secded_ecc_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_secded_ecc_dump;

    localparam int DW    = 64;
    localparam int PIPE  = 2;
    localparam int LAT   = PIPE;
    localparam int HAM   = 7;               // ham_bits(64)
    localparam int NBASE = DW + HAM;        // 71
    localparam int CW    = NBASE + 1;       // 72

    localparam bit OP_ENC = 1'b0;
    localparam bit OP_DEC = 1'b1;

    logic               clk;
    logic               rst_n;
    logic               in_valid;
    logic               in_op;
    logic [DW-1:0]      in_data;
    logic [CW-1:0]      in_code;
    logic               out_valid;
    logic               out_op;
    logic [CW-1:0]      out_code;
    logic [DW-1:0]      out_data;
    logic [HAM-1:0]     out_syndrome;
    logic               out_sbe;
    logic               out_dbe;

    integer errors = 0;
    integer checks = 0;

    // ----------------------------------------------------------------- DUT -----
    secded_ecc #(.DW(DW), .PIPE(PIPE)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid     (in_valid),
        .in_op        (in_op),
        .in_data      (in_data),
        .in_code      (in_code),
        .out_valid    (out_valid),
        .out_op       (out_op),
        .out_code     (out_code),
        .out_data     (out_data),
        .out_syndrome (out_syndrome),
        .out_sbe      (out_sbe),
        .out_dbe      (out_dbe)
    );

    // --------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;      // 100 MHz, 10 ns period

    // ================================================================ GOLDEN ===
    // Independent extended-Hamming SECDED reference over scalar args.
    function automatic bit gis_pow2(input int p);
        gis_pow2 = (p != 0) && ((p & (p - 1)) == 0);
    endfunction

    // Encode a DW-bit word -> CW-bit codeword (bit0 = overall parity).
    function automatic [CW-1:0] g_encode(input [DW-1:0] data);
        logic [CW-1:0] base;         // base[p] used for p in 1..NBASE; base[0] unused here
        logic          acc, ovp;
        int            di, p, i;
        begin
            base = '0;
            di = 0;
            for (p = 1; p <= NBASE; p++)
                if (!gis_pow2(p)) begin base[p] = data[di]; di++; end
            for (i = 0; i < HAM; i++) begin
                acc = 1'b0;
                for (p = 1; p <= NBASE; p++)
                    if (p != (1 << i) && ((p >> i) & 1)) acc ^= base[p];
                base[1 << i] = acc;
            end
            ovp = 1'b0;
            for (p = 1; p <= NBASE; p++) ovp ^= base[p];
            g_encode = base;         // positions 1..NBASE already placed
            g_encode[0] = ovp;
        end
    endfunction

    // Syndrome value over a received codeword.
    function automatic [HAM-1:0] g_syndrome(input [CW-1:0] rcv);
        logic [HAM-1:0] s;
        logic           acc;
        int             i, p;
        begin
            for (i = 0; i < HAM; i++) begin
                acc = 1'b0;
                for (p = 1; p <= NBASE; p++) if ((p >> i) & 1) acc ^= rcv[p];
                s[i] = acc;
            end
            g_syndrome = s;
        end
    endfunction

    // Corrected codeword from a received one (mirrors the DUT's exact correction).
    function automatic [CW-1:0] g_correct(input [CW-1:0] rcv);
        logic [HAM-1:0] s;
        int             sval, i;
        logic           par;
        logic [CW-1:0]  c;
        begin
            s    = g_syndrome(rcv);
            sval = 0;
            for (i = 0; i < HAM; i++) if (s[i]) sval |= (1 << i);
            par  = ^rcv;
            c    = rcv;
            if (par) begin
                if (sval == 0)          c[0]    = c[0]    ^ 1'b1;
                else if (sval <= NBASE) c[sval] = c[sval] ^ 1'b1;
            end
            g_correct = c;
        end
    endfunction

    function automatic bit g_sbe(input [CW-1:0] rcv);
        g_sbe = ^rcv;                          // odd parity -> single-bit error
    endfunction

    function automatic bit g_dbe(input [CW-1:0] rcv);
        logic [HAM-1:0] s; s = g_syndrome(rcv);
        g_dbe = (^rcv == 1'b0) && (s != '0);   // even(>0) errors -> double-bit
    endfunction

    function automatic [DW-1:0] g_extract(input [CW-1:0] cw);
        logic [DW-1:0] d;
        int            di, p;
        begin
            d = '0; di = 0;
            for (p = 1; p <= NBASE; p++)
                if (!gis_pow2(p)) begin d[di] = cw[p]; di++; end
            g_extract = d;
        end
    endfunction

    // -------------------------------------------------- scoreboard FIFOs -------
    logic [CW-1:0]  exp_code [$];
    logic [DW-1:0]  exp_data [$];
    logic [HAM-1:0] exp_synd [$];
    logic           exp_sbe  [$];
    logic           exp_dbe  [$];
    logic           exp_op   [$];
    string          exp_desc [$];

    // ------------------------------------------------------- stimulus ----------
    task automatic send(input logic v, input logic op,
                        input logic [DW-1:0] d, input logic [CW-1:0] c);
        @(posedge clk);
        in_valid <= v;
        in_op    <= op;
        in_data  <= d;
        in_code  <= c;
    endtask

    task automatic idle(input int n);
        for (int i = 0; i < n; i++) send(1'b0, 1'b0, '0, '0);
    endtask

    // Register the golden-expected result for an ENCODE of `data`.
    task automatic do_encode(input [DW-1:0] data, input string name);
        exp_op.push_back(OP_ENC);
        exp_code.push_back(g_encode(data));
        exp_data.push_back(data);
        exp_synd.push_back('0);
        exp_sbe.push_back(1'b0);
        exp_dbe.push_back(1'b0);
        exp_desc.push_back(name);
        send(1'b1, OP_ENC, data, '0);
    endtask

    // Register the golden-expected result for a DECODE of received word `rcv`.
    task automatic do_decode(input [CW-1:0] rcv, input string name);
        logic [CW-1:0] cc; cc = g_correct(rcv);
        exp_op.push_back(OP_DEC);
        exp_code.push_back(cc);
        exp_data.push_back(g_extract(cc));
        exp_synd.push_back(g_syndrome(rcv));
        exp_sbe.push_back(g_sbe(rcv));
        exp_dbe.push_back(g_dbe(rcv));
        exp_desc.push_back(name);
        send(1'b1, OP_DEC, '0, rcv);
    endtask

    // ------------------------------------------------------ scoreboard ---------
    logic [CW-1:0]  ec; logic [DW-1:0] ed; logic [HAM-1:0] es;
    logic           eb, edb, eo; string nm;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (exp_code.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: unexpected out_valid - FIFO empty", $time);
            end else begin
                ec  = exp_code.pop_front();
                ed  = exp_data.pop_front();
                es  = exp_synd.pop_front();
                eb  = exp_sbe.pop_front();
                edb = exp_dbe.pop_front();
                eo  = exp_op.pop_front();
                nm  = exp_desc.pop_front();
                checks = checks + 1;
                if (out_op !== eo || out_code !== ec || out_data !== ed ||
                    out_syndrome !== es || out_sbe !== eb || out_dbe !== edb) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH %-20s", $time, nm);
                    $display("            DUT op=%0d code=%018h data=%016h synd=%02h sbe=%0d dbe=%0d",
                             out_op, out_code, out_data, out_syndrome, out_sbe, out_dbe);
                    $display("            EXP op=%0d code=%018h data=%016h synd=%02h sbe=%0d dbe=%0d",
                             eo, ec, ed, es, eb, edb);
                end else begin
                    $display("[%0t] OK       %-20s op=%0d data=%016h synd=%02h sbe=%0d dbe=%0d",
                             $time, nm, out_op, out_data, out_syndrome, out_sbe, out_dbe);
                end
            end
        end
    end

    // ----------------------------------------------------------- test ----------
    logic [DW-1:0] data, rdata;
    logic [CW-1:0] cw, rcv;
    int            b1, b2, nf, opsel, t;

    initial begin
        $dumpfile("tb_secded_ecc_dump.vcd");
        $dumpvars(0, tb_secded_ecc_dump);

        in_valid = 0; in_op = 0; in_data = 0; in_code = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE -----------------------------------------------
        data = 64'h0123456789ABCDEF;
        // 1) ENCODE the word -> its 72-bit codeword
        do_encode(data, "enc word");
        idle(LAT + 2);

        // 2) DECODE clean (no error) -> sbe=0, dbe=0, data restored
        cw = g_encode(data);
        do_decode(cw, "dec clean");
        idle(2);

        // 3) DECODE with a SINGLE-bit flip -> sbe=1, corrected
        rcv = cw; rcv[20] = rcv[20] ^ 1'b1;
        do_decode(rcv, "dec 1-bit");
        idle(2);

        // 4) DECODE with a DOUBLE-bit flip -> dbe=1, uncorrectable
        rcv = cw; rcv[9] = rcv[9] ^ 1'b1; rcv[40] = rcv[40] ^ 1'b1;
        do_decode(rcv, "dec 2-bit");
        idle(LAT + 3);

        // ---- DIRECTED CORNERS ------------------------------------------------
        // all-zero and all-ones data words
        do_encode(64'h0, "enc all-zero");   idle(1);
        do_encode({DW{1'b1}}, "enc all-ones"); idle(LAT + 2);

        // flip in a HAMMING PARITY bit (position 16) - still a single-bit error
        cw = g_encode(64'hDEADBEEF_CAFEF00D);
        rcv = cw; rcv[16] = rcv[16] ^ 1'b1;
        do_decode(rcv, "dec parity-bit");   idle(1);

        // flip in the OVERALL-PARITY bit (position 0) -> S==0, P==1, sbe=1
        rcv = cw; rcv[0] = rcv[0] ^ 1'b1;
        do_decode(rcv, "dec ovl-parity");   idle(1);

        // flip in a DATA bit
        rcv = cw; rcv[33] = rcv[33] ^ 1'b1;
        do_decode(rcv, "dec data-bit");     idle(LAT + 2);

        // back-to-back ZERO-BUBBLE encode then decode (no idle between)
        do_encode(64'h00FF00FF_00FF00FF, "b2b enc");
        do_decode(g_encode(64'hA5A5A5A5_5A5A5A5A), "b2b dec clean");
        idle(LAT + 3);

        // ---- CONSTRAINED-RANDOM fault campaign -------------------------------
        for (t = 0; t < 500; t++) begin
            data  = {$urandom, $urandom};
            opsel = $urandom_range(0, 1);
            if (opsel == OP_ENC) begin
                do_encode(data, $sformatf("rnd enc %0d", t));
            end else begin
                cw  = g_encode(data);
                nf  = $urandom_range(0, 2);            // inject 0, 1 or 2 flips
                rcv = cw;
                if (nf >= 1) begin
                    b1 = $urandom_range(0, CW-1);
                    rcv[b1] = rcv[b1] ^ 1'b1;
                end
                if (nf == 2) begin
                    b2 = $urandom_range(0, CW-1);
                    while (b2 == b1) b2 = $urandom_range(0, CW-1);
                    rcv[b2] = rcv[b2] ^ 1'b1;
                end
                do_decode(rcv, $sformatf("rnd dec f%0d %0d", nf, t));
            end
            if (t % 7 == 0) idle(1);                   // vary inter-op spacing
        end
        idle(LAT + 6);

        // ------------------------------------------------------- verdict -------
        if (exp_code.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected results never appeared", exp_code.size());
        end
        $display("--------------------------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errors);
        if (errors == 0 && checks > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $display("--------------------------------------------------------------");
        $finish;
    end

    // --------------------------------------------------------- timeout ---------
    initial begin
        #500000;   // 500 us global watchdog
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
