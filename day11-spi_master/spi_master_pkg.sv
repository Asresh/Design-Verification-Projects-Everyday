// ============================================================================
// spi_master_pkg.sv - UVM verification environment for `spi_master`.
//
// A complete, layered UVM 1.2 environment:
//
//   * two sequence items - spi_txn (a master transfer request/result) and
//     spi_slv_txn (the byte the slave device will shift back),
//   * two active agents, each with driver + monitor + sequencer:
//       - MASTER agent : launches transfers on the parallel request bus and
//         reconstructs {mode, divider, tx_data, rx_data} from the pins,
//       - SLAVE agent  : behaves as the responding SPI device - drives MISO
//         MSB-first and recovers the MOSI byte the master shifted out,
//   * a golden reference-model SCOREBOARD enforcing the full-duplex identity
//     (master must receive exactly what the slave sent, and vice-versa),
//   * a functional COVERAGE subscriber (mode x divider x data cross),
//   * layered sequences (directed all-modes, constrained-random) and a
//     VIRTUAL SEQUENCER running master + slave virtual sequences together,
//   * a base test plus smoke / regress tests selected by +UVM_TESTNAME.
//
// Icarus Verilog does not implement UVM; build this with VCS / Questa /
// Verilator (see the Makefile). The portable Icarus-runnable check lives in
// tb_spi_master_dump.sv.
// ============================================================================
`timescale 1ns/1ps

package spi_master_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int DATA_WIDTH = 8;
    localparam int DIV_WIDTH  = 16;

    // ====================================================================
    // Sequence items.
    // ====================================================================
    // A master transfer: the randomized request, plus the captured result.
    class spi_txn extends uvm_sequence_item;
        rand bit                    cpol;
        rand bit                    cpha;
        rand bit [DIV_WIDTH-1:0]    clk_div;
        rand bit [DATA_WIDTH-1:0]   tx_data;
        bit      [DATA_WIDTH-1:0]   rx_data;   // filled by the monitor

        constraint c_div  { clk_div inside {[1:4]}; }

        `uvm_object_utils_begin(spi_txn)
            `uvm_field_int(cpol,    UVM_ALL_ON)
            `uvm_field_int(cpha,    UVM_ALL_ON)
            `uvm_field_int(clk_div, UVM_ALL_ON)
            `uvm_field_int(tx_data, UVM_ALL_ON)
            `uvm_field_int(rx_data, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "spi_txn");
            super.new(name);
        endfunction
    endclass

    // The byte the slave will shift back on MISO (and, after the exchange, the
    // MOSI byte it recovered from the master).
    class spi_slv_txn extends uvm_sequence_item;
        rand bit [DATA_WIDTH-1:0]   tx_byte;   // slave -> master (MISO)
        bit      [DATA_WIDTH-1:0]   rx_byte;   // master -> slave (MOSI), observed

        `uvm_object_utils_begin(spi_slv_txn)
            `uvm_field_int(tx_byte, UVM_ALL_ON)
            `uvm_field_int(rx_byte, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "spi_slv_txn");
            super.new(name);
        endfunction
    endclass

    // ====================================================================
    // Sequencers.
    // ====================================================================
    typedef uvm_sequencer #(spi_txn)     spi_mst_sequencer;
    typedef uvm_sequencer #(spi_slv_txn) spi_slv_sequencer;

    // ====================================================================
    // Master sequences.
    // ====================================================================
    // Directed: one transfer of every SPI mode 0..3 (a couple of dividers).
    class spi_directed_seq extends uvm_sequence #(spi_txn);
        `uvm_object_utils(spi_directed_seq)
        function new(string name = "spi_directed_seq"); super.new(name); endfunction
        virtual task body();
            bit [DATA_WIDTH-1:0] pats [] = '{8'hA5, 8'hFF, 8'h00, 8'hC3};
            for (int m = 0; m < 4; m++) begin
                spi_txn t = spi_txn::type_id::create($sformatf("dir_m%0d", m));
                start_item(t);
                if (!t.randomize() with {
                        cpol    == m[1];
                        cpha    == m[0];
                        tx_data == pats[m];
                        clk_div inside {[2:3]};
                    })
                    `uvm_error("SEQ", "directed randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Constrained-random: N fully random transfers across all modes/dividers.
    class spi_random_seq extends uvm_sequence #(spi_txn);
        `uvm_object_utils(spi_random_seq)
        rand int unsigned n_txn = 40;
        constraint c_n { n_txn inside {[20:80]}; }
        function new(string name = "spi_random_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n_txn) begin
                spi_txn t = spi_txn::type_id::create("rnd");
                start_item(t);
                if (!t.randomize())
                    `uvm_error("SEQ", "random randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Slave: supply a random byte to shift back for each transfer.
    class spi_slv_resp_seq extends uvm_sequence #(spi_slv_txn);
        `uvm_object_utils(spi_slv_resp_seq)
        rand int unsigned n_txn = 100;
        function new(string name = "spi_slv_resp_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n_txn) begin
                spi_slv_txn t = spi_slv_txn::type_id::create("slv");
                start_item(t);
                if (!t.randomize())
                    `uvm_error("SEQ", "slave randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // ====================================================================
    // Master driver - launches the parallel request and waits for `done`.
    // ====================================================================
    class spi_master_driver extends uvm_driver #(spi_txn);
        `uvm_component_utils(spi_master_driver)
        virtual spi_master_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual spi_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "master driver: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            // Idle the request lines.
            vif.mst_cb.start   <= 1'b0;
            vif.mst_cb.cpol    <= 1'b0;
            vif.mst_cb.cpha    <= 1'b0;
            vif.mst_cb.clk_div <= 'd2;
            vif.mst_cb.tx_data <= '0;
            @(posedge vif.rst_n);
            forever begin
                spi_txn t;
                seq_item_port.get_next_item(t);
                // Wait until the DUT is idle before issuing a new transfer.
                while (vif.mst_cb.busy) @(vif.mst_cb);
                vif.mst_cb.cpol    <= t.cpol;
                vif.mst_cb.cpha    <= t.cpha;
                vif.mst_cb.clk_div <= t.clk_div;
                vif.mst_cb.tx_data <= t.tx_data;
                vif.mst_cb.start   <= 1'b1;
                @(vif.mst_cb);
                vif.mst_cb.start   <= 1'b0;
                // Wait for completion.
                do @(vif.mst_cb); while (!vif.mst_cb.done);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ====================================================================
    // Slave driver - the responding device: drives MISO MSB-first per mode.
    // ====================================================================
    class spi_slave_driver extends uvm_driver #(spi_slv_txn);
        `uvm_component_utils(spi_slave_driver)
        virtual spi_master_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual spi_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "slave driver: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.slv_cb.miso <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                spi_slv_txn t;
                seq_item_port.get_next_item(t);
                drive_one(t);
                seq_item_port.item_done();
            end
        endtask

        // Shift `t.tx_byte` out on MISO and recover MOSI, synchronized to the
        // DUT's SCLK edges (detected against a registered copy) using the mode
        // published on the interface.
        task automatic drive_one(spi_slv_txn t);
            bit [DATA_WIDTH-1:0] sh_tx, sh_rx;
            bit sclk_d, cpol_l, cpha_l, leading, sample_e;
            int edges;
            // Wait for chip-select assertion.
            while (vif.slv_cb.cs_n) @(vif.slv_cb);
            cpol_l = vif.slv_cb.cpol;
            cpha_l = vif.slv_cb.cpha;
            sh_tx  = t.tx_byte;
            sh_rx  = '0;
            if (!cpha_l) begin
                vif.slv_cb.miso <= sh_tx[DATA_WIDTH-1];
                sh_tx = sh_tx << 1;
            end
            sclk_d = vif.slv_cb.sclk;
            edges  = 0;
            while (edges < 2*DATA_WIDTH) begin
                @(vif.slv_cb);
                if (vif.slv_cb.sclk !== sclk_d) begin   // an SCLK edge
                    leading  = (vif.slv_cb.sclk != cpol_l);
                    sample_e = cpha_l ? ~leading : leading;
                    if (sample_e) begin
                        sh_rx = {sh_rx[DATA_WIDTH-2:0], vif.slv_cb.mosi};
                    end else begin
                        vif.slv_cb.miso <= sh_tx[DATA_WIDTH-1];
                        sh_tx = sh_tx << 1;
                    end
                    sclk_d = vif.slv_cb.sclk;
                    edges++;
                end
            end
            t.rx_byte = sh_rx;    // the MOSI byte we recovered
        endtask
    endclass

    // ====================================================================
    // Master monitor - reconstructs each completed transfer from the pins.
    // ====================================================================
    class spi_master_monitor extends uvm_component;
        `uvm_component_utils(spi_master_monitor)
        virtual spi_master_if vif;
        uvm_analysis_port #(spi_txn) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual spi_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "master monitor: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            @(posedge vif.rst_n);
            forever begin
                spi_txn t = spi_txn::type_id::create("mon");
                // Sample the request as CS_N asserts.
                while (vif.mon_cb.cs_n) @(vif.mon_cb);
                t.cpol    = vif.mon_cb.cpol;
                t.cpha    = vif.mon_cb.cpha;
                t.clk_div = vif.mon_cb.clk_div;
                t.tx_data = vif.mon_cb.tx_data;
                // Capture the result at `done`.
                do @(vif.mon_cb); while (!vif.mon_cb.done);
                t.rx_data = vif.mon_cb.rx_data;
                ap.write(t);
            end
        endtask
    endclass

    // ====================================================================
    // Slave monitor - forwards the completed slave transaction (tx + rx).
    //   The slave driver fills rx_byte in place; the monitor snapshots the
    //   pair once the transfer finishes and publishes it for correlation.
    // ====================================================================
    class spi_slave_monitor extends uvm_component;
        `uvm_component_utils(spi_slave_monitor)
        virtual spi_master_if vif;
        uvm_analysis_port #(spi_slv_txn) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual spi_master_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "slave monitor: no vif")
        endfunction

        // Independently reconstruct the MOSI byte from the pins (does not rely
        // on the slave driver's internal state) so the scoreboard sees a truly
        // independent observation of the master-to-slave path.
        virtual task run_phase(uvm_phase phase);
            @(posedge vif.rst_n);
            forever begin
                spi_slv_txn t = spi_slv_txn::type_id::create("slvmon");
                bit [DATA_WIDTH-1:0] sh_rx;
                bit sclk_d, cpol_l, cpha_l, leading, sample_e;
                int edges;
                while (vif.mon_cb.cs_n) @(vif.mon_cb);
                cpol_l = vif.mon_cb.cpol;
                cpha_l = vif.mon_cb.cpha;
                sh_rx  = '0;
                sclk_d = vif.mon_cb.sclk;
                edges  = 0;
                while (edges < 2*DATA_WIDTH) begin
                    @(vif.mon_cb);
                    if (vif.mon_cb.sclk !== sclk_d) begin
                        leading  = (vif.mon_cb.sclk != cpol_l);
                        sample_e = cpha_l ? ~leading : leading;
                        if (sample_e)
                            sh_rx = {sh_rx[DATA_WIDTH-2:0], vif.mon_cb.mosi};
                        sclk_d = vif.mon_cb.sclk;
                        edges++;
                    end
                end
                t.rx_byte = sh_rx;
                ap.write(t);
            end
        endtask
    endclass

    // ====================================================================
    // Agents.
    // ====================================================================
    class spi_master_agent extends uvm_agent;
        `uvm_component_utils(spi_master_agent)
        spi_mst_sequencer   sqr;
        spi_master_driver   drv;
        spi_master_monitor  mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = spi_mst_sequencer::type_id::create("sqr", this);
            drv = spi_master_driver ::type_id::create("drv", this);
            mon = spi_master_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class spi_slave_agent extends uvm_agent;
        `uvm_component_utils(spi_slave_agent)
        spi_slv_sequencer   sqr;
        spi_slave_driver    drv;
        spi_slave_monitor   mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = spi_slv_sequencer::type_id::create("sqr", this);
            drv = spi_slave_driver ::type_id::create("drv", this);
            mon = spi_slave_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ====================================================================
    // Scoreboard - golden full-duplex reference model.
    //   Correlates master transactions with slave transactions in issue order
    //   and enforces: master.rx_data == slave.tx_byte (MISO path)
    //             and slave.rx_byte  == master.tx_data (MOSI path).
    // ====================================================================
    `uvm_analysis_imp_decl(_mst)
    `uvm_analysis_imp_decl(_slv)

    class spi_scoreboard extends uvm_component;
        `uvm_component_utils(spi_scoreboard)
        uvm_analysis_imp_mst #(spi_txn,     spi_scoreboard) mst_imp;
        uvm_analysis_imp_slv #(spi_slv_txn, spi_scoreboard) slv_imp;

        spi_txn     mst_q [$];
        spi_slv_txn slv_q [$];
        int matched = 0, errors = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            mst_imp = new("mst_imp", this);
            slv_imp = new("slv_imp", this);
        endfunction

        function void write_mst(spi_txn t);
            mst_q.push_back(t);
            try_match();
        endfunction
        function void write_slv(spi_slv_txn t);
            slv_q.push_back(t);
            try_match();
        endfunction

        function void try_match();
            while (mst_q.size() > 0 && slv_q.size() > 0) begin
                spi_txn     m = mst_q.pop_front();
                spi_slv_txn s = slv_q.pop_front();
                matched++;
                // MISO path: master must have received the slave's byte.
                if (m.rx_data !== s.tx_byte) begin
                    errors++;
                    `uvm_error("SB", $sformatf(
                        "MISO mismatch (mode %0d%0d): master rx=%02h exp(slave tx)=%02h",
                        m.cpol, m.cpha, m.rx_data, s.tx_byte))
                end
                // MOSI path: slave must have received the master's byte.
                if (s.rx_byte !== m.tx_data) begin
                    errors++;
                    `uvm_error("SB", $sformatf(
                        "MOSI mismatch (mode %0d%0d): slave rx=%02h exp(master tx)=%02h",
                        m.cpol, m.cpha, s.rx_byte, m.tx_data))
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matched > 0)
                `uvm_info("SB", $sformatf(
                    "RESULT: *** PASS *** (%0d transfers checked)", matched), UVM_NONE)
            else
                `uvm_error("SB", $sformatf(
                    "RESULT: *** FAIL *** (matched=%0d errors=%0d)", matched, errors))
        endfunction
    endclass

    // ====================================================================
    // Functional coverage - mode x divider x data.
    // ====================================================================
    class spi_coverage extends uvm_subscriber #(spi_txn);
        `uvm_component_utils(spi_coverage)
        spi_txn tr;

        covergroup cg;
            cp_mode : coverpoint {tr.cpol, tr.cpha} {
                bins mode0 = {2'b00};
                bins mode1 = {2'b01};
                bins mode2 = {2'b10};
                bins mode3 = {2'b11};
            }
            cp_div  : coverpoint tr.clk_div {
                bins div1 = {1};
                bins div2 = {2};
                bins div3 = {3};
                bins div4 = {4};
            }
            cp_tx   : coverpoint tr.tx_data {
                bins zero = {8'h00};
                bins ones = {8'hFF};
                bins lo   = {[8'h01:8'h7F]};
                bins hi   = {[8'h80:8'hFE]};
            }
            x_mode_div : cross cp_mode, cp_div;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent); cg = new();
        endfunction
        function void write(spi_txn t);
            tr = t; cg.sample();
        endfunction
    endclass

    // ====================================================================
    // Virtual sequencer.
    // ====================================================================
    class spi_vsequencer extends uvm_sequencer;
        `uvm_component_utils(spi_vsequencer)
        spi_mst_sequencer mst_sqr;
        spi_slv_sequencer slv_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // ====================================================================
    // Environment.
    // ====================================================================
    class spi_env extends uvm_env;
        `uvm_component_utils(spi_env)
        spi_master_agent mst;
        spi_slave_agent  slv;
        spi_scoreboard   sb;
        spi_coverage     cov;
        spi_vsequencer   vsqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            mst  = spi_master_agent::type_id::create("mst",  this);
            slv  = spi_slave_agent ::type_id::create("slv",  this);
            sb   = spi_scoreboard  ::type_id::create("sb",   this);
            cov  = spi_coverage    ::type_id::create("cov",  this);
            vsqr = spi_vsequencer  ::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            mst.mon.ap.connect(sb.mst_imp);
            mst.mon.ap.connect(cov.analysis_export);
            slv.mon.ap.connect(sb.slv_imp);
            vsqr.mst_sqr = mst.sqr;
            vsqr.slv_sqr = slv.sqr;
        endfunction
    endclass

    // ====================================================================
    // Virtual sequences - run the master stimulus and the slave responder
    // concurrently on the virtual sequencer.
    // ====================================================================
    class spi_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(spi_smoke_vseq)
        function new(string name = "spi_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            spi_vsequencer v;
            spi_directed_seq  ds = spi_directed_seq ::type_id::create("ds");
            spi_slv_resp_seq  ss = spi_slv_resp_seq ::type_id::create("ss");
            if (!$cast(v, m_sequencer)) `uvm_fatal("VSEQ", "not a vsequencer");
            ss.n_txn = 8;
            fork
                ss.start(v.slv_sqr);
                ds.start(v.mst_sqr);
            join_any
        endtask
    endclass

    class spi_regress_vseq extends uvm_sequence;
        `uvm_object_utils(spi_regress_vseq)
        function new(string name = "spi_regress_vseq"); super.new(name); endfunction
        virtual task body();
            spi_vsequencer v;
            spi_directed_seq ds = spi_directed_seq::type_id::create("ds");
            spi_random_seq   rs = spi_random_seq  ::type_id::create("rs");
            spi_slv_resp_seq ss = spi_slv_resp_seq::type_id::create("ss");
            if (!$cast(v, m_sequencer)) `uvm_fatal("VSEQ", "not a vsequencer");
            if (!rs.randomize()) `uvm_error("VSEQ", "rs randomize failed");
            ss.n_txn = 200;
            fork
                ss.start(v.slv_sqr);
                begin
                    ds.start(v.mst_sqr);
                    rs.start(v.mst_sqr);
                end
            join_any
        endtask
    endclass

    // ====================================================================
    // Tests.
    // ====================================================================
    class spi_base_test extends uvm_test;
        `uvm_component_utils(spi_base_test)
        spi_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            env = spi_env::type_id::create("env", this);
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class spi_smoke_test extends spi_base_test;
        `uvm_component_utils(spi_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            spi_smoke_vseq vseq = spi_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.drop_objection(this);
        endtask
    endclass

    class spi_regress_test extends spi_base_test;
        `uvm_component_utils(spi_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            spi_regress_vseq vseq = spi_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
