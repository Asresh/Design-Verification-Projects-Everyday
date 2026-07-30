// ============================================================================
// spi_master_if.sv - interface bundling the spi_master pins for the UVM env.
//
// Carries the parallel request/config side (start, cpol, cpha, clk_div,
// tx_data, rx_data, busy, done) driven/monitored by the master agent, plus the
// serial pins (sclk, cs_n, mosi, miso). MISO is driven by the responding
// slave agent; every other signal is a DUT output or a request input.
// ============================================================================
`timescale 1ns/1ps

interface spi_master_if #(
    parameter int DATA_WIDTH = 8,
    parameter int DIV_WIDTH  = 16
) (
    input logic clk,
    input logic rst_n
);
    // ---- parallel request / status ----
    logic                  start;
    logic                  cpol;
    logic                  cpha;
    logic [DIV_WIDTH-1:0]  clk_div;
    logic [DATA_WIDTH-1:0] tx_data;
    logic [DATA_WIDTH-1:0] rx_data;
    logic                  busy;
    logic                  done;

    // ---- serial pins ----
    logic                  sclk;
    logic                  cs_n;
    logic                  mosi;
    logic                  miso;   // driven by the slave agent

    // Master driver clocking block: launches transfer requests.
    clocking mst_cb @(posedge clk);
        default input #1step output #1;
        output start, cpol, cpha, clk_div, tx_data;
        input  rx_data, busy, done, cs_n, sclk, mosi;
    endclocking

    // Master monitor clocking block: samples request + result.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input start, cpol, cpha, clk_div, tx_data, rx_data, busy, done,
              sclk, cs_n, mosi, miso;
    endclocking

    // Slave clocking block: drives MISO, samples the serial pins.
    clocking slv_cb @(posedge clk);
        default input #1step output #1;
        output miso;
        input  sclk, cs_n, mosi, cpol, cpha;
    endclocking

    modport mst (clocking mst_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);
    modport slv (clocking slv_cb, input clk, rst_n);
endinterface
