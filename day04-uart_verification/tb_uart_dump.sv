// -----------------------------------------------------------------------------
// tb_uart_dump.sv  -  Plain module-based, self-checking UART testbench
//
// The simulator-portable companion to the UVM environment. It wires the UART in
// loopback (tx_serial -> rx_serial) and, for every byte, checks TWO things:
//
//   1) End-to-end: the byte the RX hardware deserializes (rx_data on rx_valid)
//      equals the byte the TX was asked to send, with framing_err == 0.
//   2) Line-level: an independent TB serial decoder samples the raw tx_serial
//      line at each bit centre and confirms start=0, 8 data bits (LSB first)
//      equal to the sent byte, and stop=1.
//
// Bytes are sent across several baud settings (cfg_clks_per_bit) including
// directed patterns (all-0, all-1, walking-1, alternating) and random data.
// Prints "RESULT: *** PASS ***" when errors == 0 and dumps a VCD.
//
// It exists because the open-source Icarus Verilog simulator (used to capture
// the committed waveform) does not implement the UVM class library.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_uart_dump;

    logic        clk;
    logic        rst_n;
    logic [15:0] cfg_clks_per_bit;
    logic        tx_start;
    logic [7:0]  tx_data;
    logic        tx_serial;
    logic        tx_busy;
    logic        tx_done;
    logic        rx_serial;
    logic [7:0]  rx_data;
    logic        rx_valid;
    logic        framing_err;

    int errors = 0;
    int checks = 0;

    // Loopback: transmit line feeds the receive line.
    assign rx_serial = tx_serial;

    uart dut (
        .clk(clk), .rst_n(rst_n), .cfg_clks_per_bit(cfg_clks_per_bit),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_serial(tx_serial), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx_serial(rx_serial),
        .rx_data(rx_data), .rx_valid(rx_valid), .framing_err(framing_err)
    );

    // 100 MHz clock.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Independent line-level serial decoder (samples raw tx_serial at bit
    // centres, aligned to the TX start-bit falling edge).
    // -------------------------------------------------------------------------
    task automatic decode_serial(input [7:0] expected);
        int         n;
        logic [7:0] got;
        n = cfg_clks_per_bit;
        @(negedge tx_serial);                 // start bit begins
        repeat (n/2) @(posedge clk);          // -> centre of start bit
        checks++;
        if (tx_serial !== 1'b0) begin
            errors++;
            $display("  [FAIL] serial: start bit not low");
        end
        for (int i = 0; i < 8; i++) begin
            repeat (n) @(posedge clk);         // -> centre of data bit i
            got[i] = tx_serial;
        end
        repeat (n) @(posedge clk);             // -> centre of stop bit
        checks++;
        if (tx_serial !== 1'b1) begin
            errors++;
            $display("  [FAIL] serial: stop bit not high");
        end
        checks++;
        if (got !== expected) begin
            errors++;
            $display("  [FAIL] serial decode exp=0x%02h got=0x%02h", expected, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Send one byte and check both the RX hardware and the line decoder.
    // -------------------------------------------------------------------------
    task automatic send_byte(input [7:0] b);
        fork
            begin : drive_tx
                @(posedge clk);
                tx_start <= 1'b1;
                tx_data  <= b;
                @(posedge clk);
                tx_start <= 1'b0;
            end
            begin : line_decode
                decode_serial(b);
            end
            begin : rx_check
                @(posedge rx_valid);           // wait for the deserialized byte
                checks++;
                if (rx_data !== b) begin
                    errors++;
                    $display("  [FAIL] rx_data exp=0x%02h got=0x%02h", b, rx_data);
                end
                checks++;
                if (framing_err !== 1'b0) begin
                    errors++;
                    $display("  [FAIL] framing_err asserted for 0x%02h", b);
                end
            end
        join
        // Idle gap so the line + RX settle before the next byte.
        repeat (cfg_clks_per_bit * 2) @(posedge clk);
    endtask

    // Send a set of bytes at a given baud divisor.
    task automatic run_baud(input [15:0] n, input [8*10:1] label);
        @(posedge clk);
        cfg_clks_per_bit <= n;
        repeat (4) @(posedge clk);             // let the new divisor settle
        $display("INFO: baud cfg_clks_per_bit=%0d (%0s)", n, label);
        send_byte(8'h00);   // all zeros
        send_byte(8'hFF);   // all ones
        send_byte(8'hA5);   // 1010_0101
        send_byte(8'h5A);   // 0101_1010
        send_byte(8'h01);   // LSB only
        send_byte(8'h80);   // MSB only
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    integer seed = 32'hDEAD_BEEF;
    logic [7:0] rb;

    initial begin
        $dumpfile("tb_uart_dump.vcd");
        $dumpvars(0, tb_uart_dump);

        // Idle defaults.
        cfg_clks_per_bit = 16'd16;
        tx_start = 1'b0;
        tx_data  = 8'h00;

        // Reset.
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- Showcase byte (captured in the committed waveform) ----
        // A single 0xA5 at cfg=16 shows a clean start/8-data/stop frame.
        $display("INFO: showcase - transmit 0xA5 at cfg_clks_per_bit=16");
        cfg_clks_per_bit <= 16'd16;
        repeat (2) @(posedge clk);
        send_byte(8'hA5);

        // ---- Directed sweeps across baud settings ----
        run_baud(16'd16, "cfg16");
        run_baud(16'd24, "cfg24");
        run_baud(16'd12, "cfg12");

        // ---- Random bytes at cfg=20 ----
        $display("INFO: random bytes at cfg_clks_per_bit=20");
        cfg_clks_per_bit <= 16'd20;
        repeat (4) @(posedge clk);
        for (int i = 0; i < 16; i++) begin
            rb = $random(seed);
            send_byte(rb);
        end

        repeat (20) @(posedge clk);

        $display("INFO: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // Watchdog.
    initial begin
        #2000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
