// -----------------------------------------------------------------------------
// seq_gap_detector_pkg.sv - UVM verification environment for the MARKET-DATA
// SEQUENCE GAP DETECTOR & DUPLICATE SUPPRESSOR (seq_gap_detector.sv). Requires a
// UVM-capable simulator (VCS / Questa / Verilator >= 5 with --uvm). Icarus users
// run the portable companion TB tb_seq_gap_detector_dump.sv instead (see the
// Makefile).
//
// Contents:
//   * sgd_item      - one inbound message {seq, data}
//   * sgd_obs_item  - observed message paired with the decision the pipeline
//                     produced (paired by the monitor via a FIFO, so it is
//                     robust to the exact pipeline latency)
//   * sgd_cfg       - virtual interface + the session's initial sequence number
//   * sgd_model     - golden reference sanitizer (independent, STATEFUL re-model
//                     of the compare/dedup/gap logic + running next-expected);
//                     reused by the scoreboard
//   * sgd_driver    - programs the session once, then drives one message/cycle
//   * sgd_monitor   - reassembles {input message, its decision}
//   * sgd_agent
//   * sgd_scoreboard - re-derive the decision + next-expected and check the DUT
//   * sgd_coverage  - action x gap-size cross
//   * sequences       - showcase / corners / random
//   * sgd_vseqr      - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests           - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package seq_gap_detector_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int SEQW = 32;
    localparam int DW   = 64;
    localparam int ACTW = 2;

    // action codes (mirror the DUT)
    localparam int A_PASS = 0;
    localparam int A_DUP  = 1;
    localparam int A_GAP  = 2;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class sgd_item extends uvm_sequence_item;
        rand bit [SEQW-1:0] seq;
        rand bit [DW-1:0]   data;

        `uvm_object_utils_begin(sgd_item)
            `uvm_field_int(seq,  UVM_ALL_ON)
            `uvm_field_int(data, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "sgd_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("seq=%0d data=0x%0h", seq, data);
        endfunction
    endclass

    // Observed message paired with the decision it produced.
    class sgd_obs_item extends uvm_sequence_item;
        bit [SEQW-1:0] in_seq;
        bit [DW-1:0]   in_data;
        bit            out_fwd;
        bit [ACTW-1:0] out_action;
        bit [SEQW-1:0] out_seq;
        bit [SEQW-1:0] out_gap;
        bit [SEQW-1:0] out_expected;

        `uvm_object_utils(sgd_obs_item)
        function new(string name = "sgd_obs_item"); super.new(name); endfunction

        function string convert2string();
            string a = (out_action==A_PASS)?"PASS":(out_action==A_DUP)?"DUP ":"GAP ";
            return $sformatf("seq=%0d -> %s fwd=%0d gap=%0d exp=%0d",
                             in_seq, a, out_fwd, out_gap, out_expected);
        endfunction
    endclass

    // =========================================================================
    // Config - virtual interface + the session's initial sequence number.
    // =========================================================================
    class sgd_cfg extends uvm_object;
        virtual seq_gap_detector_if vif;
        bit [SEQW-1:0] init_seq = 100;
        `uvm_object_utils(sgd_cfg)
        function new(string name = "sgd_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference sanitizer - independent, STATEFUL re-implementation.
    // Applies the same compare/dedup/gap classification and tracks the same
    // running next-expected (advances only on a forward). Used by the scoreboard.
    // =========================================================================
    class sgd_model;
        longint unsigned m_expected;

        function new(); m_expected = 0; endfunction

        function void configure(bit [SEQW-1:0] init_seq);
            m_expected = init_seq;
        endfunction

        // Classify one message. Returns the action (0 PASS / 1 DUP / 2 GAP),
        // via ref the forward flag, the gap count, and next-expected AFTER this
        // message; advances the internal expected on a forward.
        function int classify(input  bit [SEQW-1:0] seq,
                              output bit             fwd,
                              output longint unsigned gap,
                              output longint unsigned exp_after);
            int action;
            if (seq == m_expected) begin
                action = A_PASS; gap = 0; fwd = 1'b1;
                m_expected = seq + 1;
            end else if (seq > m_expected) begin
                action = A_GAP;  gap = seq - m_expected; fwd = 1'b1;
                m_expected = seq + 1;
            end else begin
                action = A_DUP;  gap = 0; fwd = 1'b0;
                // expected unchanged
            end
            exp_after = m_expected;
            return action;
        endfunction
    endclass

    // =========================================================================
    // Driver - programs the session once after reset, then presents one message
    // per handshake cycle (zero-bubble capable).
    // =========================================================================
    class sgd_driver extends uvm_driver #(sgd_item);
        `uvm_component_utils(sgd_driver)
        sgd_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(sgd_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "sgd_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.cfg_load <= 1'b0;
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_seq   <= '0;
            cfg.vif.in_data  <= '0;
            @(posedge cfg.vif.rst_n);

            // ---- program the session initial sequence for one cycle ----
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load     <= 1'b1;
            cfg.vif.drv_cb.cfg_init_seq <= cfg.init_seq;
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load <= 1'b0;

            // ---- message stream ----
            forever begin
                sgd_item req;
                seq_item_port.get_next_item(req);
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_seq   <= req.seq;
                cfg.vif.drv_cb.in_data  <= req.data;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each input message with the decision that later emerges
    // (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class sgd_monitor extends uvm_monitor;
        `uvm_component_utils(sgd_monitor)
        sgd_cfg cfg;
        uvm_analysis_port #(sgd_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(sgd_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "sgd_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit [SEQW-1:0] sq_q [$];
            bit [DW-1:0]   da_q [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    sq_q.push_back(cfg.vif.mon_cb.in_seq);
                    da_q.push_back(cfg.vif.mon_cb.in_data);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    sgd_obs_item o = sgd_obs_item::type_id::create("obs");
                    if (sq_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input message")
                    end else begin
                        o.in_seq       = sq_q.pop_front();
                        o.in_data      = da_q.pop_front();
                        o.out_fwd      = cfg.vif.mon_cb.out_fwd;
                        o.out_action   = cfg.vif.mon_cb.out_action;
                        o.out_seq      = cfg.vif.mon_cb.out_seq;
                        o.out_gap      = cfg.vif.mon_cb.out_gap;
                        o.out_expected = cfg.vif.mon_cb.out_expected;
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(sgd_item) sgd_sqr;

    class sgd_agent extends uvm_agent;
        `uvm_component_utils(sgd_agent)
        sgd_driver  drv;
        sgd_sqr     sqr;
        sgd_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = sgd_driver ::type_id::create("drv", this);
            sqr = sgd_sqr    ::type_id::create("sqr", this);
            mon = sgd_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-derive the decision + next-expected (in arrival order) and
    // check the DUT (fwd + action + gap + echoed seq + next-expected).
    // =========================================================================
    class sgd_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(sgd_scoreboard)
        uvm_analysis_imp #(sgd_obs_item, sgd_scoreboard) imp;
        sgd_model model;
        sgd_cfg   cfg;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(sgd_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "sgd_cfg missing")
            model.configure(cfg.init_seq);
        endfunction

        function void write(sgd_obs_item o);
            int              exp_action;
            bit              exp_fwd;
            longint unsigned exp_gap, exp_exp;
            bit              ok = 1;

            exp_action = model.classify(o.in_seq, exp_fwd, exp_gap, exp_exp);

            if (o.out_seq !== o.in_seq) begin
                ok = 0;
                `uvm_error("SB", $sformatf("SEQ ECHO MISMATCH got %0d exp %0d (%s)",
                           o.out_seq, o.in_seq, o.convert2string()))
            end
            if (int'(o.out_action) !== exp_action || o.out_fwd !== exp_fwd) begin
                ok = 0;
                `uvm_error("SB", $sformatf(
                    "DECISION MISMATCH got action=%0d fwd=%0d exp action=%0d fwd=%0d (%s)",
                    o.out_action, o.out_fwd, exp_action, exp_fwd, o.convert2string()))
            end
            if (o.out_gap !== exp_gap[SEQW-1:0]) begin
                ok = 0;
                `uvm_error("SB", $sformatf("GAP MISMATCH got %0d exp %0d (%s)",
                           o.out_gap, exp_gap, o.convert2string()))
            end
            if (o.out_expected !== exp_exp[SEQW-1:0]) begin
                ok = 0;
                `uvm_error("SB", $sformatf("EXPECTED MISMATCH got %0d exp %0d (%s)",
                           o.out_expected, exp_exp, o.convert2string()))
            end

            if (ok) begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end else errors++;
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d decisions checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - action x gap-size (are PASS/DUP/GAP all seen, and are small vs
    // large gaps exercised?).
    // =========================================================================
    class sgd_coverage extends uvm_subscriber #(sgd_obs_item);
        `uvm_component_utils(sgd_coverage)

        bit [ACTW-1:0]   c_action;
        longint unsigned c_gap;

        covergroup cg;
            option.per_instance = 1;
            cp_action: coverpoint c_action {
                bins pass = {A_PASS};
                bins dup  = {A_DUP};
                bins gap  = {A_GAP};
            }
            cp_gap: coverpoint c_gap {
                bins none   = {0};
                bins one    = {1};
                bins small  = {[2:8]};
                bins large  = {[9:$]};
            }
            x_action_gap: cross cp_action, cp_gap {
                // gaps only meaningful on GAP; ignore illegal PASS/DUP-with-gap crosses
                ignore_bins nonzero_nongap =
                    binsof(cp_action) intersect {A_PASS, A_DUP} &&
                    binsof(cp_gap)    intersect {[1:$]};
            }
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cg = new();
        endfunction

        function void write(sgd_obs_item o);
            c_action = o.out_action;
            c_gap    = o.out_gap;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class sgd_vseqr extends uvm_sequencer;
        `uvm_component_utils(sgd_vseqr)
        sgd_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class sgd_env extends uvm_env;
        `uvm_component_utils(sgd_env)
        sgd_agent      agent;
        sgd_scoreboard sb;
        sgd_coverage   cov;
        sgd_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = sgd_agent     ::type_id::create("agent", this);
            sb    = sgd_scoreboard::type_id::create("sb",    this);
            cov   = sgd_coverage  ::type_id::create("cov",   this);
            vseqr = sgd_vseqr     ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(sb.imp);
            agent.mon.ap.connect(cov.analysis_export);
            vseqr.req_sqr = agent.sqr;
        endfunction
    endclass

    // =========================================================================
    // Sequences
    // =========================================================================
    // Directed showcase (assumes the test programs init_seq=100). Eight back-to-
    // back messages (zero-bubble) that walk through every action and both DUP
    // flavours (a duplicate copy and a stale late retransmit):
    //   1 seq 100 -> PASS  exp 101
    //   2 seq 101 -> PASS  exp 102
    //   3 seq 101 -> DUP   exp 102  (B-line duplicate copy)
    //   4 seq 102 -> PASS  exp 103
    //   5 seq 105 -> GAP=2 exp 106  (103,104 missing -> forward 105, resync)
    //   6 seq 106 -> PASS  exp 107
    //   7 seq 104 -> DUP   exp 107  (stale late retransmit, 104 < 107)
    //   8 seq 107 -> PASS  exp 108
    class sgd_showcase_seq extends uvm_sequence #(sgd_item);
        `uvm_object_utils(sgd_showcase_seq)
        function new(string n = "sgd_showcase_seq"); super.new(n); endfunction

        task send(bit [SEQW-1:0] s, bit [DW-1:0] d);
            sgd_item c = sgd_item::type_id::create("c");
            start_item(c);
            c.seq = s; c.data = d;
            finish_item(c);
        endtask

        task body();
            send(32'd100, 64'hA000_0000_0000_0064);   // pass
            send(32'd101, 64'hA000_0000_0000_0065);   // pass
            send(32'd101, 64'hB000_0000_0000_0065);   // dup (copy)
            send(32'd102, 64'hA000_0000_0000_0066);   // pass
            send(32'd105, 64'hA000_0000_0000_0069);   // gap=2
            send(32'd106, 64'hA000_0000_0000_006A);   // pass
            send(32'd104, 64'hC000_0000_0000_0068);   // dup (stale)
            send(32'd107, 64'hA000_0000_0000_006B);   // pass
        endtask
    endclass

    // Directed corners (walked on the CONTINUOUS session; expected picks up where
    // the showcase left off at 108): resume, immediate duplicate, minimal gap-of-1,
    // large gap, far-behind stale, resync-and-continue.
    class sgd_corner_seq extends uvm_sequence #(sgd_item);
        `uvm_object_utils(sgd_corner_seq)
        function new(string n = "sgd_corner_seq"); super.new(n); endfunction

        task send(bit [SEQW-1:0] s, bit [DW-1:0] d);
            sgd_item c = sgd_item::type_id::create("c");
            start_item(c);
            c.seq = s; c.data = d;
            finish_item(c);
        endtask

        task body();
            send(32'd108, 64'd108);   // resume  -> PASS exp 109
            send(32'd108, 64'd108);   // immediate duplicate -> DUP exp 109
            send(32'd110, 64'd110);   // minimal gap-of-1 (109 missing) -> GAP=1 exp 111
            send(32'd111, 64'd111);   // PASS exp 112
            send(32'd200, 64'd200);   // large gap (112..199 missing) -> GAP=88 exp 201
            send(32'd150, 64'd150);   // far-behind stale -> DUP exp 201
            send(32'd201, 64'd201);   // PASS exp 202
            send(32'd202, 64'd202);   // PASS exp 203
        endtask
    endclass

    // Constrained-random regression: a random walk around the expected sequence,
    // mixing in-order advances, duplicates, gaps, and stale retransmits so all
    // three actions and a range of gap sizes fire often. The item carries an
    // absolute seq the sequence computes; the golden model is the sole reference.
    class sgd_random_seq extends uvm_sequence #(sgd_item);
        `uvm_object_utils(sgd_random_seq)
        rand int unsigned n_vecs;
        bit [SEQW-1:0]    next_seq;   // sender's running counter
        bit [SEQW-1:0]    last_seq;
        constraint c_n { n_vecs inside {[80:200]}; }
        function new(string n = "sgd_random_seq"); super.new(n); endfunction

        task send(bit [SEQW-1:0] s);
            sgd_item c = sgd_item::type_id::create("c");
            start_item(c);
            c.seq = s; c.data = {32'hDA7A_0000, s};
            finish_item(c);
        endtask

        task body();
            int mode, skip, back;
            next_seq = 108 + 400;          // arbitrary session point (avoid collisions)
            last_seq = next_seq;
            for (int t = 0; t < n_vecs; t++) begin
                mode = $urandom_range(0, 9);
                if (mode <= 5) begin               // 60% in-order advance -> PASS
                    last_seq = next_seq;
                    send(next_seq);
                    next_seq = next_seq + 1;
                end else if (mode <= 6) begin       // 10% duplicate of last -> DUP
                    send(last_seq);
                end else if (mode <= 8) begin       // 20% gap (skip ahead) -> GAP
                    skip     = $urandom_range(1, 12);
                    next_seq = next_seq + skip;
                    last_seq = next_seq;
                    send(next_seq);
                    next_seq = next_seq + 1;
                end else begin                      // 10% stale far-behind -> DUP
                    back = $urandom_range(1, 20);
                    send((next_seq > back) ? (next_seq - back) : 32'd0);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class sgd_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(sgd_smoke_vseq)
        sgd_vseqr vseqr;
        function new(string n = "sgd_smoke_vseq"); super.new(n); endfunction
        task body();
            sgd_showcase_seq sh  = sgd_showcase_seq::type_id::create("sh");
            sgd_random_seq   rnd = sgd_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 80; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class sgd_regress_vseq extends uvm_sequence;
        `uvm_object_utils(sgd_regress_vseq)
        sgd_vseqr vseqr;
        function new(string n = "sgd_regress_vseq"); super.new(n); endfunction
        task body();
            sgd_showcase_seq sh  = sgd_showcase_seq::type_id::create("sh");
            sgd_corner_seq   cor = sgd_corner_seq  ::type_id::create("cor");
            sgd_random_seq   rnd = sgd_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 200; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class sgd_base_test extends uvm_test;
        `uvm_component_utils(sgd_base_test)
        sgd_env env;
        sgd_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        virtual function void set_session(sgd_cfg c); endfunction

        function void build_phase(uvm_phase phase);
            cfg = sgd_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual seq_gap_detector_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            set_session(cfg);
            uvm_config_db#(sgd_cfg)::set(this, "*", "cfg", cfg);
            env = sgd_env::type_id::create("env", this);
        endfunction
    endclass

    class sgd_smoke_test extends sgd_base_test;
        `uvm_component_utils(sgd_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_session(sgd_cfg c); c.init_seq = 100; endfunction
        task run_phase(uvm_phase phase);
            sgd_smoke_vseq v = sgd_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class sgd_regress_test extends sgd_base_test;
        `uvm_component_utils(sgd_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_session(sgd_cfg c); c.init_seq = 100; endfunction
        task run_phase(uvm_phase phase);
            sgd_regress_vseq v = sgd_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
