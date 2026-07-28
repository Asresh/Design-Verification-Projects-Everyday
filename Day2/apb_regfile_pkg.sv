// -----------------------------------------------------------------------------
// apb_regfile_pkg.sv  -  UVM verification environment for apb_regfile
//
// A complete UVM testbench:
//   transaction  : apb_txn
//   sequences    : apb_base_seq, apb_write_all_seq, apb_read_all_seq,
//                  apb_rand_seq, apb_oob_seq (out-of-bounds / error)
//   sequencer    : apb_sequencer  (uvm_sequencer #(apb_txn))
//   driver       : apb_driver     (drives the APB SETUP/ACCESS phases)
//   monitor      : apb_monitor    (reconstructs completed transfers)
//   coverage     : apb_coverage   (functional covergroup subscriber)
//   agent        : apb_agent      (driver + monitor + sequencer + coverage)
//   scoreboard   : apb_scoreboard (golden reference register model)
//   vsequencer   : apb_vsequencer (holds the agent sequencer handle)
//   vsequences   : apb_reset_vseq, apb_smoke_vseq, apb_regress_vseq
//   env          : apb_env
//   tests        : apb_base_test, apb_smoke_test, apb_regress_test
// -----------------------------------------------------------------------------
package apb_regfile_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    // Environment geometry (mirrors the DUT parameter defaults).
    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;
    localparam int NBYTES     = DATA_WIDTH/8;

    // =========================================================================
    // Transaction
    // =========================================================================
    class apb_txn extends uvm_sequence_item;
        rand bit                    write;
        rand bit [ADDR_WIDTH-1:0]   addr;      // byte address
        rand bit [DATA_WIDTH-1:0]   data;      // write data
        rand bit [NBYTES-1:0]       strb;      // byte strobes (writes only)
        // Response fields populated by the monitor.
        bit      [DATA_WIDTH-1:0]   rdata;
        bit                         slverr;

        // Legal (in-range) word addresses dominate; a small slice go OOB so
        // the error path is exercised by the random sequences.
        constraint c_addr_align { addr[$clog2(NBYTES)-1:0] == '0; }
        constraint c_in_range   { soft addr[ADDR_WIDTH-1:$clog2(NBYTES)]
                                       < NUM_REGS; }
        constraint c_strb_nz    { write -> strb != '0; }

        `uvm_object_utils_begin(apb_txn)
            `uvm_field_int(write,  UVM_ALL_ON)
            `uvm_field_int(addr,   UVM_ALL_ON)
            `uvm_field_int(data,   UVM_ALL_ON)
            `uvm_field_int(strb,   UVM_ALL_ON)
            `uvm_field_int(rdata,  UVM_ALL_ON)
            `uvm_field_int(slverr, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "apb_txn");
            super.new(name);
        endfunction

        function int unsigned word_index();
            return addr >> $clog2(NBYTES);
        endfunction
    endclass

    // =========================================================================
    // Sequencer
    // =========================================================================
    typedef uvm_sequencer #(apb_txn) apb_sequencer;

    // =========================================================================
    // Sequences
    // =========================================================================
    class apb_base_seq extends uvm_sequence #(apb_txn);
        `uvm_object_utils(apb_base_seq)
        function new(string name = "apb_base_seq"); super.new(name); endfunction
    endclass

    // Write a known pattern to every register.
    class apb_write_all_seq extends apb_base_seq;
        `uvm_object_utils(apb_write_all_seq)
        function new(string name = "apb_write_all_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < NUM_REGS; i++) begin
                apb_txn t = apb_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with {
                        write == 1;
                        addr  == (i << $clog2(NBYTES));
                        strb  == '1;
                        data  == (32'hA5A5_0000 | i);
                    })
                    `uvm_error(get_type_name(), "write_all randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Read back every register.
    class apb_read_all_seq extends apb_base_seq;
        `uvm_object_utils(apb_read_all_seq)
        function new(string name = "apb_read_all_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < NUM_REGS; i++) begin
                apb_txn t = apb_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with {
                        write == 0;
                        addr  == (i << $clog2(NBYTES));
                    })
                    `uvm_error(get_type_name(), "read_all randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Constrained-random mix of reads and writes to legal addresses.
    class apb_rand_seq extends apb_base_seq;
        `uvm_object_utils(apb_rand_seq)
        int unsigned n = 200;
        function new(string name = "apb_rand_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < n; i++) begin
                apb_txn t = apb_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_error(get_type_name(), "rand randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Deliberately hammer out-of-range addresses to exercise PSLVERR.
    class apb_oob_seq extends apb_base_seq;
        `uvm_object_utils(apb_oob_seq)
        int unsigned n = 8;
        function new(string name = "apb_oob_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < n; i++) begin
                apb_txn t = apb_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with {
                        addr[ADDR_WIDTH-1:$clog2(NBYTES)] >= NUM_REGS;
                    })
                    `uvm_error(get_type_name(), "oob randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // =========================================================================
    // Driver  -  runs the two-phase APB handshake
    // =========================================================================
    class apb_driver extends uvm_driver #(apb_txn);
        `uvm_component_utils(apb_driver)
        virtual apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no virtual interface set for driver")
        endfunction

        virtual task run_phase(uvm_phase phase);
            drive_idle();
            forever begin
                apb_txn t;
                seq_item_port.get_next_item(t);
                drive_transfer(t);
                seq_item_port.item_done();
            end
        endtask

        task drive_idle();
            vif.drv_cb.PSEL    <= 1'b0;
            vif.drv_cb.PENABLE <= 1'b0;
            vif.drv_cb.PWRITE  <= 1'b0;
            vif.drv_cb.PADDR   <= '0;
            vif.drv_cb.PWDATA  <= '0;
            vif.drv_cb.PSTRB   <= '0;
        endtask

        task drive_transfer(apb_txn t);
            // Hold off until reset is released.
            wait (vif.PRESETn === 1'b1);
            // ---- SETUP phase ----
            @(vif.drv_cb);
            vif.drv_cb.PSEL    <= 1'b1;
            vif.drv_cb.PENABLE <= 1'b0;
            vif.drv_cb.PWRITE  <= t.write;
            vif.drv_cb.PADDR   <= t.addr;
            vif.drv_cb.PWDATA  <= t.data;
            vif.drv_cb.PSTRB   <= t.write ? t.strb : '0;
            // ---- ACCESS phase ----
            @(vif.drv_cb);
            vif.drv_cb.PENABLE <= 1'b1;
            // Wait for the slave to complete (zero-wait slave -> immediate).
            do @(vif.drv_cb); while (vif.drv_cb.PREADY !== 1'b1);
            // Return to IDLE.
            drive_idle();
        endtask
    endclass

    // =========================================================================
    // Monitor  -  reconstructs completed transfers from the bus
    // =========================================================================
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual apb_if vif;
        uvm_analysis_port #(apb_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no virtual interface set for monitor")
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                // A transfer completes on the ACCESS beat with PREADY high.
                if (vif.PRESETn === 1'b1 &&
                    vif.mon_cb.PSEL && vif.mon_cb.PENABLE && vif.mon_cb.PREADY) begin
                    apb_txn t = apb_txn::type_id::create("mon_txn");
                    t.write  = vif.mon_cb.PWRITE;
                    t.addr   = vif.mon_cb.PADDR;
                    t.data   = vif.mon_cb.PWDATA;
                    t.strb   = vif.mon_cb.PSTRB;
                    t.rdata  = vif.mon_cb.PRDATA;
                    t.slverr = vif.mon_cb.PSLVERR;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Coverage  -  functional covergroup on completed transfers
    // =========================================================================
    class apb_coverage extends uvm_subscriber #(apb_txn);
        `uvm_component_utils(apb_coverage)
        apb_txn tr;

        covergroup cg;
            option.per_instance = 1;
            cp_dir : coverpoint tr.write { bins rd = {0}; bins wr = {1}; }
            cp_err : coverpoint tr.slverr { bins ok = {0}; bins err = {1}; }
            cp_idx : coverpoint tr.word_index() {
                bins low   = {[0:3]};
                bins mid   = {[4:11]};
                bins high  = {[12:NUM_REGS-1]};
                bins oob   = {[NUM_REGS:$]};
            }
            cp_strb: coverpoint tr.strb iff (tr.write) {
                bins b0    = {4'h1}; bins b1 = {4'h2};
                bins b2    = {4'h4}; bins b3 = {4'h8};
                bins full  = {4'hF};
                bins other = default;
            }
            x_dir_err : cross cp_dir, cp_err;   // did we see write/read x ok/err ?
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void write(apb_txn t);
            tr = t;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_driver    driver;
        apb_monitor   monitor;
        apb_sequencer sequencer;
        apb_coverage  coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor  = apb_monitor ::type_id::create("monitor", this);
            coverage = apb_coverage::type_id::create("coverage", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = apb_driver   ::type_id::create("driver", this);
                sequencer = apb_sequencer::type_id::create("sequencer", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            monitor.ap.connect(coverage.analysis_export);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard  -  golden reference register model
    // =========================================================================
    `uvm_analysis_imp_decl(_apb)
    class apb_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(apb_scoreboard)
        uvm_analysis_imp_apb #(apb_txn, apb_scoreboard) imp;

        // Golden model: mirror of the DUT register file.
        bit [DATA_WIDTH-1:0] model [NUM_REGS];
        int unsigned n_checks;
        int unsigned n_errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            foreach (model[i]) model[i] = '0;   // matches DUT reset value
        endfunction

        // Called for every completed transfer observed by the monitor.
        function void write_apb(apb_txn t);
            int unsigned idx = t.word_index();
            bit          oob = (idx >= NUM_REGS);
            n_checks++;

            // 1) Error-response check.
            if (t.slverr !== oob) begin
                n_errors++;
                `uvm_error(get_type_name(), $sformatf(
                    "PSLVERR mismatch: addr=0x%0h expected=%0b got=%0b",
                    t.addr, oob, t.slverr))
            end

            if (oob) begin
                // OOB reads must return 0 and must not disturb the model.
                if (!t.write && t.rdata !== '0) begin
                    n_errors++;
                    `uvm_error(get_type_name(), $sformatf(
                        "OOB read returned 0x%0h, expected 0", t.rdata))
                end
                return;
            end

            if (t.write) begin
                // Apply byte-strobed write to the reference model.
                for (int b = 0; b < NBYTES; b++)
                    if (t.strb[b])
                        model[idx][8*b +: 8] = t.data[8*b +: 8];
            end else begin
                // Compare read data against the model.
                if (t.rdata !== model[idx]) begin
                    n_errors++;
                    `uvm_error(get_type_name(), $sformatf(
                        "READ mismatch @reg%0d: expected=0x%08h got=0x%08h",
                        idx, model[idx], t.rdata))
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info(get_type_name(), $sformatf(
                "scoreboard: %0d transfers checked, %0d errors",
                n_checks, n_errors), UVM_LOW)
            if (n_checks == 0)
                `uvm_error(get_type_name(), "scoreboard saw no transfers")
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer + virtual sequences
    // =========================================================================
    class apb_vsequencer extends uvm_sequencer;
        `uvm_component_utils(apb_vsequencer)
        apb_sequencer apb_seqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class apb_vseq_base extends uvm_sequence;
        `uvm_object_utils(apb_vseq_base)
        `uvm_declare_p_sequencer(apb_vsequencer)
        function new(string name = "apb_vseq_base"); super.new(name); endfunction
    endclass

    // Smoke: write every reg, then read every reg back.
    class apb_smoke_vseq extends apb_vseq_base;
        `uvm_object_utils(apb_smoke_vseq)
        function new(string name = "apb_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            apb_write_all_seq w = apb_write_all_seq::type_id::create("w");
            apb_read_all_seq  r = apb_read_all_seq ::type_id::create("r");
            w.start(p_sequencer.apb_seqr);
            r.start(p_sequencer.apb_seqr);
        endtask
    endclass

    // Regression: smoke, then random traffic, then an OOB error burst,
    // then a final read-back sweep to confirm state integrity.
    class apb_regress_vseq extends apb_vseq_base;
        `uvm_object_utils(apb_regress_vseq)
        function new(string name = "apb_regress_vseq"); super.new(name); endfunction
        virtual task body();
            apb_write_all_seq w  = apb_write_all_seq::type_id::create("w");
            apb_rand_seq      rr = apb_rand_seq     ::type_id::create("rr");
            apb_oob_seq       o  = apb_oob_seq      ::type_id::create("o");
            apb_read_all_seq  r  = apb_read_all_seq ::type_id::create("r");
            w.start (p_sequencer.apb_seqr);
            rr.start(p_sequencer.apb_seqr);
            o.start (p_sequencer.apb_seqr);
            r.start (p_sequencer.apb_seqr);
        endtask
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class apb_env extends uvm_env;
        `uvm_component_utils(apb_env)
        apb_agent      agent;
        apb_scoreboard scoreboard;
        apb_vsequencer vseqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = apb_agent     ::type_id::create("agent", this);
            scoreboard = apb_scoreboard::type_id::create("scoreboard", this);
            vseqr      = apb_vsequencer ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.monitor.ap.connect(scoreboard.imp);
            vseqr.apb_seqr = agent.sequencer;
        endfunction
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class apb_base_test extends uvm_test;
        `uvm_component_utils(apb_base_test)
        apb_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = apb_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class apb_smoke_test extends apb_base_test;
        `uvm_component_utils(apb_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            apb_smoke_vseq vs = apb_smoke_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

    class apb_regress_test extends apb_base_test;
        `uvm_component_utils(apb_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            apb_regress_vseq vs = apb_regress_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
