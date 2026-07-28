// -----------------------------------------------------------------------------
// tb_axil_dump.sv  -  Plain module-based, self-checking AXI4-Lite testbench
//
// The simulator-portable companion to the UVM environment. A task-based
// AXI4-Lite master BFM drives the same axil_regfile DUT with directed and
// randomized read/write traffic (including WSTRB partial writes and
// out-of-range accesses), checks every transfer against an inline golden
// register model, prints "RESULT: *** PASS ***" on success, and dumps a VCD.
//
// It exists because the open-source Icarus Verilog simulator (used to capture
// the committed waveform) does not implement the UVM class library; this TB
// lets the DUT be genuinely simulated and self-checked without UVM.
//
// BFM timing model:  the master presents a channel's payload one delta (#STEP)
// after a posedge and, because the slave's *READY outputs are combinational and
// asserted while idle, the address/data handshakes complete on the very next
// posedge (single-outstanding, always-drained -> deterministic latency). The
// master keeps BREADY and RREADY asserted permanently (a legal always-ready
// master) and polls the registered BVALID / RVALID for completion.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_axil_dump;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;
    localparam int NBYTES     = DATA_WIDTH/8;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    logic                    ACLK;
    logic                    ARESETn;
    // AW
    logic [ADDR_WIDTH-1:0]   AWADDR;
    logic                    AWVALID, AWREADY;
    // W
    logic [DATA_WIDTH-1:0]   WDATA;
    logic [NBYTES-1:0]       WSTRB;
    logic                    WVALID, WREADY;
    // B
    logic [1:0]              BRESP;
    logic                    BVALID, BREADY;
    // AR
    logic [ADDR_WIDTH-1:0]   ARADDR;
    logic                    ARVALID, ARREADY;
    // R
    logic [DATA_WIDTH-1:0]   RDATA;
    logic [1:0]              RRESP;
    logic                    RVALID, RREADY;

    int errors = 0;
    int checks = 0;

    // Golden reference model (mirror of the DUT register file).
    logic [DATA_WIDTH-1:0] model [NUM_REGS];

    axil_regfile #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .NUM_REGS(NUM_REGS)
    ) dut (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWADDR(AWADDR), .AWVALID(AWVALID), .AWREADY(AWREADY),
        .WDATA(WDATA), .WSTRB(WSTRB), .WVALID(WVALID), .WREADY(WREADY),
        .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
        .ARADDR(ARADDR), .ARVALID(ARVALID), .ARREADY(ARREADY),
        .RDATA(RDATA), .RRESP(RRESP), .RVALID(RVALID), .RREADY(RREADY)
    );

    // 100 MHz clock.
    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    localparam time STEP = 1;

    // -------------------------------------------------------------------------
    // AXI4-Lite master BFM
    // -------------------------------------------------------------------------
    task automatic bus_idle();
        AWADDR  = '0; AWVALID = 1'b0;
        WDATA   = '0; WSTRB = '0; WVALID = 1'b0;
        ARADDR  = '0; ARVALID = 1'b0;
        BREADY  = 1'b1;   // always-ready master
        RREADY  = 1'b1;
    endtask

    // Write a word; returns the observed BRESP.
    task automatic axil_write(input  [ADDR_WIDTH-1:0] a,
                              input  [DATA_WIDTH-1:0] d,
                              input  [NBYTES-1:0]     s,
                              output [1:0]            resp);
        // Present AW + W one delta after a posedge.
        @(posedge ACLK) #STEP;
        AWADDR = a; AWVALID = 1'b1;
        WDATA  = d; WSTRB   = s; WVALID = 1'b1;
        // Next posedge = accept edge (AWREADY/WREADY combinational-high, idle).
        @(posedge ACLK) #STEP;
        AWVALID = 1'b0;
        WVALID  = 1'b0;
        // Poll the registered write response.
        while (!BVALID) @(posedge ACLK) #STEP;
        resp = BRESP;
        @(posedge ACLK) #STEP;   // let the B handshake retire BVALID
    endtask

    // Read a word; returns observed RDATA and RRESP.
    task automatic axil_read(input  [ADDR_WIDTH-1:0] a,
                             output [DATA_WIDTH-1:0] rd,
                             output [1:0]            resp);
        @(posedge ACLK) #STEP;
        ARADDR = a; ARVALID = 1'b1;
        @(posedge ACLK) #STEP;   // accept edge
        ARVALID = 1'b0;
        while (!RVALID) @(posedge ACLK) #STEP;
        rd   = RDATA;
        resp = RRESP;
        @(posedge ACLK) #STEP;   // let the R handshake retire RVALID
    endtask

    // -------------------------------------------------------------------------
    // Inline scoreboard: check one write against the golden model.
    // -------------------------------------------------------------------------
    task automatic do_write(input [ADDR_WIDTH-1:0] a,
                            input [DATA_WIDTH-1:0] d,
                            input [NBYTES-1:0]     s);
        logic [1:0]  resp;
        int unsigned idx = a >> $clog2(NBYTES);
        bit          oob = (idx >= NUM_REGS);
        axil_write(a, d, s, resp);
        checks++;
        if (resp !== (oob ? RESP_SLVERR : RESP_OKAY)) begin
            errors++;
            $display("  [FAIL] BRESP @0x%02h exp=%02b got=%02b", a,
                     (oob ? RESP_SLVERR : RESP_OKAY), resp);
        end
        if (!oob) begin
            for (int b = 0; b < NBYTES; b++)
                if (s[b]) model[idx][8*b +: 8] = d[8*b +: 8];
        end
    endtask

    // Check one read against the golden model.
    task automatic do_read(input [ADDR_WIDTH-1:0] a);
        logic [DATA_WIDTH-1:0] rd;
        logic [1:0]            resp;
        int unsigned idx = a >> $clog2(NBYTES);
        bit          oob = (idx >= NUM_REGS);
        logic [DATA_WIDTH-1:0] exp = oob ? '0 : model[idx];
        logic [1:0]            expr = oob ? RESP_SLVERR : RESP_OKAY;
        axil_read(a, rd, resp);
        checks++;
        if (resp !== expr) begin
            errors++;
            $display("  [FAIL] RRESP @0x%02h exp=%02b got=%02b", a, expr, resp);
        end
        if (rd !== exp) begin
            errors++;
            $display("  [FAIL] RDATA @0x%02h exp=0x%08h got=0x%08h", a, exp, rd);
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    integer                seed = 32'hC0FFEE01;
    int unsigned           widx;
    logic [ADDR_WIDTH-1:0] ra;
    logic [DATA_WIDTH-1:0] rdw;
    logic [NBYTES-1:0]     rs;
    bit                    rwr;

    initial begin
        $dumpfile("tb_axil_dump.vcd");
        $dumpvars(0, tb_axil_dump);

        foreach (model[i]) model[i] = '0;
        bus_idle();

        // Reset.
        ARESETn = 1'b0;
        repeat (4) @(posedge ACLK);
        ARESETn = 1'b1;
        @(posedge ACLK);

        // ---- Showcase window (captured in the committed waveform) ----
        // A compact write -> read -> out-of-range scenario so the waveform
        // shows reset release, a full AW/W/B write, an AR/R read hit returning
        // the written data, and SLVERR on a bad address.
        $display("INFO: showcase - write reg1, read reg1, OOB write, OOB read");
        do_write(1 << 2, 32'hCAFE_BABE, 4'hF);      // write reg1
        do_read (1 << 2);                            // read  reg1 -> CAFEBABE
        do_write(NUM_REGS << 2, 32'hFFFF_FFFF, 4'hF);// OOB write -> SLVERR
        do_read (NUM_REGS << 2);                     // OOB read  -> SLVERR, 0
        repeat (2) @(posedge ACLK);

        // ---- Directed sweeps ----
        $display("INFO: write-all sweep");
        for (int i = 0; i < NUM_REGS; i++)
            do_write(i << 2, 32'hA5A5_0000 | i, 4'hF);

        $display("INFO: read-all sweep");
        for (int i = 0; i < NUM_REGS; i++)
            do_read(i << 2);

        $display("INFO: byte-strobe partial write to reg3 (lanes 0 and 2)");
        do_write(3 << 2, 32'hDEAD_BEEF, 4'b0101);
        do_read (3 << 2);

        $display("INFO: out-of-range write + read (expect SLVERR)");
        do_write(NUM_REGS << 2, 32'hFFFF_FFFF, 4'hF);
        do_read ((NUM_REGS + 3) << 2);

        // ---- Constrained-random traffic ----
        $display("INFO: constrained-random read/write mix (200 ops)");
        for (int i = 0; i < 200; i++) begin
            rwr = $random(seed) & 1'b1;
            // mostly in-range, occasionally out-of-range
            if (($random(seed) % 8) == 0)
                widx = NUM_REGS + ({$random(seed)} % 8);        // OOB
            else
                widx = {$random(seed)} % NUM_REGS;              // in range
            ra  = widx << 2;
            rdw = $random(seed);
            rs  = ({$random(seed)} % 15) + 1;   // 1..15, never all-zero strobes
            if (rwr) do_write(ra, rdw, rs);
            else     do_read(ra);
        end

        $display("INFO: final read-back sweep (state integrity)");
        for (int i = 0; i < NUM_REGS; i++)
            do_read(i << 2);

        repeat (4) @(posedge ACLK);

        $display("INFO: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // Watchdog.
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
