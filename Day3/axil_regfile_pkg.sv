// -----------------------------------------------------------------------------
// axil_regfile_pkg.sv  -  UVM verification environment for axil_regfile
//
// A complete UVM testbench for the AXI4-Lite slave register file:
//   transaction  : axil_txn
//   sequences    : axil_base_seq, axil_write_all_seq, axil_read_all_seq,
//                  axil_rand_seq, axil_oob_seq (out-of-range / SLVERR)
//   sequencer    : axil_sequencer  (uvm_sequencer #(axil_txn))
//   driver       : axil_driver     (drives the 5 AXI4-Lite channels, master)
//   monitor      : axil_monitor    (reconstructs completed AW/W/B and AR/R)
//   coverage     : axil_coverage   (functional covergroup subscriber)
//   agent        : axil_agent      (driver + monitor + sequencer + coverage)
//   scoreboard   : axil_scoreboard (golden reference register model)
//   vsequencer   : axil_vsequencer (holds the agent sequencer handle)
//   vsequences   : axil_smoke_vseq, axil_regress_vseq
//   env          : axil_env
//   tests        : axil_base_test, axil_smoke_test, axil_regress_test
// -----------------------------------------------------------------------------
package axil_regfile_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    // Environment geometry (mirrors the DUT parameter defaults).
    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;
    localparam int NBYTES     = DATA_WIDTH/8;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // =========================================================================
    // Transaction
    // =========================================================================
    class axil_txn extends uvm_sequence_item;
        rand bit                    write;
        rand bit [ADDR_WIDTH-1:0]   addr;      // byte address
        rand bit [DATA_WIDTH-1:0]   data;      // write data
        rand bit [NBYTES-1:0]       strb;      // byte strobes (writes only)
        // Response fields populated by the monitor.
        bit      [DATA_WIDTH-1:0]   rdata;
        bit      [1:0]              resp;

        constraint c_addr_align { addr[$clog2(NBYTES)-1:0] == '0; }
        constraint c_in_range   { soft addr[ADDR_WIDTH-1:$clog2(NBYTES)]
                                       < NUM_REGS; }
        constraint c_strb_nz    { write -> strb != '0; }

        `uvm_object_utils_begin(axil_txn)
            `uvm_field_int(write, UVM_ALL_ON)
            `uvm_field_int(addr,  UVM_ALL_ON)
            `uvm_field_int(data,  UVM_ALL_ON)
            `uvm_field_int(strb,  UVM_ALL_ON)
            `uvm_field_int(rdata, UVM_ALL_ON)
            `uvm_field_int(resp,  UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axil_txn");
            super.new(name);
        endfunction

        function int unsigned word_index();
            return addr >> $clog2(NBYTES);
        endfunction
    endclass

    // =========================================================================
    // Sequencer
    // =========================================================================
    typedef uvm_sequencer #(axil_txn) axil_sequencer;

    // =========================================================================
    // Sequences
    // =========================================================================
    class axil_base_seq extends uvm_sequence #(axil_txn);
        `uvm_object_utils(axil_base_seq)
        function new(string name = "axil_base_seq"); super.new(name); endfunction
    endclass

    // Write a known pattern to every register.
    class axil_write_all_seq extends axil_base_seq;
        `uvm_object_utils(axil_write_all_seq)
        function new(string name = "axil_write_all_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < NUM_REGS; i++) begin
                axil_txn t = axil_txn::type_id::create("t");
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
    class axil_read_all_seq extends axil_base_seq;
        `uvm_object_utils(axil_read_all_seq)
        function new(string name = "axil_read_all_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < NUM_REGS; i++) begin
                axil_txn t = axil_txn::type_id::create("t");
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
    class axil_rand_seq extends axil_base_seq;
        `uvm_object_utils(axil_rand_seq)
        int unsigned n = 200;
        function new(string name = "axil_rand_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < n; i++) begin
                axil_txn t = axil_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_error(get_type_name(), "rand randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Hammer out-of-range addresses to exercise the SLVERR path.
    class axil_oob_seq extends axil_base_seq;
        `uvm_object_utils(axil_oob_seq)
        int unsigned n = 8;
        function new(string name = "axil_oob_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < n; i++) begin
                axil_txn t = axil_txn::type_id::create("t");
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
    // Driver  -  drives the AXI4-Lite master side (always-ready for B / R)
    // =========================================================================
    class axil_driver extends uvm_driver #(axil_txn);
        `uvm_component_utils(axil_driver)
        virtual axil_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no virtual interface set for driver")
        endfunction

        virtual task run_phase(uvm_phase phase);
            drive_idle();
            forever begin
                axil_txn t;
                seq_item_port.get_next_item(t);
                if (t.write) drive_write(t);
                else         drive_read(t);
                seq_item_port.item_done();
            end
        endtask

        task drive_idle();
            vif.drv_cb.AWVALID <= 1'b0;
            vif.drv_cb.WVALID  <= 1'b0;
            vif.drv_cb.ARVALID <= 1'b0;
            vif.drv_cb.BREADY  <= 1'b1;   // always-ready master
            vif.drv_cb.RREADY  <= 1'b1;
            vif.drv_cb.AWADDR  <= '0;
            vif.drv_cb.WDATA   <= '0;
            vif.drv_cb.WSTRB   <= '0;
            vif.drv_cb.ARADDR  <= '0;
        endtask

        task drive_write(axil_txn t);
            wait (vif.ARESETn === 1'b1);
            @(vif.drv_cb);
            vif.drv_cb.AWADDR  <= t.addr;
            vif.drv_cb.AWVALID <= 1'b1;
            vif.drv_cb.WDATA   <= t.data;
            vif.drv_cb.WSTRB   <= t.strb;
            vif.drv_cb.WVALID  <= 1'b1;
            // Drop each request VALID once its READY is seen.
            fork
                begin
                    do @(vif.drv_cb); while (vif.drv_cb.AWREADY !== 1'b1);
                    vif.drv_cb.AWVALID <= 1'b0;
                end
                begin
                    do @(vif.drv_cb); while (vif.drv_cb.WREADY !== 1'b1);
                    vif.drv_cb.WVALID <= 1'b0;
                end
            join
            // Wait for the write response (BREADY is held high).
            do @(vif.drv_cb); while (vif.drv_cb.BVALID !== 1'b1);
            t.resp = vif.drv_cb.BRESP;
        endtask

        task drive_read(axil_txn t);
            wait (vif.ARESETn === 1'b1);
            @(vif.drv_cb);
            vif.drv_cb.ARADDR  <= t.addr;
            vif.drv_cb.ARVALID <= 1'b1;
            do @(vif.drv_cb); while (vif.drv_cb.ARREADY !== 1'b1);
            vif.drv_cb.ARVALID <= 1'b0;
            // Wait for read data (RREADY is held high).
            do @(vif.drv_cb); while (vif.drv_cb.RVALID !== 1'b1);
            t.rdata = vif.drv_cb.RDATA;
            t.resp  = vif.drv_cb.RRESP;
        endtask
    endclass

    // =========================================================================
    // Monitor  -  reconstructs completed transfers from the five channels
    // (single-outstanding slave: track the latest AW/W/AR, emit on B/R)
    // =========================================================================
    class axil_monitor extends uvm_monitor;
        `uvm_component_utils(axil_monitor)
        virtual axil_if vif;
        uvm_analysis_port #(axil_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no virtual interface set for monitor")
        endfunction

        virtual task run_phase(uvm_phase phase);
            bit [ADDR_WIDTH-1:0] aw_addr, ar_addr;
            bit [DATA_WIDTH-1:0] w_data;
            bit [NBYTES-1:0]     w_strb;
            forever begin
                @(vif.mon_cb);
                if (vif.ARESETn !== 1'b1) continue;
                // Latch request payloads on their handshakes.
                if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY)
                    aw_addr = vif.mon_cb.AWADDR;
                if (vif.mon_cb.WVALID && vif.mon_cb.WREADY) begin
                    w_data = vif.mon_cb.WDATA;
                    w_strb = vif.mon_cb.WSTRB;
                end
                if (vif.mon_cb.ARVALID && vif.mon_cb.ARREADY)
                    ar_addr = vif.mon_cb.ARADDR;
                // Emit a write transaction on the B handshake.
                if (vif.mon_cb.BVALID && vif.mon_cb.BREADY) begin
                    axil_txn t = axil_txn::type_id::create("mon_wr");
                    t.write = 1'b1;
                    t.addr  = aw_addr;
                    t.data  = w_data;
                    t.strb  = w_strb;
                    t.resp  = vif.mon_cb.BRESP;
                    ap.write(t);
                end
                // Emit a read transaction on the R handshake.
                if (vif.mon_cb.RVALID && vif.mon_cb.RREADY) begin
                    axil_txn t = axil_txn::type_id::create("mon_rd");
                    t.write = 1'b0;
                    t.addr  = ar_addr;
                    t.rdata = vif.mon_cb.RDATA;
                    t.resp  = vif.mon_cb.RRESP;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Coverage  -  functional covergroup on completed transfers
    // =========================================================================
    class axil_coverage extends uvm_subscriber #(axil_txn);
        `uvm_component_utils(axil_coverage)
        axil_txn tr;

        covergroup cg;
            option.per_instance = 1;
            cp_dir : coverpoint tr.write { bins rd = {0}; bins wr = {1}; }
            cp_resp: coverpoint tr.resp {
                bins okay   = {RESP_OKAY};
                bins slverr = {RESP_SLVERR};
            }
            cp_idx : coverpoint tr.word_index() {
                bins low  = {[0:3]};
                bins mid  = {[4:11]};
                bins high = {[12:NUM_REGS-1]};
                bins oob  = {[NUM_REGS:$]};
            }
            cp_strb: coverpoint tr.strb iff (tr.write) {
                bins b0    = {4'h1}; bins b1 = {4'h2};
                bins b2    = {4'h4}; bins b3 = {4'h8};
                bins full  = {4'hF};
                bins other = default;
            }
            x_dir_resp : cross cp_dir, cp_resp;   // write/read x okay/slverr
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void write(axil_txn t);
            tr = t;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class axil_agent extends uvm_agent;
        `uvm_component_utils(axil_agent)
        axil_driver    driver;
        axil_monitor   monitor;
        axil_sequencer sequencer;
        axil_coverage  coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor  = axil_monitor ::type_id::create("monitor", this);
            coverage = axil_coverage::type_id::create("coverage", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = axil_driver   ::type_id::create("driver", this);
                sequencer = axil_sequencer::type_id::create("sequencer", this);
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
    `uvm_analysis_imp_decl(_axil)
    class axil_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(axil_scoreboard)
        uvm_analysis_imp_axil #(axil_txn, axil_scoreboard) imp;

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

        function void write_axil(axil_txn t);
            int unsigned idx = t.word_index();
            bit          oob = (idx >= NUM_REGS);
            bit [1:0]    exp_resp = oob ? RESP_SLVERR : RESP_OKAY;
            n_checks++;

            // 1) Response-code check.
            if (t.resp !== exp_resp) begin
                n_errors++;
                `uvm_error(get_type_name(), $sformatf(
                    "RESP mismatch: %s addr=0x%0h expected=%02b got=%02b",
                    t.write ? "WR" : "RD", t.addr, exp_resp, t.resp))
            end

            if (oob) begin
                // OOB reads must return 0; state must be undisturbed.
                if (!t.write && t.rdata !== '0) begin
                    n_errors++;
                    `uvm_error(get_type_name(), $sformatf(
                        "OOB read returned 0x%0h, expected 0", t.rdata))
                end
                return;
            end

            if (t.write) begin
                for (int b = 0; b < NBYTES; b++)
                    if (t.strb[b])
                        model[idx][8*b +: 8] = t.data[8*b +: 8];
            end else begin
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
    class axil_vsequencer extends uvm_sequencer;
        `uvm_component_utils(axil_vsequencer)
        axil_sequencer axil_seqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class axil_vseq_base extends uvm_sequence;
        `uvm_object_utils(axil_vseq_base)
        `uvm_declare_p_sequencer(axil_vsequencer)
        function new(string name = "axil_vseq_base"); super.new(name); endfunction
    endclass

    // Smoke: write every reg, then read every reg back.
    class axil_smoke_vseq extends axil_vseq_base;
        `uvm_object_utils(axil_smoke_vseq)
        function new(string name = "axil_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            axil_write_all_seq w = axil_write_all_seq::type_id::create("w");
            axil_read_all_seq  r = axil_read_all_seq ::type_id::create("r");
            w.start(p_sequencer.axil_seqr);
            r.start(p_sequencer.axil_seqr);
        endtask
    endclass

    // Regression: write-all, random traffic, an OOB error burst, then a final
    // read-back sweep to confirm state integrity.
    class axil_regress_vseq extends axil_vseq_base;
        `uvm_object_utils(axil_regress_vseq)
        function new(string name = "axil_regress_vseq"); super.new(name); endfunction
        virtual task body();
            axil_write_all_seq w  = axil_write_all_seq::type_id::create("w");
            axil_rand_seq      rr = axil_rand_seq     ::type_id::create("rr");
            axil_oob_seq       o  = axil_oob_seq      ::type_id::create("o");
            axil_read_all_seq  r  = axil_read_all_seq ::type_id::create("r");
            w.start (p_sequencer.axil_seqr);
            rr.start(p_sequencer.axil_seqr);
            o.start (p_sequencer.axil_seqr);
            r.start (p_sequencer.axil_seqr);
        endtask
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class axil_env extends uvm_env;
        `uvm_component_utils(axil_env)
        axil_agent      agent;
        axil_scoreboard scoreboard;
        axil_vsequencer vseqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = axil_agent     ::type_id::create("agent", this);
            scoreboard = axil_scoreboard::type_id::create("scoreboard", this);
            vseqr      = axil_vsequencer ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.monitor.ap.connect(scoreboard.imp);
            vseqr.axil_seqr = agent.sequencer;
        endfunction
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class axil_base_test extends uvm_test;
        `uvm_component_utils(axil_base_test)
        axil_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = axil_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class axil_smoke_test extends axil_base_test;
        `uvm_component_utils(axil_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            axil_smoke_vseq vs = axil_smoke_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

    class axil_regress_test extends axil_base_test;
        `uvm_component_utils(axil_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            axil_regress_vseq vs = axil_regress_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
