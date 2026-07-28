// -----------------------------------------------------------------------------
// uart.sv  -  Synthesizable UART (TX + RX) controller DUT
//
// A full-duplex 8-N-1 UART (1 start bit, 8 data bits LSB-first, 1 stop bit, no
// parity) with a *runtime* baud divisor `cfg_clks_per_bit` (number of clock
// cycles per serial bit). Two independent wires: tx_serial (out) and rx_serial
// (in). The receiver double-flops the line for metastability and samples each
// bit at its centre; it flags a framing error if the stop bit is not high.
//
// Contains three modules:
//   uart_tx  - parallel byte -> serial frame
//   uart_rx  - serial frame  -> parallel byte (+ rx_valid pulse, framing_err)
//   uart     - top wrapping both (shared clock, reset and baud divisor)
// -----------------------------------------------------------------------------

// ----------------------------- Transmitter ---------------------------------
module uart_tx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] cfg_clks_per_bit,   // clocks per serial bit
    input  logic        tx_start,           // 1-cycle pulse to launch a byte
    input  logic [7:0]  tx_data,            // byte to transmit (sampled on start)
    output logic        tx_serial,          // serial line (idles high)
    output logic        tx_busy,            // high while a frame is in flight
    output logic        tx_done             // 1-cycle pulse at end of stop bit
);
    localparam logic [2:0] S_IDLE = 3'd0, S_START = 3'd1,
                           S_DATA = 3'd2, S_STOP  = 3'd3;

    logic [2:0]  state;
    logic [15:0] cnt;
    logic [2:0]  bidx;
    logic [7:0]  data_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            tx_serial <= 1'b1;
            tx_busy   <= 1'b0;
            tx_done   <= 1'b0;
            cnt       <= '0;
            bidx      <= '0;
            data_q    <= '0;
        end else begin
            tx_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    tx_serial <= 1'b1;
                    tx_busy   <= 1'b0;
                    cnt       <= '0;
                    bidx      <= '0;
                    if (tx_start) begin
                        data_q  <= tx_data;
                        tx_busy <= 1'b1;
                        state   <= S_START;
                    end
                end
                S_START: begin
                    tx_serial <= 1'b0;              // start bit
                    tx_busy   <= 1'b1;
                    if (cnt < cfg_clks_per_bit - 1) cnt <= cnt + 1;
                    else begin cnt <= '0; state <= S_DATA; end
                end
                S_DATA: begin
                    tx_serial <= data_q[bidx];     // LSB first
                    tx_busy   <= 1'b1;
                    if (cnt < cfg_clks_per_bit - 1) cnt <= cnt + 1;
                    else begin
                        cnt <= '0;
                        if (bidx == 3'd7) begin bidx <= '0; state <= S_STOP; end
                        else                bidx <= bidx + 1;
                    end
                end
                S_STOP: begin
                    tx_serial <= 1'b1;             // stop bit
                    tx_busy   <= 1'b1;
                    if (cnt < cfg_clks_per_bit - 1) cnt <= cnt + 1;
                    else begin cnt <= '0; tx_done <= 1'b1; state <= S_IDLE; end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// ------------------------------- Receiver -----------------------------------
module uart_rx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] cfg_clks_per_bit,
    input  logic        rx_serial,          // serial line
    output logic [7:0]  rx_data,            // received byte
    output logic        rx_valid,           // 1-cycle pulse when a byte lands
    output logic        framing_err         // stop bit was not high
);
    localparam logic [2:0] R_IDLE = 3'd0, R_START = 3'd1,
                           R_DATA = 3'd2, R_STOP  = 3'd3;

    logic [2:0]  state;
    logic [15:0] cnt;
    logic [2:0]  bidx;
    logic [7:0]  data_q;
    logic        rx_meta, rx_sync;

    // Two-flop synchronizer (metastability guard); line idles high.
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else        begin rx_meta <= rx_serial; rx_sync <= rx_meta; end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= R_IDLE;
            cnt         <= '0;
            bidx        <= '0;
            data_q      <= '0;
            rx_data     <= '0;
            rx_valid    <= 1'b0;
            framing_err <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            case (state)
                R_IDLE: begin
                    cnt  <= '0;
                    bidx <= '0;
                    if (rx_sync == 1'b0) state <= R_START;   // start-bit edge
                end
                R_START: begin
                    // Advance to the centre of the start bit and re-check.
                    if (cnt == (cfg_clks_per_bit >> 1)) begin
                        if (rx_sync == 1'b0) begin cnt <= '0; state <= R_DATA; end
                        else                 state <= R_IDLE;   // false start
                    end else cnt <= cnt + 1;
                end
                R_DATA: begin
                    // Sample one bit period later => centre of each data bit.
                    if (cnt == cfg_clks_per_bit - 1) begin
                        cnt            <= '0;
                        data_q[bidx]   <= rx_sync;
                        if (bidx == 3'd7) begin bidx <= '0; state <= R_STOP; end
                        else                bidx <= bidx + 1;
                    end else cnt <= cnt + 1;
                end
                R_STOP: begin
                    // Centre of the stop bit: latch byte + check framing.
                    if (cnt == cfg_clks_per_bit - 1) begin
                        cnt         <= '0;
                        rx_data     <= data_q;
                        rx_valid    <= 1'b1;
                        framing_err <= ~rx_sync;     // stop bit must be high
                        state       <= R_IDLE;
                    end else cnt <= cnt + 1;
                end
                default: state <= R_IDLE;
            endcase
        end
    end
endmodule

// --------------------------------- Top --------------------------------------
module uart (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] cfg_clks_per_bit,
    // TX (parallel) side
    input  logic        tx_start,
    input  logic [7:0]  tx_data,
    output logic        tx_serial,
    output logic        tx_busy,
    output logic        tx_done,
    // RX (parallel) side
    input  logic        rx_serial,
    output logic [7:0]  rx_data,
    output logic        rx_valid,
    output logic        framing_err
);
    uart_tx u_tx (
        .clk(clk), .rst_n(rst_n), .cfg_clks_per_bit(cfg_clks_per_bit),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_serial(tx_serial), .tx_busy(tx_busy), .tx_done(tx_done)
    );

    uart_rx u_rx (
        .clk(clk), .rst_n(rst_n), .cfg_clks_per_bit(cfg_clks_per_bit),
        .rx_serial(rx_serial),
        .rx_data(rx_data), .rx_valid(rx_valid), .framing_err(framing_err)
    );
endmodule
