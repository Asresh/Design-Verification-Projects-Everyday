// ============================================================================
// axis_skid_pkg.sv - full UVM verification environment for the AXI4-Stream
// skid buffer (register slice).
//
// This is the primary deliverable: a complete UVM-1.2 testbench with TWO
// agents (a stream SOURCE and a back-pressure SINK), layered sequences, an
// independent golden-queue reference-model scoreboard, a functional-coverage
// collector, a virtual sequencer, and virtual sequences, wired up by an env
// and a small hierarchy of tests.
//
//   master_seq --> m_sqr --> master_driver --> s_* pins ->|
//                                                         |  DUT (axis_skid)
//   slave_seq  --> s_sqr --> slave_driver  --> m_tready ->|
//                                                         |
//        master_monitor  <-- s_tvalid&&s_tready (input beats)
//        slave_monitor   <-- m_tvalid&&m_tready (output beats)
//                 |                        |
//                 v                        v
//            scoreboard (golden FIFO)   coverage collector
//
//   virtual_sequencer -> {m_sqr, s_sqr}     (two-agent orchestration)
//
// Icarus Verilog does not implement UVM, so this package is compiled by a
// UVM-capable simulator (VCS/Questa/Verilator>=5 --uvm). See the Makefile.
// The portable, self-checking companion testbench that runs under Icarus and
// produces the committed waveform is tb_axis_skid_dump.sv - it reproduces the
// SAME verification intent (golden-queue scoreboard, two-sided back-pressure,
// directed + constrained-random stimulus, VCD dump).
// ============================================================================
`ifndef AXIS_SKID_PKG_SV
`define AXIS_SKID_PKG_SV

package axis_skid_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    parameter int AXIS_DW = 8;                         // TDATA width
    parameter int AXIS_KW = (AXIS_DW + 7) / 8;         // TKEEP width

    // =======================================================================
    // Source transaction - one AXI-Stream beat plus a stimulus-shaping knob.
    // =======================================================================
    class axis_beat extends uvm_sequence_item;
        rand logic [AXIS_DW-1:0] tdata;
        rand logic [AXIS_KW-1:0] tkeep;
        rand bit                 tlast;
        rand int unsigned        pre_delay;   // idle cycles before asserting valid

        // Observed context (filled by the master monitor for checking/coverage).
        int unsigned             stall_cycles; // cycles valid waited for ready

        `uvm_object_utils_begin(axis_beat)
            `uvm_field_int(tdata,        UVM_ALL_ON)
            `uvm_field_int(tkeep,        UVM_ALL_ON)
            `uvm_field_int(tlast,        UVM_ALL_ON)
            `uvm_field_int(pre_delay,    UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(stall_cycles, UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "axis_beat"); super.new(name); endfunction

        // Most beats flow with no gap; keep bytes valid by default.
        constraint c_delay { pre_delay dist { 0 := 8, [1:3] := 3, [4:8] := 1 }; }
        constraint c_keep  { tkeep dist { '1 := 9, 0 := 1 }; }
    endclass

    // =======================================================================
    // Sink transaction - a back-pressure directive: hold m_tready at `ready`
    // for `len` clock cycles.
    // =======================================================================
    class axis_rdy extends uvm_sequence_item;
        rand bit          ready;
        rand int unsigned len;

        `uvm_object_utils_begin(axis_rdy)
            `uvm_field_int(ready, UVM_ALL_ON)
            `uvm_field_int(len,   UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "axis_rdy"); super.new(name); endfunction

        constraint c_len { len inside {[1:4]}; }
        // Ready most of the time, but stall often enough to fill the skid.
        constraint c_rdy { ready dist { 1 := 3, 0 := 1 }; }
    endclass

    // =======================================================================
    // Sequencers
    // =======================================================================
    typedef uvm_sequencer #(axis_beat) axis_src_sequencer;
    typedef uvm_sequencer #(axis_rdy)  axis_snk_sequencer;

    // ------------------------ source (stream) sequences --------------------
    // A single random packet: N-1 non-last beats then a beat with tlast.
    class axis_packet_seq extends uvm_sequence #(axis_beat);
        `uvm_object_utils(axis_packet_seq)
        rand int unsigned len;
        constraint c_len { len inside {[1:8]}; }
        function new(string name = "axis_packet_seq"); super.new(name); endfunction
        virtual task body();
            for (int i = 0; i < len; i++)
                `uvm_do_with(req, { req.tlast == (i == len-1); })
        endtask
    endclass

    // A stream of several random packets.
    class axis_stream_seq extends uvm_sequence #(axis_beat);
        `uvm_object_utils(axis_stream_seq)
        rand int unsigned npkts = 20;
        constraint c_np { npkts inside {[5:40]}; }
        function new(string name = "axis_stream_seq"); super.new(name); endfunction
        // set by the vseq before start (typed handle to the source sequencer)
        axis_src_sequencer src_sqr;
        virtual task body();
            repeat (npkts) begin
                axis_packet_seq p = axis_packet_seq::type_id::create("p");
                void'(p.randomize());
                p.start(src_sqr);
            end
        endtask
    endclass

    // Directed showcase packet: a fixed byte pattern with a marked null byte,
    // driven with no input gaps so the story is told by the sink's back-pressure.
    class axis_directed_seq extends uvm_sequence #(axis_beat);
        `uvm_object_utils(axis_directed_seq)
        function new(string name = "axis_directed_seq"); super.new(name); endfunction
        task beat(logic [AXIS_DW-1:0] d, logic [AXIS_KW-1:0] k, bit last);
            `uvm_do_with(req, { req.tdata == d; req.tkeep == k; req.tlast == last;
                                req.pre_delay == 0; })
        endtask
        virtual task body();
            beat(8'hA0, '1, 1'b0);
            beat(8'hA1, '1, 1'b0);
            beat(8'hA2, '0, 1'b0);   // null byte (tkeep=0) passes through unchanged
            beat(8'hA3, '1, 1'b0);
            beat(8'hA4, '1, 1'b0);
            beat(8'hA5, '1, 1'b1);   // end of packet
        endtask
    endclass

    // ------------------------ sink (back-pressure) sequences ---------------
    // Always ready - maximum throughput, no back-pressure.
    class axis_rdy_always_seq extends uvm_sequence #(axis_rdy);
        `uvm_object_utils(axis_rdy_always_seq)
        rand int unsigned n = 200;
        function new(string name = "axis_rdy_always_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n) `uvm_do_with(req, { req.ready == 1'b1; req.len == 4; })
        endtask
    endclass

    // Randomized back-pressure - stalls the master side to fill the skid.
    class axis_rdy_random_seq extends uvm_sequence #(axis_rdy);
        `uvm_object_utils(axis_rdy_random_seq)
        rand int unsigned n = 400;
        function new(string name = "axis_rdy_random_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n) `uvm_do(req)
        endtask
    endclass

    // =======================================================================
    // Master (source) driver - drives the slave-side (s_*) input channel.
    // Inserts pre_delay idle cycles, then presents the beat and holds it
    // (valid + payload stable) until the handshake completes.
    // =======================================================================
    class axis_master_driver extends uvm_driver #(axis_beat);
        `uvm_component_utils(axis_master_driver)
        virtual axis_skid_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axis_skid_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "virtual interface 'vif' not set")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.s_tvalid <= 1'b0;
            vif.s_tdata  <= '0;
            vif.s_tkeep  <= '0;
            vif.s_tlast  <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                axis_beat t;
                seq_item_port.get_next_item(t);
                // optional idle gap with valid low
                repeat (t.pre_delay) begin
                    @(posedge vif.clk);
                    vif.s_tvalid <= 1'b0;
                end
                // present the beat
                @(posedge vif.clk);
                vif.s_tvalid <= 1'b1;
                vif.s_tdata  <= t.tdata;
                vif.s_tkeep  <= t.tkeep;
                vif.s_tlast  <= t.tlast;
                // hold until accepted (valid stays high, payload stable)
                do @(posedge vif.clk); while (vif.s_tready !== 1'b1);
                vif.s_tvalid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =======================================================================
    // Slave (sink) driver - drives the m_tready back-pressure line by applying
    // ready/stall directives for `len` cycles each.
    // =======================================================================
    class axis_slave_driver extends uvm_driver #(axis_rdy);
        `uvm_component_utils(axis_slave_driver)
        virtual axis_skid_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axis_skid_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "virtual interface 'vif' not set")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.m_tready <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                axis_rdy t;
                seq_item_port.get_next_item(t);
                repeat (t.len) begin
                    @(posedge vif.clk);
                    vif.m_tready <= t.ready;
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =======================================================================
    // Master monitor - samples ACCEPTED input beats (s_tvalid && s_tready) and
    // measures how many cycles valid had to wait (upstream back-pressure).
    // =======================================================================
    class axis_master_monitor extends uvm_component;
        `uvm_component_utils(axis_master_monitor)
        virtual axis_skid_if vif;
        uvm_analysis_port #(axis_beat) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axis_skid_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "virtual interface 'vif' not set")
        endfunction
        virtual task run_phase(uvm_phase phase);
            int unsigned stall = 0;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n) begin
                    if (vif.s_tvalid && !vif.s_tready) stall++;
                    if (vif.s_tvalid && vif.s_tready) begin
                        axis_beat b = axis_beat::type_id::create("in_beat");
                        b.tdata = vif.s_tdata;
                        b.tkeep = vif.s_tkeep;
                        b.tlast = vif.s_tlast;
                        b.stall_cycles = stall;
                        ap.write(b);
                        stall = 0;
                    end
                end
            end
        endtask
    endclass

    // =======================================================================
    // Slave monitor - samples output beats (m_tvalid && m_tready).
    // =======================================================================
    class axis_slave_monitor extends uvm_component;
        `uvm_component_utils(axis_slave_monitor)
        virtual axis_skid_if vif;
        uvm_analysis_port #(axis_beat) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axis_skid_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "virtual interface 'vif' not set")
        endfunction
        virtual task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.m_tvalid && vif.m_tready) begin
                    axis_beat b = axis_beat::type_id::create("out_beat");
                    b.tdata = vif.m_tdata;
                    b.tkeep = vif.m_tkeep;
                    b.tlast = vif.m_tlast;
                    ap.write(b);
                end
            end
        endtask
    endclass

    // =======================================================================
    // Agents
    // =======================================================================
    class axis_master_agent extends uvm_agent;
        `uvm_component_utils(axis_master_agent)
        axis_master_driver    drv;
        axis_master_monitor   mon;
        axis_src_sequencer    sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = axis_master_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = axis_master_driver::type_id::create("drv", this);
                sqr = axis_src_sequencer::type_id::create("sqr", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class axis_slave_agent extends uvm_agent;
        `uvm_component_utils(axis_slave_agent)
        axis_slave_driver     drv;
        axis_slave_monitor    mon;
        axis_snk_sequencer    sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = axis_slave_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = axis_slave_driver::type_id::create("drv", this);
                sqr = axis_snk_sequencer::type_id::create("sqr", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =======================================================================
    // Scoreboard - golden-queue reference model.
    //   input beats  -> push {tdata,tkeep,tlast} onto the expected FIFO
    //   output beats -> pop the oldest, compare EXACT payload + order
    // A skid buffer is a pure pass-through, so the reference model IS an
    // order-preserving queue: nothing may be dropped, duplicated, or reordered.
    // =======================================================================
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    class axis_scoreboard extends uvm_component;
        `uvm_component_utils(axis_scoreboard)
        uvm_analysis_imp_in  #(axis_beat, axis_scoreboard) in_imp;
        uvm_analysis_imp_out #(axis_beat, axis_scoreboard) out_imp;

        axis_beat expected_q[$];
        int matched = 0;
        int mismatched = 0;
        int in_count = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            in_imp  = new("in_imp",  this);
            out_imp = new("out_imp", this);
        endfunction

        function void write_in(axis_beat b);
            axis_beat e = axis_beat::type_id::create("exp");
            e.tdata = b.tdata; e.tkeep = b.tkeep; e.tlast = b.tlast;
            expected_q.push_back(e);
            in_count++;
        endfunction

        function void write_out(axis_beat r);
            axis_beat e;
            if (expected_q.size() == 0) begin
                mismatched++;
                `uvm_error("SCB", $sformatf(
                    "output beat with NO expected input: data=%02h keep=%b last=%b",
                    r.tdata, r.tkeep, r.tlast))
                return;
            end
            e = expected_q.pop_front();
            if ((r.tdata !== e.tdata) || (r.tkeep !== e.tkeep) ||
                (r.tlast !== e.tlast)) begin
                mismatched++;
                `uvm_error("SCB", $sformatf(
                    "MISMATCH: DUT data=%02h keep=%b last=%b | EXP data=%02h keep=%b last=%b",
                    r.tdata, r.tkeep, r.tlast, e.tdata, e.tkeep, e.tlast))
            end else begin
                matched++;
                `uvm_info("SCB", $sformatf("MATCH data=%02h keep=%b last=%b",
                    r.tdata, r.tkeep, r.tlast), UVM_HIGH)
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (expected_q.size() != 0)
                `uvm_error("SCB", $sformatf(
                    "%0d input beats never appeared on the output", expected_q.size()))
        endfunction

        function void report_phase(uvm_phase phase);
            if (mismatched == 0 && matched > 0 && expected_q.size() == 0)
                `uvm_info("SCB", $sformatf(
                    "beats in=%0d matched=%0d  RESULT: *** PASS ***",
                    in_count, matched), UVM_LOW)
            else
                `uvm_error("SCB", $sformatf(
                    "in=%0d matched=%0d mismatched=%0d leftover=%0d  RESULT: *** FAIL ***",
                    in_count, matched, mismatched, expected_q.size()))
        endfunction
    endclass

    // =======================================================================
    // Functional coverage - subscribes to the observed OUTPUT beat stream.
    // Covers payload buckets, packet framing (tlast), the null-byte (tkeep=0)
    // case, and crosses framing with the null-byte case.
    // =======================================================================
    class axis_coverage extends uvm_subscriber #(axis_beat);
        `uvm_component_utils(axis_coverage)

        logic [AXIS_DW-1:0] cg_data;
        logic [AXIS_KW-1:0] cg_keep;
        bit                 cg_last;

        covergroup cg;
            option.per_instance = 1;
            cp_data: coverpoint cg_data {
                bins zero    = {8'h00};
                bins allone  = {8'hFF};
                bins low[4]  = {[8'h01:8'h7F]};
                bins high[4] = {[8'h80:8'hFE]};
            }
            cp_keep: coverpoint cg_keep {
                bins kept = {'1};
                bins null_byte = {0};
            }
            cp_last: coverpoint cg_last;               // packet-boundary seen both ways
            x_last_keep: cross cp_last, cp_keep;       // e.g. null byte at end of packet
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent); cg = new();
        endfunction

        function void write(axis_beat b);
            cg_data = b.tdata; cg_keep = b.tkeep; cg_last = b.tlast;
            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("functional coverage = %0.2f%%",
                                       cg.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // =======================================================================
    // Virtual sequencer - holds handles to BOTH leaf sequencers so a virtual
    // sequence can orchestrate the source and the back-pressure sink together.
    // =======================================================================
    class axis_vsequencer extends uvm_sequencer;
        `uvm_component_utils(axis_vsequencer)
        axis_src_sequencer m_sqr;   // stream source
        axis_snk_sequencer s_sqr;   // back-pressure sink
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // =======================================================================
    // Environment
    // =======================================================================
    class axis_env extends uvm_env;
        `uvm_component_utils(axis_env)
        axis_master_agent m_agent;   // source
        axis_slave_agent  s_agent;   // back-pressure sink
        axis_scoreboard   scb;
        axis_coverage     cov;
        axis_vsequencer   vsqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            m_agent = axis_master_agent::type_id::create("m_agent", this);
            s_agent = axis_slave_agent::type_id::create("s_agent", this);
            scb     = axis_scoreboard::type_id::create("scb", this);
            cov     = axis_coverage::type_id::create("cov", this);
            vsqr    = axis_vsequencer::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            m_agent.mon.ap.connect(scb.in_imp);    // input beats  -> expected FIFO
            s_agent.mon.ap.connect(scb.out_imp);   // output beats -> checked
            s_agent.mon.ap.connect(cov.analysis_export);
            vsqr.m_sqr = m_agent.sqr;
            vsqr.s_sqr = s_agent.sqr;
        endfunction
    endclass

    // =======================================================================
    // Virtual sequences - orchestrate the source stream and the back-pressure
    // sink concurrently on the virtual sequencer.
    // =======================================================================
    // Smoke: directed showcase packet against a mostly-ready sink.
    class axis_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(axis_smoke_vseq)
        axis_vsequencer vsqr;
        function new(string name = "axis_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            axis_directed_seq   dseq = axis_directed_seq::type_id::create("dseq");
            axis_rdy_random_seq rdy  = axis_rdy_random_seq::type_id::create("rdy");
            void'(rdy.randomize() with { n == 40; });
            fork
                rdy.start(vsqr.s_sqr);       // sink applies back-pressure
                dseq.start(vsqr.m_sqr);      // source streams the directed packet
            join_any
            disable fork;
        endtask
    endclass

    // Regression: many random packets against randomized two-sided back-pressure.
    class axis_regress_vseq extends uvm_sequence;
        `uvm_object_utils(axis_regress_vseq)
        axis_vsequencer vsqr;
        function new(string name = "axis_regress_vseq"); super.new(name); endfunction
        virtual task body();
            axis_stream_seq     str = axis_stream_seq::type_id::create("str");
            axis_rdy_random_seq rdy = axis_rdy_random_seq::type_id::create("rdy");
            void'(str.randomize() with { npkts == 30; });
            void'(rdy.randomize() with { n == 400; });
            str.src_sqr = vsqr.m_sqr;
            fork
                rdy.start(vsqr.s_sqr);
                str.start(vsqr.m_sqr);
            join_any
            disable fork;
        endtask
    endclass

    // =======================================================================
    // Tests
    // =======================================================================
    class axis_base_test extends uvm_test;
        `uvm_component_utils(axis_base_test)
        axis_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = axis_env::type_id::create("env", this);
            uvm_config_db#(uvm_active_passive_enum)::set(this, "env.m_agent",
                                                         "is_active", UVM_ACTIVE);
            uvm_config_db#(uvm_active_passive_enum)::set(this, "env.s_agent",
                                                         "is_active", UVM_ACTIVE);
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class axis_smoke_test extends axis_base_test;
        `uvm_component_utils(axis_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            axis_smoke_vseq vseq = axis_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.vsqr = env.vsqr;
            vseq.start(env.vsqr);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class axis_regress_test extends axis_base_test;
        `uvm_component_utils(axis_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            axis_regress_vseq vseq = axis_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.vsqr = env.vsqr;
            vseq.start(env.vsqr);
            #500ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
`endif
