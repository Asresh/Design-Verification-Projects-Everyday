// ============================================================================
// i2c_master_pkg.sv - UVM verification environment for the I2C master.
// ----------------------------------------------------------------------------
// Components:
//   * i2c_txn         - sequence item {rw, addr, wdata, mem} + captured results.
//   * i2c_model       - independent golden reference model (transaction level).
//   * i2c_driver      - programs the slave read byte, pulses `start`, waits for
//                       `done` (one transaction per item).
//   * i2c_monitor     - watches start->done, publishes the completed
//                       transaction (request + {ack_error, rd_data,
//                       slv_wr_byte}) on an analysis port.
//   * i2c_scoreboard  - runs the golden model on each observed transaction and
//                       checks {ack_error, rd_data, write-byte}.
//   * i2c_coverage    - covergroup over rw x ack and data classes.
//   * i2c_agent       - driver + monitor + sequencer.
//   * i2c_vseqr       - virtual sequencer.
//   * i2c_env         - agent + scoreboard + coverage.
//   * sequences       - write / read / addr-NACK / random + smoke & regress
//                       virtual sequences.
//   * tests           - i2c_smoke_test, i2c_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). Icarus
// cannot run UVM - use tb_i2c_master_dump.sv there (see the Makefile).
// ============================================================================
`timescale 1ns/1ps

package i2c_master_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // The slave address the environment talks to (matches tb_top's slave).
    localparam logic [6:0] SLV_ADDR = 7'h42;

    // ------------------------------------------------------------------
    // Transaction
    // ------------------------------------------------------------------
    class i2c_txn extends uvm_sequence_item;
        rand bit        rw;         // 0 = write, 1 = read
        rand bit [6:0]  addr;
        rand bit [7:0]  wdata;      // byte to write
        rand bit [7:0]  mem;        // byte the slave should return on a read

        // captured on completion (filled by the monitor)
        bit             ack_error;
        bit [7:0]       rd_data;
        bit [7:0]       slv_wr_byte;

        // Bias: about half the traffic hits the real slave address.
        constraint c_addr { addr dist { SLV_ADDR := 5, [0:127] := 5 }; }

        `uvm_object_utils_begin(i2c_txn)
            `uvm_field_int(rw,          UVM_ALL_ON)
            `uvm_field_int(addr,        UVM_ALL_ON)
            `uvm_field_int(wdata,       UVM_ALL_ON)
            `uvm_field_int(mem,         UVM_ALL_ON)
            `uvm_field_int(ack_error,   UVM_ALL_ON)
            `uvm_field_int(rd_data,     UVM_ALL_ON)
            `uvm_field_int(slv_wr_byte, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "i2c_txn"); super.new(name); endfunction
    endclass

    // ------------------------------------------------------------------
    // Golden reference model (independent of the DUT).
    // ------------------------------------------------------------------
    class i2c_model extends uvm_object;
        `uvm_object_utils(i2c_model)
        function new(string name = "i2c_model"); super.new(name); endfunction

        // Predict {ack_error, rd_data, write-byte} for a transaction.
        function void predict(input i2c_txn t, output bit exp_ackerr,
                              output bit [7:0] exp_rd, output bit [7:0] exp_wr);
            if (t.addr == SLV_ADDR) begin
                exp_ackerr = 1'b0;
                exp_rd     = t.rw ? t.mem   : 8'h00;
                exp_wr     = t.rw ? 8'h00   : t.wdata;
            end else begin
                exp_ackerr = 1'b1;          // address not ACKed
                exp_rd     = 8'h00;
                exp_wr     = 8'h00;
            end
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Driver
    // ------------------------------------------------------------------
    class i2c_driver extends uvm_driver #(i2c_txn);
        `uvm_component_utils(i2c_driver)
        virtual i2c_master_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual i2c_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "no virtual interface for driver")
        endfunction

        task run_phase(uvm_phase phase);
            // idle
            vif.drv_cb.start    <= 1'b0;
            vif.drv_cb.rw       <= 1'b0;
            vif.drv_cb.dev_addr <= '0;
            vif.drv_cb.wr_data  <= '0;
            vif.drv_cb.slv_mem  <= '0;
            @(posedge vif.rst_n);
            @(vif.drv_cb);

            forever begin
                seq_item_port.get_next_item(req);
                // program the slave read byte + the request
                vif.drv_cb.slv_mem  <= req.mem;
                vif.drv_cb.rw       <= req.rw;
                vif.drv_cb.dev_addr <= req.addr;
                vif.drv_cb.wr_data  <= req.wdata;
                vif.drv_cb.start    <= 1'b1;
                @(vif.drv_cb);
                vif.drv_cb.start    <= 1'b0;
                // wait for completion
                do @(vif.drv_cb); while (!vif.drv_cb.done);
                // idle gap
                repeat (3) @(vif.drv_cb);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Monitor
    // ------------------------------------------------------------------
    class i2c_monitor extends uvm_monitor;
        `uvm_component_utils(i2c_monitor)
        virtual i2c_master_if vif;
        uvm_analysis_port #(i2c_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual i2c_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "no virtual interface for monitor")
        endfunction

        task run_phase(uvm_phase phase);
            bit         c_rw;
            bit [6:0]   c_addr;
            bit [7:0]   c_wdata, c_mem;
            @(posedge vif.rst_n);
            forever begin
                @(vif.mon_cb);
                // latch the request at the launch cycle
                if (vif.mon_cb.start && !vif.mon_cb.busy) begin
                    c_rw    = vif.mon_cb.rw;
                    c_addr  = vif.mon_cb.dev_addr;
                    c_wdata = vif.mon_cb.wr_data;
                    c_mem   = vif.mon_cb.slv_mem;
                end
                // publish on completion
                if (vif.mon_cb.done) begin
                    i2c_txn t = i2c_txn::type_id::create("t");
                    t.rw          = c_rw;
                    t.addr        = c_addr;
                    t.wdata       = c_wdata;
                    t.mem         = c_mem;
                    t.ack_error   = vif.mon_cb.ack_error;
                    t.rd_data     = vif.mon_cb.rd_data;
                    t.slv_wr_byte = vif.mon_cb.slv_wr_byte;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    `uvm_analysis_imp_decl(_i2c)
    class i2c_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(i2c_scoreboard)
        uvm_analysis_imp_i2c #(i2c_txn, i2c_scoreboard) imp;
        i2c_model model;
        int unsigned checks, errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            model = i2c_model::type_id::create("model");
        endfunction

        function void write_i2c(i2c_txn t);
            bit exp_ae; bit [7:0] exp_rd, exp_wr;
            model.predict(t, exp_ae, exp_rd, exp_wr);
            checks++;
            if (t.ack_error !== exp_ae)
                report_err(t, $sformatf("ack_error got %0b exp %0b", t.ack_error, exp_ae));
            if (t.rw && !exp_ae && t.rd_data !== exp_rd)
                report_err(t, $sformatf("rd_data got 0x%02h exp 0x%02h", t.rd_data, exp_rd));
            if (!t.rw && !exp_ae && t.slv_wr_byte !== exp_wr)
                report_err(t, $sformatf("slave wr_byte got 0x%02h exp 0x%02h",
                                        t.slv_wr_byte, exp_wr));
        endfunction

        function void report_err(i2c_txn t, string msg);
            errors++;
            `uvm_error("SCB", $sformatf("MISMATCH rw=%0b addr=0x%02h : %s",
                                        t.rw, t.addr, msg))
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0)
                `uvm_info("SCB", $sformatf("RESULT: *** PASS *** (%0d checks)", checks), UVM_NONE)
            else
                `uvm_error("SCB", $sformatf("RESULT: *** FAIL *** (%0d checks, %0d errors)",
                                            checks, errors))
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Coverage
    // ------------------------------------------------------------------
    class i2c_coverage extends uvm_component;
        `uvm_component_utils(i2c_coverage)
        uvm_analysis_imp_i2c #(i2c_txn, i2c_coverage) imp;
        i2c_txn tr;

        covergroup cg;
            cp_rw   : coverpoint tr.rw       { bins wr = {0}; bins rd = {1}; }
            cp_ack  : coverpoint tr.ack_error{ bins ack = {0}; bins nack = {1}; }
            cp_data : coverpoint tr.wdata {
                bins zero = {8'h00};
                bins ones = {8'hFF};
                bins mid  = {[8'h01:8'hFE]};
            }
            x_rw_ack: cross cp_rw, cp_ack;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
            cg  = new();
        endfunction

        function void write_i2c(i2c_txn t);
            tr = t;
            cg.sample();
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Agent
    // ------------------------------------------------------------------
    class i2c_agent extends uvm_agent;
        `uvm_component_utils(i2c_agent)
        i2c_driver                 drv;
        i2c_monitor                mon;
        uvm_sequencer #(i2c_txn)   seqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv  = i2c_driver::type_id::create("drv", this);
            mon  = i2c_monitor::type_id::create("mon", this);
            seqr = uvm_sequencer#(i2c_txn)::type_id::create("seqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Virtual sequencer
    // ------------------------------------------------------------------
    class i2c_vseqr extends uvm_sequencer;
        `uvm_component_utils(i2c_vseqr)
        uvm_sequencer #(i2c_txn) seqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------------
    class i2c_env extends uvm_env;
        `uvm_component_utils(i2c_env)
        i2c_agent      agent;
        i2c_scoreboard scb;
        i2c_coverage   cov;
        i2c_vseqr      vseqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = i2c_agent::type_id::create("agent", this);
            scb   = i2c_scoreboard::type_id::create("scb", this);
            cov   = i2c_coverage::type_id::create("cov", this);
            vseqr = i2c_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(scb.imp);
            agent.mon.ap.connect(cov.imp);
            vseqr.seqr = agent.seqr;
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Sequences
    // ------------------------------------------------------------------
    class i2c_write_seq extends uvm_sequence #(i2c_txn);
        `uvm_object_utils(i2c_write_seq)
        function new(string name = "i2c_write_seq"); super.new(name); endfunction
        task body();
            i2c_txn t = i2c_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { rw == 0; addr == SLV_ADDR; })
                `uvm_error("RAND", "write randomize failed")
            finish_item(t);
        endtask
    endclass

    class i2c_read_seq extends uvm_sequence #(i2c_txn);
        `uvm_object_utils(i2c_read_seq)
        function new(string name = "i2c_read_seq"); super.new(name); endfunction
        task body();
            i2c_txn t = i2c_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { rw == 1; addr == SLV_ADDR; })
                `uvm_error("RAND", "read randomize failed")
            finish_item(t);
        endtask
    endclass

    class i2c_nack_seq extends uvm_sequence #(i2c_txn);
        `uvm_object_utils(i2c_nack_seq)
        function new(string name = "i2c_nack_seq"); super.new(name); endfunction
        task body();
            i2c_txn t = i2c_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { addr != SLV_ADDR; })
                `uvm_error("RAND", "nack randomize failed")
            finish_item(t);
        endtask
    endclass

    class i2c_random_seq extends uvm_sequence #(i2c_txn);
        `uvm_object_utils(i2c_random_seq)
        rand int unsigned n;
        constraint c_n { n inside {[40:80]}; }
        function new(string name = "i2c_random_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                i2c_txn t = i2c_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_error("RAND", "random randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Virtual sequences
    // ------------------------------------------------------------------
    class i2c_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(i2c_smoke_vseq)
        function new(string name = "i2c_smoke_vseq"); super.new(name); endfunction

        task body();
            i2c_vseqr    vs;
            i2c_write_seq w = i2c_write_seq::type_id::create("w");
            i2c_read_seq  r = i2c_read_seq::type_id::create("r");
            i2c_nack_seq  n = i2c_nack_seq::type_id::create("n");
            if (!$cast(vs, m_sequencer))
                `uvm_fatal("VSEQ", "smoke not on i2c_vseqr")
            w.start(vs.seqr);
            r.start(vs.seqr);
            n.start(vs.seqr);
        endtask
    endclass

    class i2c_regress_vseq extends uvm_sequence;
        `uvm_object_utils(i2c_regress_vseq)
        function new(string name = "i2c_regress_vseq"); super.new(name); endfunction

        task body();
            i2c_vseqr     vs;
            i2c_write_seq  w = i2c_write_seq::type_id::create("w");
            i2c_read_seq   r = i2c_read_seq::type_id::create("r");
            i2c_nack_seq   n = i2c_nack_seq::type_id::create("n");
            i2c_random_seq rnd = i2c_random_seq::type_id::create("rnd");
            if (!$cast(vs, m_sequencer))
                `uvm_fatal("VSEQ", "regress not on i2c_vseqr")
            w.start(vs.seqr);
            r.start(vs.seqr);
            n.start(vs.seqr);
            if (!rnd.randomize()) `uvm_error("RAND", "regress n randomize failed")
            rnd.start(vs.seqr);
        endtask
    endclass

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    class i2c_base_test extends uvm_test;
        `uvm_component_utils(i2c_base_test)
        i2c_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = i2c_env::type_id::create("env", this);
        endfunction
    endclass

    class i2c_smoke_test extends i2c_base_test;
        `uvm_component_utils(i2c_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            i2c_smoke_vseq vseq = i2c_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

    class i2c_regress_test extends i2c_base_test;
        `uvm_component_utils(i2c_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            i2c_regress_vseq vseq = i2c_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
