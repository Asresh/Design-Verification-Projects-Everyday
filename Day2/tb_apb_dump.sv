// -----------------------------------------------------------------------------
// tb_apb_dump.sv  -  Plain module-based, self-checking APB testbench
//
// This is the simulator-portable companion to the UVM environment. It drives
// the same apb_regfile DUT through directed + strobed traffic, checks every
// transfer against an inline golden reference model, exercises the PSLVERR
// error path, prints "RESULT: *** PASS ***" on success, and dumps a VCD.
//
// It exists because the open-source Icarus Verilog simulator (used to capture
// the committed waveform) does not support the UVM class library; this TB lets
// the DUT be genuinely simulated and self-checked without UVM.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_apb_dump;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;
    localparam int NBYTES     = DATA_WIDTH/8;

    logic                    PCLK;
    logic                    PRESETn;
    logic                    PSEL;
    logic                    PENABLE;
    logic                    PWRITE;
    logic [ADDR_WIDTH-1:0]   PADDR;
    logic [DATA_WIDTH-1:0]   PWDATA;
    logic [NBYTES-1:0]       PSTRB;
    logic [DATA_WIDTH-1:0]   PRDATA;
    logic                    PREADY;
    logic                    PSLVERR;

    int errors = 0;

    // Golden reference model.
    logic [DATA_WIDTH-1:0] model [NUM_REGS];

    apb_regfile #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .NUM_REGS(NUM_REGS)
    ) dut (
        .PCLK(PCLK), .PRESETn(PRESETn),
        .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PADDR(PADDR), .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR)
    );

    // 100 MHz clock.
    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    // ---- Bus-functional tasks (two-phase APB) ----
    // Stimulus is driven one delta (#1) after each posedge so the DUT's
    // always_ff samples the intended values (avoids a driver/DUT race on the
    // completing edge). Mirrors the output skew of the UVM clocking block.
    localparam time STEP = 1;

    task automatic apb_setup_idle();
        PSEL = 0; PENABLE = 0; PWRITE = 0; PADDR = '0; PWDATA = '0; PSTRB = '0;
    endtask

    task automatic apb_write(input [ADDR_WIDTH-1:0] a,
                             input [DATA_WIDTH-1:0] d,
                             input [NBYTES-1:0]     s);
        // SETUP
        @(posedge PCLK) #STEP;
        PSEL = 1; PENABLE = 0; PWRITE = 1; PADDR = a; PWDATA = d; PSTRB = s;
        // ACCESS
        @(posedge PCLK) #STEP;
        PENABLE = 1;
        // Completing edge: DUT latches the write here; sample the response.
        @(posedge PCLK) #STEP;
        check_transfer(1, a, d, s, PRDATA, PSLVERR);
        apb_setup_idle();
    endtask

    task automatic apb_read(input [ADDR_WIDTH-1:0] a);
        // SETUP
        @(posedge PCLK) #STEP;
        PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = a; PWDATA = '0; PSTRB = '0;
        // ACCESS
        @(posedge PCLK) #STEP;
        PENABLE = 1;
        // Completing edge: PRDATA/PSLVERR are valid combinationally; sample.
        @(posedge PCLK) #STEP;
        check_transfer(0, a, '0, '0, PRDATA, PSLVERR);
        apb_setup_idle();
    endtask

    // ---- Inline scoreboard ----
    function automatic void check_transfer(
            input bit                  is_write,
            input [ADDR_WIDTH-1:0]     a,
            input [DATA_WIDTH-1:0]     wd,
            input [NBYTES-1:0]         s,
            input [DATA_WIDTH-1:0]     rd,
            input bit                  err);
        int unsigned idx = a >> $clog2(NBYTES);
        bit          oob = (idx >= NUM_REGS);

        if (err !== oob) begin
            errors++;
            $display("  [FAIL] PSLVERR mismatch @0x%02h exp=%0b got=%0b", a, oob, err);
        end
        if (oob) begin
            if (!is_write && rd !== '0) begin
                errors++;
                $display("  [FAIL] OOB read @0x%02h returned 0x%08h (exp 0)", a, rd);
            end
            return;
        end
        if (is_write) begin
            for (int b = 0; b < NBYTES; b++)
                if (s[b]) model[idx][8*b +: 8] = wd[8*b +: 8];
        end else begin
            if (rd !== model[idx]) begin
                errors++;
                $display("  [FAIL] READ @reg%0d exp=0x%08h got=0x%08h",
                         idx, model[idx], rd);
            end
        end
    endfunction

    // ---- Stimulus ----
    initial begin
        $dumpfile("tb_apb_dump.vcd");
        $dumpvars(0, tb_apb_dump);

        foreach (model[i]) model[i] = '0;
        apb_setup_idle();

        // Reset.
        PRESETn = 0;
        repeat (3) @(posedge PCLK);
        PRESETn = 1;
        @(posedge PCLK);

        // ---- Showcase window (captured in the committed waveform) ----
        // A compact write -> read -> out-of-range(error) scenario so the
        // waveform shows reset release, a full SETUP/ACCESS write handshake,
        // a read hit, and PSLVERR on a bad address - all within ~15 cycles.
        $display("INFO: showcase - write reg1, read reg1, OOB write, OOB read");
        apb_write(1 << 2, 32'hCAFE_BABE, 4'hF);   // write reg1
        apb_read (1 << 2);                         // read  reg1 -> CAFEBABE
        apb_write(NUM_REGS << 2, 32'hFFFF_FFFF, 4'hF); // OOB write -> PSLVERR
        apb_read (NUM_REGS << 2);                       // OOB read  -> PSLVERR
        repeat (2) @(posedge PCLK);

        $display("INFO: write-all sweep");
        for (int i = 0; i < NUM_REGS; i++)
            apb_write(i << 2, 32'hA5A5_0000 | i, 4'hF);

        $display("INFO: read-all sweep");
        for (int i = 0; i < NUM_REGS; i++)
            apb_read(i << 2);

        $display("INFO: byte-strobe partial write to reg3");
        apb_write(3 << 2, 32'hDEAD_BEEF, 4'b0101);   // only bytes 0 and 2
        apb_read (3 << 2);

        $display("INFO: out-of-range write + read (expect PSLVERR)");
        apb_write(NUM_REGS << 2, 32'hFFFF_FFFF, 4'hF);
        apb_read (NUM_REGS << 2);

        $display("INFO: overwrite reg7 and confirm");
        apb_write(7 << 2, 32'h1234_5678, 4'hF);
        apb_read (7 << 2);

        repeat (4) @(posedge PCLK);

        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // Watchdog.
    initial begin
        #50000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
