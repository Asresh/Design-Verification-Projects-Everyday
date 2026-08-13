// ============================================================================
// spi_master.sv - parameterized, mode-configurable SPI master (single slave).
//
// A synchronous, full-duplex SPI master. On a one-cycle `start` pulse it
// latches the transfer configuration (CPOL, CPHA, clock divider) and the byte
// to transmit, drives CS_N low, and shifts DATA_WIDTH bits out on MOSI while
// simultaneously shifting DATA_WIDTH bits in from MISO - MSB first. When the
// transfer completes it captures the received byte on `rx_data`, pulses
// `done` for one clock, and returns CS_N high.
//
// SCLK is generated from the system clock by a programmable divider: SCLK
// toggles once every `clk_div` system-clock cycles, so one SCLK period spans
// 2*clk_div system cycles. `clk_div` is treated as >= 1 (a value of 0 is
// promoted to 1 internally).
//
// SPI mode (CPOL, CPHA), MSB-first, is the classic Motorola convention:
//
//   * SCLK idles at CPOL.
//   * The "leading" edge is the first transition of a transfer (CPOL -> ~CPOL);
//     the "trailing" edge is the return (~CPOL -> CPOL).
//   * CPHA=0 : data is SAMPLED on the leading edge and CHANGED on the trailing
//              edge. The first bit is therefore presented as CS_N asserts
//              (pre-driven), before any SCLK edge.
//   * CPHA=1 : data is CHANGED on the leading edge and SAMPLED on the trailing
//              edge. The first bit is presented on the first leading edge.
//
// The design is reset-safe (synchronous active-low), fully registered on the
// system clock, and contains no latches or combinational feedback.
// ============================================================================
`timescale 1ns/1ps

module spi_master #(
    parameter int DATA_WIDTH = 8,
    parameter int DIV_WIDTH  = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // ---- transfer request / configuration (sampled on `start`) ----
    input  logic                  start,     // one-cycle pulse to begin (ignored while busy)
    input  logic                  cpol,      // clock polarity
    input  logic                  cpha,      // clock phase
    input  logic [DIV_WIDTH-1:0]  clk_div,   // system cycles per SCLK half-period (>=1)
    input  logic [DATA_WIDTH-1:0] tx_data,   // byte to shift out (MSB first)

    // ---- serial pins ----
    output logic                  sclk,
    output logic                  cs_n,
    output logic                  mosi,
    input  logic                  miso,

    // ---- results / status ----
    output logic [DATA_WIDTH-1:0] rx_data,   // byte shifted in (valid at `done`)
    output logic                  busy,      // high for the duration of a transfer
    output logic                  done       // one-cycle pulse when a transfer ends
);

    // Number of SCLK edges in a full transfer (two per bit).
    localparam int NEDGE = 2 * DATA_WIDTH;

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
    state_t state;

    // Latched configuration for the in-flight transfer.
    logic                  cpol_r, cpha_r;
    logic [DIV_WIDTH-1:0]  div_r;

    // Divider + edge bookkeeping.
    logic [DIV_WIDTH-1:0]  div_cnt;                 // counts system cycles to next SCLK edge
    logic [$clog2(NEDGE+1)-1:0] edge_idx;           // index of NEXT SCLK edge to produce (0..NEDGE)

    // Shift registers (MSB is the live serial bit for tx).
    logic [DATA_WIDTH-1:0] tx_sh, rx_sh;

    // A divider "tick" is due when div_cnt reaches div_r-1 while running.
    wire tick = (state == S_RUN) && (div_cnt == div_r - 1'b1);

    // This tick produces edge number `edge_idx`; even indices are leading
    // edges (SCLK -> ~CPOL), odd indices are trailing edges (SCLK -> CPOL).
    wire       is_leading  = (edge_idx[0] == 1'b0);
    // CPHA=0 samples on leading, changes on trailing; CPHA=1 is the opposite.
    wire       sample_edge = cpha_r ? ~is_leading :  is_leading;
    wire       change_edge = cpha_r ?  is_leading : ~is_leading;
    wire       last_edge   = (edge_idx == NEDGE - 1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            sclk     <= 1'b0;
            cs_n     <= 1'b1;
            mosi     <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            rx_data  <= '0;
            div_cnt  <= '0;
            edge_idx <= '0;
            tx_sh    <= '0;
            rx_sh    <= '0;
            cpol_r   <= 1'b0;
            cpha_r   <= 1'b0;
            div_r    <= '0;
        end else begin
            done <= 1'b0;   // default: single-cycle pulse

            case (state)
                // ----------------------------------------------------------
                S_IDLE: begin
                    sclk <= cpol;              // hold pins at idle for the mode
                    cs_n <= 1'b1;
                    busy <= 1'b0;
                    if (start) begin
                        // Latch configuration for this transfer.
                        cpol_r <= cpol;
                        cpha_r <= cpha;
                        div_r  <= (clk_div == '0) ? {{(DIV_WIDTH-1){1'b0}}, 1'b1} : clk_div;

                        sclk     <= cpol;      // start at the idle level
                        cs_n     <= 1'b0;      // assert chip-select
                        busy     <= 1'b1;
                        div_cnt  <= '0;
                        edge_idx <= '0;
                        rx_sh    <= '0;

                        if (!cpha) begin
                            // CPHA=0: pre-drive the MSB; advance the shifter so
                            // the first trailing (change) edge presents bit N-2.
                            mosi  <= tx_data[DATA_WIDTH-1];
                            tx_sh <= tx_data << 1;
                        end else begin
                            // CPHA=1: the first leading (change) edge presents
                            // the MSB via the output-then-advance rule below.
                            mosi  <= 1'b0;
                            tx_sh <= tx_data;
                        end

                        state <= S_RUN;
                    end
                end

                // ----------------------------------------------------------
                S_RUN: begin
                    if (tick) begin
                        sclk    <= ~sclk;              // produce the SCLK edge
                        div_cnt <= '0;

                        // Sample MISO into the rx shifter on the sample edge.
                        if (sample_edge)
                            rx_sh <= {rx_sh[DATA_WIDTH-2:0], miso};

                        // Present the current MSB then advance (output-then-
                        // advance) on the change edge.
                        if (change_edge) begin
                            mosi  <= tx_sh[DATA_WIDTH-1];
                            tx_sh <= tx_sh << 1;
                        end

                        edge_idx <= edge_idx + 1'b1;

                        if (last_edge)
                            state <= S_DONE;
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                // ----------------------------------------------------------
                S_DONE: begin
                    // De-assert, return SCLK to idle, publish the captured byte.
                    sclk    <= cpol_r;
                    cs_n    <= 1'b1;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    rx_data <= rx_sh;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
