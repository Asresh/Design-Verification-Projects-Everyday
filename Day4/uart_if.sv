// -----------------------------------------------------------------------------
// uart_if.sv  -  UART interface + clocking blocks + framing assertions (SVA)
//
// Carries both the parallel side (tx_start/tx_data, rx_data/rx_valid, status)
// and the two serial wires. The TX agent drives the parallel transmit side; the
// RX agent bit-bangs the serial receive line; monitors sample everything.
// -----------------------------------------------------------------------------
interface uart_if (
    input logic clk,
    input logic rst_n
);
    // Shared baud divisor (clocks per serial bit).
    logic [15:0] cfg_clks_per_bit;

    // TX (parallel) side.
    logic        tx_start;
    logic [7:0]  tx_data;
    logic        tx_serial;   // driven by DUT TX
    logic        tx_busy;
    logic        tx_done;

    // RX side.
    logic        rx_serial;   // driven into DUT RX (by loopback or RX BFM)
    logic [7:0]  rx_data;
    logic        rx_valid;
    logic        framing_err;

    // TX-agent driver: pulses tx_start / tx_data.
    clocking tx_drv_cb @(posedge clk);
        default input #1step output #1;
        output tx_start, tx_data;
        input  tx_serial, tx_busy, tx_done;
    endclocking

    // RX-agent driver: bit-bangs the serial receive line.
    clocking rx_drv_cb @(posedge clk);
        default input #1step output #1;
        output rx_serial;
        input  rx_data, rx_valid, framing_err;
    endclocking

    // Passive monitor: sample everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input tx_start, tx_data, tx_serial, tx_busy, tx_done,
              rx_serial, rx_data, rx_valid, framing_err, cfg_clks_per_bit;
    endclocking

    modport tx_drv (clocking tx_drv_cb, input clk, rst_n);
    modport rx_drv (clocking rx_drv_cb, input clk, rst_n);
    modport mon    (clocking mon_cb,    input clk, rst_n);

    // ------------------------------------------------------------------
    // Framing assertions (only meaningful under an SVA-capable sim).
    // ------------------------------------------------------------------
`ifndef UART_NO_SVA
    // The transmit line idles high whenever TX is not busy.
    a_tx_idle_high: assert property (
        @(posedge clk) disable iff (!rst_n)
            (!tx_busy && !tx_start) |-> tx_serial)
        else $error("UART: tx_serial not high while idle");

    // A rx_valid pulse lasts exactly one cycle.
    a_rx_valid_pulse: assert property (
        @(posedge clk) disable iff (!rst_n)
            rx_valid |=> !rx_valid)
        else $error("UART: rx_valid asserted for more than one cycle");

    // When a byte is accepted with no framing error, the line is at the stop
    // level (high) on that cycle.
    a_stop_high_on_valid: assert property (
        @(posedge clk) disable iff (!rst_n)
            (rx_valid && !framing_err) |-> rx_serial)
        else $error("UART: stop bit not high on a clean rx_valid");

    // tx_done implies a frame just finished (TX returns to idle next cycle).
    a_done_then_idle: assert property (
        @(posedge clk) disable iff (!rst_n)
            tx_done |=> !tx_busy)
        else $error("UART: tx_busy still set after tx_done");
`endif
endinterface
