// -----------------------------------------------------------------------------
// risk_gate_pkg.sv - UVM verification environment for the pre-trade RISK-CHECK
// GATE (risk_gate.sv). Requires a UVM-capable simulator (VCS / Questa /
// Verilator >= 5 with --uvm). Icarus users run the portable companion TB
// tb_risk_gate_dump.sv instead (see the Makefile).
//
// Contents:
//   * risk_item      - one order {side, price, qty}
//   * risk_obs_item  - observed order paired with the verdict the pipeline
//                      produced (paired by the monitor via a FIFO, so it is
//                      robust to the exact pipeline latency)
//   * risk_cfg       - virtual interface + the risk limits to program
//   * risk_model     - golden reference gate (independent, STATEFUL re-model of
//                      the priority-encoded checks + the running net position);
//                      reused by the scoreboard
//   * risk_driver    - programs the limits once, then drives one order per cycle
//   * risk_monitor   - reassembles {input order, its verdict}
//   * risk_agent
//   * risk_scoreboard - re-derives the verdict + position and checks the DUT
//   * risk_coverage  - reason x side x accept cross
//   * sequences       - showcase / corners / random
//   * risk_vseqr      - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests           - base / smoke / regress (each programs its own limits)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package risk_gate_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int PW   = 16;
    localparam int QW   = 16;
    localparam int POSW = 32;
    localparam int NW   = PW + QW;      // 32
    localparam int RW   = 3;

    // reason codes (mirror the DUT)
    localparam int R_OK       = 0;
    localparam int R_QTY_ZERO = 1;
    localparam int R_QTY_MAX  = 2;
    localparam int R_BAND     = 3;
    localparam int R_NOTIONAL = 4;
    localparam int R_POSLIM   = 5;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class risk_item extends uvm_sequence_item;
        rand bit              side;         // 0 = buy, 1 = sell
        rand bit [PW-1:0]     price;
        rand bit [QW-1:0]     qty;

        `uvm_object_utils_begin(risk_item)
            `uvm_field_int(side,  UVM_ALL_ON)
            `uvm_field_int(price, UVM_ALL_ON)
            `uvm_field_int(qty,   UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "risk_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("%s price=%0d qty=%0d",
                             side ? "SELL" : "BUY ", price, qty);
        endfunction
    endclass

    // Observed order paired with the verdict it produced.
    class risk_obs_item extends uvm_sequence_item;
        bit                   in_side;
        bit [PW-1:0]          in_price;
        bit [QW-1:0]          in_qty;
        bit                   out_accept;
        bit [RW-1:0]          out_reason;
        bit                   out_side;
        bit signed [POSW-1:0] out_pos;

        `uvm_object_utils(risk_obs_item)
        function new(string name = "risk_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("%s price=%0d qty=%0d -> accept=%0d reason=%0d pos=%0d",
                             in_side ? "SELL" : "BUY ", in_price, in_qty,
                             out_accept, out_reason, out_pos);
        endfunction
    endclass

    // =========================================================================
    // Config - virtual interface + the risk limits the test wants programmed.
    // =========================================================================
    class risk_cfg extends uvm_object;
        virtual risk_gate_if vif;
        bit [QW-1:0]   max_qty      = 1000;
        bit [PW-1:0]   min_price    = 100;
        bit [PW-1:0]   max_price    = 200;
        bit [NW-1:0]   max_notional = 100000;
        bit [POSW-1:0] pos_limit    = 500;
        `uvm_object_utils(risk_cfg)
        function new(string name = "risk_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference gate - independent, STATEFUL re-implementation. Applies
    // the same strict-priority checks and tracks the same running net position
    // (advances only on an accept). Used by the scoreboard.
    // =========================================================================
    class risk_model;
        // programmed limits
        longint unsigned m_max_qty;
        longint unsigned m_min_price;
        longint unsigned m_max_price;
        longint unsigned m_max_notional;
        longint unsigned m_pos_limit;
        // running net position (signed)
        longint          m_pos;

        function new();
            m_max_qty = 0; m_min_price = 0; m_max_price = 0;
            m_max_notional = 0; m_pos_limit = 0; m_pos = 0;
        endfunction

        function void configure(bit [QW-1:0]   max_qty,
                                bit [PW-1:0]   min_price,
                                bit [PW-1:0]   max_price,
                                bit [NW-1:0]   max_notional,
                                bit [POSW-1:0] pos_limit);
            m_max_qty      = max_qty;
            m_min_price    = min_price;
            m_max_price    = max_price;
            m_max_notional = max_notional;
            m_pos_limit    = pos_limit;
        endfunction

        function void reset_pos(); m_pos = 0; endfunction

        // Evaluate one order against the current limits + position. Returns the
        // priority-encoded reason (0 = accept) and, via ref, the position AFTER
        // this order; advances the internal position on an accept.
        function int check(input bit side, input bit [PW-1:0] price,
                           input bit [QW-1:0] qty, output longint pos_after);
            longint unsigned notional;
            longint          delta, proj;
            int              reason;

            notional = longint'(price) * longint'(qty);
            delta    = side ? -longint'(qty) : longint'(qty);
            proj     = m_pos + delta;

            if      (qty == 0)                                     reason = R_QTY_ZERO;
            else if (longint'(qty) > m_max_qty)                    reason = R_QTY_MAX;
            else if (price < m_min_price || price > m_max_price)   reason = R_BAND;
            else if (notional > m_max_notional)                    reason = R_NOTIONAL;
            else if (proj > longint'(m_pos_limit) ||
                     proj < -longint'(m_pos_limit))                reason = R_POSLIM;
            else                                                   reason = R_OK;

            if (reason == R_OK) m_pos = proj;   // book advances only on accept
            pos_after = m_pos;
            return reason;
        endfunction
    endclass

    // =========================================================================
    // Driver - programs the limits once after reset, then presents one order per
    // handshake cycle (zero-bubble capable).
    // =========================================================================
    class risk_driver extends uvm_driver #(risk_item);
        `uvm_component_utils(risk_driver)
        risk_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(risk_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "risk_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.cfg_load <= 1'b0;
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_side  <= 1'b0;
            cfg.vif.in_price <= '0;
            cfg.vif.in_qty   <= '0;
            @(posedge cfg.vif.rst_n);

            // ---- program the risk limits for one cycle ----
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load         <= 1'b1;
            cfg.vif.drv_cb.cfg_max_qty      <= cfg.max_qty;
            cfg.vif.drv_cb.cfg_min_price    <= cfg.min_price;
            cfg.vif.drv_cb.cfg_max_price    <= cfg.max_price;
            cfg.vif.drv_cb.cfg_max_notional <= cfg.max_notional;
            cfg.vif.drv_cb.cfg_pos_limit    <= cfg.pos_limit;
            @(cfg.vif.drv_cb);
            cfg.vif.drv_cb.cfg_load <= 1'b0;

            // ---- order stream ----
            forever begin
                risk_item req;
                seq_item_port.get_next_item(req);
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_side  <= req.side;
                cfg.vif.drv_cb.in_price <= req.price;
                cfg.vif.drv_cb.in_qty   <= req.qty;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each accepted input order with the verdict that later
    // emerges (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class risk_monitor extends uvm_monitor;
        `uvm_component_utils(risk_monitor)
        risk_cfg cfg;
        uvm_analysis_port #(risk_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(risk_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "risk_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit          sd_q [$];
            bit [PW-1:0] pr_q [$];
            bit [QW-1:0] qt_q [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    sd_q.push_back(cfg.vif.mon_cb.in_side);
                    pr_q.push_back(cfg.vif.mon_cb.in_price);
                    qt_q.push_back(cfg.vif.mon_cb.in_qty);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    risk_obs_item o = risk_obs_item::type_id::create("obs");
                    if (sd_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input order")
                    end else begin
                        o.in_side    = sd_q.pop_front();
                        o.in_price   = pr_q.pop_front();
                        o.in_qty     = qt_q.pop_front();
                        o.out_accept = cfg.vif.mon_cb.out_accept;
                        o.out_reason = cfg.vif.mon_cb.out_reason;
                        o.out_side   = cfg.vif.mon_cb.out_side;
                        o.out_pos    = cfg.vif.mon_cb.out_pos;
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(risk_item) risk_sqr;

    class risk_agent extends uvm_agent;
        `uvm_component_utils(risk_agent)
        risk_driver  drv;
        risk_sqr     sqr;
        risk_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = risk_driver ::type_id::create("drv", this);
            sqr = risk_sqr    ::type_id::create("sqr", this);
            mon = risk_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-derive the verdict + net position (in arrival order) and
    // check the DUT (accept + reason + echoed order + position).
    // =========================================================================
    class risk_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(risk_scoreboard)
        uvm_analysis_imp #(risk_obs_item, risk_scoreboard) imp;
        risk_model model;
        risk_cfg   cfg;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(risk_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "risk_cfg missing")
            model.configure(cfg.max_qty, cfg.min_price, cfg.max_price,
                            cfg.max_notional, cfg.pos_limit);
            model.reset_pos();
        endfunction

        function void write(risk_obs_item o);
            int     exp_reason;
            bit     exp_accept;
            longint exp_pos;
            bit     ok = 1;

            exp_reason = model.check(o.in_side, o.in_price, o.in_qty, exp_pos);
            exp_accept = (exp_reason == R_OK);

            if (o.out_side !== o.in_side) begin
                ok = 0;
                `uvm_error("SB", $sformatf("SIDE ECHO MISMATCH got %0d exp %0d (%s)",
                           o.out_side, o.in_side, o.convert2string()))
            end
            if (o.out_accept !== exp_accept || int'(o.out_reason) !== exp_reason) begin
                ok = 0;
                `uvm_error("SB", $sformatf(
                    "VERDICT MISMATCH got accept=%0d reason=%0d exp accept=%0d reason=%0d (%s)",
                    o.out_accept, o.out_reason, exp_accept, exp_reason, o.convert2string()))
            end
            if (o.out_pos !== exp_pos[POSW-1:0]) begin
                ok = 0;
                `uvm_error("SB", $sformatf("POSITION MISMATCH got %0d exp %0d (%s)",
                           o.out_pos, exp_pos, o.convert2string()))
            end

            if (ok) begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end else errors++;
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d verdicts checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - reason x side x accept (are all reject reasons exercised for
    // both buys and sells, and are accepts seen?).
    // =========================================================================
    class risk_coverage extends uvm_subscriber #(risk_obs_item);
        `uvm_component_utils(risk_coverage)

        bit [RW-1:0] c_reason;
        bit          c_side;
        bit          c_accept;

        covergroup cg;
            option.per_instance = 1;
            cp_reason: coverpoint c_reason {
                bins accept   = {R_OK};
                bins qty_zero = {R_QTY_ZERO};
                bins qty_max  = {R_QTY_MAX};
                bins band     = {R_BAND};
                bins notional = {R_NOTIONAL};
                bins poslim   = {R_POSLIM};
            }
            cp_side:   coverpoint c_side   { bins buy = {0}; bins sell = {1}; }
            cp_accept: coverpoint c_accept { bins reject = {0}; bins accept = {1}; }
            x_reason_side: cross cp_reason, cp_side;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cg = new();
        endfunction

        function void write(risk_obs_item o);
            c_reason = o.out_reason;
            c_side   = o.in_side;
            c_accept = o.out_accept;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class risk_vseqr extends uvm_sequencer;
        `uvm_component_utils(risk_vseqr)
        risk_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class risk_env extends uvm_env;
        `uvm_component_utils(risk_env)
        risk_agent      agent;
        risk_scoreboard sb;
        risk_coverage   cov;
        risk_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = risk_agent     ::type_id::create("agent", this);
            sb    = risk_scoreboard::type_id::create("sb",    this);
            cov   = risk_coverage  ::type_id::create("cov",   this);
            vseqr = risk_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase (assumes the test's default limits: max_qty=1000,
    // price band [100,200], max_notional=100000, pos_limit=500). Eight back-to-
    // back orders that walk through every verdict, in strict-priority order, and
    // exercise position accumulation and a position-reducing sell:
    //   1 BUY  150 x100 -> ACCEPT           pos +100
    //   2 BUY  150 x300 -> ACCEPT           pos +400
    //   3 BUY  150 x300 -> POS_LIMIT (5)    pos +400 (would be +700 > 500)
    //   4 BUY  150 x2000-> QTY_MAX  (2)     pos +400
    //   5 SELL  50 x100 -> PRICE_BAND(3)    pos +400 (50 < 100)
    //   6 BUY  200 x800 -> NOTIONAL (4)     pos +400 (160000 > 100000)
    //   7 BUY  100 x0   -> QTY_ZERO (1)     pos +400
    //   8 SELL 150 x300 -> ACCEPT           pos +100
    class risk_showcase_seq extends uvm_sequence #(risk_item);
        `uvm_object_utils(risk_showcase_seq)
        function new(string n = "risk_showcase_seq"); super.new(n); endfunction

        task send(bit sd, bit [PW-1:0] pr, bit [QW-1:0] qt);
            risk_item c = risk_item::type_id::create("c");
            start_item(c);
            c.side = sd; c.price = pr; c.qty = qt;
            finish_item(c);
        endtask

        task body();
            send(1'b0, 16'd150, 16'd100);   // accept
            send(1'b0, 16'd150, 16'd300);   // accept
            send(1'b0, 16'd150, 16'd300);   // pos limit
            send(1'b0, 16'd150, 16'd2000);  // qty max
            send(1'b1, 16'd50,  16'd100);   // price band
            send(1'b0, 16'd200, 16'd800);   // notional
            send(1'b0, 16'd100, 16'd0);     // qty zero
            send(1'b1, 16'd150, 16'd300);   // accept (sell reduces position)
        endtask
    endclass

    // Directed corners: boundary values (exactly at each limit, which must be
    // ACCEPTED since the checks are strict), a sell that drives the position
    // negative to the opposite limit, and a wrap back toward flat.
    class risk_corner_seq extends uvm_sequence #(risk_item);
        `uvm_object_utils(risk_corner_seq)
        function new(string n = "risk_corner_seq"); super.new(n); endfunction

        task send(bit sd, bit [PW-1:0] pr, bit [QW-1:0] qt);
            risk_item c = risk_item::type_id::create("c");
            start_item(c);
            c.side = sd; c.price = pr; c.qty = qt;
            finish_item(c);
        endtask

        task body();
            send(1'b0, 16'd100, 16'd1000);  // qty exactly == max_qty -> accept
            send(1'b1, 16'd200, 16'd1000);  // price exactly == max_price, sell
            send(1'b0, 16'd100, 16'd500);   // pos exactly == +pos_limit -> accept
            send(1'b1, 16'd150, 16'd1000);  // sell toward -pos_limit
            send(1'b1, 16'd150, 16'd100);   // drive to exactly -pos_limit -> accept
            send(1'b0, 16'd100, 16'd1);     // tiny buy back toward flat
        endtask
    endclass

    // Constrained-random regression: random side / price / qty, with a fraction
    // squeezed toward the limits so rejects fire often, and occasional zero qty.
    class risk_random_seq extends uvm_sequence #(risk_item);
        `uvm_object_utils(risk_random_seq)
        rand int unsigned n_vecs;
        constraint c_n { n_vecs inside {[80:200]}; }
        function new(string n = "risk_random_seq"); super.new(n); endfunction

        task body();
            for (int t = 0; t < n_vecs; t++) begin
                risk_item c = risk_item::type_id::create("c");
                start_item(c);
                if (t % 7 == 0) begin
                    // zero qty occasionally -> QTY_ZERO
                    if (!c.randomize() with { qty == 0; })
                        `uvm_error("RND", "randomize failed")
                end else if (t % 3 == 0) begin
                    // squeeze price/qty near the limits to force frequent rejects
                    if (!c.randomize() with {
                        price inside {[16'd50 : 16'd250]};
                        qty   inside {[16'd1  : 16'd1500]};
                    }) `uvm_error("RND", "randomize failed")
                end else begin
                    if (!c.randomize() with {
                        price inside {[16'd90 : 16'd210]};
                        qty   inside {[16'd1  : 16'd800]};
                    }) `uvm_error("RND", "randomize failed")
                end
                finish_item(c);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class risk_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(risk_smoke_vseq)
        risk_vseqr vseqr;
        function new(string n = "risk_smoke_vseq"); super.new(n); endfunction
        task body();
            risk_showcase_seq sh  = risk_showcase_seq::type_id::create("sh");
            risk_random_seq   rnd = risk_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 80; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class risk_regress_vseq extends uvm_sequence;
        `uvm_object_utils(risk_regress_vseq)
        risk_vseqr vseqr;
        function new(string n = "risk_regress_vseq"); super.new(n); endfunction
        task body();
            risk_showcase_seq sh  = risk_showcase_seq::type_id::create("sh");
            risk_corner_seq   cor = risk_corner_seq  ::type_id::create("cor");
            risk_random_seq   rnd = risk_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 200; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests - each programs its own risk-limit profile (so the two tests give
    // config-value coverage without mid-stream reconfiguration).
    // =========================================================================
    class risk_base_test extends uvm_test;
        `uvm_component_utils(risk_base_test)
        risk_env env;
        risk_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        // overridden per test to set the limit profile
        virtual function void set_limits(risk_cfg c); endfunction

        function void build_phase(uvm_phase phase);
            cfg = risk_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual risk_gate_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            set_limits(cfg);
            uvm_config_db#(risk_cfg)::set(this, "*", "cfg", cfg);
            env = risk_env::type_id::create("env", this);
        endfunction
    endclass

    class risk_smoke_test extends risk_base_test;
        `uvm_component_utils(risk_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_limits(risk_cfg c);
            c.max_qty = 1000; c.min_price = 100; c.max_price = 200;
            c.max_notional = 100000; c.pos_limit = 500;   // showcase-matched
        endfunction
        task run_phase(uvm_phase phase);
            risk_smoke_vseq v = risk_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class risk_regress_test extends risk_base_test;
        `uvm_component_utils(risk_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void set_limits(risk_cfg c);
            c.max_qty = 1000; c.min_price = 100; c.max_price = 200;
            c.max_notional = 100000; c.pos_limit = 500;   // showcase-matched
        endfunction
        task run_phase(uvm_phase phase);
            risk_regress_vseq v = risk_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
