// -----------------------------------------------------------------------------
// tb_bbo_reduce_dump.sv - portable, module-based, SELF-CHECKING testbench for the
// streaming Best-Bid/Best-Offer (BBO) top-of-book reduction tree. Runs on open-
// source Icarus Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - a full 8-level price ladder
//         [100,105,103,110,108,102,110,101]  (all levels populated)
//     so the captured VCD tells the classic story: an 8-level book streams in
//     and, LAT cycles later, the BBO comes out as
//         best bid  = 110 @ level 3   (110 also at level 6 -> LOWEST index wins)
//         best offer = 100 @ level 0,
//   * runs DIRECTED CORNERS (single populated level, empty book -> identities,
//     a max/min tie that must resolve to the lowest index, all-equal prices,
//     min/max price extremes 0x0000 / 0xFFFF, a sparse mask, and a zero-bubble
//     back-to-back stream that fills the pipeline),
//   * runs a CONSTRAINED-RANDOM regression of random prices + random masks while
//     a golden reference model independently computes the BBO for each vector,
//   * checks every BBO result against the golden model (value + index + any),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in bbo_reduce_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_bbo_reduce_dump;

    localparam int N   = 8;
    localparam int DW  = 16;
    localparam int IW  = 3;          // log2(8)
    localparam int L   = 3;          // log2(8)
    localparam int LAT = L + 2;      // 5-cycle latency

    logic              clk;
    logic              rst_n;
    logic              in_valid;
    logic [N*DW-1:0]   in_price;
    logic [N-1:0]      in_mask;
    logic              out_valid;
    logic              out_any;
    logic [DW-1:0]     out_max_val;
    logic [IW-1:0]     out_max_idx;
    logic [DW-1:0]     out_min_val;
    logic [IW-1:0]     out_min_idx;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    bbo_reduce #(.N(N), .DW(DW)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .in_price   (in_price),
        .in_mask    (in_mask),
        .out_valid  (out_valid),
        .out_any    (out_any),
        .out_max_val(out_max_val),
        .out_max_idx(out_max_idx),
        .out_min_val(out_min_val),
        .out_min_idx(out_min_idx)
    );

    // ---- per-level views broken out for a readable waveform -------------------
    logic [DW-1:0] p0, p1, p2, p3, p4, p5, p6, p7;
    assign p0 = in_price[0*DW +: DW];
    assign p1 = in_price[1*DW +: DW];
    assign p2 = in_price[2*DW +: DW];
    assign p3 = in_price[3*DW +: DW];
    assign p4 = in_price[4*DW +: DW];
    assign p5 = in_price[5*DW +: DW];
    assign p6 = in_price[6*DW +: DW];
    assign p7 = in_price[7*DW +: DW];

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------- expected-output FIFO (golden scoreboard) -----
    logic          eany_q [$];
    logic [DW-1:0] emxv_q [$];
    logic [IW-1:0] emxi_q [$];
    logic [DW-1:0] emnv_q [$];
    logic [IW-1:0] emni_q [$];
    string         enm_q  [$];

    // Golden BBO: lowest-index-wins argmax + argmin over the VALID lanes only.
    task automatic golden(input  logic [N*DW-1:0] vec,
                          input  logic [N-1:0]    mask,
                          output logic            any,
                          output logic [DW-1:0]   mxv,
                          output logic [IW-1:0]   mxi,
                          output logic [DW-1:0]   mnv,
                          output logic [IW-1:0]   mni);
        logic [DW-1:0] price;
        any = 1'b0;
        mxv = '0; mxi = '0; mnv = {DW{1'b1}}; mni = '0;
        for (int i = 0; i < N; i++) begin
            if (mask[i]) begin
                price = vec[i*DW +: DW];
                if (!any) begin
                    any = 1'b1;
                    mxv = price; mxi = IW'(i);
                    mnv = price; mni = IW'(i);
                end else begin
                    if (price > mxv) begin mxv = price; mxi = IW'(i); end // strictly greater -> update (lowest idx kept on tie)
                    if (price < mnv) begin mnv = price; mni = IW'(i); end
                end
            end
        end
        if (!any) begin
            mxv = '0; mxi = '0; mnv = {DW{1'b1}}; mni = '0;
        end
    endtask

    // -------------------------------------------------------- driver task -----
    task automatic drive_vec(input logic [N*DW-1:0] vec, input logic [N-1:0] mask,
                             input string nm);
        logic any; logic [DW-1:0] mxv, mnv; logic [IW-1:0] mxi, mni;
        golden(vec, mask, any, mxv, mxi, mnv, mni);
        @(posedge clk);
        in_valid <= 1'b1;
        in_price <= vec;
        in_mask  <= mask;
        eany_q.push_back(any);
        emxv_q.push_back(mxv);
        emxi_q.push_back(mxi);
        emnv_q.push_back(mnv);
        emni_q.push_back(mni);
        enm_q .push_back(nm);
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // helper: build a packed N-lane vector from eight scalar prices (low first)
    function automatic logic [N*DW-1:0] mk(
            input logic [DW-1:0] a0, a1, a2, a3, a4, a5, a6, a7);
        logic [N*DW-1:0] v;
        v = '0;
        v[0*DW +: DW] = a0; v[1*DW +: DW] = a1; v[2*DW +: DW] = a2; v[3*DW +: DW] = a3;
        v[4*DW +: DW] = a4; v[5*DW +: DW] = a5; v[6*DW +: DW] = a6; v[7*DW +: DW] = a7;
        return v;
    endfunction

    // ------------------------------------------------ scoreboard (monitor) -----
    logic          xany; logic [DW-1:0] xmxv, xmnv; logic [IW-1:0] xmxi, xmni;
    string         xnm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (eany_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                xany = eany_q.pop_front();
                xmxv = emxv_q.pop_front();
                xmxi = emxi_q.pop_front();
                xmnv = emnv_q.pop_front();
                xmni = emni_q.pop_front();
                xnm  = enm_q .pop_front();
                checks = checks + 1;
                if (out_any !== xany) begin
                    errors = errors + 1;
                    $display("[%0t] ANY MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_any, xany);
                end else if (xany && ((out_max_val !== xmxv) || (out_max_idx !== xmxi) ||
                                      (out_min_val !== xmnv) || (out_min_idx !== xmni))) begin
                    errors = errors + 1;
                    $display("[%0t] BBO MISMATCH (%s):", $time, xnm);
                    $display("    max got 0x%04h@%0d exp 0x%04h@%0d | min got 0x%04h@%0d exp 0x%04h@%0d",
                             out_max_val, out_max_idx, xmxv, xmxi,
                             out_min_val, out_min_idx, xmnv, xmni);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic [N*DW-1:0] rvec;
    logic [N-1:0]    rmask;
    int trials;

    initial begin
        $dumpfile("tb_bbo_reduce_dump.vcd");
        $dumpvars(0, tb_bbo_reduce_dump);

        in_valid = 1'b0;
        in_price = '0;
        in_mask  = '0;
        rst_n    = 1'b0;
        repeat (4) @(posedge clk);
        rst_n    = 1'b1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: full 8-level book ----
        // prices 100,105,103,110,108,102,110,101 (all valid) ->
        //   best bid  = 110 @ level 3 (110 also at level 6 -> LOWEST index wins)
        //   best offer = 100 @ level 0
        drive_vec(mk(16'd100,16'd105,16'd103,16'd110,16'd108,16'd102,16'd110,16'd101),
                  8'hFF, "showcase_full_book");
        repeat (LAT + 3) @(posedge clk);      // let it drain, keep window clean

        // ---- CORNER: single populated level (only level 5) ----
        drive_vec(mk(16'd0,16'd0,16'd0,16'd0,16'd0,16'd777,16'd0,16'd0),
                  8'b0010_0000, "single_level");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: empty book (mask 0) -> identities, any=0 ----
        drive_vec(mk(16'd11,16'd22,16'd33,16'd44,16'd55,16'd66,16'd77,16'd88),
                  8'h00, "empty_book");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: a max AND a min tie -> both resolve to LOWEST index ----
        // 9 at levels 1 and 4 (max), 2 at levels 2 and 6 (min): max@1, min@2.
        drive_vec(mk(16'd5,16'd9,16'd2,16'd5,16'd9,16'd5,16'd2,16'd5),
                  8'hFF, "tie_lowest_index");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: all-equal prices -> max==min, both @ level 0 ----
        drive_vec(mk(16'd50,16'd50,16'd50,16'd50,16'd50,16'd50,16'd50,16'd50),
                  8'hFF, "all_equal");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: price extremes 0x0000 and 0xFFFF present ----
        drive_vec(mk(16'hFFFF,16'd100,16'h0000,16'd200,16'd150,16'hFFFF,16'h0000,16'd120),
                  8'hFF, "extremes");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: sparse mask (only levels 2,3,7 populated) ----
        // valid prices 400@2, 250@3, 600@7 -> max 600@7, min 250@3.
        drive_vec(mk(16'd999,16'd999,16'd400,16'd250,16'd999,16'd999,16'd999,16'd600),
                  8'b1000_1100, "sparse_mask");
        repeat (LAT + 2) @(posedge clk);

        // ---- CORNER: back-to-back stream (fills the pipeline, no bubbles) ----
        for (int t = 0; t < 6; t++) begin
            for (int i = 0; i < N; i++)
                rvec[i*DW +: DW] = DW'($urandom_range(0, 16'hFFFF));
            rmask = $urandom_range(1, 8'hFF);    // keep book non-empty in stream
            begin
                logic any; logic [DW-1:0] mxv, mnv; logic [IW-1:0] mxi, mni;
                golden(rvec, rmask, any, mxv, mxi, mnv, mni);
                @(posedge clk);
                in_valid <= 1'b1;
                in_price <= rvec;
                in_mask  <= rmask;
                eany_q.push_back(any); emxv_q.push_back(mxv); emxi_q.push_back(mxi);
                emnv_q.push_back(mnv); emni_q.push_back(mni);
                enm_q .push_back($sformatf("stream_%0d", t));
            end
        end
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 3) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression ----
        trials = 300;
        for (int t = 0; t < trials; t++) begin
            for (int i = 0; i < N; i++) begin
                if (t % 3 == 0)
                    rvec[i*DW +: DW] = DW'($urandom_range(0, 16'd20));   // small range -> many ties
                else
                    rvec[i*DW +: DW] = DW'($urandom_range(0, 16'hFFFF)); // full range
            end
            // allow the empty book (mask 0) occasionally to exercise identities
            rmask = (t % 17 == 0) ? 8'h00 : $urandom_range(0, 8'hFF);
            drive_vec(rvec, rmask, $sformatf("rand_%0d", t));
            // vary the gap so the pipeline sees isolated and dense traffic
            if (t % 3 == 0) repeat (2) @(posedge clk);
        end
        repeat (LAT + 5) @(posedge clk);

        // -------------------------------------------------------- verdict ----
        if (eany_q.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected results never appeared", eany_q.size());
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

    // ------------------------------------------------------------- timeout ----
    initial begin
        #300000;   // 300 us global watchdog
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
