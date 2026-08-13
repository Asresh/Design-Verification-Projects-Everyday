// -----------------------------------------------------------------------------
// tb_risk_gate_dump.sv - portable, module-based, SELF-CHECKING testbench for the
// pre-trade RISK-CHECK GATE. Runs on open-source Icarus Verilog (which does not
// implement the UVM class library). It:
//
//   * programs the risk limits once (max_qty=1000, price band [100,200],
//     max_notional=100000, pos_limit=500),
//   * drives a DIRECTED SHOWCASE - eight BACK-TO-BACK orders (zero-bubble) that
//     walk through every verdict in strict priority and exercise the running
//     net position, so the captured VCD tells the classic story:
//         1 BUY  150 x100  -> ACCEPT            pos +100
//         2 BUY  150 x300  -> ACCEPT            pos +400
//         3 BUY  150 x300  -> reject POS_LIMIT  pos +400 (would be +700 > 500)
//         4 BUY  150 x2000 -> reject QTY_MAX    pos +400
//         5 SELL  50 x100  -> reject PRICE_BAND pos +400 (50 < 100)
//         6 BUY  200 x800  -> reject NOTIONAL   pos +400 (160000 > 100000)
//         7 BUY  100 x0    -> reject QTY_ZERO   pos +400
//         8 SELL 150 x300  -> ACCEPT            pos +100  (sell reduces position)
//   * runs DIRECTED CORNERS (boundary values exactly at each limit, which the
//     strict checks must ACCEPT, and a position swing to the negative limit),
//   * runs a CONSTRAINED-RANDOM regression of random side/price/qty while an
//     independent STATEFUL golden reference model computes the verdict + running
//     position for each order,
//   * checks every verdict against the golden model (accept + reason + echoed
//     side + net position),
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in risk_gate_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_risk_gate_dump;

    localparam int PW   = 16;
    localparam int QW   = 16;
    localparam int POSW = 32;
    localparam int NW   = PW + QW;
    localparam int RW   = 3;
    localparam int PIPE = 2;
    localparam int LAT  = PIPE + 1;      // 3-cycle latency

    // reason codes
    localparam int R_OK       = 0;
    localparam int R_QTY_ZERO = 1;
    localparam int R_QTY_MAX  = 2;
    localparam int R_BAND     = 3;
    localparam int R_NOTIONAL = 4;
    localparam int R_POSLIM   = 5;

    // programmed limits (mirror the golden model below)
    localparam int unsigned LIM_MAX_QTY      = 1000;
    localparam int unsigned LIM_MIN_PRICE    = 100;
    localparam int unsigned LIM_MAX_PRICE    = 200;
    localparam int unsigned LIM_MAX_NOTIONAL = 100000;
    localparam int unsigned LIM_POS_LIMIT    = 500;

    logic                   clk;
    logic                   rst_n;
    logic                   cfg_load;
    logic [QW-1:0]          cfg_max_qty;
    logic [PW-1:0]          cfg_min_price;
    logic [PW-1:0]          cfg_max_price;
    logic [NW-1:0]          cfg_max_notional;
    logic [POSW-1:0]        cfg_pos_limit;
    logic                   in_valid;
    logic                   in_side;
    logic [PW-1:0]          in_price;
    logic [QW-1:0]          in_qty;
    logic                   out_valid;
    logic                   out_accept;
    logic [RW-1:0]          out_reason;
    logic                   out_side;
    logic [PW-1:0]          out_price;
    logic [QW-1:0]          out_qty;
    logic signed [POSW-1:0] out_pos;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------- DUT -----
    risk_gate #(.PW(PW), .QW(QW), .POSW(POSW), .PIPE(PIPE)) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_load         (cfg_load),
        .cfg_max_qty      (cfg_max_qty),
        .cfg_min_price    (cfg_min_price),
        .cfg_max_price    (cfg_max_price),
        .cfg_max_notional (cfg_max_notional),
        .cfg_pos_limit    (cfg_pos_limit),
        .in_valid         (in_valid),
        .in_side          (in_side),
        .in_price         (in_price),
        .in_qty           (in_qty),
        .out_valid        (out_valid),
        .out_accept       (out_accept),
        .out_reason       (out_reason),
        .out_side         (out_side),
        .out_price        (out_price),
        .out_qty          (out_qty),
        .out_pos          (out_pos)
    );

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------------------------- golden reference (stateful)
    // Independent re-model: strict-priority checks + running net position that
    // advances only on an accept.
    longint g_pos;   // signed running position

    // expected-output FIFO (golden scoreboard)
    integer            eacc_q [$];   // expected accept (0/1)
    integer            ers_q  [$];   // expected reason
    integer            esd_q  [$];   // expected echoed side
    longint            epos_q [$];   // expected position after order
    string             enm_q  [$];

    // Evaluate one order, push the expected verdict, advance g_pos on accept.
    task automatic model_push(input logic sd, input logic [PW-1:0] pr,
                              input logic [QW-1:0] qt, input string nm);
        longint unsigned notional;
        longint          delta, proj;
        integer          reason;
        logic            accept;
        notional = longint'(pr) * longint'(qt);
        delta    = sd ? -longint'(qt) : longint'(qt);
        proj     = g_pos + delta;
        if      (qt == 0)                                     reason = R_QTY_ZERO;
        else if (longint'(qt) > longint'(LIM_MAX_QTY))        reason = R_QTY_MAX;
        else if (pr < LIM_MIN_PRICE || pr > LIM_MAX_PRICE)    reason = R_BAND;
        else if (notional > longint'(LIM_MAX_NOTIONAL))       reason = R_NOTIONAL;
        else if (proj > longint'(LIM_POS_LIMIT) ||
                 proj < -longint'(LIM_POS_LIMIT))             reason = R_POSLIM;
        else                                                  reason = R_OK;
        accept = (reason == R_OK);
        if (accept) g_pos = proj;
        eacc_q.push_back(accept);
        ers_q .push_back(reason);
        esd_q .push_back(sd);
        epos_q.push_back(g_pos);
        enm_q .push_back(nm);
    endtask

    // -------------------------------------------------------- driver task -----
    task automatic drive_order(input logic sd, input logic [PW-1:0] pr,
                               input logic [QW-1:0] qt, input string nm);
        model_push(sd, pr, qt, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_side  <= sd;
        in_price <= pr;
        in_qty   <= qt;
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // back-to-back variant: hold in_valid high across consecutive orders (used
    // for the zero-bubble showcase stream).
    task automatic drive_stream(input logic sd, input logic [PW-1:0] pr,
                                input logic [QW-1:0] qt, input string nm);
        model_push(sd, pr, qt, nm);
        @(posedge clk);
        in_valid <= 1'b1;
        in_side  <= sd;
        in_price <= pr;
        in_qty   <= qt;
    endtask

    // ------------------------------------------------ scoreboard (monitor) -----
    integer xacc, xrs, xsd; longint xpos; string xnm;
    always @(posedge clk) begin
        #1;
        if (rst_n && out_valid) begin
            if (eacc_q.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: out_valid with empty expected FIFO", $time);
            end else begin
                xacc = eacc_q.pop_front();
                xrs  = ers_q .pop_front();
                xsd  = esd_q .pop_front();
                xpos = epos_q.pop_front();
                xnm  = enm_q .pop_front();
                checks = checks + 1;
                if (out_side !== xsd[0]) begin
                    errors = errors + 1;
                    $display("[%0t] SIDE-ECHO MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_side, xsd);
                end
                if ((out_accept !== xacc[0]) || (int'(out_reason) !== xrs)) begin
                    errors = errors + 1;
                    $display("[%0t] VERDICT MISMATCH (%s): got accept=%0d reason=%0d exp accept=%0d reason=%0d",
                             $time, xnm, out_accept, out_reason, xacc, xrs);
                end
                if (out_pos !== xpos[POSW-1:0]) begin
                    errors = errors + 1;
                    $display("[%0t] POSITION MISMATCH (%s): got %0d exp %0d",
                             $time, xnm, out_pos, xpos);
                end
            end
        end
    end

    // ------------------------------------------------------------- stimulus ----
    logic       rsd;
    logic [PW-1:0] rpr;
    logic [QW-1:0] rqt;
    int trials;

    initial begin
        $dumpfile("tb_risk_gate_dump.vcd");
        $dumpvars(0, tb_risk_gate_dump);

        cfg_load = 1'b0;
        in_valid = 1'b0; in_side = 1'b0; in_price = '0; in_qty = '0;
        cfg_max_qty = '0; cfg_min_price = '0; cfg_max_price = '0;
        cfg_max_notional = '0; cfg_pos_limit = '0;
        g_pos = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- program the risk limits ----
        cfg_load         <= 1'b1;
        cfg_max_qty      <= LIM_MAX_QTY;
        cfg_min_price    <= LIM_MIN_PRICE;
        cfg_max_price    <= LIM_MAX_PRICE;
        cfg_max_notional <= LIM_MAX_NOTIONAL;
        cfg_pos_limit    <= LIM_POS_LIMIT;
        @(posedge clk);
        cfg_load <= 1'b0;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE: eight zero-bubble orders (see header) --------
        drive_stream(1'b0, 16'd150, 16'd100,  "1_buy_accept");
        drive_stream(1'b0, 16'd150, 16'd300,  "2_buy_accept");
        drive_stream(1'b0, 16'd150, 16'd300,  "3_pos_limit");
        drive_stream(1'b0, 16'd150, 16'd2000, "4_qty_max");
        drive_stream(1'b1, 16'd50,  16'd100,  "5_price_band");
        drive_stream(1'b0, 16'd200, 16'd800,  "6_notional");
        drive_stream(1'b0, 16'd100, 16'd0,    "7_qty_zero");
        drive_stream(1'b1, 16'd150, 16'd300,  "8_sell_accept");
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (LAT + 4) @(posedge clk);      // drain, keep the window clean

        // ---- CORNERS: boundary values, walked on the CONTINUOUS book ---------
        // The running position is +100 here (from showcase order 8). Every order
        // below is checked against the continuous golden model - no resync.
        //   c1 SELL 150 x100  -> ACCEPT  pos 0     (flatten)
        //   c2 BUY  100 x1    -> ACCEPT  pos +1    (price == min_price edge)
        //   c3 SELL 100 x1    -> ACCEPT  pos 0     (back to flat)
        //   c4 BUY  200 x500  -> ACCEPT  pos +500  (price==max & notional==max &
        //                                           pos==+limit, all exactly at
        //                                           the edge -> strict => accept)
        //   c5 BUY  100 x1    -> POS_LIMIT          (+501 > +500, strict +1)
        //   c6 SELL 100 x1000 -> ACCEPT  pos -500  (qty==max, notional==max,
        //                                           pos==-limit exactly)
        //   c7 SELL 100 x1    -> POS_LIMIT          (-501 < -500, strict +1)
        //   c8 BUY  100 x1000 -> ACCEPT  pos +500  (swing back across zero)
        drive_order(1'b1, 16'd150, 16'd100,  "c1_flatten");     repeat (LAT + 2) @(posedge clk);
        drive_order(1'b0, 16'd100, 16'd1,    "c2_price_min");   repeat (LAT + 2) @(posedge clk);
        drive_order(1'b1, 16'd100, 16'd1,    "c3_flat");        repeat (LAT + 2) @(posedge clk);
        drive_order(1'b0, 16'd200, 16'd500,  "c4_triple_edge"); repeat (LAT + 2) @(posedge clk);
        drive_order(1'b0, 16'd100, 16'd1,    "c5_pos_over");    repeat (LAT + 2) @(posedge clk);
        drive_order(1'b1, 16'd100, 16'd1000, "c6_neg_edge");    repeat (LAT + 2) @(posedge clk);
        drive_order(1'b1, 16'd100, 16'd1,    "c7_neg_over");    repeat (LAT + 2) @(posedge clk);
        drive_order(1'b0, 16'd100, 16'd1000, "c8_swing_back");  repeat (LAT + 2) @(posedge clk);

        // ---- CONSTRAINED-RANDOM regression -----------------------------------
        trials = 300;
        for (int t = 0; t < trials; t++) begin
            rsd = $urandom_range(0, 1);
            if (t % 7 == 0) begin
                rqt = 16'd0;                                   // zero qty
                rpr = $urandom_range(90, 210);
            end else if (t % 3 == 0) begin
                rpr = $urandom_range(50, 250);                 // near band edges
                rqt = $urandom_range(1, 1500);                 // near qty max
            end else begin
                rpr = $urandom_range(90, 210);
                rqt = $urandom_range(1, 800);
            end
            drive_order(rsd, rpr, rqt, $sformatf("rand_%0d", t));
            if (t % 3 == 0) repeat (1) @(posedge clk);         // vary the gap
        end
        repeat (LAT + 5) @(posedge clk);

        // -------------------------------------------------------- verdict ----
        if (eacc_q.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected verdicts never appeared", eacc_q.size());
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
        #400000;   // 400 us global watchdog
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
