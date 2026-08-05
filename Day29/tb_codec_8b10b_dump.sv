// ============================================================================
// tb_codec_8b10b_dump.sv - portable, self-checking testbench for the 8b/10b
// codec.  No UVM, no constraint solver, no SVA - so it runs on Icarus Verilog
// as well as on the commercial simulators, and it is what captures the VCD
// that docs/make_waveform.py renders into the committed waveform image.
//
// It is the procedural twin of the UVM environment in codec_8b10b_pkg.sv:
//
//   * the same golden model (codec_8b10b_ref_pkg) drives the same two
//     expectation queues, one drained by the transmit-side checker and one by
//     the receive-side checker, both in request order;
//   * the same properties the interface asserts in SVA are checked here in
//     procedural code, including the run-length-across-a-junction property
//     and its K.28.7 exemption;
//   * the same functional-coverage questions are tallied, and the run fails
//     if a bin that the stimulus was written to hit came back empty.
//
// Stimulus, in order:
//   1. the directed showcase (this is the window the waveform image shows)
//   2. every one of the 256 data bytes
//   3. all 12 control symbols from both running-disparity states, plus
//      requests for control symbols that do not exist
//   4. the alternate-encoding corners: all six D.x.A7 symbols from both RD
//      states, and the two balanced-but-alternating entries D.07 and D.x.3
//   5. a single bit flip walked through all ten wire positions of a comma, a
//      balanced data symbol and an A7 symbol, then adjacent double flips
//   6. a long pseudo-random regression with occasional injected corruption
// ============================================================================
`timescale 1ns/1ps

module tb_codec_8b10b_dump;

    import codec_8b10b_ref_pkg::*;

    // ----------------------------------------------------------------
    // clock / reset / DUT
    // ----------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    logic       in_valid = 1'b0;
    logic [7:0] in_data  = 8'h00;
    logic       in_k     = 1'b0;
    logic [9:0] err_mask = 10'b0;

    logic       enc_valid, enc_rd, enc_kerr, enc_comma;
    logic [9:0] enc_code, wire_code;
    logic       out_valid, out_k, out_code_err, out_disp_err, out_rd, out_comma;
    logic [7:0] out_data;

    codec_8b10b dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid     (in_valid),
        .in_data      (in_data),
        .in_k         (in_k),
        .err_mask     (err_mask),
        .enc_valid    (enc_valid),
        .enc_code     (enc_code),
        .wire_code    (wire_code),
        .enc_rd       (enc_rd),
        .enc_kerr     (enc_kerr),
        .enc_comma    (enc_comma),
        .out_valid    (out_valid),
        .out_data     (out_data),
        .out_k        (out_k),
        .out_code_err (out_code_err),
        .out_disp_err (out_disp_err),
        .out_rd       (out_rd),
        .out_comma    (out_comma)
    );

    // ----------------------------------------------------------------
    // scoreboard state
    // ----------------------------------------------------------------
    bit [REF_EXP_W-1:0] tx_q [$];
    bit [REF_EXP_W-1:0] rx_q [$];
    bit [7:0]           sent_data_q [$];   // for readable mismatch messages
    bit                 sent_k_q    [$];
    bit [9:0]           sent_mask_q [$];
    bit                 sent_probe_q[$];   // starts a detection-latency window

    bit tx_rd = RD_NEG;                    // the model's two RD registers
    bit rx_rd = RD_NEG;

    int n_req = 0, n_tx = 0, n_rx = 0, errors = 0;
    int n_clean = 0, n_disp = 0, n_code = 0, n_kerr = 0;

    // ---- functional-coverage tallies --------------------------------
    int cov_kind   [3];        // 0 data, 1 legal K, 2 unencodable K request
    int cov_verd   [3];        // 0 clean, 1 disparity error, 2 code error
    int cov_nflip  [4];        // 0, 1, 2, 3+ injected bit flips
    int cov_y      [8];
    int cov_xclass [5];        // a7-data, k-capable, k28, d07, other
    int cov_cross  [3][3];     // kind x verdict
    int cov_rd     [2];        // transmit RD entering the symbol
    int cov_comma  = 0, cov_recovered = 0, cov_survived_flip = 0;

    // Per-symbol logs, so error-detection latency can be measured after the
    // run instead of guessed at during it.  8b/10b is expected to catch every
    // single-bit wire error, but not always on the symbol that carried it: a
    // flip that lands on a balanced sub-block leaves that codeword legal and
    // only shows up as a running-disparity violation one symbol later.  The
    // post-run sweep below measures exactly that, over isolated single-bit
    // flips (a corrupted symbol whose successor is clean), where the
    // attribution is unambiguous.
    int verd_log  [$];
    int mask_log  [$];
    bit probe_log [$];

    // set while the detection-latency sweep is driving
    bit latency_probe = 1'b0;

    task automatic fail(input string msg);
        errors++;
        $display("[%0t] ERROR: %s", $time, msg);
    endtask

    // ----------------------------------------------------------------
    // stimulus helpers - one symbol per cycle, zero bubbles
    // ----------------------------------------------------------------
    task automatic send(input bit [7:0] d, input bit k,
                        input bit [9:0] mask = 10'b0);
        ref_exp_t e;
        int       xc;
        @(negedge clk);
        in_valid = 1'b1;
        in_data  = d;
        in_k     = k;
        err_mask = mask;

        // step the model in request order and file both expectations
        e     = ref_link_step(d, k, mask, tx_rd, rx_rd);
        cov_rd[tx_rd]++;
        tx_rd = e.enc_rd;
        rx_rd = e.out_rd;
        tx_q.push_back(e);
        rx_q.push_back(e);
        sent_data_q.push_back(d);
        sent_k_q.push_back(k);
        sent_mask_q.push_back(mask);
        sent_probe_q.push_back(latency_probe && $countones(mask) == 1);
        n_req++;

        // coverage on the request itself
        cov_kind[k ? (e.enc_kerr ? 2 : 1) : 0]++;
        cov_nflip[($countones(mask) > 3) ? 3 : $countones(mask)]++;
        cov_y[d[7:5]]++;
        xc = 4;
        if (d[4:0] == 5'd11 || d[4:0] == 5'd13 || d[4:0] == 5'd14 ||
            d[4:0] == 5'd17 || d[4:0] == 5'd18 || d[4:0] == 5'd20) xc = 0;
        else if (d[4:0] == 5'd23 || d[4:0] == 5'd27 ||
                 d[4:0] == 5'd29 || d[4:0] == 5'd30)               xc = 1;
        else if (d[4:0] == 5'd28)                                  xc = 2;
        else if (d[4:0] == 5'd7)                                   xc = 3;
        cov_xclass[xc]++;
    endtask

    task automatic idle(input int n = 1);
        @(negedge clk);
        in_valid = 1'b0;
        in_data  = 8'h00;
        in_k     = 1'b0;
        err_mask = 10'b0;
        repeat (n - 1) @(negedge clk);
    endtask

    // ----------------------------------------------------------------
    // transmit-side checker - drains tx_q one cycle after each request
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && enc_valid) begin
            ref_exp_t e;
            if (tx_q.size() == 0) begin
                fail("codeword on the wire with no request behind it");
            end else begin
                e = tx_q.pop_front();
                n_tx++;
                if (enc_code !== e.enc_code || wire_code !== e.wire_code ||
                    enc_rd !== e.enc_rd || enc_kerr !== e.enc_kerr ||
                    enc_comma !== e.enc_comma)
                    fail($sformatf(
                        "transmit #%0d: got code=%b wire=%b rd=%0b kerr=%0b comma=%0b | expected code=%b wire=%b rd=%0b kerr=%0b comma=%0b",
                        n_tx, enc_code, wire_code, enc_rd, enc_kerr, enc_comma,
                        e.enc_code, e.wire_code, e.enc_rd, e.enc_kerr, e.enc_comma));
            end
        end
    end

    // ----------------------------------------------------------------
    // receive-side checker - drains rx_q two cycles after each request
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            ref_exp_t e;
            bit [7:0] sd;
            bit       sk;
            bit [9:0] sm;
            bit       sp;
            int       v;
            if (rx_q.size() == 0) begin
                fail("symbol out of the receiver with no request behind it");
            end else begin
                e  = rx_q.pop_front();
                sd = sent_data_q.pop_front();
                sk = sent_k_q.pop_front();
                sm = sent_mask_q.pop_front();
                sp = sent_probe_q.pop_front();
                n_rx++;
                if (out_data !== e.out_data || out_k !== e.out_k ||
                    out_code_err !== e.out_code_err ||
                    out_disp_err !== e.out_disp_err ||
                    out_rd !== e.out_rd || out_comma !== e.out_comma)
                    fail($sformatf(
                        "receive #%0d (sent %s 0x%02h mask=%b): got data=%02h k=%0b code_err=%0b disp_err=%0b rd=%0b comma=%0b | expected data=%02h k=%0b code_err=%0b disp_err=%0b rd=%0b comma=%0b",
                        n_rx, sk ? "K" : "D", sd, sm,
                        out_data, out_k, out_code_err, out_disp_err, out_rd, out_comma,
                        e.out_data, e.out_k, e.out_code_err, e.out_disp_err,
                        e.out_rd, e.out_comma));

                v = e.out_code_err ? 2 : (e.out_disp_err ? 1 : 0);
                cov_verd[v]++;
                verd_log.push_back(v);
                mask_log.push_back($countones(sm));
                probe_log.push_back(sp);
                cov_cross[sk ? (e.enc_kerr ? 2 : 1) : 0][v]++;
                if (e.out_code_err) n_code++;
                else if (e.out_disp_err) n_disp++;
                else n_clean++;
                if (e.enc_kerr) n_kerr++;
                if (e.out_comma) cov_comma++;
                if (v == 0 && e.out_data == sd && e.out_k == sk)
                    cov_recovered++;
                // A corrupted word that the receiver did not flag at all is
                // the code's known residual - 8b/10b detects most but not all
                // multi-bit errors - so it is counted and reported, not
                // treated as a failure.
                if (sm != 0 && v == 0) cov_survived_flip++;
            end
        end
    end

    // ================================================================
    // procedural equivalents of the SVA in codec_8b10b_if.sv
    // ================================================================
    logic       iv_d1, iv_d2, ev_d1;
    logic [7:0] id_d1, id_d2;
    logic       ik_d1, ik_d2;
    logic [9:0] prev_code;
    logic       prev_code_vld, prev_was_k287, prev_kerr;
    logic       enc_rd_d1, out_rd_d1;

    // Icarus mis-evaluates $isunknown() applied directly to a concatenation,
    // so the checker collects the bits into a variable first.  Same check,
    // portable everywhere.
    logic [22:0] tx_bits;
    logic [12:0] rx_bits;

    function automatic int longest_run20(input logic [19:0] w);
        int run, best;
        run  = 1;
        best = 1;
        for (int i = 18; i >= 0; i--) begin
            run = (w[i] === w[i+1]) ? run + 1 : 1;
            if (run > best) best = run;
        end
        return best;
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            iv_d1 <= 1'b0; iv_d2 <= 1'b0; ev_d1 <= 1'b0;
            prev_code_vld <= 1'b0; prev_was_k287 <= 1'b0; prev_kerr <= 1'b0;
        end else begin
            int run;

            // ---- fixed-latency pipeline contract ----
            if (enc_valid !== iv_d1)
                fail($sformatf("enc_valid=%0b but the request one cycle ago was %0b",
                               enc_valid, iv_d1));
            if (out_valid !== ev_d1)
                fail($sformatf("out_valid=%0b but enc_valid one cycle ago was %0b",
                               out_valid, ev_d1));

            if (enc_valid) begin
                // ---- no X on the transmit side ----
                tx_bits = {enc_code, wire_code, enc_rd, enc_kerr, enc_comma};
                if ($isunknown(tx_bits))
                    fail($sformatf("X on the transmit side while valid: code=%b wire=%b rd=%b kerr=%b comma=%b",
                                   enc_code, wire_code, enc_rd, enc_kerr, enc_comma));

                if (!enc_kerr) begin
                    // ---- P1: every codeword is DC-bounded ----
                    if ($countones(enc_code) < 4 || $countones(enc_code) > 6)
                        fail($sformatf("codeword %b has %0d ones - not DC-bounded",
                                       enc_code, $countones(enc_code)));

                    // ---- P3: no run of 6 across a codeword junction ----
                    // Exempt when the previous symbol was K.28.7: the only
                    // legal symbol the standard restricts, and the exemption
                    // is derived rather than assumed - docs/gen_kat.py sweeps
                    // every legal junction and reports exactly which
                    // successors K.28.7 may not precede.
                    if (prev_code_vld && !prev_kerr && !prev_was_k287) begin
                        run = longest_run20({prev_code, enc_code});
                        if (run > 5)
                            fail($sformatf("run of %0d bits across the %b|%b junction",
                                           run, prev_code, enc_code));
                    end
                end

                // ---- P5: the comma belongs to K.28.1/.5/.7 alone ----
                if (enc_comma && !(ik_d1 && id_d1[4:0] == 5'd28 &&
                                   (id_d1[7:5] == 3'd1 || id_d1[7:5] == 3'd5 ||
                                    id_d1[7:5] == 3'd7)))
                    fail($sformatf("comma on the wire from request %s 0x%02h",
                                   ik_d1 ? "K" : "D", id_d1));

                // ---- an unencodable request stays off the wire ----
                if (enc_kerr) begin
                    if (!ik_d1)
                        fail("kerr raised for a data request");
                    if (enc_code !== 10'b0)
                        fail($sformatf("unencodable request put %b on the wire", enc_code));
                    if (enc_rd !== enc_rd_d1)
                        fail("unencodable request disturbed the transmit RD");
                end

                prev_code     <= enc_code;
                prev_code_vld <= 1'b1;
                prev_kerr     <= enc_kerr;
                prev_was_k287 <= ik_d1 && (id_d1 == 8'hFC);
            end

            // ---- RD only moves on a valid symbol ----
            if (!iv_d1 && enc_rd !== enc_rd_d1)
                fail("transmit RD moved without a symbol");
            if (!ev_d1 && out_rd !== out_rd_d1)
                fail("receive RD moved without a symbol");

            if (out_valid) begin
                rx_bits = {out_data, out_k, out_code_err, out_disp_err,
                           out_rd, out_comma};
                if ($isunknown(rx_bits))
                    fail($sformatf("X on the receive side while valid: data=%b k=%b ce=%b de=%b rd=%b comma=%b",
                                   out_data, out_k, out_code_err, out_disp_err,
                                   out_rd, out_comma));
                // ---- the two error classes are distinct verdicts ----
                if (out_code_err && out_disp_err)
                    fail("code error and disparity error reported together");
                // ---- a word that is not in the code carries no symbol ----
                if (out_code_err && (out_data !== 8'h00 || out_k !== 1'b0))
                    fail($sformatf("code error still produced symbol %02h k=%0b",
                                   out_data, out_k));
            end

            iv_d1 <= in_valid;  iv_d2 <= iv_d1;
            id_d1 <= in_data;   id_d2 <= id_d1;
            ik_d1 <= in_k;      ik_d2 <= ik_d1;
            ev_d1 <= enc_valid;
        end
        enc_rd_d1 <= enc_rd;
        out_rd_d1 <= out_rd;
    end

    // ================================================================
    // stimulus
    // ================================================================
    // The twelve legal control symbols (K.28.0..7 then K.{23,27,29,30}.7) and
    // the six data symbols that need the alternate D.x.A7 3b/4b encoding.
    // Written as functions rather than array parameters so the file compiles
    // on simulators without unpacked-array parameter support.
    function automatic bit [7:0] k_legal_sym(input int i);
        case (i)
            0: k_legal_sym = 8'h1C;  // K.28.0
            1: k_legal_sym = 8'h3C;  // K.28.1
            2: k_legal_sym = 8'h5C;  // K.28.2
            3: k_legal_sym = 8'h7C;  // K.28.3
            4: k_legal_sym = 8'h9C;  // K.28.4
            5: k_legal_sym = 8'hBC;  // K.28.5
            6: k_legal_sym = 8'hDC;  // K.28.6
            7: k_legal_sym = 8'hFC;  // K.28.7
            8: k_legal_sym = 8'hF7;  // K.23.7
            9: k_legal_sym = 8'hFB;  // K.27.7
            10:k_legal_sym = 8'hFD;  // K.29.7
            default: k_legal_sym = 8'hFE; // K.30.7
        endcase
    endfunction

    function automatic bit [7:0] a7_sym(input int i);
        case (i)
            0: a7_sym = 8'hEB;  // D.11.7
            1: a7_sym = 8'hED;  // D.13.7
            2: a7_sym = 8'hEE;  // D.14.7
            3: a7_sym = 8'hF1;  // D.17.7
            4: a7_sym = 8'hF2;  // D.18.7
            default: a7_sym = 8'hF4; // D.20.7
        endcase
    endfunction

    // How many symbols the detection-latency sweep leaves clean after each
    // injected flip before it gives up looking for the resulting error.
    localparam int LAT_WINDOW = 8;

    // marker so the waveform renderer can find the showcase window in the VCD
    logic   mark = 1'b0;
    integer showcase_start, showcase_end;

    int seed = 32'd29;

    function automatic bit [7:0] rnd8();
        rnd8 = $random(seed);
    endfunction

    function automatic int rnd_range(input int n);
        int v;
        v = $random(seed) % n;
        return (v < 0) ? -v : v;
    endfunction

    initial begin
        int bad, want;

        $dumpfile("tb_codec_8b10b_dump.vcd");
        $dumpvars(0, tb_codec_8b10b_dump);

        $display("========================================================");
        $display(" Day29 - 8b/10b encoder/decoder, self-checking testbench");
        $display("========================================================");

        // ---- what checks the checker -------------------------------
        $display("\n[1] reference-model self-check");
        bad  = property_selfcheck(1'b1);
        bad += kat_selfcheck(1'b1);
        if (bad != 0) begin
            $display("\nRESULT: *** FAIL *** - the reference model failed its own");
            $display("self-check (%0d problems); no DUT result can be trusted.", bad);
            $finish;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1. the directed showcase (the waveform window) --------
        $display("\n[2] directed showcase");
        showcase_start = $time;
        mark = 1'b1;
        send(8'h00, 1'b0);              // D.0.0  - unbalanced, drives RD+
        send(8'hBC, 1'b1);              // K.28.5 - the comma
        send(8'h55, 1'b0);              // D.21.2 - balanced both halves
        send(8'hAA, 1'b0);              // D.10.5 - balanced both halves
        send(8'hF4, 1'b0);              // D.20.7 - needs the alternate D.x.A7
        send(8'hFF, 1'b0);              // D.31.7 - unbalanced both halves
        send(8'hBC, 1'b1, 10'b1000000000); // comma with bit 9 flipped on the wire
        send(8'h00, 1'b0);              // recovery begins immediately
        send(8'hFB, 1'b1);              // K.27.7
        send(8'h55, 1'b1);              // a control symbol that does not exist
        send(8'h07, 1'b0);              // D.7.0  - balanced but alternating
        send(8'h67, 1'b0);              // D.7.3  - balanced but alternating
        send(8'h3C, 1'b1);              // K.28.1 - another comma
        send(8'h00, 1'b0);
        idle(1);
        mark = 1'b0;
        showcase_end = $time;
        repeat (3) @(negedge clk);

        // ---- 2. every data byte ------------------------------------
        $display("[3] all 256 data symbols");
        for (int d = 0; d < 256; d++) send(d[7:0], 1'b0);

        // ---- 3. every control symbol, from both RD states ----------
        $display("[4] all 12 control symbols from both RD states, plus unencodable requests");
        for (int i = 0; i < 12; i++) begin
            send(k_legal_sym(i), 1'b1);
            send(8'h00, 1'b0);          // D.0.0 is unbalanced, so RD flips
            send(k_legal_sym(i), 1'b1);
        end
        send(8'h00, 1'b1);              // K.0.0  does not exist
        send(8'h55, 1'b1);              // K.21.2 does not exist
        send(8'hE3, 1'b1);              // K.3.7  does not exist

        // ---- 4. the alternate-encoding corners ---------------------
        $display("[5] alternate-encoding corners: D.x.A7, D.07, D.x.3");
        for (int i = 0; i < 6; i++)
            repeat (2) begin
                send(a7_sym(i), 1'b0);
                send(8'h00, 1'b0);
                send(a7_sym(i), 1'b0);
            end
        repeat (4) begin
            send(8'h07, 1'b0);          // D.7.0
            send(8'h67, 1'b0);          // D.7.3
            send(8'h00, 1'b0);
        end

        // ---- 5. injected wire errors -------------------------------
        $display("[6] single and double bit flips walked across the wire");
        for (int b = 0; b < 10; b++) begin
            send(8'hBC, 1'b1, 10'b1 << b);   // the comma
            send(8'h55, 1'b0, 10'b1 << b);   // balanced data
            send(8'hEB, 1'b0, 10'b1 << b);   // an A7 symbol
        end
        for (int b = 0; b < 9; b++)
            send(8'hAA, 1'b0, 10'b11 << b);  // adjacent pairs
        repeat (8) send(8'hBC, 1'b1);        // a clean run: RD must resynchronise

        // ---- 6. single-bit error detection latency -----------------
        $display("[7] single-bit error detection latency sweep");
        latency_probe = 1'b1;
        for (int si = 0; si < 6; si++) begin
            bit [7:0] sym;
            bit       symk;
            symk = (si == 0);
            case (si)
                0: sym = 8'hBC;   // K.28.5, the comma
                1: sym = 8'h55;   // D.21.2, balanced in both halves
                2: sym = 8'hAA;   // D.10.5, balanced in both halves
                3: sym = 8'hF4;   // D.20.7, uses the alternate D.x.A7
                4: sym = 8'h00;   // D.0.0,  unbalanced in both halves
                default: sym = 8'hFF; // D.31.7
            endcase
            for (int b = 0; b < 10; b++) begin
                send(sym, symk, 10'b1 << b);
                // A clean window whose first half is nothing but
                // balanced, non-alternating symbols - the codewords that look
                // identical in both RD states and therefore hide an
                // out-of-step running disparity for as long as they last.
                latency_probe = 1'b0;
                send(8'h55, 1'b0);   // D.21.2  balanced
                send(8'hAA, 1'b0);   // D.10.5  balanced
                send(8'h35, 1'b0);   // D.21.1  balanced
                send(8'h4A, 1'b0);   // D.10.2  balanced
                send(8'h00, 1'b0);   // D.0.0   unbalanced - forces the issue
                send(8'h55, 1'b0);
                send(8'hAA, 1'b0);
                send(8'h00, 1'b0);
                latency_probe = 1'b1;
            end
        end
        latency_probe = 1'b0;

        // ---- 7. pseudo-random regression ---------------------------
        $display("[8] pseudo-random regression");
        for (int i = 0; i < 4000; i++) begin
            bit [7:0] d;
            bit       k;
            bit [9:0] m;
            int       r;
            r = rnd_range(100);
            m = 10'b0;
            if (r < 70) begin
                d = rnd8(); k = 1'b0;
            end else if (r < 97) begin
                d = k_legal_sym(rnd_range(12)); k = 1'b1;
            end else begin
                d = rnd8(); k = 1'b1;                 // usually unencodable
            end
            r = rnd_range(100);
            if      (r < 12) m = 10'b1 << rnd_range(10);
            else if (r < 18) m = (10'b1 << rnd_range(10)) | (10'b1 << rnd_range(10));
            else if (r < 20) m = (10'b1 << rnd_range(10)) | (10'b1 << rnd_range(10))
                                 | (10'b1 << rnd_range(10));
            send(d, k, m);
            if ((i % 250) == 249) idle(2);            // a gap now and then
        end

        idle(4);
        repeat (8) @(posedge clk);

        // ================================================================
        // report
        // ================================================================
        $display("\n--------------------------------------------------------");
        $display(" requests driven ........... %0d", n_req);
        $display(" codewords checked ......... %0d", n_tx);
        $display(" symbols checked ........... %0d", n_rx);
        $display(" verdicts .................. %0d clean, %0d disparity error, %0d code error",
                 n_clean, n_disp, n_code);
        $display(" unencodable requests ...... %0d", n_kerr);
        $display("--------------------------------------------------------");
        $display(" functional coverage");
        $display("   request kind ............ data=%0d legal-K=%0d unencodable-K=%0d",
                 cov_kind[0], cov_kind[1], cov_kind[2]);
        $display("   injected flips .......... 0=%0d 1=%0d 2=%0d 3+=%0d",
                 cov_nflip[0], cov_nflip[1], cov_nflip[2], cov_nflip[3]);
        $display("   verdict ................. clean=%0d disp=%0d code=%0d",
                 cov_verd[0], cov_verd[1], cov_verd[2]);
        $display("   3b/4b half (y) .......... %0d %0d %0d %0d %0d %0d %0d %0d",
                 cov_y[0], cov_y[1], cov_y[2], cov_y[3],
                 cov_y[4], cov_y[5], cov_y[6], cov_y[7]);
        $display("   5b/6b half (x class) .... A7-data=%0d K-capable=%0d K.28=%0d D.07=%0d other=%0d",
                 cov_xclass[0], cov_xclass[1], cov_xclass[2], cov_xclass[3],
                 cov_xclass[4]);
        $display("   RD entering the symbol .. RD-=%0d RD+=%0d",
                 cov_rd[0], cov_rd[1]);
        $display("   commas on the wire ...... %0d", cov_comma);
        $display("   symbols recovered ....... %0d", cov_recovered);
        $display("   corrupted words the receiver did not flag ... %0d",
                 cov_survived_flip);

        // ---- single-bit error detection latency ------------------------
        // Measured only over the dedicated sweep, where every corrupted
        // symbol is followed by a guaranteed clean window, so a detection can
        // be attributed to exactly one injected flip.
        begin
            int n_probe = 0, hist [0:LAT_WINDOW], worst = 0, never = 0;
            for (int i = 0; i <= LAT_WINDOW; i++) hist[i] = 0;
            for (int i = 0; i < probe_log.size(); i++) begin
                int d;
                if (!probe_log[i]) continue;
                n_probe++;
                d = -1;
                for (int j = 0; j <= LAT_WINDOW; j++)
                    if (i + j < verd_log.size() && verd_log[i+j] != 0) begin
                        d = j;
                        break;
                    end
                if (d < 0) never++;
                else begin
                    hist[d]++;
                    if (d > worst) worst = d;
                end
            end
            $display("--------------------------------------------------------");
            $display(" single-bit wire errors, detection latency (%0d injected,",
                     n_probe);
            $display(" each followed by a clean %0d-symbol window)", LAT_WINDOW);
            for (int i = 0; i <= LAT_WINDOW; i++)
                if (hist[i] != 0)
                    $display("   flagged %0d symbol(s) after the flip ...... %0d",
                             i, hist[i]);
            $display("   never flagged ........................... %0d", never);
            $display("   worst-case detection latency ............ %0d symbols",
                     worst);
            if (n_probe == 0)
                fail("the detection-latency sweep injected nothing");
            // Every single-bit error must be caught.  It is not always caught
            // on the symbol that carried it: a flip landing on a balanced
            // sub-block can leave that codeword legal and merely knock the
            // receiver's running disparity out of step with the
            // transmitter's, which then surfaces on the next symbol whose
            // encoding actually depends on RD.
            if (never != 0)
                fail($sformatf("%0d single-bit wire errors were never detected",
                               never));
        end
        $display("--------------------------------------------------------");

        // A bin the stimulus was written to hit but did not is a hole in the
        // test, not a pass.
        want = 0;
        for (int i = 0; i < 3; i++) if (cov_kind[i] == 0) begin
            fail($sformatf("coverage hole: request kind %0d never driven", i));
            want++;
        end
        for (int i = 0; i < 3; i++) if (cov_verd[i] == 0) begin
            fail($sformatf("coverage hole: verdict %0d never observed", i));
            want++;
        end
        for (int i = 0; i < 4; i++) if (cov_nflip[i] == 0) begin
            fail($sformatf("coverage hole: %0d-flip bin never driven", i));
            want++;
        end
        for (int i = 0; i < 8; i++) if (cov_y[i] == 0) begin
            fail($sformatf("coverage hole: 3b/4b y=%0d never driven", i));
            want++;
        end
        for (int i = 0; i < 5; i++) if (cov_xclass[i] == 0) begin
            fail($sformatf("coverage hole: 5b/6b class %0d never driven", i));
            want++;
        end
        if (cov_rd[0] == 0 || cov_rd[1] == 0)
            fail("coverage hole: symbols were only ever sent from one RD state");
        for (int a = 0; a < 3; a++)
            for (int b = 0; b < 3; b++)
                if (a != 2 && cov_cross[a][b] == 0)
                    fail($sformatf("coverage hole: kind %0d never produced verdict %0d",
                                   a, b));

        if (tx_q.size() != 0)
            fail($sformatf("%0d requests never reached the wire", tx_q.size()));
        if (rx_q.size() != 0)
            fail($sformatf("%0d codewords never came out of the receiver",
                           rx_q.size()));

        if (errors == 0)
            $display("\nRESULT: *** PASS ***  (%0d requests, %0d codeword checks, %0d symbol checks, 0 mismatches)",
                     n_req, n_tx, n_rx);
        else
            $display("\nRESULT: *** FAIL ***  (%0d problems)", errors);

        $display("showcase window: %0d ns .. %0d ns", showcase_start, showcase_end);
        $finish;
    end

    // A hung link must fail the run rather than hang the regression.
    initial begin
        #3_000_000;
        $display("\nRESULT: *** FAIL *** - timeout at %0t", $time);
        $finish;
    end

endmodule : tb_codec_8b10b_dump
