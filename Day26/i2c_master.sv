// ============================================================================
// i2c_master.sv - Single-master, open-drain I2C master controller (DUT)
// ----------------------------------------------------------------------------
// A clean, synthesizable, reset-safe I2C master that performs ONE single-byte
// transaction per `start` pulse:
//
//   * 7-bit addressing, MSB-first, with the R/W bit appended (addr<<1 | rw)
//   * WRITE  (rw=0): START - addr+W - [slave ACK] - data - [slave ACK] - STOP
//   * READ   (rw=1): START - addr+R - [slave ACK] - data(from slave) -
//                    master NACK (single byte) - STOP
//   * ack_error is raised if the addressed slave does not ACK the address
//     phase (or the data phase on a write).
//
// Line discipline is true I2C OPEN-DRAIN wired-AND: the master never drives a
// logic '1'; it either pulls a line LOW (oe=1 => 0) or releases it to the
// external pull-up (oe=0 => z). Sampling of SDA (ACK bit / read data) happens
// while SCL is HIGH, which is exactly where the SVA / monitor expect stable
// data.
//
// Bit timing: every I2C bit is divided into 4 equal QUARTER phases, each
// lasting DIV core-clock cycles, so one SCL period = 4*DIV core clocks:
//
//        quarter:   0      1      2      3
//        SCL     : _____/^^^^^^^^^^^\_____     (low in q0/q3, high in q1/q2)
//        SDA     : <set while SCL low (q0)><----- stable while SCL high ----->
//
// START = SDA falls while SCL high;  STOP = SDA rises while SCL high.
// ============================================================================
`default_nettype none

module i2c_master #(
    parameter int unsigned DIV = 4   // core clocks per quarter phase (>=1)
) (
    input  wire        clk,
    input  wire        rst_n,        // active-low synchronous-safe reset

    // ---- transaction request (sampled when start & !busy) ----
    input  wire        start,        // 1-cycle pulse to launch a transaction
    input  wire        rw,           // 0 = write, 1 = read (single byte)
    input  wire [6:0]  dev_addr,     // 7-bit slave address
    input  wire [7:0]  wr_data,      // byte to write (rw=0)

    // ---- status ----
    output wire        busy,         // high while a transaction is in flight
    output logic       done,         // 1-cycle pulse when transaction completes
    output logic       ack_error,    // latched: addr/data not ACKed by slave
    output logic [7:0] rd_data,      // captured read byte (valid at done, rw=1)

    // ---- open-drain I2C bus pins (need external/TB pull-ups) ----
    inout  wire        scl,
    inout  wire        sda
);

    // ------------------------------------------------------------------
    // Open-drain drivers: oe=1 pulls the line low, oe=0 releases it (z).
    // ------------------------------------------------------------------
    logic scl_oe, sda_oe;
    assign scl = scl_oe ? 1'b0 : 1'bz;
    assign sda = sda_oe ? 1'b0 : 1'bz;

    // Resolved (wired-AND) line values as seen by the master.
    wire  sda_in = (sda === 1'b0) ? 1'b0 : 1'b1;

    // ------------------------------------------------------------------
    // States
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,     // bus released, waiting for start
        S_START,    // generate START condition
        S_ADDR,     // shift out {addr[6:0], rw}
        S_ADDR_ACK, // release SDA, sample slave ACK of the address
        S_WDATA,    // shift out write data byte
        S_WACK,     // release SDA, sample slave ACK of the data
        S_RDATA,    // release SDA, sample 8 read bits from slave
        S_RACK,     // master drives NACK (single-byte read)
        S_STOP,     // generate STOP condition
        S_DONE      // pulse done, return to idle
    } state_e;

    state_e state;

    // ------------------------------------------------------------------
    // Timing counters
    // ------------------------------------------------------------------
    localparam int unsigned DW = (DIV <= 1) ? 1 : $clog2(DIV);
    logic [DW-1:0] qcnt;    // counts core clocks inside one quarter phase
    logic [1:0]    phase;   // quarter within the current bit (0..3)
    logic [2:0]    bitc;    // bit index within a byte (7..0)
    logic          qtick;   // pulses on the last core clock of a quarter

    assign qtick = (qcnt == (DIV[DW-1:0] - 1'b1));

    // ------------------------------------------------------------------
    // Data path registers
    // ------------------------------------------------------------------
    logic [7:0] shift_out;  // outgoing byte, MSB first
    logic [7:0] shift_in;   // incoming read byte
    logic       cur_rw;     // latched rw for this transaction
    logic       sda_bit;    // level the master intends to place on SDA (1=release)

    assign busy = (state != S_IDLE);

    // SCL is high only in quarters 1 and 2 while we are clocking a bit-cell.
    // START/STOP manage SCL explicitly below.
    wire scl_high_q = (phase == 2'd1) || (phase == 2'd2);

    // ------------------------------------------------------------------
    // Main sequential FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            qcnt      <= '0;
            phase     <= 2'd0;
            bitc      <= 3'd7;
            shift_out <= '0;
            shift_in  <= '0;
            cur_rw    <= 1'b0;
            sda_bit   <= 1'b1;     // released
            scl_oe    <= 1'b0;     // bus idle: both released (pulled high)
            sda_oe    <= 1'b0;
            done      <= 1'b0;
            ack_error <= 1'b0;
            rd_data   <= '0;
        end else begin
            done <= 1'b0;   // default; pulsed for one cycle in S_DONE

            // Quarter-phase clock divider (free-running while not idle).
            if (state == S_IDLE) begin
                qcnt  <= '0;
                phase <= 2'd0;
            end else if (qtick) begin
                qcnt  <= '0;
                phase <= phase + 2'd1;   // wraps 3->0
            end else begin
                qcnt <= qcnt + 1'b1;
            end

            unique case (state)
                // ----------------------------------------------------------
                S_IDLE: begin
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    if (start) begin
                        cur_rw    <= rw;
                        shift_out <= {dev_addr, rw};   // addr + R/W bit
                        ack_error <= 1'b0;
                        bitc      <= 3'd7;
                        phase     <= 2'd0;
                        qcnt      <= '0;
                        // Enter START with SCL high, SDA high.
                        scl_oe    <= 1'b0;
                        sda_oe    <= 1'b0;
                        sda_bit   <= 1'b1;
                        state     <= S_START;
                    end
                end

                // ----------------------------------------------------------
                // START: hold SCL high; SDA high in q0/q1, LOW in q2/q3
                // (SDA falls while SCL high), then drop SCL entering q3->addr.
                S_START: begin
                    scl_oe <= 1'b0;                         // SCL released (high)
                    sda_oe <= (phase >= 2'd2) ? 1'b1 : 1'b0; // pull SDA low at q2
                    if (qtick && phase == 2'd3) begin
                        // Falling into the first address bit-cell.
                        state <= S_ADDR;
                        bitc  <= 3'd7;
                    end
                end

                // ----------------------------------------------------------
                // Drive {addr,rw} MSB-first. Set SDA in q0 (SCL low),
                // hold through the SCL-high window.
                S_ADDR: begin
                    scl_oe <= scl_high_q ? 1'b0 : 1'b1;   // high in q1/q2
                    sda_oe <= (shift_out[7] == 1'b0) ? 1'b1 : 1'b0;
                    if (qtick && phase == 2'd3) begin
                        if (bitc == 3'd0) begin
                            state <= S_ADDR_ACK;
                        end else begin
                            shift_out <= {shift_out[6:0], 1'b0};
                            bitc      <= bitc - 3'd1;
                        end
                    end
                end

                // ----------------------------------------------------------
                // ACK of address: master releases SDA, samples it while SCL high.
                S_ADDR_ACK: begin
                    scl_oe <= scl_high_q ? 1'b0 : 1'b1;
                    sda_oe <= 1'b0;                        // release for slave ACK
                    if (qtick && phase == 2'd1) begin      // sample in high window
                        if (sda_in == 1'b1) ack_error <= 1'b1; // NACK
                    end
                    if (qtick && phase == 2'd3) begin
                        if (ack_error) begin
                            state <= S_STOP;               // abort on NACK
                        end else if (cur_rw == 1'b0) begin
                            shift_out <= wr_data;
                            bitc      <= 3'd7;
                            state     <= S_WDATA;
                        end else begin
                            shift_in <= '0;
                            bitc     <= 3'd7;
                            state    <= S_RDATA;
                        end
                    end
                end

                // ----------------------------------------------------------
                S_WDATA: begin
                    scl_oe <= scl_high_q ? 1'b0 : 1'b1;
                    sda_oe <= (shift_out[7] == 1'b0) ? 1'b1 : 1'b0;
                    if (qtick && phase == 2'd3) begin
                        if (bitc == 3'd0) begin
                            state <= S_WACK;
                        end else begin
                            shift_out <= {shift_out[6:0], 1'b0};
                            bitc      <= bitc - 3'd1;
                        end
                    end
                end

                // ----------------------------------------------------------
                S_WACK: begin
                    scl_oe <= scl_high_q ? 1'b0 : 1'b1;
                    sda_oe <= 1'b0;                        // release for slave ACK
                    if (qtick && phase == 2'd1) begin
                        if (sda_in == 1'b1) ack_error <= 1'b1;
                    end
                    if (qtick && phase == 2'd3) begin
                        state <= S_STOP;
                    end
                end

                // ----------------------------------------------------------
                // Read data: master releases SDA, samples 8 bits while SCL high.
                S_RDATA: begin
                    scl_oe <= scl_high_q ? 1'b0 : 1'b1;
                    sda_oe <= 1'b0;                        // release: slave drives
                    if (qtick && phase == 2'd1) begin
                        shift_in <= {shift_in[6:0], sda_in};
                    end
                    if (qtick && phase == 2'd3) begin
                        if (bitc == 3'd0) begin
                            state <= S_RACK;
                        end else begin
                            bitc <= bitc - 3'd1;
                        end
                    end
                end

                // ----------------------------------------------------------
                // Master NACKs the single read byte: drive SDA HIGH (release)
                // during the ACK bit so the slave sees a NACK, then STOP.
                S_RACK: begin
                    scl_oe  <= scl_high_q ? 1'b0 : 1'b1;
                    sda_oe  <= 1'b0;                       // release => NACK (high)
                    if (qtick && phase == 2'd3) begin
                        rd_data <= shift_in;
                        state   <= S_STOP;
                    end
                end

                // ----------------------------------------------------------
                // STOP: SCL low in q0, high from q1; SDA low until q1 then
                // released in q2/q3 (SDA rises while SCL high).
                S_STOP: begin
                    scl_oe <= (phase == 2'd0) ? 1'b1 : 1'b0;  // rise after q0
                    sda_oe <= (phase <= 2'd1) ? 1'b1 : 1'b0;  // release at q2
                    if (qtick && phase == 2'd3) begin
                        state <= S_DONE;
                    end
                end

                // ----------------------------------------------------------
                S_DONE: begin
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef I2C_SVA
    // ------------------------------------------------------------------
    // Concurrent assertions (bound where the simulator supports SVA).
    // ------------------------------------------------------------------
    // done is always a single-cycle pulse.
    property p_done_pulse;
        @(posedge clk) disable iff (!rst_n) done |=> !done;
    endproperty
    a_done_pulse: assert property (p_done_pulse);

    // busy must be asserted the cycle done pulses (done only inside a txn).
    a_done_in_busy: assert property (@(posedge clk) disable iff (!rst_n)
        done |-> $past(busy));
`endif

endmodule

`default_nettype wire
