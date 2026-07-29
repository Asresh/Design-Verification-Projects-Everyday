// ============================================================================
// async_fifo_pkg.sv - UVM verification environment for the dual-clock async_fifo
// ----------------------------------------------------------------------------
// A full class-based UVM environment for verifying a clock-domain-crossing FIFO:
//
//   * Two independent agents, one per clock domain:
//       - wr_agent : wr_sequencer + wr_driver + wr_monitor   (wr_clk domain)
//       - rd_agent : rd_sequencer + rd_driver + rd_monitor   (rd_clk domain)
//   * A golden-queue SCOREBOARD that receives write and read transactions on two
//     analysis exports and proves DATA INTEGRITY + ORDERING across the CDC.
//   * A COVERAGE subscriber (functional coverage on data, flags, corners).
//   * A VIRTUAL SEQUENCER coordinating both domain sequencers, and VIRTUAL
//     SEQUENCES (fill/drain and concurrent random) that drive multi-domain tests.
//
// Requires a UVM-capable simulator (VCS / Questa / Xcelium / Verilator >=5 --uvm).
// Icarus Verilog cannot compile this; use tb_async_fifo_dump.sv there instead.
// ============================================================================
`ifndef ASYNC_FIFO_PKG_SV
`define ASYNC_FIFO_PKG_SV
`timescale 1ns/1ps

package async_fifo_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    // Compile-time data width the environment is built for (matches tb_top).
    parameter int DW    = 8;
    parameter int AW    = 4;
    parameter int DEPTH = 1 << AW;

    // ------------------------------------------------------------------
    // Transactions
    // ------------------------------------------------------------------
    class wr_txn extends uvm_sequence_item;
        rand bit [DW-1:0] data;
        rand int unsigned pre_gap;      // idle wr-cycles before this write

        constraint c_gap { pre_gap inside {[0:3]}; }

        `uvm_object_utils_begin(wr_txn)
            `uvm_field_int(data,    UVM_ALL_ON)
            `uvm_field_int(pre_gap, UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_object_utils_end

        function new(string name = "wr_txn"); super.new(name); endfunction
    endclass

    class rd_txn extends uvm_sequence_item;
        rand int unsigned pre_gap;      // idle rd-cycles before this read
        bit [DW-1:0]      data;         // captured by the monitor on a read

        constraint c_gap { pre_gap inside {[0:3]}; }

        `uvm_object_utils_begin(rd_txn)
            `uvm_field_int(pre_gap, UVM_ALL_ON | UVM_NOCOMPARE)
            `uvm_field_int(data,    UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "rd_txn"); super.new(name); endfunction
    endclass

    // ------------------------------------------------------------------
    // Config object
    // ------------------------------------------------------------------
    class fifo_cfg extends uvm_object;
        virtual async_fifo_if #(DW) vif;
        `uvm_object_utils(fifo_cfg)
        function new(string name = "fifo_cfg"); super.new(name); endfunction
    endclass

    // ------------------------------------------------------------------
    // Sequencers
    // ------------------------------------------------------------------
    typedef uvm_sequencer #(wr_txn) wr_sequencer;
    typedef uvm_sequencer #(rd_txn) rd_sequencer;

    // ------------------------------------------------------------------
    // Write driver: honours wr_full (never overflows the FIFO).
    // ------------------------------------------------------------------
    class wr_driver extends uvm_driver #(wr_txn);
        `uvm_component_utils(wr_driver)
        virtual async_fifo_if #(DW) vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            fifo_cfg cfg;
            if (!uvm_config_db#(fifo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "wr_driver: fifo_cfg not set")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            // Idle until write reset is released.
            vif.wr_drv_cb.wr_en   <= 1'b0;
            vif.wr_drv_cb.wr_data <= '0;
            @(posedge vif.wr_rst_n);
            forever begin
                wr_txn tr;
                seq_item_port.get_next_item(tr);
                repeat (tr.pre_gap) begin
                    vif.wr_drv_cb.wr_en <= 1'b0;
                    @(vif.wr_drv_cb);
                end
                // Wait for space, then drive exactly one accepted write.
                while (vif.wr_drv_cb.wr_full) begin
                    vif.wr_drv_cb.wr_en <= 1'b0;
                    @(vif.wr_drv_cb);
                end
                vif.wr_drv_cb.wr_en   <= 1'b1;
                vif.wr_drv_cb.wr_data <= tr.data;
                @(vif.wr_drv_cb);
                vif.wr_drv_cb.wr_en <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Read driver: honours rd_empty (never underflows the FIFO).
    // ------------------------------------------------------------------
    class rd_driver extends uvm_driver #(rd_txn);
        `uvm_component_utils(rd_driver)
        virtual async_fifo_if #(DW) vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            fifo_cfg cfg;
            if (!uvm_config_db#(fifo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "rd_driver: fifo_cfg not set")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            vif.rd_drv_cb.rd_en <= 1'b0;
            @(posedge vif.rd_rst_n);
            forever begin
                rd_txn tr;
                seq_item_port.get_next_item(tr);
                repeat (tr.pre_gap) begin
                    vif.rd_drv_cb.rd_en <= 1'b0;
                    @(vif.rd_drv_cb);
                end
                while (vif.rd_drv_cb.rd_empty) begin
                    vif.rd_drv_cb.rd_en <= 1'b0;
                    @(vif.rd_drv_cb);
                end
                vif.rd_drv_cb.rd_en <= 1'b1;
                @(vif.rd_drv_cb);
                vif.rd_drv_cb.rd_en <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Write monitor: broadcasts every ACCEPTED write (wr_en & !wr_full).
    // ------------------------------------------------------------------
    class wr_monitor extends uvm_monitor;
        `uvm_component_utils(wr_monitor)
        virtual async_fifo_if #(DW) vif;
        uvm_analysis_port #(wr_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            fifo_cfg cfg;
            if (!uvm_config_db#(fifo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "wr_monitor: fifo_cfg not set")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            @(posedge vif.wr_rst_n);
            forever begin
                @(vif.wr_mon_cb);
                if (vif.wr_mon_cb.wr_en && !vif.wr_mon_cb.wr_full) begin
                    wr_txn tr = wr_txn::type_id::create("wr_obs");
                    tr.data = vif.wr_mon_cb.wr_data;
                    ap.write(tr);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Read monitor: broadcasts every ACCEPTED read (rd_en & !rd_empty),
    // capturing the first-word-fall-through data present this cycle.
    // ------------------------------------------------------------------
    class rd_monitor extends uvm_monitor;
        `uvm_component_utils(rd_monitor)
        virtual async_fifo_if #(DW) vif;
        uvm_analysis_port #(rd_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            fifo_cfg cfg;
            if (!uvm_config_db#(fifo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "rd_monitor: fifo_cfg not set")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            @(posedge vif.rd_rst_n);
            forever begin
                @(vif.rd_mon_cb);
                if (vif.rd_mon_cb.rd_en && !vif.rd_mon_cb.rd_empty) begin
                    rd_txn tr = rd_txn::type_id::create("rd_obs");
                    tr.data = vif.rd_mon_cb.rd_data;
                    ap.write(tr);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Agents
    // ------------------------------------------------------------------
    class wr_agent extends uvm_agent;
        `uvm_component_utils(wr_agent)
        wr_sequencer sqr;
        wr_driver    drv;
        wr_monitor   mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            mon = wr_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = wr_sequencer::type_id::create("sqr", this);
                drv = wr_driver   ::type_id::create("drv", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class rd_agent extends uvm_agent;
        `uvm_component_utils(rd_agent)
        rd_sequencer sqr;
        rd_driver    drv;
        rd_monitor   mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            mon = rd_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = rd_sequencer::type_id::create("sqr", this);
                drv = rd_driver   ::type_id::create("drv", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Scoreboard - golden FIFO reference model across the CDC
    // ------------------------------------------------------------------
    `uvm_analysis_imp_decl(_wr)
    `uvm_analysis_imp_decl(_rd)

    class fifo_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(fifo_scoreboard)

        uvm_analysis_imp_wr #(wr_txn, fifo_scoreboard) wr_imp;
        uvm_analysis_imp_rd #(rd_txn, fifo_scoreboard) rd_imp;

        bit [DW-1:0] golden [$];
        int unsigned n_wr, n_rd, n_err;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            wr_imp = new("wr_imp", this);
            rd_imp = new("rd_imp", this);
        endfunction

        // Every accepted write pushes the golden queue.
        function void write_wr(wr_txn tr);
            golden.push_back(tr.data);
            n_wr++;
            `uvm_info("SB", $sformatf("PUSH  0x%02h (occupancy=%0d)",
                                      tr.data, golden.size()), UVM_HIGH)
        endfunction

        // Every accepted read must match (and pop) the golden queue front.
        function void write_rd(rd_txn tr);
            bit [DW-1:0] exp;
            n_rd++;
            if (golden.size() == 0) begin
                n_err++;
                `uvm_error("SB", $sformatf("READ 0x%02h but golden FIFO empty",
                                           tr.data))
                return;
            end
            exp = golden.pop_front();
            if (tr.data !== exp) begin
                n_err++;
                `uvm_error("SB", $sformatf("DATA MISMATCH got=0x%02h exp=0x%02h",
                                           tr.data, exp))
            end else begin
                `uvm_info("SB", $sformatf("POP   0x%02h OK (occupancy=%0d)",
                                          exp, golden.size()), UVM_HIGH)
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (n_wr == 0 || n_rd == 0)
                `uvm_error("SB", "no traffic observed")
            if (n_err != 0)
                `uvm_error("SB", $sformatf("%0d mismatch(es) detected", n_err))
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf(
                "writes=%0d reads=%0d residual=%0d errors=%0d",
                n_wr, n_rd, golden.size(), n_err), UVM_LOW)
            if (n_err == 0 && n_wr > 0 && n_rd > 0)
                `uvm_info("SB", "RESULT: *** PASS ***", UVM_NONE)
            else
                `uvm_error("SB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Coverage subscriber - functional coverage on data and CDC corners
    // ------------------------------------------------------------------
    class fifo_coverage extends uvm_component;
        `uvm_component_utils(fifo_coverage)

        uvm_analysis_imp_wr #(wr_txn, fifo_coverage) wr_imp;
        uvm_analysis_imp_rd #(rd_txn, fifo_coverage) rd_imp;

        bit [DW-1:0] wr_d, rd_d;

        covergroup cg_wr;
            option.per_instance = 1;
            cp_wr_data : coverpoint wr_d {
                bins low   = {[0 : (1<<(DW-1))-1]};
                bins high  = {[(1<<(DW-1)) : (1<<DW)-1]};
                bins zero  = {0};
                bins ones  = {(1<<DW)-1};
            }
        endgroup

        covergroup cg_rd;
            option.per_instance = 1;
            cp_rd_data : coverpoint rd_d {
                bins low   = {[0 : (1<<(DW-1))-1]};
                bins high  = {[(1<<(DW-1)) : (1<<DW)-1]};
                bins zero  = {0};
                bins ones  = {(1<<DW)-1};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_wr  = new();
            cg_rd  = new();
            wr_imp = new("wr_imp", this);
            rd_imp = new("rd_imp", this);
        endfunction

        function void write_wr(wr_txn tr); wr_d = tr.data; cg_wr.sample(); endfunction
        function void write_rd(rd_txn tr); rd_d = tr.data; cg_rd.sample(); endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("wr coverage=%.1f%%  rd coverage=%.1f%%",
                       cg_wr.get_inst_coverage(), cg_rd.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Virtual sequencer
    // ------------------------------------------------------------------
    class fifo_vseqr extends uvm_sequencer;
        `uvm_component_utils(fifo_vseqr)
        wr_sequencer wr_sqr;
        rd_sequencer rd_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // ------------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------------
    class fifo_env extends uvm_env;
        `uvm_component_utils(fifo_env)
        wr_agent        wr_agt;
        rd_agent        rd_agt;
        fifo_scoreboard sb;
        fifo_coverage   cov;
        fifo_vseqr      vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            wr_agt = wr_agent      ::type_id::create("wr_agt", this);
            rd_agt = rd_agent      ::type_id::create("rd_agt", this);
            sb     = fifo_scoreboard::type_id::create("sb", this);
            cov    = fifo_coverage ::type_id::create("cov", this);
            vseqr  = fifo_vseqr    ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Monitors -> scoreboard + coverage
            wr_agt.mon.ap.connect(sb.wr_imp);
            rd_agt.mon.ap.connect(sb.rd_imp);
            wr_agt.mon.ap.connect(cov.wr_imp);
            rd_agt.mon.ap.connect(cov.rd_imp);
            // Virtual sequencer handles
            vseqr.wr_sqr = wr_agt.sqr;
            vseqr.rd_sqr = rd_agt.sqr;
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Domain sequences
    // ------------------------------------------------------------------
    class wr_burst_seq extends uvm_sequence #(wr_txn);
        `uvm_object_utils(wr_burst_seq)
        rand int unsigned n;
        constraint c_n { n inside {[1:64]}; }
        function new(string name = "wr_burst_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                wr_txn tr = wr_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize()) `uvm_error("SEQ", "wr randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    class rd_burst_seq extends uvm_sequence #(rd_txn);
        `uvm_object_utils(rd_burst_seq)
        rand int unsigned n;
        constraint c_n { n inside {[1:64]}; }
        function new(string name = "rd_burst_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                rd_txn tr = rd_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize()) `uvm_error("SEQ", "rd randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Virtual sequences
    // ------------------------------------------------------------------
    // Fill the FIFO, then drain it - stresses the full and empty corners and
    // the Gray-pointer synchronizers when the FIFO transitions full<->empty.
    class fill_drain_vseq extends uvm_sequence;
        `uvm_object_utils(fill_drain_vseq)
        fifo_vseqr vseqr;
        function new(string name = "fill_drain_vseq"); super.new(name); endfunction
        task body();
            if (!$cast(vseqr, m_sequencer))
                `uvm_fatal("VSEQ", "fill_drain_vseq needs a fifo_vseqr")
            // Run the write and read bursts CONCURRENTLY. Equal counts guarantee
            // every written word has a matching read, so neither driver stalls
            // forever: the faster write clock transiently fills the FIFO (the
            // driver's full-guard stall/resume path is exercised) while the
            // slower read clock lets it approach empty between bursts. Running
            // them sequentially would deadlock - a DEPTH+2 write burst with no
            // concurrent reader stalls the write driver at wr_full permanently.
            repeat (3) begin
                fork
                    begin
                        wr_burst_seq wseq = wr_burst_seq::type_id::create("wseq");
                        wseq.n = DEPTH + 2;         // writer outruns reader -> hits full
                        wseq.start(vseqr.wr_sqr);
                    end
                    begin
                        rd_burst_seq rseq = rd_burst_seq::type_id::create("rseq");
                        rseq.n = DEPTH + 2;         // matched count -> drains, no deadlock
                        rseq.start(vseqr.rd_sqr);
                    end
                join
            end
        endtask
    endclass

    // Both domains run concurrently at independent, randomized rates.
    class concurrent_vseq extends uvm_sequence;
        `uvm_object_utils(concurrent_vseq)
        fifo_vseqr vseqr;
        function new(string name = "concurrent_vseq"); super.new(name); endfunction
        task body();
            if (!$cast(vseqr, m_sequencer))
                `uvm_fatal("VSEQ", "concurrent_vseq needs a fifo_vseqr")
            fork
                begin
                    wr_burst_seq wseq = wr_burst_seq::type_id::create("wseq");
                    wseq.n = 128;
                    wseq.start(vseqr.wr_sqr);
                end
                begin
                    rd_burst_seq rseq = rd_burst_seq::type_id::create("rseq");
                    rseq.n = 128;
                    rseq.start(vseqr.rd_sqr);
                end
            join
        endtask
    endclass

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    class fifo_base_test extends uvm_test;
        `uvm_component_utils(fifo_base_test)
        fifo_env env;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            env = fifo_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class fifo_smoke_test extends fifo_base_test;
        `uvm_component_utils(fifo_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            fill_drain_vseq vseq = fill_drain_vseq::type_id::create("vseq");
            phase.raise_objection(this, "smoke");
            vseq.start(env.vseqr);
            #500ns;                          // let the CDC drain
            phase.drop_objection(this, "smoke");
        endtask
    endclass

    class fifo_regress_test extends fifo_base_test;
        `uvm_component_utils(fifo_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            concurrent_vseq vseq = concurrent_vseq::type_id::create("vseq");
            phase.raise_objection(this, "regress");
            vseq.start(env.vseqr);
            #1000ns;
            phase.drop_objection(this, "regress");
        endtask
    endclass

endpackage
`endif
