// ============================================================================
// codec_8b10b_if.sv - pin interface + concurrent SVA for the 8b/10b link.
// ----------------------------------------------------------------------------
// Carries the transmit request (in_valid / in_data / in_k), the per-symbol wire
// error mask (err_mask), the transmit-side taps (enc_*, wire_code) and the
// receive-side taps (out_*).
//
// The assertions here are the ones worth writing structurally rather than in a
// scoreboard: the fixed-latency pipeline contract, and - more interestingly -
// the two properties that make 8b/10b a *line* code rather than just a
// bijection.  Those two are junction properties, invisible to any per-symbol
// check:
//
//   a_run_length : no run of 6 identical bits across a codeword boundary
//   a_balance    : every codeword has 4, 5 or 6 ones
//
// a_run_length carries an explicit exemption for K.28.7, and that exemption is
// not folklore - docs/gen_kat.py derives it by sweeping all ~143k legal
// codeword junctions and reports the exact 56-symbol successor set that
// K.28.7 may not precede.  The assertion encodes the conclusion; the generator
// proves it.
//
// The UVM flow (VCS / Questa / Verilator) compiles these.  Icarus does not
// support these assertion forms, so tb_codec_8b10b_dump.sv carries equivalent
// procedural checkers - including the run-length one.
// ============================================================================
`timescale 1ns/1ps

interface codec_8b10b_if (input logic clk, input logic rst_n);

    // request
    logic       in_valid;
    logic [7:0] in_data;
    logic       in_k;
    logic [9:0] err_mask;

    // transmit side (LAT 1)
    logic       enc_valid;
    logic [9:0] enc_code;
    logic [9:0] wire_code;
    logic       enc_rd;
    logic       enc_kerr;
    logic       enc_comma;

    // receive side (LAT 2)
    logic       out_valid;
    logic [7:0] out_data;
    logic       out_k;
    logic       out_code_err;
    logic       out_disp_err;
    logic       out_rd;
    logic       out_comma;

    // clocking block for the driver (synchronous stimulus).
    clocking drv_cb @(posedge clk);
        default output #1;
        output in_valid, in_data, in_k, err_mask;
    endclocking

    modport drv (clocking drv_cb, input clk, input rst_n);

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // longest run of identical bits in a 20-bit window (two codewords)
    // ------------------------------------------------------------------
    function automatic int longest_run20(input logic [19:0] w);
        int run, best;
        run  = 1;
        best = 1;
        for (int i = 18; i >= 0; i--) begin
            run  = (w[i] === w[i+1]) ? run + 1 : 1;
            if (run > best) best = run;
        end
        return best;
    endfunction

    // ------------------------------------------------------------------
    // fixed-latency pipeline contract
    // ------------------------------------------------------------------
    a_enc_lat: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |=> enc_valid)
        else $error("enc_valid did not follow in_valid by 1 cycle");

    a_enc_src: assert property (@(posedge clk) disable iff (!rst_n)
        enc_valid |-> $past(in_valid))
        else $error("enc_valid without a prior in_valid");

    a_dec_lat: assert property (@(posedge clk) disable iff (!rst_n)
        enc_valid |=> out_valid)
        else $error("out_valid did not follow enc_valid by 1 cycle");

    a_dec_src: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> $past(in_valid, 2))
        else $error("out_valid without a request two cycles earlier");

    // ------------------------------------------------------------------
    // the line-code properties
    // ------------------------------------------------------------------
    // Every transmitted codeword is DC-bounded.  An unencodable control
    // request is the one case where nothing legal goes on the wire.
    a_balance: assert property (@(posedge clk) disable iff (!rst_n)
        (enc_valid && !enc_kerr) |->
            ($countones(enc_code) >= 4 && $countones(enc_code) <= 6))
        else $error("codeword %b is not DC-bounded", enc_code);

    // No run of 6 across a codeword junction, so the receiver CDR always sees
    // an edge.  Exempt when the previous symbol was K.28.7 (the request two
    // cycles ago), and when either symbol was an unencodable request.
    a_run_length: assert property (@(posedge clk) disable iff (!rst_n)
        (enc_valid && $past(enc_valid) && !enc_kerr && !$past(enc_kerr) &&
         !($past(in_k, 2) && $past(in_data, 2) == 8'hFC)) |->
            longest_run20({$past(enc_code), enc_code}) <= 5)
        else $error("run of %0d bits across the %b|%b junction",
                    longest_run20({$past(enc_code), enc_code}),
                    $past(enc_code), enc_code);

    // The comma is the framing marker, so it must appear only in K.28.1/.5/.7.
    a_comma_source: assert property (@(posedge clk) disable iff (!rst_n)
        enc_comma |-> ($past(in_k) && $past(in_data[4:0]) == 5'd28 &&
                       ($past(in_data[7:5]) == 3'd1 ||
                        $past(in_data[7:5]) == 3'd5 ||
                        $past(in_data[7:5]) == 3'd7)))
        else $error("comma on the wire from a non-K.28.1/.5/.7 request");

    // ------------------------------------------------------------------
    // encoder / decoder contracts
    // ------------------------------------------------------------------
    // An unencodable control request puts nothing on the wire and leaves the
    // link's running disparity alone.
    a_kerr_silent: assert property (@(posedge clk) disable iff (!rst_n)
        enc_kerr |-> (enc_code == 10'b0 && enc_rd == $past(enc_rd)))
        else $error("unencodable request disturbed the wire or RD");

    a_kerr_only_k: assert property (@(posedge clk) disable iff (!rst_n)
        enc_kerr |-> $past(in_k))
        else $error("kerr raised for a data request");

    // The two receive error classes are distinct verdicts, never both.
    a_err_exclusive: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !(out_code_err && out_disp_err))
        else $error("code error and disparity error reported together");

    // A word that is not in the code carries no symbol.
    a_code_err_no_sym: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_code_err) |-> (out_data == 8'h00 && !out_k))
        else $error("code error still produced a symbol");

    // Running disparity only moves on a valid symbol.
    a_enc_rd_stable: assert property (@(posedge clk) disable iff (!rst_n)
        !$past(in_valid) |-> enc_rd == $past(enc_rd))
        else $error("transmit RD moved without a symbol");

    a_dec_rd_stable: assert property (@(posedge clk) disable iff (!rst_n)
        !$past(enc_valid) |-> out_rd == $past(out_rd))
        else $error("receive RD moved without a symbol");

    // ------------------------------------------------------------------
    // no X anywhere it matters
    // ------------------------------------------------------------------
    a_enc_nox: assert property (@(posedge clk) disable iff (!rst_n)
        enc_valid |-> !$isunknown({enc_code, wire_code, enc_rd, enc_kerr,
                                   enc_comma}))
        else $error("X on the transmit side while valid");

    a_dec_nox: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_data, out_k, out_code_err,
                                   out_disp_err, out_rd, out_comma}))
        else $error("X on the receive side while valid");
`endif

endinterface : codec_8b10b_if
