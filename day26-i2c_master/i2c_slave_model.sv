// ============================================================================
// i2c_slave_model.sv - Behavioral open-drain I2C slave (verification component)
// ----------------------------------------------------------------------------
// A simple, single-byte 7-bit I2C slave used by the testbench as the far end of
// the bus. It is NOT a DUT - it is a reactive bus model:
//
//   * Watches for START / STOP (SDA edge while SCL high).
//   * Shifts the address+R/W byte in on the falling edge of SCL (data set by
//     the master while SCL is low is stable at the following SCL-low edge).
//   * ACKs (pulls SDA low) only when the address matches ADDR7; otherwise it
//     leaves the line released so the master sees a NACK.
//   * WRITE : captures the data byte and ACKs it; exposes {wr_byte, wr_valid}.
//   * READ  : drives `mem_byte` back MSB-first, then releases so the master can
//     (N)ACK.
//
// Open-drain: the model only ever pulls SDA low (oe=1 => 0) or releases (z).
// The bus pull-ups live in the testbench top.
// ============================================================================
`default_nettype none

module i2c_slave_model #(
    parameter logic [6:0] ADDR7 = 7'h00
) (
    input  wire       clk,        // only for registering the exposed strobes
    input  wire       rst_n,
    input  wire [7:0] mem_byte,   // byte returned to the master on a READ
    inout  wire       scl,
    inout  wire       sda,

    // observation ports (for the scoreboard / directed checks)
    output logic [7:0] wr_byte,   // last byte the master wrote to us
    output logic       wr_valid,  // pulses 1 cycle when wr_byte updates
    output logic       saw_read,  // pulses 1 cycle when a READ transfer occurs
    output logic       saw_nack   // pulses when we NACKed an address
);

    // Open-drain slave driver.
    logic oe;                       // 1 => pull SDA low, 0 => release
    assign sda = oe ? 1'b0 : 1'bz;

    wire sda_in = (sda === 1'b0) ? 1'b0 : 1'b1;
    wire scl_in = (scl === 1'b0) ? 1'b0 : 1'b1;

    typedef enum logic [2:0] {ST_IDLE, ST_ADDR, ST_AACK, ST_WR, ST_WACK,
                              ST_RD, ST_RACK} sstate_e;
    sstate_e    sstate;
    logic [2:0] bcnt;
    logic [7:0] rx;
    logic [7:0] txsr;
    logic       rw_l;
    logic       skip1;              // ignore the leading negedge after START

    // event strobes into the clk domain
    logic       wr_evt, rd_evt, nack_evt;

    // Power-on state so the open-drain line is released (never X) before the
    // first START / SCL edge arrives.
    initial begin
        oe     = 1'b0;
        sstate = ST_IDLE;
        skip1  = 1'b0;
        bcnt   = 3'd0;
        rx     = 8'd0;
        txsr   = 8'd0;
        rw_l   = 1'b0;
        wr_evt = 1'b0; rd_evt = 1'b0; nack_evt = 1'b0;
    end

    // ------------------------------------------------------------------
    // START / STOP detection (SDA edge while SCL held high).
    // These fire only during the SCL-high window, temporally disjoint from
    // the negedge-SCL FSM below, so there is no shared-variable race.
    // ------------------------------------------------------------------
    always @(negedge sda_in) begin       // SDA 1->0 while SCL high => START
        if (rst_n && scl_in === 1'b1) begin
            sstate <= ST_ADDR;
            bcnt   <= 3'd0;
            rx     <= 8'd0;
            oe     <= 1'b0;
            skip1  <= 1'b1;
        end
    end

    always @(posedge sda_in) begin       // SDA 0->1 while SCL high => STOP
        if (rst_n && scl_in === 1'b1) begin
            sstate <= ST_IDLE;
            oe     <= 1'b0;
            skip1  <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Bit engine: sample the master / advance state / drive on each SCL fall.
    // ------------------------------------------------------------------
    always @(negedge scl_in) begin
        wr_evt   <= 1'b0;
        rd_evt   <= 1'b0;
        nack_evt <= 1'b0;

        if (!rst_n) begin
            sstate <= ST_IDLE;
            oe     <= 1'b0;
            skip1  <= 1'b0;
        end else if (skip1) begin
            skip1 <= 1'b0;               // consume the START->bit0 leading edge
            oe    <= 1'b0;
        end else begin
            unique case (sstate)
                // ---- receive {addr[6:0], rw} ----
                ST_ADDR: begin
                    logic [7:0] full;
                    full = {rx[6:0], sda_in};
                    rx   <= full;
                    if (bcnt == 3'd7) begin
                        rw_l <= full[0];
                        bcnt <= 3'd0;
                        if (full[7:1] == ADDR7) begin
                            oe     <= 1'b1;          // ACK the address
                            sstate <= ST_AACK;
                        end else begin
                            oe       <= 1'b0;        // NACK (release)
                            nack_evt <= 1'b1;
                            sstate   <= ST_IDLE;     // wait for STOP
                        end
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                // ---- address ACK cell ended: branch to write/read ----
                ST_AACK: begin
                    if (rw_l == 1'b0) begin
                        oe     <= 1'b0;              // release: receive data
                        rx     <= 8'd0;
                        bcnt   <= 3'd0;
                        sstate <= ST_WR;
                    end else begin
                        txsr   <= mem_byte;
                        oe     <= (mem_byte[7] == 1'b0) ? 1'b1 : 1'b0; // drive bit7
                        bcnt   <= 3'd0;
                        sstate <= ST_RD;
                    end
                end

                // ---- receive the write data byte ----
                ST_WR: begin
                    logic [7:0] full;
                    full = {rx[6:0], sda_in};
                    rx   <= full;
                    if (bcnt == 3'd7) begin
                        wr_byte <= full;
                        wr_evt  <= 1'b1;
                        oe      <= 1'b1;             // ACK the data
                        bcnt    <= 3'd0;
                        sstate  <= ST_WACK;
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                ST_WACK: begin
                    oe     <= 1'b0;                  // release after data-ACK
                    sstate <= ST_IDLE;              // single byte: wait STOP
                end

                // ---- transmit the read data byte, MSB first ----
                ST_RD: begin
                    if (bcnt == 3'd7) begin
                        oe     <= 1'b0;             // release for master (N)ACK
                        rd_evt <= 1'b1;
                        bcnt   <= 3'd0;
                        sstate <= ST_RACK;
                    end else begin
                        txsr <= {txsr[6:0], 1'b0};
                        oe   <= (txsr[6] == 1'b0) ? 1'b1 : 1'b0; // next MSB
                        bcnt <= bcnt + 3'd1;
                    end
                end

                ST_RACK: begin
                    oe     <= 1'b0;
                    sstate <= ST_IDLE;
                end

                default: begin
                    oe     <= 1'b0;
                    sstate <= ST_IDLE;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Register the async strobes into the clk domain for easy sampling.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_valid <= 1'b0;
            saw_read <= 1'b0;
            saw_nack <= 1'b0;
        end else begin
            wr_valid <= wr_evt;
            saw_read <= rd_evt;
            saw_nack <= nack_evt;
        end
    end

endmodule

`default_nettype wire
