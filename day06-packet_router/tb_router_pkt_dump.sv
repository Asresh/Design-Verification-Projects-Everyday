// -----------------------------------------------------------------------------
// tb_router_pkt_dump.sv  -  Portable, self-checking testbench for router_pkt
//
// This is the open-source companion to the UVM environment in router_pkt_pkg.sv.
// Icarus Verilog does not implement the UVM class library, so this module-based
// testbench reproduces the *same* verification intent with plain SystemVerilog:
//
//   * a golden reference model  : one SV queue per output port (expected order)
//   * a stimulus generator      : directed packets + constrained-random beats,
//                                 with random per-output backpressure
//   * a scoreboard              : every accepted output beat is checked against
//                                 the head of that port's golden queue
//   * end-of-test reconciliation: all golden queues must be empty (no drops,
//                                 no duplicates, no misroutes)
//   * a global timeout and a VCD dump for the waveform image
//
// It prints "RESULT: *** PASS ***" only if every check passed and the router
// delivered exactly the beats it accepted, in per-port order.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_router_pkt_dump;

    // ---- geometry (mirrors the DUT defaults) --------------------------------
    localparam int NUM_OUT = 4;
    localparam int DW      = 8;
    localparam int DEPTH   = 4;
    localparam int DEST_W  = $clog2(NUM_OUT);

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;               // 100 MHz, posedge at 5 + 10k ns

    // ---- DUT connections ----------------------------------------------------
    logic                  in_valid;
    logic                  in_ready;
    logic [DEST_W-1:0]     in_dest;
    logic [DW-1:0]         in_data;
    logic                  in_last;

    logic [NUM_OUT-1:0]        out_valid;
    logic [NUM_OUT-1:0]        out_ready;
    logic [NUM_OUT*DW-1:0]     out_data;
    logic [NUM_OUT-1:0]        out_last;

    router_pkt #(.NUM_OUT(NUM_OUT), .DW(DW), .DEPTH(DEPTH)) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_dest, .in_data, .in_last,
        .out_valid, .out_ready, .out_data, .out_last
    );

    // Convenience: per-port output data slice.
    function automatic logic [DW-1:0] odata(int p);
        return out_data[p*DW +: DW];
    endfunction

    // ---- golden reference model: expected {last,data} per output port -------
    // Icarus does not support arrays-of-queues, so the golden FIFO per port is
    // a plain circular buffer with head/tail pointers (fully portable).
    localparam int MAXQ = 256;
    logic [DW:0] gmem [NUM_OUT][MAXQ];  // expected {last,data} per port
    int          ghead [NUM_OUT];       // pop pointer
    int          gtail [NUM_OUT];       // push pointer
    int          sent;                  // beats accepted by the router
    int          got;                   // beats delivered by the router
    int          errors;

    function automatic int gsize(int p);
        return gtail[p] - ghead[p];
    endfunction

    // Single deterministic reference process: first check/pop every completed
    // output handshake against the head of that port's golden FIFO, then
    // predict/push the beat accepted on the input port this cycle. Doing both
    // in one clocked block with blocking updates avoids ordering hazards.
    integer pp;
    logic [DW:0] exp;
    always @(posedge clk) if (rst_n) begin
        // ---- check + pop outputs ----
        for (pp = 0; pp < NUM_OUT; pp++) begin
            if (out_valid[pp] && out_ready[pp]) begin
                if (gsize(pp) == 0) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR port%0d: unexpected beat data=0x%02h last=%0b",
                             $time, pp, odata(pp), out_last[pp]);
                end else begin
                    exp        = gmem[pp][ghead[pp]];
                    ghead[pp]  = ghead[pp] + 1;
                    got        = got + 1;
                    if ({out_last[pp], odata(pp)} !== exp) begin
                        errors = errors + 1;
                        $display("[%0t] ERROR port%0d: got {last=%0b,0x%02h} exp {last=%0b,0x%02h}",
                                 $time, pp, out_last[pp], odata(pp), exp[DW], exp[DW-1:0]);
                    end
                end
            end
        end
        // ---- predict + push input ----
        if (in_valid && in_ready) begin
            gmem[in_dest][gtail[in_dest]] = {in_last, in_data};
            gtail[in_dest]                = gtail[in_dest] + 1;
            sent                          = sent + 1;
        end
    end

    // ---- random per-output backpressure -------------------------------------
    // Each output pulls its ready randomly so FIFOs fill and drain, exercising
    // both full (input stall) and empty (output idle) corners.
    int seed = 32'hC0FFEE;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_ready <= '1;             // drain freely during reset
        else        out_ready <= $random(seed);  // random 4-bit ready mask
    end

    // ---- input driver -------------------------------------------------------
    task automatic drive_beat(input logic [DEST_W-1:0] dst,
                              input logic [DW-1:0]      dat,
                              input logic               last);
        in_dest  <= dst;
        in_data  <= dat;
        in_last  <= last;
        in_valid <= 1'b1;
        // Hold until the beat is accepted (respects backpressure / FIFO full).
        do @(posedge clk); while (!in_ready);
        in_valid <= 1'b0;
        in_dest  <= '0;
        in_data  <= '0;
        in_last  <= 1'b0;
    endtask

    // Send a packet of `len` beats to `dst` (last asserted on the final beat).
    task automatic send_packet(input logic [DEST_W-1:0] dst, input int len);
        for (int i = 0; i < len; i++)
            drive_beat(dst, $random(seed), (i == len-1));
    endtask

    // ---- stimulus + reconciliation ------------------------------------------
    integer di;
    initial begin
        in_valid = 1'b0; in_dest = '0; in_data = '0; in_last = 1'b0;
        errors   = 0; sent = 0; got = 0;
        for (int p = 0; p < NUM_OUT; p++) begin ghead[p] = 0; gtail[p] = 0; end

        // Reset.
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- directed phase: one short packet to each port ------------------
        send_packet(2'd0, 2);
        send_packet(2'd1, 3);
        send_packet(2'd2, 1);
        send_packet(2'd3, 2);

        // ---- directed corner: overflow one FIFO to force input stall --------
        // Hammer port 1 with more beats than DEPTH while its ready is random,
        // so in_ready must deassert (full) at least once.
        for (di = 0; di < DEPTH + 4; di++)
            drive_beat(2'd1, 8'hA0 + di[7:0], (di == DEPTH+3));

        // ---- constrained-random phase --------------------------------------
        repeat (60) begin
            logic [DEST_W-1:0] d;
            d = $random(seed);
            drive_beat(d, $random(seed), ($random(seed) & 1));
        end

        // ---- drain: force all outputs ready and let FIFOs empty -------------
        in_valid = 1'b0;
        force out_ready = '1;
        wait (out_valid == '0);
        repeat (4) @(posedge clk);
        release out_ready;

        // ---- reconciliation -------------------------------------------------
        for (int p = 0; p < NUM_OUT; p++)
            if (gsize(p) != 0) begin
                errors = errors + 1;
                $display("ERROR: port%0d left %0d undelivered beat(s)",
                         p, gsize(p));
            end

        $display("----------------------------------------------------------");
        $display(" router_pkt self-check:  accepted=%0d  delivered=%0d  errors=%0d",
                 sent, got, errors);
        if (errors == 0 && sent == got && sent > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---- global timeout -----------------------------------------------------
    initial begin
        #50000;
        $display("RESULT: *** FAIL ***  (timeout)");
        $finish;
    end

    // ---- waveform dump ------------------------------------------------------
    initial begin
        $dumpfile("tb_router_pkt_dump.vcd");
        $dumpvars(0, tb_router_pkt_dump);
    end

endmodule
