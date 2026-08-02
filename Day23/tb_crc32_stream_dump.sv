// -----------------------------------------------------------------------------
// tb_crc32_stream_dump.sv - portable, module-based, SELF-CHECKING testbench for
// the STREAMING CRC-32 (Ethernet FCS) GENERATOR/CHECKER. Runs on open-source
// Icarus Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - the canonical CRC-32 check vector "123456789"
//     streamed one byte per cycle (zero-bubble) in GENERATE mode, so the captured
//     VCD shows the FCS emerging as the textbook 0xCBF43926, followed by a
//     CHECK-good frame (message + its little-endian FCS -> out_ok=1, residue
//     0x2144DF1C) and a CHECK-bad frame (one payload byte flipped -> out_ok=0),
//   * runs DIRECTED CORNERS (single-byte frame, all-zero payload, all-0xFF
//     payload, back-to-back zero-bubble frames),
//   * runs a CONSTRAINED-RANDOM regression - random-length frames, random GENERATE
//     vs CHECK mode, and for CHECK frames a fair mix of intact and corrupted FCS,
//   * for every frame an independent GOLDEN reference model (the same reflected
//     CRC-32 the DUT implements, bit-identical to zlib/binascii.crc32) computes
//     the expected {out_crc, out_mode, out_ok}, which a FIFO scoreboard checks
//     against the DUT output in arrival order,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// NOTE ON STYLE: Icarus Verilog does not accept queue/dynamic-array arguments to
// functions/tasks, so frames live in a module-level byte buffer `fbuf[0..flen-1]`
// and the helpers take only scalar args - keeping the file fully Icarus-portable.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in crc32_stream_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_crc32_stream_dump;

    localparam int              DW      = 8;
    localparam int              CRCW    = 32;
    localparam [CRCW-1:0]       POLY    = 32'hEDB88320;
    localparam [CRCW-1:0]       INIT    = 32'hFFFFFFFF;
    localparam [CRCW-1:0]       XOROUT  = 32'hFFFFFFFF;
    localparam [CRCW-1:0]       RESIDUE = 32'h2144DF1C;
    localparam int              PIPE    = 2;
    localparam int              LAT     = PIPE;

    localparam bit MODE_GEN = 1'b0;
    localparam bit MODE_CHK = 1'b1;

    logic              clk;
    logic              rst_n;
    logic              in_valid;
    logic              in_sop;
    logic              in_eop;
    logic              in_mode;
    logic [DW-1:0]     in_data;
    logic              out_valid;
    logic [CRCW-1:0]   out_crc;
    logic              out_mode;
    logic              out_ok;

    integer errors = 0;
    integer checks = 0;

    // ----------------------------------------------------------------- DUT -----
    crc32_stream #(.DW(DW), .CRCW(CRCW), .POLY(POLY), .INIT(INIT),
                   .XOROUT(XOROUT), .RESIDUE(RESIDUE), .PIPE(PIPE)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_sop    (in_sop),
        .in_eop    (in_eop),
        .in_mode   (in_mode),
        .in_data   (in_data),
        .out_valid (out_valid),
        .out_crc   (out_crc),
        .out_mode  (out_mode),
        .out_ok    (out_ok)
    );

    // --------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;      // 100 MHz, 10 ns period

    // ------------------------------------------------ frame buffer + golden ----
    // Module-level frame buffer; helpers index it with scalar args only.
    logic [7:0] fbuf [0:1023];
    int         flen;

    // Reflected CRC-32 over fbuf[0..n-1]; bit-identical to the DUT and to
    // zlib/binascii.crc32. Returns the emitted value (running ^ XOROUT).
    function automatic [CRCW-1:0] crc_prefix(input int n);
        logic [CRCW-1:0] c;
        begin
            c = INIT;
            for (int i = 0; i < n; i++) begin
                c = c ^ {{(CRCW-DW){1'b0}}, fbuf[i]};
                for (int k = 0; k < DW; k++)
                    c = c[0] ? ((c >> 1) ^ POLY) : (c >> 1);
            end
            crc_prefix = c ^ XOROUT;
        end
    endfunction

    // Append the little-endian FCS of the first `srclen` bytes at fbuf[flen..].
    task automatic append_fcs(input int srclen);
        logic [CRCW-1:0] f;
        f = crc_prefix(srclen);
        fbuf[flen]   = f[7:0];
        fbuf[flen+1] = f[15:8];
        fbuf[flen+2] = f[23:16];
        fbuf[flen+3] = f[31:24];
        flen = flen + 4;
    endtask

    // -------------------------------------------------- scoreboard FIFOs -------
    logic [CRCW-1:0] exp_crc  [$];
    logic            exp_mode [$];
    logic            exp_ok   [$];
    string           exp_desc [$];

    // ------------------------------------------------------- stimulus ----------
    // Present one byte on the interface, sampled by the DUT at the next posedge.
    task automatic send_byte(input logic v, input logic sop, input logic eop,
                             input logic mode, input logic [7:0] d);
        @(posedge clk);
        in_valid <= v;
        in_sop   <= sop;
        in_eop   <= eop;
        in_mode  <= mode;
        in_data  <= d;
    endtask

    task automatic idle(input int n);
        for (int i = 0; i < n; i++)
            send_byte(1'b0, 1'b0, 1'b0, 1'b0, 8'h00);
    endtask

    // Stream the current fbuf[0..flen-1] as one zero-bubble frame and register
    // the expected result the DUT must produce.
    task automatic drive_fbuf(input bit mode, input string name);
        logic [CRCW-1:0] fcs;
        fcs = crc_prefix(flen);
        exp_crc.push_back(fcs);
        exp_mode.push_back(mode);
        exp_ok.push_back(mode ? (fcs == RESIDUE) : 1'b1);
        exp_desc.push_back(name);
        for (int i = 0; i < flen; i++)
            send_byte(1'b1, (i == 0), (i == flen-1), mode, fbuf[i]);
    endtask

    // ------------------------------------------------------ scoreboard ---------
    logic [CRCW-1:0] ec;
    logic            em, eo;
    string           nm;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (exp_crc.size() == 0) begin
                errors = errors + 1;
                $display("[%0t] SCOREBOARD: unexpected out_valid (crc=%08h) - FIFO empty",
                         $time, out_crc);
            end else begin
                ec = exp_crc.pop_front();
                em = exp_mode.pop_front();
                eo = exp_ok.pop_front();
                nm = exp_desc.pop_front();
                checks = checks + 1;
                if (out_crc !== ec || out_mode !== em || out_ok !== eo) begin
                    errors = errors + 1;
                    $display("[%0t] MISMATCH %-18s DUT{crc=%08h mode=%0d ok=%0d} EXP{crc=%08h mode=%0d ok=%0d}",
                             $time, nm, out_crc, out_mode, out_ok, ec, em, eo);
                end else begin
                    $display("[%0t] OK       %-18s crc=%08h mode=%0d ok=%0d",
                             $time, nm, out_crc, out_mode, out_ok);
                end
            end
        end
    end

    // ----------------------------------------------------------- test ----------
    int    len, mode_sel, corrupt, bidx, shf;
    string rname;
    logic [7:0] bb;

    initial begin
        $dumpfile("tb_crc32_stream_dump.vcd");
        $dumpvars(0, tb_crc32_stream_dump);

        in_valid = 0; in_sop = 0; in_eop = 0; in_mode = 0; in_data = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- DIRECTED SHOWCASE ------------------------------------------------
        // 1) canonical check vector "123456789" in GENERATE mode -> 0xCBF43926
        for (int i = 0; i < 9; i++) fbuf[i] = 8'h31 + i;
        flen = 9;
        drive_fbuf(MODE_GEN, "gen \"123456789\"");

        idle(LAT + 3);                          // let the showcase FCS settle

        // 2) CHECK-good: same message with its intact FCS appended -> ok=1
        for (int i = 0; i < 9; i++) fbuf[i] = 8'h31 + i;
        flen = 9;
        append_fcs(9);                          // flen becomes 13
        drive_fbuf(MODE_CHK, "chk good");

        idle(2);

        // 3) CHECK-bad: flip one payload byte AFTER appending the (stale) FCS ->
        //    the residue no longer matches, so out_ok must be 0.
        for (int i = 0; i < 9; i++) fbuf[i] = 8'h31 + i;
        flen = 9;
        append_fcs(9);
        fbuf[3] = fbuf[3] ^ 8'hFF;              // corrupt payload byte 3
        drive_fbuf(MODE_CHK, "chk corrupt");

        idle(LAT + 3);

        // ---- DIRECTED CORNERS -------------------------------------------------
        // single-byte GENERATE frame (sop & eop same cycle)
        fbuf[0] = 8'h41; flen = 1;              // "A"
        drive_fbuf(MODE_GEN, "gen 1-byte");
        idle(2);

        // all-zero payload
        for (int i = 0; i < 4; i++) fbuf[i] = 8'h00; flen = 4;
        drive_fbuf(MODE_GEN, "gen all-zero");
        idle(2);

        // all-0xFF payload
        for (int i = 0; i < 4; i++) fbuf[i] = 8'hFF; flen = 4;
        drive_fbuf(MODE_GEN, "gen all-ff");
        idle(2);

        // back-to-back ZERO-BUBBLE generate frames (no idle between)
        fbuf[0]=8'hDE; fbuf[1]=8'hAD;                 flen=2; drive_fbuf(MODE_GEN, "b2b #1");
        fbuf[0]=8'hBE; fbuf[1]=8'hEF; fbuf[2]=8'h55;  flen=3; drive_fbuf(MODE_GEN, "b2b #2");
        fbuf[0]=8'h01;                                flen=1; drive_fbuf(MODE_GEN, "b2b #3");
        idle(LAT + 3);

        // ---- CONSTRAINED-RANDOM regression -----------------------------------
        for (int t = 0; t < 400; t++) begin
            len      = $urandom_range(1, 12);
            mode_sel = $urandom_range(0, 1);        // GENERATE or CHECK
            for (int i = 0; i < len; i++)
                fbuf[i] = $urandom_range(0, 255);
            flen = len;

            if (mode_sel == MODE_GEN) begin
                rname = $sformatf("rnd gen %0d", t);
                drive_fbuf(MODE_GEN, rname);
            end else begin
                append_fcs(len);                    // message||FCS as a receiver sees
                corrupt = ($urandom_range(0, 2) == 0);   // ~1/3 corrupted
                if (corrupt) begin
                    bidx = $urandom_range(0, flen-1);
                    shf  = $urandom_range(0, 7);
                    bb   = 8'h01 << shf;
                    fbuf[bidx] = fbuf[bidx] ^ bb;
                    rname = $sformatf("rnd chk BAD %0d", t);
                end else begin
                    rname = $sformatf("rnd chk ok %0d", t);
                end
                drive_fbuf(MODE_CHK, rname);
            end
            if (t % 5 == 0) idle(1);                // vary inter-frame spacing
        end
        idle(LAT + 6);

        // ------------------------------------------------------- verdict -------
        if (exp_crc.size() != 0) begin
            errors = errors + 1;
            $display("SCOREBOARD: %0d expected results never appeared", exp_crc.size());
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
