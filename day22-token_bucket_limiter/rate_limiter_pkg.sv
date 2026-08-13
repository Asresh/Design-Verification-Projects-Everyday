// -----------------------------------------------------------------------------
// rate_limiter_pkg.sv - UVM verification environment for the TOKEN-BUCKET
// ORDER-RATE LIMITER (rate_limiter.sv). Requires a UVM-capable simulator
// (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run the portable
// companion TB tb_rate_limiter_dump.sv instead (see the Makefile).
//
// Contents:
//   * rl_item      - one inbound request {ts, cost}
//   * rl_obs_item  - observed request paired with the decision the pipeline
//                    produced (paired by the monitor via a FIFO, so it is robust
//                    to the exact pipeline latency)
//   * rl_cfg       - virtual interface + the session's initial timestamp
//   * rl_model     - golden reference token bucket (independent, STATEFUL re-model
//                    of the lazy-refill + strict-priority admission logic + the
//                    running {tokens, last_ts}); reused by the scoreboard
//   * rl_driver    - programs the session once, then drives one request/cycle
//   * rl_monitor   - reassembles {input request, its decision}
//   * rl_agent
//   * rl_scoreboard - re-derive the decision + bucket level and check the DUT
//   * rl_coverage  - reason x cost-class cross
//   * sequences      - showcase / corners / random
//   * rl_vseqr      - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests          - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package rate_limiter_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int TSW             = 32;
    localparam int TOKW            = 16;
    localparam int COSTW           = 8;
    localparam int RSNW            = 2;
    localparam int BUCKET_MAX      = 8;
    localparam int REFILL_PER_TICK = 1;

    // reason codes (mirror the DUT)
    localparam int R_GRANT = 0;
    localparam int R_THROT = 1;
    localparam int R_ZERO  = 2;
    localparam int R_OVER  = 3;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class rl_item extends uvm_sequence_item;
        rand bit [TSW-1:0]   ts;
        rand bit [COSTW-1:0] cost;

        `uvm_object_utils_begin(rl_item)
            `uvm_field_int(ts,   UVM_ALL_ON)
            `uvm_field_int(cost, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "rl_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("ts=%0d cost=%0d", ts, cost);
        endfunction
    endclass

    // Observed request paired with the decision it produced.
    class rl_obs_item extends uvm_sequence_item;
        bit [TSW-1:0]   in_ts;
        bit [COSTW-1:0] in_cost;
        bit             out_grant;
        bit [RSNW-1:0]  out_reason;
        bit [TSW-1:0]   out_ts;
        bit [COSTW-1:0] out_cost;
        bit [TOKW-1:0]  out_avail;
        bit [TOKW-1:0]  out_tokens;

        `uvm_object_utils(rl_obs_item)
        function new(string name = "rl_obs_item"); super.new(name); endfunction

        function string reason_str();
            case (out_reason)
                R_GRANT: return "GRANT";
                R_THROT: return "THROT";
                R_ZERO : return "ZERO ";
                default: return "OVER ";
            endcase
        endfunction

        function string convert2string();
            return $sformatf("ts=%0d cost=%0d -> %s grant=%0d avail=%0d tokens=%0d",
                             in_ts, in_cost, reason_str(), out_grant,
                             out_avail, out_tokens);
        endfunction
    endclass

    // =========================================================================
    // Config - virtual interface + the session's initial timestamp.
    // =========================================================================
    class rl_cfg extends uvm_object;
        virtual rate_limiter_if vif;
        bit [TSW-1:0] init_ts = 0;
        `uvm_object_utils(rl_cfg)
        function new(string name = "rl_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference token bucket - independent, STATEFUL re-implementation.
    // Applies the same lazy refill (elapsed*REFILL_PER_TICK saturated at
    // BUCKET_MAX) and the same strict-priority admission classification, and
    // tracks the same running {tokens, last_ts}. Used by the scoreboard.
    // =========================================================================
    class rl_model;
        longint unsigned m_tokens;
        longint unsigned m_last_ts;

        function new(); m_tokens = BUCKET_MAX; m_last_ts = 0; endfunction

        // session (re)start: bucket full, clock anchored.
        function void configure(bit [TSW-1:0] init_ts);
            m_tokens  = BUCKET_MAX;
            m_last_ts = init_ts;
        endfunction

        // Classify one request. Returns the reason (0..3), via ref the grant flag,
        // the available (post-refill, pre-spend) level, and the remaining tokens;
        // advances the internal {tokens, last_ts}.
        function int classify(input  bit [TSW-1:0]   ts,
                              input  bit [COSTW-1:0] cost,
                              output bit             grant,
                              output longint unsigned avail,
                              output longint unsigned tokens_after);
            longint unsigned elapsed, refill, av;
            int reason;
            elapsed = (ts >= m_last_ts) ? (ts - m_last_ts) : 0;
            refill  = elapsed * REFILL_PER_TICK;
            av      = m_tokens + refill;
            if (av > BUCKET_MAX) av = BUCKET_MAX;

            if (cost == 0) begin
                reason = R_ZERO;  grant = 1'b0; m_tokens = av;
            end else if (cost > BUCKET_MAX) begin
                reason = R_OVER;  grant = 1'b0; m_tokens = av;
            end else if (av < cost) begin
                reason = R_THROT; grant = 1'b0; m_tokens = av;
            end else begin
                reason = R_GRANT; grant = 1'b1; m_tokens = av - cost;
            end
            m_last_ts    = ts;
            avail        = av;
            tokens_after = m_tokens;
            return reason;
        endfunction
    endclass

    // =========================================================================
    // Driver - programs the session once after reset, then presents one request
    // per handshake cycle (zero-bubble capable).
    // =========================================================================
    class rl_driver extends uvm_driver #(rl_item);
        `uvm_component_utils(rl_driver)
        rl_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(rl_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "rl_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.cfg_load <= 1'b0;
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_ts    <= '0;
            cfg.vif.in_cost  <= '0;
            @(posedge cfg.vif.rst_n);

            // ---- program the session initial timestamp for one cycle ----
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load    <= 1'b1;
            cfg.vif.drv_cb.cfg_init_ts <= cfg.init_ts;
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load <= 1'b0;

            // ---- request stream ----
            forever begin
                rl_item req;
                seq_item_port.get_next_item(req);
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_ts    <= req.ts;
                cfg.vif.drv_cb.in_cost  <= req.cost;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each input request with the decision that later emerges
    // (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class rl_monitor extends uvm_monitor;
        `uvm_component_utils(rl_monitor)
        rl_cfg cfg;
        uvm_analysis_port #(rl_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(rl_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "rl_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit [TSW-1:0]   ts_q  [$];
            bit [COSTW-1:0] co_q  [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    ts_q.push_back(cfg.vif.mon_cb.in_ts);
                    co_q.push_back(cfg.vif.mon_cb.in_cost);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    rl_obs_item o = rl_obs_item::type_id::create("obs");
                    if (ts_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input request")
                    end else begin
                        o.in_ts      = ts_q.pop_front();
                        o.in_cost    = co_q.pop_front();
                        o.out_grant  = cfg.vif.mon_cb.out_grant;
                        o.out_reason = cfg.vif.mon_cb.out_reason;
                        o.out_ts     = cfg.vif.mon_cb.out_ts;
                        o.out_cost   = cfg.vif.mon_cb.out_cost;
                        o.out_avail  = cfg.vif.mon_cb.out_avail;
                        o.out_tokens = cfg.vif.mon_cb.out_tokens;
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(rl_item) rl_sqr;

    class rl_agent extends uvm_agent;
        `uvm_component_utils(rl_agent)
        rl_driver  drv;
        rl_sqr     sqr;
        rl_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = rl_driver ::type_id::create("drv", this);
            sqr = rl_sqr    ::type_id::create("sqr", this);
            mon = rl_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-derive the decision + bucket level (in arrival order) and
    // check the DUT (grant + reason + echoed ts/cost + avail + remaining tokens).
    // =========================================================================
    class rl_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(rl_scoreboard)
        uvm_analysis_imp #(rl_obs_item, rl_scoreboard) imp;
        rl_model model;
        rl_cfg   cfg;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(rl_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "rl_cfg missing")
            model.configure(cfg.init_ts);
        endfunction

        function void write(rl_obs_item o);
            int              exp_reason;
            bit              exp_grant;
            longint unsigned exp_avail, exp_tokens;
            bit              ok = 1;

            exp_reason = model.classify(o.in_ts, o.in_cost, exp_grant,
                                        exp_avail, exp_tokens);

            if (o.out_ts !== o.in_ts || o.out_cost !== o.in_cost) begin
                ok = 0;
                `uvm_error("SB", $sformatf("ECHO MISMATCH got ts=%0d cost=%0d exp ts=%0d cost=%0d",
                           o.out_ts, o.out_cost, o.in_ts, o.in_cost))
            end
            if (int'(o.out_reason) !== exp_reason || o.out_grant !== exp_grant) begin
                ok = 0;
                `uvm_error("SB", $sformatf(
                    "DECISION MISMATCH got reason=%0d grant=%0d exp reason=%0d grant=%0d (%s)",
                    o.out_reason, o.out_grant, exp_reason, exp_grant, o.convert2string()))
            end
            if (o.out_avail !== exp_avail[TOKW-1:0]) begin
                ok = 0;
                `uvm_error("SB", $sformatf("AVAIL MISMATCH got %0d exp %0d (%s)",
                           o.out_avail, exp_avail, o.convert2string()))
            end
            if (o.out_tokens !== exp_tokens[TOKW-1:0]) begin
                ok = 0;
                `uvm_error("SB", $sformatf("TOKENS MISMATCH got %0d exp %0d (%s)",
                           o.out_tokens, exp_tokens, o.convert2string()))
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
    // Coverage - reason x cost-class (are all four reasons seen, across zero /
    // unit / burst / oversized cost classes?).
    // =========================================================================
    class rl_coverage extends uvm_subscriber #(rl_obs_item);
        `uvm_component_utils(rl_coverage)

        bit [RSNW-1:0]  c_reason;
        bit [COSTW-1:0] c_cost;
        bit [TOKW-1:0]  c_avail;

        covergroup cg;
            option.per_instance = 1;
            cp_reason: coverpoint c_reason {
                bins grant = {R_GRANT};
                bins throt = {R_THROT};
                bins zero  = {R_ZERO};
                bins over  = {R_OVER};
            }
            cp_cost: coverpoint c_cost {
                bins zero    = {0};
                bins one     = {1};
                bins burst   = {[2:BUCKET_MAX]};
                bins over    = {[BUCKET_MAX+1:$]};
            }
            cp_avail: coverpoint c_avail {
                bins empty = {0};
                bins mid   = {[1:BUCKET_MAX-1]};
                bins full  = {BUCKET_MAX};
            }
            x_reason_cost: cross cp_reason, cp_cost;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cg = new();
        endfunction

        function void write(rl_obs_item o);
            c_reason = o.out_reason;
            c_cost   = o.out_cost;
            c_avail  = o.out_avail;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class rl_vseqr extends uvm_sequencer;
        `uvm_component_utils(rl_vseqr)
        rl_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class rl_env extends uvm_env;
        `uvm_component_utils(rl_env)
        rl_agent      agent;
        rl_scoreboard sb;
        rl_coverage   cov;
        rl_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = rl_agent     ::type_id::create("agent", this);
            sb    = rl_scoreboard::type_id::create("sb",    this);
            cov   = rl_coverage  ::type_id::create("cov",   this);
            vseqr = rl_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase (assumes the test programs init_ts=0, bucket full=8).
    // Eight back-to-back requests (zero-bubble) that walk through every reason,
    // a burst drain, a throttle, a same-tick refill=0, a refill-and-recover, and
    // both malformed rejects:
    //   1 ts=10 cost=3 -> GRANT    avail=8 tokens=5  (bucket was full)
    //   2 ts=10 cost=4 -> GRANT    avail=5 tokens=1  (same tick, no refill)
    //   3 ts=10 cost=2 -> THROTTLE avail=1 tokens=1  (rate exceeded)
    //   4 ts=10 cost=1 -> GRANT    avail=1 tokens=0
    //   5 ts=10 cost=1 -> THROTTLE avail=0 tokens=0  (bucket empty)
    //   6 ts=13 cost=2 -> GRANT    avail=3 tokens=1  (+3 refill over 3 ticks)
    //   7 ts=13 cost=0 -> ZEROCOST avail=1 tokens=1  (malformed)
    //   8 ts=20 cost=9 -> OVERSIZED avail=8 tokens=8 (cost>BUCKET_MAX, +7 sat 8)
    class rl_showcase_seq extends uvm_sequence #(rl_item);
        `uvm_object_utils(rl_showcase_seq)
        function new(string n = "rl_showcase_seq"); super.new(n); endfunction

        task send(bit [TSW-1:0] t, bit [COSTW-1:0] c);
            rl_item it = rl_item::type_id::create("it");
            start_item(it);
            it.ts = t; it.cost = c;
            finish_item(it);
        endtask

        task body();
            send(32'd10, 8'd3);   // grant  (full bucket)
            send(32'd10, 8'd4);   // grant
            send(32'd10, 8'd2);   // throttle
            send(32'd10, 8'd1);   // grant
            send(32'd10, 8'd1);   // throttle (empty)
            send(32'd13, 8'd2);   // grant   (refilled)
            send(32'd13, 8'd0);   // zerocost
            send(32'd20, 8'd9);   // oversized
        endtask
    endclass

    // Directed corners on the CONTINUOUS session (picks up after the showcase):
    // full refill saturation, exact-boundary grant, one-over throttle, cost==
    // BUCKET_MAX single-shot drain, and a long idle that saturates the bucket.
    class rl_corner_seq extends uvm_sequence #(rl_item);
        `uvm_object_utils(rl_corner_seq)
        function new(string n = "rl_corner_seq"); super.new(n); endfunction

        task send(bit [TSW-1:0] t, bit [COSTW-1:0] c);
            rl_item it = rl_item::type_id::create("it");
            start_item(it);
            it.ts = t; it.cost = c;
            finish_item(it);
        endtask

        task body();
            send(32'd100, 8'd8);   // long idle -> bucket saturates to 8, cost 8 -> GRANT tokens=0
            send(32'd100, 8'd1);   // same tick, empty -> THROTTLE
            send(32'd104, 8'd4);   // +4 refill, cost 4 exact boundary -> GRANT tokens=0
            send(32'd105, 8'd2);   // +1 refill (=1), cost 2 -> THROTTLE (one over)
            send(32'd113, 8'd8);   // +8 refill sat 8, cost 8 -> GRANT tokens=0
            send(32'd113, 8'd9);   // oversized, tokens stay 0
            send(32'd113, 8'd0);   // zerocost
            send(32'd200, 8'd1);   // long idle saturate, cost 1 -> GRANT tokens=7
        endtask
    endclass

    // Constrained-random regression: a monotonically advancing timestamp with
    // random small inter-arrival gaps and random costs squeezed toward the bucket
    // depth (so grants, throttles, zero-cost and oversized all fire). The golden
    // model is the sole reference.
    class rl_random_seq extends uvm_sequence #(rl_item);
        `uvm_object_utils(rl_random_seq)
        rand int unsigned n_vecs;
        bit [TSW-1:0]     cur_ts;
        constraint c_n { n_vecs inside {[80:200]}; }
        function new(string n = "rl_random_seq"); super.new(n); endfunction

        task send(bit [TSW-1:0] t, bit [COSTW-1:0] c);
            rl_item it = rl_item::type_id::create("it");
            start_item(it);
            it.ts = t; it.cost = c;
            finish_item(it);
        endtask

        task body();
            int gap; bit [COSTW-1:0] c;
            cur_ts = 32'd1000;                 // arbitrary session continuation
            for (int t = 0; t < n_vecs; t++) begin
                gap = $urandom_range(0, 4);    // 0 -> same-tick burst
                cur_ts = cur_ts + gap[TSW-1:0];
                // costs: mostly 0..BUCKET_MAX (with a few oversized / zero)
                case ($urandom_range(0, 9))
                    0:       c = 8'd0;                                  // zerocost
                    1:       c = BUCKET_MAX + $urandom_range(1, 4);     // oversized
                    default: c = $urandom_range(1, BUCKET_MAX);         // normal
                endcase
                send(cur_ts, c);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class rl_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(rl_smoke_vseq)
        rl_vseqr vseqr;
        function new(string n = "rl_smoke_vseq"); super.new(n); endfunction
        task body();
            rl_showcase_seq sh  = rl_showcase_seq::type_id::create("sh");
            rl_random_seq   rnd = rl_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 80; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class rl_regress_vseq extends uvm_sequence;
        `uvm_object_utils(rl_regress_vseq)
        rl_vseqr vseqr;
        function new(string n = "rl_regress_vseq"); super.new(n); endfunction
        task body();
            rl_showcase_seq sh  = rl_showcase_seq::type_id::create("sh");
            rl_corner_seq   cor = rl_corner_seq  ::type_id::create("cor");
            rl_random_seq   rnd = rl_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 200; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class rl_base_test extends uvm_test;
        `uvm_component_utils(rl_base_test)
        rl_env env;
        rl_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        virtual function void set_session(rl_cfg c); endfunction

        function void build_phase(uvm_phase phase);
            cfg = rl_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual rate_limiter_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            set_session(cfg);
            uvm_config_db#(rl_cfg)::set(this, "*", "cfg", cfg);
            env = rl_env::type_id::create("env", this);
        endfunction
    endclass

    class rl_smoke_test extends rl_base_test;
        `uvm_component_utils(rl_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_session(rl_cfg c); c.init_ts = 0; endfunction
        task run_phase(uvm_phase phase);
            rl_smoke_vseq v = rl_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class rl_regress_test extends rl_base_test;
        `uvm_component_utils(rl_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_session(rl_cfg c); c.init_ts = 0; endfunction
        task run_phase(uvm_phase phase);
            rl_regress_vseq v = rl_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
