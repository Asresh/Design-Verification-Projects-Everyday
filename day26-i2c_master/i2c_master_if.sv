// ----------------------------------------------------------------------------
// i2c_master_if.sv - SystemVerilog interface for the I2C master UVM
// environment. Bundles the transaction-level request ({start, rw, dev_addr,
// wr_data} plus the slave's read-data byte slv_mem the driver programs) and the
// completion status ({busy, done, ack_error, rd_data}), the open-drain bus pins
// (scl, sda) for the protocol monitor / assertions, and the slave model's
// captured write byte (slv_wr_byte) so the scoreboard can confirm the byte that
// actually landed on a write. Clocking blocks give the driver and the passive
// monitor their views.
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

interface i2c_master_if (input logic clk, input logic rst_n);

    // ---- transaction request (driven by the UVM driver) ----
    logic        start;
    logic        rw;          // 0 = write, 1 = read
    logic [6:0]  dev_addr;
    logic [7:0]  wr_data;
    logic [7:0]  slv_mem;     // byte the slave returns on a read

    // ---- DUT status ----
    logic        busy;
    logic        done;
    logic        ack_error;
    logic [7:0]  rd_data;

    // ---- bus pins + slave observation (monitored) ----
    logic        scl;
    logic        sda;
    logic [7:0]  slv_wr_byte; // byte the slave captured on the last write

    // Stimulus driver: drives the request, samples completion.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output start, rw, dev_addr, wr_data, slv_mem;
        input  busy, done, ack_error, rd_data, slv_wr_byte;
    endclocking

    // Passive monitor: sees everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input start, rw, dev_addr, wr_data, slv_mem;
        input busy, done, ack_error, rd_data, slv_wr_byte;
        input scl, sda;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

`ifdef I2C_SVA
    // -------------------------------------------------------------------
    // Pin-level protocol assertions (bound in the interface so the DUT
    // stays clean). Enabled with +define+I2C_SVA on a UVM-capable sim.
    // -------------------------------------------------------------------
    // done is always a single-cycle pulse.
    property p_done_pulse;
        @(posedge clk) disable iff (!rst_n) done |=> !done;
    endproperty
    a_done_pulse: assert property (p_done_pulse);

    // done only ever pulses inside an active transaction.
    a_done_in_busy: assert property (@(posedge clk) disable iff (!rst_n)
        done |-> $past(busy));

    // The bus must never be X while a transfer is in flight.
    a_no_x_bus: assert property (@(posedge clk) disable iff (!rst_n)
        busy |-> (!$isunknown(scl) && !$isunknown(sda)));
`endif

endinterface
