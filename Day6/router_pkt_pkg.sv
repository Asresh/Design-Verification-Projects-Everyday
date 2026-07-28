// -----------------------------------------------------------------------------
// router_pkt_pkg.sv  -  UVM verification environment for router_pkt
//
// A complete UVM testbench for the store-and-forward 1->N packet router:
//   transactions : router_beat   (an input-stream beat: dest/data/last)
//                  router_bp     (an output backpressure setting: ready mask)
//                  router_obs    (a monitored output beat: port/data/last)
//   sequencers   : router_beat_sequencer, router_bp_sequencer
//   sequences    : beat  - base / single-packet / multi-packet / rand / hammer
//                  bp    - all-ready / random-backpressure
//   drivers      : router_in_driver   (drives the input stream, honours full)
//                  router_bp_driver   (drives the whole out_ready vector)
//   monitors     : router_in_monitor  (accepted input beats  -> scoreboard)
//                  router_out_monitor (delivered output beats -> scoreboard)
//   coverage     : router_coverage    (dest x last x backpressure covergroup)
//   agents       : router_in_agent (driver+monitor+sequencer+coverage)
//                  router_out_agent(bp driver + output monitor + sequencer)
//   scoreboard   : router_scoreboard (golden per-port FIFO reference model)
//   vsequencer   : router_vsequencer (holds both sub-sequencers)
//   vsequences   : router_smoke_vseq, router_regress_vseq
//   env          : router_env
//   tests        : router_base_test, router_smoke_test, router_regress_test
//
//   NOTE: Icarus Verilog does not implement the UVM class library, so this
//   package is elaborated by VCS / Questa / Verilator. The portable, self-
//   checking companion testbench is tb_router_pkt_dump.sv (runs under Icarus).
// -----------------------------------------------------------------------------
`ifndef ROUTER_PKT_PKG_SV
`define ROUTER_PKT_PKG_SV

package router_pkt_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    // Environment geometry (mirrors the DUT parameter defaults).
    localparam int NUM_OUT = 4;
    localparam int DW      = 8;
    localparam int DEPTH   = 4;
    localparam int DEST_W  = $clog2(NUM_OUT);

    // Distinct analysis-imp suffixes so the scoreboard can receive two streams.
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    // =========================================================================
    // Transactions
    // =========================================================================
    // An input-stream beat.
    class router_beat extends uvm_sequence_item;
        rand bit [DEST_W-1:0] dest;
        rand bit [DW-1:0]     data;
        rand bit              last;

        `uvm_object_utils_begin(router_beat)
            `uvm_field_int(dest, UVM_ALL_ON)
            `uvm_field_int(data, UVM_ALL_ON)
            `uvm_field_int(last, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "router_beat"); super.new(name); endfunction
    endclass

    // An output-port backpressure setting (drives the whole out_ready vector).
    class router_bp extends uvm_sequence_item;
        rand bit [NUM_OUT-1:0] ready_mask;
        rand int unsigned      hold;          // cycles to hold this mask

        constraint c_hold { hold inside {[1:3]}; }

        `uvm_object_utils_begin(router_bp)
            `uvm_field_int(ready_mask, UVM_ALL_ON)
            `uvm_field_int(hold,       UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "router_bp"); super.new(name); endfunction
    endclass

    // A monitored output beat (produced by the output monitor).
    class router_obs extends uvm_sequence_item;
        int          port;
        bit [DW-1:0] data;
        bit          last;

        `uvm_object_utils_begin(router_obs)
            `uvm_field_int(port, UVM_ALL_ON)
            `uvm_field_int(data, UVM_ALL_ON)
            `uvm_field_int(last, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "router_obs"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Sequencers
    // =========================================================================
    typedef uvm_sequencer #(router_beat) router_beat_sequencer;
    typedef uvm_sequencer #(router_bp)   router_bp_sequencer;

    // =========================================================================
    // Input-stream sequences
    // =========================================================================
    class router_beat_base_seq extends uvm_sequence #(router_beat);
        `uvm_object_utils(router_beat_base_seq)
        function new(string name = "router_beat_base_seq"); super.new(name); endfunction
    endclass

    // Send one packet of `len` beats to output port `port`.
    class router_one_packet_seq extends router_beat_base_seq;
        rand int unsigned      len;
        rand bit [DEST_W-1:0]  port;
        constraint c_len { len inside {[1:6]}; }

        `uvm_object_utils(router_one_packet_seq)
        function new(string name = "router_one_packet_seq"); super.new(name); endfunction

        virtual task body();
            for (int i = 0; i < len; i++) begin
                router_beat b = router_beat::type_id::create("b");
                start_item(b);
                if (!b.randomize() with { dest == port; last == (i == len-1); })
                    `uvm_error("SEQ", "randomize failed")
                finish_item(b);
            end
        endtask
    endclass

    // One directed packet to every output port, in order.
    class router_all_ports_seq extends router_beat_base_seq;
        `uvm_object_utils(router_all_ports_seq)
        function new(string name = "router_all_ports_seq"); super.new(name); endfunction

        virtual task body();
            for (int p = 0; p < NUM_OUT; p++) begin
                router_one_packet_seq pk = router_one_packet_seq::type_id::create("pk");
                if (!pk.randomize() with { port == p; len == (p+1); })
                    `uvm_error("SEQ", "randomize failed")
                pk.start(m_sequencer);
            end
        endtask
    endclass

    // Constrained-random beats.
    class router_rand_seq extends router_beat_base_seq;
        rand int unsigned n;
        constraint c_n { n inside {[20:60]}; }

        `uvm_object_utils(router_rand_seq)
        function new(string name = "router_rand_seq"); super.new(name); endfunction

        virtual task body();
            for (int i = 0; i < n; i++) begin
                router_beat b = router_beat::type_id::create("b");
                start_item(b);
                if (!b.randomize())
                    `uvm_error("SEQ", "randomize failed")
                finish_item(b);
            end
        endtask
    endclass

    // Hammer a single port with more beats than DEPTH to force FIFO full.
    class router_hammer_seq extends router_beat_base_seq;
        rand bit [DEST_W-1:0] port;
        `uvm_object_utils(router_hammer_seq)
        function new(string name = "router_hammer_seq"); super.new(name); endfunction

        virtual task body();
            for (int i = 0; i < DEPTH + 6; i++) begin
                router_beat b = router_beat::type_id::create("b");
                start_item(b);
                if (!b.randomize() with { dest == port; last == (i == DEPTH+5); })
                    `uvm_error("SEQ", "randomize failed")
                finish_item(b);
            end
        endtask
    endclass

    // =========================================================================
    // Output backpressure sequences
    // =========================================================================
    class router_bp_all_ready_seq extends uvm_sequence #(router_bp);
        `uvm_object_utils(router_bp_all_ready_seq)
        function new(string name = "router_bp_all_ready_seq"); super.new(name); endfunction
        virtual task body();
            forever begin
                router_bp t = router_bp::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { ready_mask == '1; hold == 1; })
                    `uvm_error("SEQ", "randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    class router_bp_random_seq extends uvm_sequence #(router_bp);
        `uvm_object_utils(router_bp_random_seq)
        function new(string name = "router_bp_random_seq"); super.new(name); endfunction
        virtual task body();
            forever begin
                router_bp t = router_bp::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_error("SEQ", "randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // =========================================================================
    // Input-stream driver
    // =========================================================================
    class router_in_driver extends uvm_driver #(router_beat);
        `uvm_component_utils(router_in_driver)
        virtual router_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual router_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "router_in_driver: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            // Idle until reset deasserts.
            vif.in_drv_cb.in_valid <= 1'b0;
            vif.in_drv_cb.in_dest  <= '0;
            vif.in_drv_cb.in_data  <= '0;
            vif.in_drv_cb.in_last  <= 1'b0;
            @(posedge vif.rst_n);
            @(vif.in_drv_cb);
            forever begin
                router_beat b;
                seq_item_port.get_next_item(b);
                vif.in_drv_cb.in_valid <= 1'b1;
                vif.in_drv_cb.in_dest  <= b.dest;
                vif.in_drv_cb.in_data  <= b.data;
                vif.in_drv_cb.in_last  <= b.last;
                // Hold the beat until it is accepted (respects FIFO-full).
                do @(vif.in_drv_cb); while (vif.in_drv_cb.in_ready !== 1'b1);
                vif.in_drv_cb.in_valid <= 1'b0;
                vif.in_drv_cb.in_last  <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Output backpressure driver (drives the whole out_ready vector)
    // =========================================================================
    class router_bp_driver extends uvm_driver #(router_bp);
        `uvm_component_utils(router_bp_driver)
        virtual router_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual router_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "router_bp_driver: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.out_drv_cb.out_ready <= '1;      // drain freely during reset
            @(posedge vif.rst_n);
            forever begin
                router_bp t;
                seq_item_port.get_next_item(t);
                vif.out_drv_cb.out_ready <= t.ready_mask;
                repeat (t.hold) @(vif.out_drv_cb);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Input monitor: publish every accepted input beat.
    // =========================================================================
    class router_in_monitor extends uvm_component;
        `uvm_component_utils(router_in_monitor)
        virtual router_if vif;
        uvm_analysis_port #(router_beat) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual router_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "router_in_monitor: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n && vif.mon_cb.in_valid && vif.mon_cb.in_ready) begin
                    router_beat b = router_beat::type_id::create("b");
                    b.dest = vif.mon_cb.in_dest;
                    b.data = vif.mon_cb.in_data;
                    b.last = vif.mon_cb.in_last;
                    ap.write(b);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Output monitor: publish every delivered output beat (per port).
    // =========================================================================
    class router_out_monitor extends uvm_component;
        `uvm_component_utils(router_out_monitor)
        virtual router_if vif;
        uvm_analysis_port #(router_obs) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual router_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "router_out_monitor: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n) begin
                    for (int p = 0; p < NUM_OUT; p++) begin
                        if (vif.mon_cb.out_valid[p] && vif.mon_cb.out_ready[p]) begin
                            router_obs o = router_obs::type_id::create("o");
                            o.port = p;
                            o.data = vif.mon_cb.out_data[p*DW +: DW];
                            o.last = vif.mon_cb.out_last[p];
                            ap.write(o);
                        end
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Coverage subscriber (samples input beats)
    // =========================================================================
    class router_coverage extends uvm_subscriber #(router_beat);
        `uvm_component_utils(router_coverage)
        router_beat tr;

        covergroup cg;
            option.per_instance = 1;
            cp_dest : coverpoint tr.dest { bins port[] = {[0:NUM_OUT-1]}; }
            cp_last : coverpoint tr.last { bins eop = {1}; bins mid = {0}; }
            x_dest_last : cross cp_dest, cp_last;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        virtual function void write(router_beat t);
            tr = t;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Input agent
    // =========================================================================
    class router_in_agent extends uvm_agent;
        `uvm_component_utils(router_in_agent)
        router_beat_sequencer sqr;
        router_in_driver      drv;
        router_in_monitor     mon;
        router_coverage       cov;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = router_beat_sequencer::type_id::create("sqr", this);
            drv = router_in_driver     ::type_id::create("drv", this);
            mon = router_in_monitor    ::type_id::create("mon", this);
            cov = router_coverage      ::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
            mon.ap.connect(cov.analysis_export);
        endfunction
    endclass

    // =========================================================================
    // Output agent (backpressure driver + output monitor)
    // =========================================================================
    class router_out_agent extends uvm_agent;
        `uvm_component_utils(router_out_agent)
        router_bp_sequencer sqr;
        router_bp_driver    drv;
        router_out_monitor  mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = router_bp_sequencer::type_id::create("sqr", this);
            drv = router_bp_driver   ::type_id::create("drv", this);
            mon = router_out_monitor ::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard: golden per-port FIFO reference model
    // =========================================================================
    class router_scoreboard extends uvm_component;
        `uvm_component_utils(router_scoreboard)

        uvm_analysis_imp_in  #(router_beat, router_scoreboard) in_imp;
        uvm_analysis_imp_out #(router_obs,  router_scoreboard) out_imp;

        // One golden queue of expected {last,data} per output port.
        bit [DW:0] gold [NUM_OUT][$];
        int        n_sent, n_recv, n_err;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            in_imp  = new("in_imp",  this);
            out_imp = new("out_imp", this);
        endfunction

        // Predict: accepted input beat -> push onto the selected port's queue.
        virtual function void write_in(router_beat b);
            gold[b.dest].push_back({b.last, b.data});
            n_sent++;
        endfunction

        // Check: delivered output beat -> compare with head of that port's queue.
        virtual function void write_out(router_obs o);
            bit [DW:0] exp;
            n_recv++;
            if (gold[o.port].size() == 0) begin
                n_err++;
                `uvm_error("SCB", $sformatf("port%0d unexpected beat data=0x%02h last=%0b",
                                            o.port, o.data, o.last))
                return;
            end
            exp = gold[o.port].pop_front();
            if ({o.last, o.data} !== exp)
                begin
                    n_err++;
                    `uvm_error("SCB", $sformatf(
                        "port%0d mismatch: got {last=%0b,0x%02h} exp {last=%0b,0x%02h}",
                        o.port, o.last, o.data, exp[DW], exp[DW-1:0]))
                end
        endfunction

        virtual function void check_phase(uvm_phase phase);
            for (int p = 0; p < NUM_OUT; p++)
                if (gold[p].size() != 0) begin
                    n_err++;
                    `uvm_error("SCB", $sformatf("port%0d left %0d undelivered beat(s)",
                                                p, gold[p].size()))
                end
        endfunction

        virtual function void report_phase(uvm_phase phase);
            `uvm_info("SCB", $sformatf("accepted=%0d delivered=%0d errors=%0d",
                                       n_sent, n_recv, n_err), UVM_LOW)
            if (n_err == 0 && n_sent == n_recv && n_sent > 0)
                `uvm_info("SCB", "RESULT: *** PASS ***", UVM_NONE)
            else
                `uvm_error("SCB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer + environment
    // =========================================================================
    class router_vsequencer extends uvm_sequencer;
        `uvm_component_utils(router_vsequencer)
        router_beat_sequencer beat_sqr;
        router_bp_sequencer   bp_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    class router_env extends uvm_env;
        `uvm_component_utils(router_env)
        router_in_agent    in_agent;
        router_out_agent   out_agent;
        router_scoreboard  scb;
        router_vsequencer  vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            in_agent  = router_in_agent  ::type_id::create("in_agent",  this);
            out_agent = router_out_agent ::type_id::create("out_agent", this);
            scb       = router_scoreboard ::type_id::create("scb",       this);
            vseqr     = router_vsequencer ::type_id::create("vseqr",     this);
        endfunction

        function void connect_phase(uvm_phase phase);
            in_agent.mon.ap.connect(scb.in_imp);
            out_agent.mon.ap.connect(scb.out_imp);
            vseqr.beat_sqr = in_agent.sqr;
            vseqr.bp_sqr   = out_agent.sqr;
        endfunction
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class router_vseq_base extends uvm_sequence;
        `uvm_object_utils(router_vseq_base)
        function new(string name = "router_vseq_base"); super.new(name); endfunction

        router_vsequencer vseqr;
        virtual task body();
            if (!$cast(vseqr, m_sequencer))
                `uvm_fatal("VSEQ", "not running on a router_vsequencer")
        endtask
    endclass

    // Smoke: all outputs always ready, one directed packet per port.
    class router_smoke_vseq extends router_vseq_base;
        `uvm_object_utils(router_smoke_vseq)
        function new(string name = "router_smoke_vseq"); super.new(name); endfunction

        virtual task body();
            router_bp_all_ready_seq bp;
            router_all_ports_seq    pk;
            super.body();
            bp = router_bp_all_ready_seq::type_id::create("bp");
            fork bp.start(vseqr.bp_sqr); join_none      // continuous backpressure
            pk = router_all_ports_seq::type_id::create("pk");
            pk.start(vseqr.beat_sqr);                    // outputs drain via drain-time
        endtask
    endclass

    // Regress: random backpressure + hammer + heavy random traffic.
    class router_regress_vseq extends router_vseq_base;
        `uvm_object_utils(router_regress_vseq)
        function new(string name = "router_regress_vseq"); super.new(name); endfunction

        virtual task body();
            router_bp_random_seq bp;
            router_all_ports_seq pk;
            router_hammer_seq    hm;
            router_rand_seq      rs;
            super.body();
            bp = router_bp_random_seq::type_id::create("bp");
            fork bp.start(vseqr.bp_sqr); join_none

            pk = router_all_ports_seq::type_id::create("pk");
            pk.start(vseqr.beat_sqr);

            hm = router_hammer_seq::type_id::create("hm");
            if (!hm.randomize() with { port == 1; })
                `uvm_error("VSEQ", "randomize failed")
            hm.start(vseqr.beat_sqr);

            rs = router_rand_seq::type_id::create("rs");
            if (!rs.randomize()) `uvm_error("VSEQ", "randomize failed")
            rs.start(vseqr.beat_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class router_base_test extends uvm_test;
        `uvm_component_utils(router_base_test)
        router_env env;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = router_env::type_id::create("env", this);
        endfunction

        // Let the FIFOs drain (under random backpressure) before the test ends.
        virtual task run_phase(uvm_phase phase);
            phase.phase_done.set_drain_time(this, 500ns);
        endtask

        virtual function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class router_smoke_test extends router_base_test;
        `uvm_component_utils(router_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        virtual task run_phase(uvm_phase phase);
            router_smoke_vseq vseq;
            super.run_phase(phase);
            phase.raise_objection(this);
            vseq = router_smoke_vseq::type_id::create("vseq");
            vseq.start(env.vseqr);
            #500ns;
            phase.drop_objection(this);
        endtask
    endclass

    class router_regress_test extends router_base_test;
        `uvm_component_utils(router_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        virtual task run_phase(uvm_phase phase);
            router_regress_vseq vseq;
            super.run_phase(phase);
            phase.raise_objection(this);
            vseq = router_regress_vseq::type_id::create("vseq");
            vseq.start(env.vseqr);
            #2000ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
`endif
