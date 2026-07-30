// -----------------------------------------------------------------------------
// coalescer_pkg.sv - UVM verification environment for the GPU memory-coalescing
// unit (coalescer.sv). Requires a UVM-capable simulator (VCS / Questa /
// Verilator >= 5 with --uvm). Icarus users run the portable companion TB
// tb_coalescer_dump.sv instead (see the Makefile).
//
// Contents:
//   * coal_req_item     - warp request: per-lane byte address + active mask
//   * coal_txn_item     - one observed coalesced line transaction
//   * coal_sink_item    - one back-pressure directive for the line-stream sink
//   * coal_cfg          - virtual interface + knobs
//   * coal_ref          - golden coalescing reference model (static function)
//   * coal_src_driver / coal_sink_driver
//   * coal_req_monitor  - publishes accepted warp requests
//   * coal_txn_monitor  - publishes accepted line transactions
//   * coal_agent (source) + coal_sink_agent
//   * coal_scoreboard   - expands each request via the golden model and matches
//                         the observed line stream in order (line/mask/last)
//   * coal_coverage     - active-lane count x #lines x efficiency
//   * sequences         - showcase / corners / random  (+ sink no-bp / bp)
//   * coal_vseqr        - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests             - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package coalescer_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int NLANES = 8;
    localparam int ADDR_W = 32;
    localparam int OFF_W  = 7;
    localparam int LINE_W = ADDR_W - OFF_W;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class coal_req_item extends uvm_sequence_item;
        rand bit [ADDR_W-1:0] addr [NLANES];   // per-lane byte address
        rand bit [NLANES-1:0] en;              // active mask
        // Address window (lower half constrains how much coalescing happens).
        rand bit [ADDR_W-1:0] base;
        rand int unsigned     span_lines;      // #lines the window spans

        `uvm_object_utils_begin(coal_req_item)
            `uvm_field_int(en,   UVM_ALL_ON)
            `uvm_field_int(base, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "coal_req_item"); super.new(name); endfunction

        // Keep the window small so random warps produce a mix of coalesced and
        // scattered patterns (1..NLANES lines), the interesting DV regime.
        constraint c_span   { span_lines inside {[1:NLANES]}; }
        constraint c_base   { base[OFF_W-1:0] == '0;           // line-aligned base
                              base < (32'h1 << (OFF_W + 8)); }
        constraint c_addr   { foreach (addr[i])
                                  addr[i] inside {[base : base + (span_lines << OFF_W) - 1]}; }
        constraint c_en_sol { solve span_lines before addr; }

        function string convert2string();
            string s;
            s = $sformatf("REQ en=%b base=0x%0h span=%0d :", en, base, span_lines);
            foreach (addr[i]) s = {s, $sformatf(" a[%0d]=0x%0h", i, addr[i])};
            return s;
        endfunction
    endclass

    class coal_txn_item extends uvm_sequence_item;
        bit [LINE_W-1:0] line;
        bit [NLANES-1:0] mask;
        bit              last;

        `uvm_object_utils_begin(coal_txn_item)
            `uvm_field_int(line, UVM_ALL_ON)
            `uvm_field_int(mask, UVM_ALL_ON)
            `uvm_field_int(last, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "coal_txn_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("TXN line=0x%0h mask=%b last=%0b", line, mask, last);
        endfunction
    endclass

    // Back-pressure directive for the line-stream sink: hold txn_ready at `rdy`
    // for `len` cycles.
    class coal_sink_item extends uvm_sequence_item;
        rand bit          rdy;
        rand int unsigned len;
        `uvm_object_utils_begin(coal_sink_item)
            `uvm_field_int(rdy, UVM_ALL_ON)
            `uvm_field_int(len, UVM_ALL_ON)
        `uvm_object_utils_end
        constraint c_len { len inside {[1:4]}; }
        function new(string name = "coal_sink_item"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class coal_cfg extends uvm_object;
        virtual coalescer_if vif;
        bit                  sink_backpressure = 0;   // sink default behaviour
        `uvm_object_utils(coal_cfg)
        function new(string name = "coal_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference model - independent re-implementation of the coalescing
    // algorithm. Given a warp (addr[], en) it returns the exact ordered list of
    // expected transactions (line, mask, last).
    // =========================================================================
    class coal_ref;
        static function void expand(input bit [ADDR_W-1:0] addr [NLANES],
                                    input bit [NLANES-1:0]  en,
                                    ref   coal_txn_item     exp[$]);
            bit [NLANES-1:0] served;
            bit [NLANES-1:0] pending;
            bit [NLANES-1:0] mask;
            bit [LINE_W-1:0] sel;
            int              leader;
            exp.delete();
            served = '0;
            forever begin
                pending = en & ~served;
                if (pending == '0) break;
                // lowest pending lane is the leader; its line is the target
                leader = -1;
                for (int i = 0; i < NLANES; i++)
                    if (pending[i] && leader < 0) leader = i;
                sel  = addr[leader][ADDR_W-1:OFF_W];
                mask = '0;
                for (int k = 0; k < NLANES; k++)
                    if (pending[k] && (addr[k][ADDR_W-1:OFF_W] == sel)) mask[k] = 1'b1;
                served |= mask;
                begin
                    coal_txn_item t = coal_txn_item::type_id::create("exp");
                    t.line = sel;
                    t.mask = mask;
                    t.last = ((en & ~served) == '0);
                    exp.push_back(t);
                end
            end
        endfunction
    endclass

    // =========================================================================
    // Source driver - drives warp requests
    // =========================================================================
    class coal_src_driver extends uvm_driver #(coal_req_item);
        `uvm_component_utils(coal_src_driver)
        coal_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(coal_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "coal_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.req_valid <= 1'b0;
            cfg.vif.lane_addr <= '0;
            cfg.vif.lane_en   <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                coal_req_item req;
                seq_item_port.get_next_item(req);
                @(cfg.vif.src_cb);
                for (int i = 0; i < NLANES; i++)
                    cfg.vif.src_cb.lane_addr[i*ADDR_W +: ADDR_W] <= req.addr[i];
                cfg.vif.src_cb.lane_en   <= req.en;
                cfg.vif.src_cb.req_valid <= 1'b1;
                // hold until accepted
                do @(cfg.vif.src_cb); while (cfg.vif.src_cb.req_ready !== 1'b1);
                cfg.vif.src_cb.req_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Sink driver - drives txn_ready back-pressure from directives
    // =========================================================================
    class coal_sink_driver extends uvm_driver #(coal_sink_item);
        `uvm_component_utils(coal_sink_driver)
        coal_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(coal_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "coal_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.txn_ready <= 1'b1;   // default: accept
            @(posedge cfg.vif.rst_n);
            forever begin
                coal_sink_item it;
                seq_item_port.get_next_item(it);
                for (int c = 0; c < it.len; c++) begin
                    @(cfg.vif.sink_cb);
                    cfg.vif.sink_cb.txn_ready <= it.rdy;
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Request monitor
    // =========================================================================
    class coal_req_monitor extends uvm_monitor;
        `uvm_component_utils(coal_req_monitor)
        coal_cfg cfg;
        uvm_analysis_port #(coal_req_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(coal_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "coal_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.req_valid && cfg.vif.mon_cb.req_ready) begin
                    coal_req_item t = coal_req_item::type_id::create("req_obs");
                    for (int i = 0; i < NLANES; i++)
                        t.addr[i] = cfg.vif.mon_cb.lane_addr[i*ADDR_W +: ADDR_W];
                    t.en = cfg.vif.mon_cb.lane_en;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Transaction monitor
    // =========================================================================
    class coal_txn_monitor extends uvm_monitor;
        `uvm_component_utils(coal_txn_monitor)
        coal_cfg cfg;
        uvm_analysis_port #(coal_txn_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(coal_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "coal_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.txn_valid && cfg.vif.mon_cb.txn_ready) begin
                    coal_txn_item t = coal_txn_item::type_id::create("txn_obs");
                    t.line = cfg.vif.mon_cb.txn_line;
                    t.mask = cfg.vif.mon_cb.txn_mask;
                    t.last = cfg.vif.mon_cb.txn_last;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Sequencers / agents
    // =========================================================================
    typedef uvm_sequencer #(coal_req_item)  coal_req_sqr;
    typedef uvm_sequencer #(coal_sink_item) coal_sink_sqr;

    class coal_agent extends uvm_agent;
        `uvm_component_utils(coal_agent)
        coal_src_driver   drv;
        coal_req_sqr      sqr;
        coal_req_monitor  mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = coal_src_driver ::type_id::create("drv", this);
            sqr = coal_req_sqr    ::type_id::create("sqr", this);
            mon = coal_req_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class coal_sink_agent extends uvm_agent;
        `uvm_component_utils(coal_sink_agent)
        coal_sink_driver  drv;
        coal_sink_sqr     sqr;
        coal_txn_monitor  mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = coal_sink_driver::type_id::create("drv", this);
            sqr = coal_sink_sqr   ::type_id::create("sqr", this);
            mon = coal_txn_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - golden coalescing model vs observed line stream
    // =========================================================================
    `uvm_analysis_imp_decl(_req)
    `uvm_analysis_imp_decl(_txn)

    class coal_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(coal_scoreboard)
        uvm_analysis_imp_req #(coal_req_item, coal_scoreboard) req_imp;
        uvm_analysis_imp_txn #(coal_txn_item, coal_scoreboard) txn_imp;

        coal_txn_item exp_q [$];   // expected transactions, FIFO order
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            req_imp = new("req_imp", this);
            txn_imp = new("txn_imp", this);
        endfunction

        // A new warp -> expand the golden model and append its transactions.
        function void write_req(coal_req_item r);
            coal_txn_item exp[$];
            coal_ref::expand(r.addr, r.en, exp);
            foreach (exp[i]) exp_q.push_back(exp[i]);
            `uvm_info("SB", $sformatf("%s  -> %0d expected line(s)",
                      r.convert2string(), exp.size()), UVM_HIGH)
        endfunction

        // An observed line -> compare against the head of the expected FIFO.
        function void write_txn(coal_txn_item o);
            coal_txn_item e;
            if (exp_q.size() == 0) begin
                errors++;
                `uvm_error("SB", $sformatf("UNEXPECTED %s", o.convert2string()))
                return;
            end
            e = exp_q.pop_front();
            if (o.line !== e.line || o.mask !== e.mask || o.last !== e.last) begin
                errors++;
                `uvm_error("SB", $sformatf("MISMATCH  got %s  exp %s",
                           o.convert2string(), e.convert2string()))
            end else begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (exp_q.size() != 0) begin
                errors++;
                `uvm_error("SB", $sformatf("%0d expected transaction(s) never seen",
                           exp_q.size()))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d line txns checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage
    // =========================================================================
    class coal_coverage extends uvm_subscriber #(coal_req_item);
        `uvm_component_utils(coal_coverage)

        int active_lanes;   // popcount(en)
        int num_lines;      // #transactions this warp produces
        int efficiency_pct; // 100*active_lanes/num_lines bucketed

        covergroup cg;
            option.per_instance = 1;
            cp_active: coverpoint active_lanes {
                bins none   = {0};
                bins low    = {[1:2]};
                bins mid    = {[3:5]};
                bins full   = {[6:NLANES]};
            }
            cp_lines: coverpoint num_lines {
                bins one     = {1};
                bins few     = {[2:3]};
                bins many    = {[4:6]};
                bins scatter = {[7:NLANES]};
            }
            cp_eff: coverpoint efficiency_pct {
                bins worst  = {[0:25]};    // fully / near scattered
                bins mid    = {[26:75]};
                bins best   = {[76:100]};  // fully coalesced
            }
            x_lanes_lines: cross cp_active, cp_lines;
        endgroup

        function new(string n, uvm_component p); super.new(n, p); cg = new(); endfunction

        function void write(coal_req_item r);
            coal_txn_item exp[$];
            active_lanes = $countones(r.en);
            coal_ref::expand(r.addr, r.en, exp);
            num_lines = exp.size();
            efficiency_pct = (num_lines == 0) ? 0 : (100 * active_lanes) / num_lines;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class coal_vseqr extends uvm_sequencer;
        `uvm_component_utils(coal_vseqr)
        coal_req_sqr  req_sqr;
        coal_sink_sqr sink_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class coal_env extends uvm_env;
        `uvm_component_utils(coal_env)
        coal_agent       agent;
        coal_sink_agent  sink;
        coal_scoreboard  sb;
        coal_coverage    cov;
        coal_vseqr       vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = coal_agent     ::type_id::create("agent", this);
            sink  = coal_sink_agent::type_id::create("sink",  this);
            sb    = coal_scoreboard::type_id::create("sb",    this);
            cov   = coal_coverage  ::type_id::create("cov",   this);
            vseqr = coal_vseqr     ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(sb.req_imp);
            agent.mon.ap.connect(cov.analysis_export);
            sink.mon.ap.connect(sb.txn_imp);
            vseqr.req_sqr  = agent.sqr;
            vseqr.sink_sqr = sink.sqr;
        endfunction
    endclass

    // =========================================================================
    // Request sequences
    // =========================================================================
    // Directed 2-line showcase: 8 lanes coalesce into 2 cache lines.
    class coal_showcase_seq extends uvm_sequence #(coal_req_item);
        `uvm_object_utils(coal_showcase_seq)
        function new(string n = "coal_showcase_seq"); super.new(n); endfunction
        task body();
            coal_req_item r = coal_req_item::type_id::create("show");
            start_item(r);
            r.en      = 8'hFF;
            r.addr[0] = 32'h0000_1000;  // line 0x20
            r.addr[1] = 32'h0000_1004;  // line 0x20
            r.addr[2] = 32'h0000_1040;  // line 0x20
            r.addr[3] = 32'h0000_2000;  // line 0x40
            r.addr[4] = 32'h0000_2010;  // line 0x40
            r.addr[5] = 32'h0000_1078;  // line 0x20
            r.addr[6] = 32'h0000_2044;  // line 0x40
            r.addr[7] = 32'h0000_1008;  // line 0x20
            finish_item(r);
        endtask
    endclass

    // Directed corner cases.
    class coal_corner_seq extends uvm_sequence #(coal_req_item);
        `uvm_object_utils(coal_corner_seq)
        function new(string n = "coal_corner_seq"); super.new(n); endfunction

        task drive(bit [NLANES-1:0] en, bit [ADDR_W-1:0] a[NLANES]);
            coal_req_item r = coal_req_item::type_id::create("corner");
            start_item(r);
            r.en = en;
            foreach (a[i]) r.addr[i] = a[i];
            finish_item(r);
        endtask

        task body();
            bit [ADDR_W-1:0] a [NLANES];
            // 1) all lanes same address -> fully coalesced (1 line, mask=FF)
            foreach (a[i]) a[i] = 32'h4000;
            drive(8'hFF, a);
            // 2) stride-per-line -> fully uncoalesced (8 distinct lines)
            foreach (a[i]) a[i] = 32'h8000 + (i << OFF_W);
            drive(8'hFF, a);
            // 3) partial mask (only lanes 0..3 active), two lines
            foreach (a[i]) a[i] = 32'hC000 + ((i & 1) << OFF_W);
            drive(8'h0F, a);
            // 4) all-disabled warp -> zero transactions
            foreach (a[i]) a[i] = 32'hE000;
            drive(8'h00, a);
            // 5) single lane active -> one one-hot transaction
            foreach (a[i]) a[i] = 32'hF000;
            drive(8'h20, a);
        endtask
    endclass

    // Constrained-random regression.
    class coal_random_seq extends uvm_sequence #(coal_req_item);
        `uvm_object_utils(coal_random_seq)
        rand int unsigned n_warps;
        constraint c_n { n_warps inside {[40:80]}; }
        function new(string n = "coal_random_seq"); super.new(n); endfunction
        task body();
            repeat (n_warps) begin
                coal_req_item r = coal_req_item::type_id::create("rand");
                start_item(r);
                if (!r.randomize())
                    `uvm_error("RND", "randomize failed")
                finish_item(r);
            end
        endtask
    endclass

    // =========================================================================
    // Sink sequences (back-pressure)
    // =========================================================================
    class coal_sink_nobp_seq extends uvm_sequence #(coal_sink_item);
        `uvm_object_utils(coal_sink_nobp_seq)
        function new(string n = "coal_sink_nobp_seq"); super.new(n); endfunction
        task body();
            forever begin
                coal_sink_item it = coal_sink_item::type_id::create("nobp");
                start_item(it);
                it.rdy = 1'b1; it.len = 8;
                finish_item(it);
            end
        endtask
    endclass

    class coal_sink_bp_seq extends uvm_sequence #(coal_sink_item);
        `uvm_object_utils(coal_sink_bp_seq)
        function new(string n = "coal_sink_bp_seq"); super.new(n); endfunction
        task body();
            forever begin
                coal_sink_item it = coal_sink_item::type_id::create("bp");
                start_item(it);
                if (!it.randomize())
                    `uvm_error("RND", "sink randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class coal_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(coal_smoke_vseq)
        coal_vseqr vseqr;
        function new(string n = "coal_smoke_vseq"); super.new(n); endfunction
        task body();
            coal_showcase_seq  sh   = coal_showcase_seq ::type_id::create("sh");
            coal_random_seq    rnd  = coal_random_seq   ::type_id::create("rnd");
            coal_sink_nobp_seq sink = coal_sink_nobp_seq::type_id::create("sink");
            fork sink.start(vseqr.sink_sqr); join_none
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_warps == 40; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class coal_regress_vseq extends uvm_sequence;
        `uvm_object_utils(coal_regress_vseq)
        coal_vseqr vseqr;
        function new(string n = "coal_regress_vseq"); super.new(n); endfunction
        task body();
            coal_showcase_seq sh  = coal_showcase_seq::type_id::create("sh");
            coal_corner_seq   cor = coal_corner_seq  ::type_id::create("cor");
            coal_random_seq   rnd = coal_random_seq  ::type_id::create("rnd");
            coal_sink_bp_seq  sink= coal_sink_bp_seq ::type_id::create("sink");
            fork sink.start(vseqr.sink_sqr); join_none
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_warps == 80; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class coal_base_test extends uvm_test;
        `uvm_component_utils(coal_base_test)
        coal_env env;
        coal_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = coal_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual coalescer_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(coal_cfg)::set(this, "*", "cfg", cfg);
            env = coal_env::type_id::create("env", this);
        endfunction
    endclass

    class coal_smoke_test extends coal_base_test;
        `uvm_component_utils(coal_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            coal_smoke_vseq v = coal_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class coal_regress_test extends coal_base_test;
        `uvm_component_utils(coal_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            coal_regress_vseq v = coal_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
