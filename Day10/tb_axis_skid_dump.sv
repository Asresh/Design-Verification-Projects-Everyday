// ============================================================================
// tb_axis_skid_dump.sv - portable, self-checking module testbench for
// `axis_skid` (the AXI4-Stream skid buffer / register slice).
//
// WHY THIS EXISTS
//   Icarus Verilog (the open-source simulator this repo runs on) does not
//   implement the UVM class library, so it cannot elaborate axis_skid_pkg.sv /
//   tb_top.sv. This companion testbench reproduces the SAME verification
//   intent - an independent golden-queue reference model, two-sided random
//   back-pressure, directed + constrained-random stimulus, a self-checking
//   scoreboard, and a VCD dump - in plain SystemVerilog that runs everywhere.
//
// WHAT IT CHECKS
//   A skid buffer is a pure order-preserving pass-through. Every beat accepted
//   on the input (s_tvalid && s_tready) is pushed onto an expected FIFO; every
//   beat leaving the output (m_tvalid && m_tready) pops the oldest expected
//   entry and must match {tdata,tkeep,tlast} EXACTLY. Nothing may be dropped,
//   duplicated, or reordered, under any back-pressure pattern. Any mismatch,
//   an output with no matching input, or leftover un-drained beats is fatal.
//   The run ends with "RESULT: *** PASS ***" only if every check passes.
//
// The front of the run is a DIRECTED showcase: a 6-byte packet (with a null
// byte, tkeep=0) driven back-to-back while the SINK stalls mid-packet - the
// output slot holds, the skid register fills, and s_tready drops to push
// back-pressure upstream. A constrained-random, two-sided back-pressure
// regression follows to exercise the space.
// ============================================================================
`timescale 1ns/1ps
module tb_axis_skid_dump;

    localparam int DATA_WIDTH = 8;
    localparam int KEEP_WIDTH = 1;

    logic                    clk, rst_n;
    logic                    s_tvalid, s_tready, s_tlast;
    logic [DATA_WIDTH-1:0]   s_tdata;
    logic [KEEP_WIDTH-1:0]   s_tkeep;
    logic                    m_tvalid, m_tready, m_tlast;
    logic [DATA_WIDTH-1:0]   m_tdata;
    logic [KEEP_WIDTH-1:0]   m_tkeep;

    // ------------------------------------------------------------------ DUT
    axis_skid #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tvalid(s_tvalid), .s_tready(s_tready),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tlast(s_tlast),
        .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tlast(m_tlast)
    );

    // Mirror the internal skid-register-full flag to the top scope so the
    // waveform can show back-pressure forming.
    wire skid_valid_dbg = dut.skid_valid;

    // ------------------------------------------------------------------ clock
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period

    // ------------------------------------------------------------------ reset
    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------- stimulus program
    // Precomputed beat list: {tdata, tkeep, tlast} + a per-beat input gap.
    localparam int MAXB = 512;
    logic [DATA_WIDTH-1:0] stim_data [0:MAXB-1];
    logic [KEEP_WIDTH-1:0] stim_keep [0:MAXB-1];
    logic                  stim_last [0:MAXB-1];
    int                    stim_gap  [0:MAXB-1];
    int                    nbeats = 0;

    task automatic add(input logic [DATA_WIDTH-1:0] d,
                       input logic [KEEP_WIDTH-1:0] k,
                       input logic l, input int g);
        stim_data[nbeats] = d; stim_keep[nbeats] = k;
        stim_last[nbeats] = l; stim_gap[nbeats]  = g;
        nbeats = nbeats + 1;
    endtask

    integer p, bi, plen, gap0;
    logic [31:0] r;

    task automatic build_stimulus();
        nbeats = 0;
        // ---- DIRECTED showcase: one 6-byte packet, back-to-back (no gaps) ----
        add(8'hA0, 1'b1, 1'b0, 0);
        add(8'hA1, 1'b1, 1'b0, 0);
        add(8'hA2, 1'b0, 1'b0, 0);   // null byte: tkeep=0 must pass through
        add(8'hA3, 1'b1, 1'b0, 0);
        add(8'hA4, 1'b1, 1'b0, 0);
        add(8'hA5, 1'b1, 1'b1, 0);   // end of packet (tlast)
        // ---- constrained-random regression: 40 random packets ----
        for (p = 0; p < 40; p = p + 1) begin
            r     = $random;
            plen  = (r & 32'h7FFFFFFF) % 6 + 1;      // 1..6 beats
            r     = $random;
            gap0  = (r & 32'h7FFFFFFF) % 4;          // 0..3 idle cycles before pkt
            for (bi = 0; bi < plen; bi = bi + 1) begin
                r = $random;
                add(r[DATA_WIDTH-1:0],
                    ((r >> 8) % 8 == 0) ? 1'b0 : 1'b1,   // occasional null byte
                    (bi == plen - 1),                    // tlast on final beat
                    (bi == 0) ? gap0 : 0);               // gap only before beat 0
            end
        end
    endtask

    // ------------------------------------------------- golden scoreboard (FIFO)
    // Expected-beat queue: {tlast, tkeep, tdata}. A skid buffer must forward
    // every accepted input beat, in order, unchanged.
    logic [KEEP_WIDTH+DATA_WIDTH:0] expq [$];
    logic [KEEP_WIDTH+DATA_WIDTH:0] got, exp;
    int in_count  = 0;
    int out_count = 0;
    int errors    = 0;
    logic src_done = 1'b0;

    // Single sampler: push accepted inputs, then pop/check outputs. Because the
    // DUT latency is >= 1 cycle, any output popped here was pushed in an
    // earlier cycle, so ordering within the same edge is unambiguous.
    always @(posedge clk) begin
        if (rst_n) begin
            if (s_tvalid && s_tready) begin
                expq.push_back({s_tlast, s_tkeep, s_tdata});
                in_count = in_count + 1;
            end
            if (m_tvalid && m_tready) begin
                out_count = out_count + 1;
                got = {m_tlast, m_tkeep, m_tdata};
                if (expq.size() == 0) begin
                    errors = errors + 1;
                    $display("[%0t] EXTRA output beat with no matching input: %010b",
                             $time, got);
                end else begin
                    exp = expq.pop_front();
                    if (got !== exp) begin
                        errors = errors + 1;
                        $display("[%0t] MISMATCH out{last,keep,data}=%b_%b_%02h  exp=%b_%b_%02h",
                                 $time, got[KEEP_WIDTH+DATA_WIDTH],
                                 got[DATA_WIDTH +: KEEP_WIDTH], got[DATA_WIDTH-1:0],
                                 exp[KEEP_WIDTH+DATA_WIDTH],
                                 exp[DATA_WIDTH +: KEEP_WIDTH], exp[DATA_WIDTH-1:0]);
                    end
                end
            end
        end
    end

    // ------------------------------------------------------- source driver
    // Presents each beat and HOLDS it (valid high, payload stable) until the
    // handshake completes; supports true back-to-back beats when gap == 0.
    integer idx;
    initial begin
        s_tvalid = 1'b0; s_tdata = '0; s_tkeep = '0; s_tlast = 1'b0;
        build_stimulus();
        @(posedge rst_n);
        @(posedge clk);
        idx = 0;
        while (idx < nbeats) begin
            if (stim_gap[idx] > 0) begin
                s_tvalid <= 1'b0;
                repeat (stim_gap[idx]) @(posedge clk);
            end
            s_tvalid <= 1'b1;
            s_tdata  <= stim_data[idx];
            s_tkeep  <= stim_keep[idx];
            s_tlast  <= stim_last[idx];
            @(posedge clk);
            while (s_tready !== 1'b1) @(posedge clk);   // hold until accepted
            idx = idx + 1;
        end
        s_tvalid <= 1'b0;
        src_done <= 1'b1;
    end

    // ------------------------------------------------------- sink back-pressure
    // Directed window first (flow -> stall -> drain) so the committed waveform
    // shows the skid filling and s_tready dropping; then random back-pressure.
    initial begin
        m_tready = 1'b0;
        @(posedge rst_n);
        @(posedge clk);
        m_tready <= 1'b1;               // accept
        repeat (2) @(posedge clk);
        m_tready <= 1'b0;               // downstream STALL: output holds, skid fills
        repeat (3) @(posedge clk);
        m_tready <= 1'b1;               // drain
        repeat (4) @(posedge clk);
        forever begin                   // randomized back-pressure regression
            r = $random;
            m_tready <= ((r & 3) != 0); // ready ~75% of cycles
            @(posedge clk);
        end
    end

    // ------------------------------------------------------- run control
    integer guard;
    initial begin
        wait (src_done);
        guard = 0;
        while (out_count < in_count && guard < 4000) begin
            @(posedge clk); guard = guard + 1;
        end
        repeat (5) @(posedge clk);
        $display("----------------------------------------------------------");
        $display(" beats in=%0d  out=%0d  errors=%0d  leftover=%0d",
                 in_count, out_count, errors, expq.size());
        if (errors == 0 && in_count == out_count && expq.size() == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (errors=%0d leftover=%0d)",
                     errors, expq.size());
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------------------------------------------------- SVA assertions
    // Concurrent SVA (Icarus does not implement `assert property`, so this
    // block compiles only under a UVM-capable simulator via +define+AXIS_SVA).
`ifdef AXIS_SVA
    // Master must not retract a valid beat before it is accepted.
    a_mvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (m_tvalid && !m_tready) |=> m_tvalid)
        else $error("m_tvalid dropped before m_tready");
    // Payload stable while the output is stalled.
    a_mpayload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (m_tvalid && !m_tready) |=> $stable({m_tdata, m_tkeep, m_tlast}))
        else $error("m_* payload changed while stalled");
`endif

    // ------------------------------------------------------------- timeout
    initial begin
        #200000;   // 200 us hard cap
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ------------------------------------------------------------- VCD dump
    initial begin
        $dumpfile("tb_axis_skid_dump.vcd");
        $dumpvars(0, tb_axis_skid_dump);
    end

endmodule
