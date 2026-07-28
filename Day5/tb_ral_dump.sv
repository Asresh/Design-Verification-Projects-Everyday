// -----------------------------------------------------------------------------
// tb_ral_dump.sv  -  Plain module-based, self-checking testbench for the
//                    register block with RW / RO / W1C fields
//
// The simulator-portable companion to the UVM RAL environment. A task-based APB
// master BFM exercises the same ral_regblock DUT through the bus front door and
// checks every access against an inline golden model that mirrors each field's
// access policy (RW read/write, RO write-ignored, W1C write-1-to-clear with a
// hardware-set event). Prints "RESULT: *** PASS ***" on success, dumps a VCD.
//
// It exists because the open-source Icarus Verilog simulator (used to capture
// the committed waveform) does not implement the UVM class library; this TB
// self-checks the DUT without UVM, mirroring what the RAL model + predictor and
// the uvm_reg_hw_reset_seq / uvm_reg_bit_bash_seq verify under a UVM simulator.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ral_dump;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NBYTES     = DATA_WIDTH/8;

    // Register byte addresses.
    localparam [7:0] CTRL = 8'h00, STATUS = 8'h04, INTF = 8'h08, SCRATCH = 8'h0C;

    logic                    PCLK, PRESETn;
    logic                    PSEL, PENABLE, PWRITE;
    logic [ADDR_WIDTH-1:0]   PADDR;
    logic [DATA_WIDTH-1:0]   PWDATA;
    logic [NBYTES-1:0]       PSTRB;
    logic [DATA_WIDTH-1:0]   PRDATA;
    logic                    PREADY, PSLVERR;
    logic [DATA_WIDTH-1:0]   hw_event;

    int errors = 0;
    int checks = 0;

    // Golden model of the four registers.
    logic [DATA_WIDTH-1:0] m_ctrl, m_status, m_intf, m_scratch;

    ral_regblock #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (
        .PCLK(PCLK), .PRESETn(PRESETn),
        .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PADDR(PADDR), .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .hw_event(hw_event)
    );

    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    localparam time STEP = 1;

    // -------------------------------------------------------------------------
    // APB master BFM (two-phase, zero-wait slave). Stimulus is driven one delta
    // after each posedge so the DUT's always_ff samples the intended values.
    // -------------------------------------------------------------------------
    task automatic apb_idle();
        PSEL = 0; PENABLE = 0; PWRITE = 0; PADDR = '0; PWDATA = '0; PSTRB = '0;
    endtask

    task automatic apb_write(input [ADDR_WIDTH-1:0] a,
                             input [DATA_WIDTH-1:0] d,
                             input [NBYTES-1:0]     s,
                             output logic           err);
        @(posedge PCLK) #STEP;                       // SETUP
        PSEL = 1; PENABLE = 0; PWRITE = 1; PADDR = a; PWDATA = d; PSTRB = s;
        @(posedge PCLK) #STEP;                       // ACCESS
        PENABLE = 1;
        @(posedge PCLK) #STEP;                        // completing edge
        err = PSLVERR;
        apb_idle();
    endtask

    task automatic apb_read(input  [ADDR_WIDTH-1:0] a,
                            output logic [DATA_WIDTH-1:0] rd,
                            output logic                  err);
        @(posedge PCLK) #STEP;                       // SETUP
        PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = a; PWDATA = '0; PSTRB = '0;
        @(posedge PCLK) #STEP;                       // ACCESS
        PENABLE = 1;
        @(posedge PCLK) #STEP;                        // completing edge
        rd  = PRDATA;
        err = PSLVERR;
        apb_idle();
    endtask

    // Pulse a hardware event for exactly one cycle (sets INTFLAGS bits).
    task automatic pulse_event(input [DATA_WIDTH-1:0] v);
        @(posedge PCLK) #STEP;
        hw_event = v;
        @(posedge PCLK) #STEP;
        hw_event = '0;
        m_intf = m_intf | v;      // OR-in (no concurrent bus clear)
    endtask

    // ---- Golden helpers ----
    function automatic logic [DATA_WIDTH-1:0] strobed(
            input logic [DATA_WIDTH-1:0] cur,
            input logic [DATA_WIDTH-1:0] wr,
            input logic [NBYTES-1:0]     s);
        logic [DATA_WIDTH-1:0] r = cur;
        for (int b = 0; b < NBYTES; b++)
            if (s[b]) r[8*b +: 8] = wr[8*b +: 8];
        return r;
    endfunction

    // ---- Checked front-door write (updates model per field policy) ----
    task automatic wr_chk(input [ADDR_WIDTH-1:0] a,
                          input [DATA_WIDTH-1:0] d,
                          input [NBYTES-1:0]     s);
        logic err;
        int unsigned i = a >> 2;
        apb_write(a, d, s, err);
        checks++;
        if (err !== 1'b0) begin
            errors++;
            $display("  [FAIL] unexpected PSLVERR on write @0x%02h", a);
        end
        case (i)
            0: m_ctrl    = strobed(m_ctrl, d, s);          // RW
            1: ;                                           // RO: ignored
            2: m_intf    = m_intf & ~strobed('0, d, s);    // W1C clear
            3: m_scratch = strobed(m_scratch, d, s);       // RW
            default: ;
        endcase
    endtask

    // ---- Checked front-door read (compares vs model) ----
    task automatic rd_chk(input [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] exp);
        logic [DATA_WIDTH-1:0] rd;
        logic                  err;
        apb_read(a, rd, err);
        checks++;
        if (err !== 1'b0) begin
            errors++;
            $display("  [FAIL] unexpected PSLVERR on read @0x%02h", a);
        end
        if (rd !== exp) begin
            errors++;
            $display("  [FAIL] read @0x%02h exp=0x%08h got=0x%08h", a, exp, rd);
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    integer seed = 32'h5A5A_1234;
    logic [DATA_WIDTH-1:0] rdv;
    logic                  errv;
    logic [ADDR_WIDTH-1:0] ra;
    logic [DATA_WIDTH-1:0] rd;
    logic [NBYTES-1:0]     rs;

    initial begin
        $dumpfile("tb_ral_dump.vcd");
        $dumpvars(0, tb_ral_dump);

        // Model reset values (mirror the DUT).
        m_ctrl = 32'h0; m_status = 32'hDEAD_BEEF; m_intf = 32'h0; m_scratch = 32'h0;
        apb_idle();
        hw_event = '0;

        // Reset.
        PRESETn = 0;
        repeat (3) @(posedge PCLK);
        PRESETn = 1;
        @(posedge PCLK);

        // ---- Showcase window (captured in the committed waveform) ----
        // A couple of register writes/reads: write CTRL, read CTRL, read the
        // read-only STATUS returning its hardware reset value.
        $display("INFO: showcase - write CTRL, read CTRL, read RO STATUS");
        wr_chk(CTRL, 32'h1234_5678, 4'hF);
        rd_chk(CTRL, m_ctrl);
        rd_chk(STATUS, m_status);          // 0xDEADBEEF
        repeat (2) @(posedge PCLK);

        // ---- hw_reset check: every register reads its reset value ----
        $display("INFO: hw_reset - check reset values (mirrors uvm_reg_hw_reset_seq)");
        // (re-apply reset so the earlier CTRL write does not mask the check)
        PRESETn = 0; repeat (3) @(posedge PCLK); PRESETn = 1; @(posedge PCLK);
        m_ctrl = 32'h0; m_status = 32'hDEAD_BEEF; m_intf = 32'h0; m_scratch = 32'h0;
        rd_chk(CTRL,    32'h0000_0000);
        rd_chk(STATUS,  32'hDEAD_BEEF);
        rd_chk(INTF,    32'h0000_0000);
        rd_chk(SCRATCH, 32'h0000_0000);

        // ---- RW behaviour (CTRL, SCRATCH) incl. byte strobes ----
        $display("INFO: RW - CTRL / SCRATCH write-read round-trips");
        wr_chk(CTRL,    32'hA5A5_5A5A, 4'hF); rd_chk(CTRL,    m_ctrl);
        wr_chk(SCRATCH, 32'hCAFE_BABE, 4'hF); rd_chk(SCRATCH, m_scratch);
        wr_chk(CTRL,    32'h0000_00FF, 4'b0001); rd_chk(CTRL, m_ctrl); // low byte only
        wr_chk(SCRATCH, 32'hFF00_0000, 4'b1000); rd_chk(SCRATCH, m_scratch);

        // ---- RO behaviour (STATUS): writes ignored ----
        $display("INFO: RO - STATUS ignores writes, keeps hardware value");
        wr_chk(STATUS, 32'hFFFF_FFFF, 4'hF);   // ignored by RO field
        rd_chk(STATUS, 32'hDEAD_BEEF);

        // ---- W1C behaviour (INTFLAGS): hw sets, write-1 clears ----
        $display("INFO: W1C - INTFLAGS hardware-set then write-1-to-clear");
        pulse_event(32'h0000_00FF);            // hw sets low byte
        rd_chk(INTF, m_intf);                  // expect 0x000000FF
        wr_chk(INTF, 32'h0000_000F, 4'hF);     // clear low nibble
        rd_chk(INTF, m_intf);                  // expect 0x000000F0
        wr_chk(INTF, 32'h0000_0000, 4'hF);     // write 0 -> no change
        rd_chk(INTF, m_intf);                  // still 0x000000F0
        pulse_event(32'h0000_0F00);            // hw sets more bits
        rd_chk(INTF, m_intf);                  // expect 0x00000FF0
        wr_chk(INTF, 32'hFFFF_FFFF, 4'hF);     // clear everything
        rd_chk(INTF, m_intf);                  // expect 0

        // ---- Bit-bash style walk on the RW CTRL register ----
        $display("INFO: bit-bash - walking-1 across CTRL (mirrors uvm_reg_bit_bash_seq)");
        for (int b = 0; b < DATA_WIDTH; b++) begin
            wr_chk(CTRL, (32'h1 << b), 4'hF);
            rd_chk(CTRL, m_ctrl);
        end

        // ---- Random RW traffic on CTRL + SCRATCH ----
        $display("INFO: constrained-random RW traffic (100 ops)");
        for (int i = 0; i < 100; i++) begin
            ra = (($random(seed) & 1) ? CTRL : SCRATCH);
            rd = $random(seed);
            rs = ({$random(seed)} % 15) + 1;
            wr_chk(ra, rd, rs);
            rd_chk(ra, (ra == CTRL) ? m_ctrl : m_scratch);
        end

        // ---- Out-of-range access -> PSLVERR ----
        $display("INFO: out-of-range access expects PSLVERR");
        apb_write(8'h40, 32'hDEAD_C0DE, 4'hF, errv);
        checks++;
        if (errv !== 1'b1) begin errors++; $display("  [FAIL] OOB write no PSLVERR"); end
        apb_read(8'h40, rdv, errv);
        checks++;
        if (errv !== 1'b1) begin errors++; $display("  [FAIL] OOB read no PSLVERR"); end
        if (rdv !== 32'h0) begin errors++; $display("  [FAIL] OOB read data non-zero"); end

        repeat (4) @(posedge PCLK);

        $display("INFO: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // Watchdog.
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
