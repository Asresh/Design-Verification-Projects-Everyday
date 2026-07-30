// ============================================================================
// tb_spi_master_dump.sv - portable, self-checking module testbench for
// `spi_master`.
//
// WHY THIS EXISTS
//   Icarus Verilog (the open-source simulator this repo runs on) does not
//   implement the UVM class library, so it cannot elaborate spi_master_pkg.sv
//   / tb_top.sv. This companion testbench reproduces the SAME verification
//   intent - an INDEPENDENT SPI-slave reference model, a full-duplex
//   scoreboard, directed coverage of all four SPI modes, a constrained-random
//   regression, and a VCD dump - in plain SystemVerilog that runs everywhere.
//
// HOW THE CHECKING WORKS
//   A correct full-duplex SPI exchange has a simple invariant: each side
//   receives EXACTLY what the other side sent. The testbench instantiates an
//   independent behavioural SPI slave (it shares no logic with the DUT - it
//   samples MOSI and drives MISO purely from the SCLK/CS_N pins and the mode
//   configuration). For every transfer the scoreboard then requires:
//       * master rx_data  == the byte the slave shifted back  (MISO path)
//       * slave received   == the byte the master was told to send (MOSI path)
//   across CPOL/CPHA modes 0..3, several clock dividers, and random data.
//   Any mismatch is fatal; the run prints "RESULT: *** PASS ***" only if every
//   transfer of every mode checks out.
//
// The FIRST transfer is a directed mode-0 showcase (master 0xA5 <-> slave 0x3C)
// with a small divider so the committed waveform shows a clean, readable
// exchange: CS_N asserting, SCLK stepping, MSB-first MOSI/MISO shifting, and
// done pulsing with rx_data captured.
// ============================================================================
`timescale 1ns/1ps
module tb_spi_master_dump;

    localparam int DATA_WIDTH = 8;
    localparam int DIV_WIDTH  = 16;

    // ------------------------------------------------------------------ nets
    logic                  clk, rst_n;
    logic                  start, cpol, cpha;
    logic [DIV_WIDTH-1:0]  clk_div;
    logic [DATA_WIDTH-1:0] tx_data;
    logic                  sclk, cs_n, mosi, miso;
    logic [DATA_WIDTH-1:0] rx_data;
    logic                  busy, done;

    // ------------------------------------------------------------------ DUT
    spi_master #(.DATA_WIDTH(DATA_WIDTH), .DIV_WIDTH(DIV_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .cpol(cpol), .cpha(cpha),
        .clk_div(clk_div), .tx_data(tx_data),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .rx_data(rx_data), .busy(busy), .done(done)
    );

    // ------------------------------------------------------------------ clock
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period

    // ------------------------------------------------------------------ reset
    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // ====================================================================
    // INDEPENDENT SPI SLAVE reference model.
    //   Shares no logic with the DUT: it observes SCLK/CS_N/MOSI and drives
    //   MISO using only the agreed mode. Same output-then-advance / pre-drive
    //   rules a real slave uses, expressed independently from the master RTL.
    // ====================================================================
    logic                  cpol_tb, cpha_tb;         // mode the slave is told
    logic [DATA_WIDTH-1:0] slave_tx_byte;            // byte the slave will send
    logic [DATA_WIDTH-1:0] slv_tx, slv_rx;           // slave shifters
    logic                  miso_drv;
    assign miso = miso_drv;

    // Pre-load at chip-select assertion (CPHA=0 pre-drives the MSB).
    always @(negedge cs_n) begin
        slv_rx = '0;
        if (!cpha_tb) begin
            miso_drv = slave_tx_byte[DATA_WIDTH-1];
            slv_tx   = slave_tx_byte << 1;
        end else begin
            miso_drv = 1'b0;
            slv_tx   = slave_tx_byte;
        end
    end

    task automatic slave_edge(input bit is_posedge);
        bit leading, sample_e;
        leading  = (is_posedge != cpol_tb);          // transition toward ~CPOL
        sample_e = cpha_tb ? ~leading : leading;      // when the slave samples MOSI
        if (sample_e) begin
            slv_rx = {slv_rx[DATA_WIDTH-2:0], mosi};   // capture master's bit
        end else begin
            miso_drv = slv_tx[DATA_WIDTH-1];           // present next bit to master
            slv_tx   = slv_tx << 1;
        end
    endtask

    always @(posedge sclk) if (!cs_n) slave_edge(1'b1);
    always @(negedge sclk) if (!cs_n) slave_edge(1'b0);

    // ====================================================================
    // Scoreboard / stimulus.
    // ====================================================================
    int xfers  = 0;
    int errors = 0;

    // Golden check for one completed transfer: full-duplex identity.
    task automatic check_xfer(input [DATA_WIDTH-1:0] m_sent,
                              input [DATA_WIDTH-1:0] s_sent,
                              input logic cpol_i, cpha_i,
                              input [DIV_WIDTH-1:0] div_i);
        xfers = xfers + 1;
        if (rx_data !== s_sent) begin
            errors = errors + 1;
            $display("[%0t] MISMATCH (MISO) mode=%0d%0d div=%0d: master rx=%02h exp=%02h",
                     $time, cpol_i, cpha_i, div_i, rx_data, s_sent);
        end
        if (slv_rx !== m_sent) begin
            errors = errors + 1;
            $display("[%0t] MISMATCH (MOSI) mode=%0d%0d div=%0d: slave rx=%02h exp=%02h",
                     $time, cpol_i, cpha_i, div_i, slv_rx, m_sent);
        end
    endtask

    // Drive one complete full-duplex transfer and score it.
    task automatic do_xfer(input logic cpol_i, cpha_i,
                           input [DIV_WIDTH-1:0] div_i,
                           input [DATA_WIDTH-1:0] m_tx, s_tx);
        @(posedge clk);
        // Configure both the DUT and the slave BEFORE start (before CS asserts).
        cpol_tb       = cpol_i;
        cpha_tb       = cpha_i;
        slave_tx_byte = s_tx;
        cpol          = cpol_i;
        cpha          = cpha_i;
        clk_div       = div_i;
        tx_data       = m_tx;
        start        <= 1'b1;
        @(posedge clk);
        start        <= 1'b0;
        @(posedge done);           // transfer complete
        @(posedge clk);            // let rx_data / slv_rx settle
        check_xfer(m_tx, s_tx, cpol_i, cpha_i, div_i);
    endtask

    // -------------------------------------------------- stimulus program
    integer i;
    logic [31:0] r;
    logic        rc, rp;
    logic [DATA_WIDTH-1:0] md, sd;
    logic [DIV_WIDTH-1:0]  dv;

    initial begin
        start   = 1'b0; cpol = 1'b0; cpha = 1'b0; clk_div = 16'd2;
        tx_data = '0; cpol_tb = 1'b0; cpha_tb = 1'b0; slave_tx_byte = '0;
        miso_drv = 1'b0; slv_tx = '0; slv_rx = '0;

        @(posedge rst_n);
        @(posedge clk);

        // ---- DIRECTED showcase (mode 0, small divider) for the waveform ----
        do_xfer(1'b0, 1'b0, 16'd2, 8'hA5, 8'h3C);

        // ---- DIRECTED: every SPI mode with a couple of dividers ----
        do_xfer(1'b0, 1'b0, 16'd3, 8'h81, 8'h7E);   // mode 0
        do_xfer(1'b0, 1'b1, 16'd2, 8'hFF, 8'h00);   // mode 1, all-ones vs all-zeros
        do_xfer(1'b1, 1'b0, 16'd2, 8'h00, 8'hFF);   // mode 2
        do_xfer(1'b1, 1'b1, 16'd3, 8'hC3, 8'h5A);   // mode 3
        do_xfer(1'b0, 1'b0, 16'd1, 8'h5A, 8'hA5);   // fastest divider (SCLK = clk/2)

        // ---- CONSTRAINED-RANDOM regression across all modes ----
        for (i = 0; i < 60; i = i + 1) begin
            r  = $random; rc = r[0]; rp = r[1];
            r  = $random; dv = (r % 3) + 1;              // divider 1..3
            r  = $random; md = r[DATA_WIDTH-1:0];
            r  = $random; sd = r[DATA_WIDTH-1:0];
            do_xfer(rc, rp, dv, md, sd);
        end

        repeat (5) @(posedge clk);
        $display("----------------------------------------------------------");
        $display(" transfers=%0d  errors=%0d", xfers, errors);
        if (errors == 0 && xfers > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (errors=%0d)", errors);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------- timeout
    initial begin
        #500000;   // 500 us hard cap
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ------------------------------------------------------------- VCD dump
    initial begin
        $dumpfile("tb_spi_master_dump.vcd");
        $dumpvars(0, tb_spi_master_dump);
    end

endmodule
