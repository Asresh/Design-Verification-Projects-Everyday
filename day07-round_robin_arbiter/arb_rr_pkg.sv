// -----------------------------------------------------------------------------
// arb_rr_pkg.sv  -  UVM verification environment for the round-robin arbiter
//
// Full UVM component set:
//   * arb_txn            - sequence item (stimulus req/en + observed grant)
//   * arb_sequencer      - uvm_sequencer#(arb_txn)
//   * arb_driver         - drives {req,en}, back-annotates the observed grant
//   * arb_monitor        - passive, publishes every sampled cycle
//   * arb_coverage       - functional coverage subscriber
//   * arb_agent          - sequencer + driver + monitor + coverage
//   * arb_scoreboard     - INDEPENDENT golden round-robin reference model
//   * arb_vsequencer     - virtual sequencer owning the agent sequencer
//   * sequences          - all-request, random, stall, one-hot walk
//   * virtual sequences  - smoke, regress
//   * arb_env            - agent + scoreboard + coverage + vsequencer
//   * tests              - base / smoke / regress
//
// Requires a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm).
// Icarus users run tb_arb_rr_dump.sv instead (see the Makefile).
// -----------------------------------------------------------------------------
`ifndef ARB_RR_PKG_SV
`define ARB_RR_PKG_SV

package arb_rr_pkg;
    import uvm_pkg::*;
`include "uvm_macros.svh"

    localparam int NUM_REQ = 4;
    localparam int PW      = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1;

    // =========================================================================
    // Sequence item
    // =========================================================================
    class arb_txn extends uvm_sequence_item;
        // ---- stimulus ----
        rand bit [NUM_REQ-1:0] req;
        rand bit               en;
        // ---- observed (filled by monitor / driver back-annotation) ----
        bit [NUM_REQ-1:0]      grant;
        bit                    grant_valid;
        bit [PW-1:0]           grant_idx;

        // Bias toward exercising the resource: mostly enabled, mix of densities.
        constraint c_en   { en dist { 1 := 7, 0 := 1 }; }
        constraint c_req  { req dist { 0 := 1, [1:(1<<NUM_REQ)-1] := 9 }; }

        `uvm_object_utils_begin(arb_txn)
            `uvm_field_int(req,         UVM_ALL_ON)
            `uvm_field_int(en,          UVM_ALL_ON)
            `uvm_field_int(grant,       UVM_ALL_ON)
            `uvm_field_int(grant_valid, UVM_ALL_ON)
            `uvm_field_int(grant_idx,   UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "arb_txn");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("req=%b en=%b -> grant=%b valid=%b idx=%0d",
                             req, en, grant, grant_valid, grant_idx);
        endfunction
    endclass

    // =========================================================================
    // Sequencer
    // =========================================================================
    typedef uvm_sequencer#(arb_txn) arb_sequencer;

    // =========================================================================
    // Driver : drive {req,en} through the req_drv clocking block, then sample
    //          the combinational grant that results and back-annotate the item.
    // =========================================================================
    class arb_driver extends uvm_driver#(arb_txn);
        `uvm_component_utils(arb_driver)
        virtual arb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "arb_driver: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            // idle until reset is released
            vif.req_drv_cb.req <= '0;
            vif.req_drv_cb.en  <= 1'b0;
            wait (vif.rst_n === 1'b1);
            forever begin
                arb_txn tr;
                seq_item_port.get_next_item(tr);
                @(vif.req_drv_cb);
                vif.req_drv_cb.req <= tr.req;
                vif.req_drv_cb.en  <= tr.en;
                @(vif.req_drv_cb);                 // let the grant settle
                tr.grant       = vif.req_drv_cb.grant;
                tr.grant_valid = vif.req_drv_cb.grant_valid;
                tr.grant_idx   = vif.req_drv_cb.grant_idx;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor : passively sample every cycle after reset and broadcast it.
    // =========================================================================
    class arb_monitor extends uvm_monitor;
        `uvm_component_utils(arb_monitor)
        virtual arb_if                 vif;
        uvm_analysis_port#(arb_txn)    ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "arb_monitor: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            wait (vif.rst_n === 1'b1);
            forever begin
                @(vif.mon_cb);
                begin
                    arb_txn tr = arb_txn::type_id::create("mon_tr");
                    tr.req         = vif.mon_cb.req;
                    tr.en          = vif.mon_cb.en;
                    tr.grant       = vif.mon_cb.grant;
                    tr.grant_valid = vif.mon_cb.grant_valid;
                    tr.grant_idx   = vif.mon_cb.grant_idx;
                    ap.write(tr);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Functional coverage subscriber
    // =========================================================================
    class arb_coverage extends uvm_subscriber#(arb_txn);
        `uvm_component_utils(arb_coverage)
        arb_txn tr;

        covergroup cg;
            option.per_instance = 1;
            // which requester won (only meaningful when a grant occurred)
            cp_winner : coverpoint tr.grant_idx iff (tr.grant_valid) {
                bins req_id[] = {[0:NUM_REQ-1]};
            }
            // was a grant issued at all
            cp_valid : coverpoint tr.grant_valid { bins yes = {1}; bins no = {0}; }
            // resource enable
            cp_en : coverpoint tr.en { bins on = {1}; bins off = {0}; }
            // request density: none / single / some / all contended
            cp_density : coverpoint $countones(tr.req) {
                bins none   = {0};
                bins one    = {1};
                bins some[] = {[2:NUM_REQ-1]};
                bins all    = {NUM_REQ};
            }
            // cross: every winner should be seen under real contention
            x_winner_density : cross cp_winner, cp_density;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void write(arb_txn t);
            tr = t;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class arb_agent extends uvm_agent;
        `uvm_component_utils(arb_agent)
        arb_sequencer sqr;
        arb_driver    drv;
        arb_monitor   mon;
        arb_coverage  cov;

        uvm_analysis_port#(arb_txn) ap;   // re-exported monitor stream

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = arb_monitor::type_id::create("mon", this);
            cov = arb_coverage::type_id::create("cov", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = arb_sequencer::type_id::create("sqr", this);
                drv = arb_driver::type_id::create("drv", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            mon.ap.connect(cov.analysis_export);
            mon.ap.connect(ap);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard : INDEPENDENT golden round-robin reference model.
    //   Keeps its own priority pointer `m_ptr`, recomputes the expected winner
    //   from scratch each cycle, and compares against the monitored grant.
    // =========================================================================
    `uvm_analysis_imp_decl(_mon)
    class arb_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(arb_scoreboard)
        uvm_analysis_imp_mon#(arb_txn, arb_scoreboard) imp;

        bit [PW-1:0] m_ptr;
        int unsigned checks, errors;
        int unsigned grants, stalls, idles;
        int unsigned served [NUM_REQ];

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            m_ptr = '0; checks = 0; errors = 0;
            grants = 0; stalls = 0; idles = 0;
            foreach (served[i]) served[i] = 0;
        endfunction

        // reference round-robin: first set bit of r at or after pointer p
        function automatic bit [NUM_REQ-1:0] ref_pick(bit [NUM_REQ-1:0] r,
                                                      bit [PW-1:0]      p);
            bit [NUM_REQ-1:0] g = '0;
            int j;
            for (int k = 0; k < NUM_REQ; k++) begin
                j = (int'(p) + k) % NUM_REQ;
                if (r[j] && g == '0) g[j] = 1'b1;
            end
            return g;
        endfunction

        function automatic bit [PW-1:0] ref_idx(bit [NUM_REQ-1:0] g);
            bit [PW-1:0] k = '0;
            for (int i = 0; i < NUM_REQ; i++) if (g[i]) k = PW'(i);
            return k;
        endfunction

        function void write_mon(arb_txn t);
            bit [NUM_REQ-1:0] exp_g;
            bit [PW-1:0]      exp_i;

            exp_g = (t.en && (|t.req)) ? ref_pick(t.req, m_ptr) : '0;
            exp_i = ref_idx(exp_g);
            checks++;

            if (t.grant !== exp_g) begin
                errors++;
                `uvm_error("SB_GRANT",
                    $sformatf("grant mismatch: %s | m_ptr=%0d exp=%b",
                              t.convert2string(), m_ptr, exp_g))
            end
            if (t.grant_valid !== (|t.grant)) begin
                errors++;
                `uvm_error("SB_VALID",
                    $sformatf("grant_valid inconsistent: %s", t.convert2string()))
            end
            if ((t.grant != '0) && (t.grant_idx !== exp_i)) begin
                errors++;
                `uvm_error("SB_IDX",
                    $sformatf("grant_idx wrong: got %0d exp %0d", t.grant_idx, exp_i))
            end
            if (!$onehot0(t.grant)) begin
                errors++;
                `uvm_error("SB_ONEHOT",
                    $sformatf("grant not one-hot0: %b", t.grant))
            end

            if (t.grant != '0) begin
                grants++;
                served[exp_i]++;
            end
            else if (!t.en) stalls++;
            else            idles++;

            // advance the model pointer with the DUT's rule
            if (t.en && (|t.req))
                m_ptr = (exp_i == PW'(NUM_REQ-1)) ? '0 : exp_i + PW'(1);
        end

        function void report_phase(uvm_phase phase);
            bit starved = 0;
            `uvm_info("SB", $sformatf(
                "checks=%0d grants=%0d stalls=%0d idles=%0d errors=%0d",
                checks, grants, stalls, idles, errors), UVM_LOW)
            foreach (served[i]) begin
                `uvm_info("SB", $sformatf("  requester[%0d] served %0d", i, served[i]),
                          UVM_LOW)
                if (served[i] == 0) starved = 1;
            end
            if (errors == 0 && checks > 0 && !starved)
                `uvm_info("SB", "RESULT: *** PASS ***", UVM_NONE)
            else
                `uvm_error("SB", $sformatf(
                    "RESULT: *** FAIL *** (errors=%0d checks=%0d starved=%0b)",
                    errors, checks, starved))
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer
    // =========================================================================
    class arb_vsequencer extends uvm_sequencer#(uvm_sequence_item);
        `uvm_component_utils(arb_vsequencer)
        arb_sequencer req_sqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    // =========================================================================
    // Leaf sequences (run on the arb_sequencer)
    // =========================================================================

    // All requesters assert simultaneously for N beats -> pure rotation.
    class arb_all_req_seq extends uvm_sequence#(arb_txn);
        `uvm_object_utils(arb_all_req_seq)
        int unsigned n = 8;
        function new(string name = "arb_all_req_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                arb_txn tr = arb_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with { req == '1; en == 1'b1; })
                    `uvm_error("RAND", "all_req randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // Constrained-random requests and enable.
    class arb_random_seq extends uvm_sequence#(arb_txn);
        `uvm_object_utils(arb_random_seq)
        int unsigned n = 60;
        function new(string name = "arb_random_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                arb_txn tr = arb_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize())
                    `uvm_error("RAND", "random randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // Hold full contention but chop the enable so the pointer must survive stalls.
    class arb_stall_seq extends uvm_sequence#(arb_txn);
        `uvm_object_utils(arb_stall_seq)
        int unsigned n = 12;
        function new(string name = "arb_stall_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < n; i++) begin
                arb_txn tr = arb_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with { req == '1; en == ((i % 3) != 0); })
                    `uvm_error("RAND", "stall randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // Walk a single request across every position (directed corner).
    class arb_onehot_seq extends uvm_sequence#(arb_txn);
        `uvm_object_utils(arb_onehot_seq)
        function new(string name = "arb_onehot_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < NUM_REQ; i++) begin
                arb_txn tr = arb_txn::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with { req == (1 << i); en == 1'b1; })
                    `uvm_error("RAND", "onehot randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class arb_smoke_vseq extends uvm_sequence#(uvm_sequence_item);
        `uvm_object_utils(arb_smoke_vseq)
        arb_vsequencer vsqr;
        function new(string name = "arb_smoke_vseq"); super.new(name); endfunction
        task body();
            arb_all_req_seq s0 = arb_all_req_seq::type_id::create("s0");
            arb_onehot_seq  s1 = arb_onehot_seq::type_id::create("s1");
            if (!$cast(vsqr, m_sequencer))
                `uvm_fatal("VSEQ", "smoke: sequencer is not an arb_vsequencer")
            s0.n = 8;
            s0.start(vsqr.req_sqr);
            s1.start(vsqr.req_sqr);
        endtask
    endclass

    class arb_regress_vseq extends uvm_sequence#(uvm_sequence_item);
        `uvm_object_utils(arb_regress_vseq)
        arb_vsequencer vsqr;
        function new(string name = "arb_regress_vseq"); super.new(name); endfunction
        task body();
            arb_all_req_seq a = arb_all_req_seq::type_id::create("a");
            arb_stall_seq   b = arb_stall_seq::type_id::create("b");
            arb_onehot_seq  c = arb_onehot_seq::type_id::create("c");
            arb_random_seq  d = arb_random_seq::type_id::create("d");
            if (!$cast(vsqr, m_sequencer))
                `uvm_fatal("VSEQ", "regress: sequencer is not an arb_vsequencer")
            a.n = 8;  a.start(vsqr.req_sqr);
            b.n = 12; b.start(vsqr.req_sqr);
            c.start(vsqr.req_sqr);
            d.n = 120;
            if (!d.randomize()) `uvm_warning("RAND", "regress random cfg failed")
            d.start(vsqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class arb_env extends uvm_env;
        `uvm_component_utils(arb_env)
        arb_agent        agent;
        arb_scoreboard   sb;
        arb_vsequencer   vsqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = arb_agent::type_id::create("agent", this);
            sb    = arb_scoreboard::type_id::create("sb", this);
            vsqr  = arb_vsequencer::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.ap.connect(sb.imp);
            vsqr.req_sqr = agent.sqr;
        endfunction
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class arb_base_test extends uvm_test;
        `uvm_component_utils(arb_base_test)
        arb_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = arb_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class arb_smoke_test extends arb_base_test;
        `uvm_component_utils(arb_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            arb_smoke_vseq vseq = arb_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.phase_done.set_drain_time(this, 50ns);
            phase.drop_objection(this);
        endtask
    endclass

    class arb_regress_test extends arb_base_test;
        `uvm_component_utils(arb_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            arb_regress_vseq vseq = arb_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.phase_done.set_drain_time(this, 50ns);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
`endif
