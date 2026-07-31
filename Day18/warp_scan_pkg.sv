// -----------------------------------------------------------------------------
// warp_scan_pkg.sv - UVM verification environment for the GPU warp-level
// parallel prefix-sum (scan) engine (warp_scan.sv). Requires a UVM-capable
// simulator (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run the
// portable companion TB tb_warp_scan_dump.sv instead (see the Makefile).
//
// Contents:
//   * scan_item     - one input vector (N lanes) + scan mode (incl/excl)
//   * scan_obs_item - observed input vector paired with the scanned vector the
//                     pipeline produced (paired by the monitor via a FIFO, so it
//                     is robust to the exact pipeline latency)
//   * scan_cfg      - virtual interface + knobs
//   * scan_model    - golden reference scan (independent re-model, modular
//                     DW-bit prefix sum); reused by scoreboard and coverage
//   * scan_driver   - presents one input vector per cycle (zero-bubble capable)
//   * scan_monitor  - reassembles {input vector, its scanned output}
//   * scan_agent
//   * scan_scoreboard - re-scans the input and checks the DUT lane-by-lane
//   * scan_coverage - mode x total-sign x zero-content x wrap cross
//   * sequences      - showcase / corners / random
//   * scan_vseqr     - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests          - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package warp_scan_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int N  = 8;
    localparam int DW = 16;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class scan_item extends uvm_sequence_item;
        rand bit [DW-1:0] lanes [N];
        rand bit          excl;             // 0 = inclusive, 1 = exclusive

        `uvm_object_utils_begin(scan_item)
            `uvm_field_sarray_int(lanes, UVM_ALL_ON)
            `uvm_field_int(excl, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "scan_item"); super.new(name); endfunction

        function string convert2string();
            string s = $sformatf("excl=%0d lanes=[", excl);
            foreach (lanes[i]) s = {s, $sformatf("%0d:0x%04h ", i, lanes[i])};
            return {s, "]"};
        endfunction
    endclass

    // Observed input vector paired with the scanned output vector it produced.
    class scan_obs_item extends uvm_sequence_item;
        bit [DW-1:0] in_lanes  [N];
        bit          in_excl;
        bit [DW-1:0] out_lanes [N];
        bit          out_excl;

        `uvm_object_utils(scan_obs_item)
        function new(string name = "scan_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("excl=%0d in[0]=0x%04h out[0]=0x%04h out[%0d]=0x%04h",
                             in_excl, in_lanes[0], out_lanes[0], N-1, out_lanes[N-1]);
        endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class scan_cfg extends uvm_object;
        virtual warp_scan_if vif;
        `uvm_object_utils(scan_cfg)
        function new(string name = "scan_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference scan - independent re-implementation of a modular DW-bit
    // prefix sum, inclusive or exclusive. Used by scoreboard + coverage.
    // =========================================================================
    class scan_model;
        // Modular DW-bit inclusive/exclusive prefix sum.
        function void scan(input  bit [DW-1:0] in_lanes  [N],
                           input  bit          excl,
                           output bit [DW-1:0] out_lanes [N]);
            bit [DW-1:0] acc = '0;
            for (int i = 0; i < N; i++) begin
                if (excl) begin
                    out_lanes[i] = acc;                 // running sum BEFORE lane i
                    acc          = acc + in_lanes[i];   // modular DW-bit add
                end else begin
                    acc          = acc + in_lanes[i];
                    out_lanes[i] = acc;                 // running sum INCLUDING lane i
                end
            end
        endfunction

        // Sign of the full-vector total, interpreted as two's complement:
        // 0 = negative, 1 = zero, 2 = positive.
        function int total_sign(input bit [DW-1:0] in_lanes [N]);
            bit [DW-1:0] acc = '0;
            foreach (in_lanes[i]) acc = acc + in_lanes[i];
            if (acc == '0)         return 1;
            if (acc[DW-1] == 1'b1) return 0;
            return 2;
        endfunction

        // Zero-content class of the input: 0 = no zero lanes, 1 = some zero
        // lanes, 2 = all lanes zero.
        function int zero_content(input bit [DW-1:0] in_lanes [N]);
            int z = 0;
            foreach (in_lanes[i]) if (in_lanes[i] == '0) z++;
            if (z == 0) return 0;
            if (z == N) return 2;
            return 1;
        endfunction

        // Did the (signed) running sum overflow the DW-bit lane width at any
        // prefix? Compares a wide reference accumulator against the modular
        // DW-bit result; 1 = a wrap occurred, 0 = no wrap.
        function bit wrapped(input bit [DW-1:0] in_lanes [N]);
            longint acc = 0;
            bit [DW-1:0] macc = '0;
            for (int i = 0; i < N; i++) begin
                // sign-extend the DW-bit lane, add to the exact wide accumulator
                longint lane = $signed(in_lanes[i]);
                acc  = acc + lane;
                macc = macc + in_lanes[i];
                // exact prefix, sign-extended down to DW bits, must equal modular
                if ($signed(macc) !== acc) return 1'b1;
            end
            return 1'b0;
        endfunction
    endclass

    // =========================================================================
    // Driver - presents one input vector per handshake cycle
    // =========================================================================
    class scan_driver extends uvm_driver #(scan_item);
        `uvm_component_utils(scan_driver)
        scan_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(scan_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "scan_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_excl  <= 1'b0;
            cfg.vif.in_data  <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                scan_item req;
                bit [N*DW-1:0] packed_in;
                seq_item_port.get_next_item(req);
                packed_in = '0;
                foreach (req.lanes[i]) packed_in[i*DW +: DW] = req.lanes[i];
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_excl  <= req.excl;
                cfg.vif.drv_cb.in_data  <= packed_in;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each accepted input vector with the scanned vector that
    // later emerges (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class scan_monitor extends uvm_monitor;
        `uvm_component_utils(scan_monitor)
        scan_cfg cfg;
        uvm_analysis_port #(scan_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(scan_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "scan_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit [N*DW-1:0] in_q  [$];
            bit            ine_q [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    in_q.push_back(cfg.vif.mon_cb.in_data);
                    ine_q.push_back(cfg.vif.mon_cb.in_excl);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    scan_obs_item o = scan_obs_item::type_id::create("obs");
                    bit [N*DW-1:0] iv;
                    if (in_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input vector")
                    end else begin
                        iv        = in_q.pop_front();
                        o.in_excl = ine_q.pop_front();
                        for (int i = 0; i < N; i++)
                            o.in_lanes[i] = iv[i*DW +: DW];
                        o.out_excl = cfg.vif.mon_cb.out_excl;
                        for (int i = 0; i < N; i++)
                            o.out_lanes[i] = cfg.vif.mon_cb.out_data[i*DW +: DW];
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(scan_item) scan_sqr;

    class scan_agent extends uvm_agent;
        `uvm_component_utils(scan_agent)
        scan_driver  drv;
        scan_sqr     sqr;
        scan_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = scan_driver ::type_id::create("drv", this);
            sqr = scan_sqr    ::type_id::create("sqr", this);
            mon = scan_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-scan the input and check the DUT vector lane-by-lane.
    // =========================================================================
    class scan_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(scan_scoreboard)
        uvm_analysis_imp #(scan_obs_item, scan_scoreboard) imp;
        scan_model model;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void write(scan_obs_item o);
            bit [DW-1:0] exp [N];
            bit          ok = 1;

            model.scan(o.in_lanes, o.in_excl, exp);

            if (o.out_excl !== o.in_excl) begin
                ok = 0;
                `uvm_error("SB", $sformatf("MODE MISMATCH got %0d exp %0d",
                           o.out_excl, o.in_excl))
            end
            foreach (exp[k]) begin
                if (o.out_lanes[k] !== exp[k]) begin
                    ok = 0;
                    `uvm_error("SB", $sformatf(
                        "LANE MISMATCH lane %0d | got 0x%04h exp 0x%04h (%s)",
                        k, o.out_lanes[k], exp[k], o.convert2string()))
                end
            end

            if (ok) begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end else errors++;
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d vectors checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - mode x total-sign x zero-content x wrap
    // =========================================================================
    class scan_coverage extends uvm_subscriber #(scan_obs_item);
        `uvm_component_utils(scan_coverage)
        scan_model cov_model;

        bit c_excl;
        int c_sign;   // 0 neg, 1 zero, 2 pos
        int c_zero;   // 0 none, 1 some, 2 all
        bit c_wrap;

        covergroup cg;
            option.per_instance = 1;
            cp_excl: coverpoint c_excl { bins incl = {0}; bins excl = {1}; }
            cp_sign: coverpoint c_sign {
                bins negative = {0};
                bins zero     = {1};
                bins positive = {2};
            }
            cp_zero: coverpoint c_zero {
                bins none = {0};
                bins some = {1};
                bins all  = {2};
            }
            cp_wrap: coverpoint c_wrap { bins no = {0}; bins yes = {1}; }
            x_excl_sign: cross cp_excl, cp_sign;
            x_excl_wrap: cross cp_excl, cp_wrap;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cov_model = new(); cg = new();
        endfunction

        function void write(scan_obs_item o);
            c_excl = o.in_excl;
            c_sign = cov_model.total_sign(o.in_lanes);
            c_zero = cov_model.zero_content(o.in_lanes);
            c_wrap = cov_model.wrapped(o.in_lanes);
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class scan_vseqr extends uvm_sequencer;
        `uvm_component_utils(scan_vseqr)
        scan_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class scan_env extends uvm_env;
        `uvm_component_utils(scan_env)
        scan_agent      agent;
        scan_scoreboard sb;
        scan_coverage   cov;
        scan_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = scan_agent     ::type_id::create("agent", this);
            sb    = scan_scoreboard::type_id::create("sb",    this);
            cov   = scan_coverage  ::type_id::create("cov",   this);
            vseqr = scan_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase: inclusive scan of the ramp 1..N (triangular numbers),
    // the same ramp as an exclusive scan, and an inclusive scan of all-ones.
    class scan_showcase_seq extends uvm_sequence #(scan_item);
        `uvm_object_utils(scan_showcase_seq)
        function new(string n = "scan_showcase_seq"); super.new(n); endfunction

        task send(bit [DW-1:0] r [N], bit e);
            scan_item c = scan_item::type_id::create("c");
            start_item(c);
            foreach (r[i]) c.lanes[i] = r[i];
            c.excl = e;
            finish_item(c);
        endtask

        task body();
            bit [DW-1:0] r [N];
            // ramp 1..N -> inclusive triangular numbers 1,3,6,10,...
            for (int i = 0; i < N; i++) r[i] = DW'(i + 1);
            send(r, 1'b0);
            // same ramp, exclusive scan -> 0,1,3,6,...
            for (int i = 0; i < N; i++) r[i] = DW'(i + 1);
            send(r, 1'b1);
            // all-ones, inclusive -> 1,2,3,...,N (a plain index/rank)
            for (int i = 0; i < N; i++) r[i] = DW'(1);
            send(r, 1'b0);
        endtask
    endclass

    // Directed corners: all-zero, a single one, alternating +/- ones (cancels),
    // and a wrap-inducing set of large positive lanes.
    class scan_corner_seq extends uvm_sequence #(scan_item);
        `uvm_object_utils(scan_corner_seq)
        function new(string n = "scan_corner_seq"); super.new(n); endfunction

        task send(bit [DW-1:0] r [N], bit e);
            scan_item c = scan_item::type_id::create("c");
            start_item(c);
            foreach (r[i]) c.lanes[i] = r[i];
            c.excl = e;
            finish_item(c);
        endtask

        task body();
            bit [DW-1:0] r [N];
            // all zero (inclusive) -> all zero
            for (int i = 0; i < N; i++) r[i] = '0;
            send(r, 1'b0);
            // single one in the middle, exclusive
            for (int i = 0; i < N; i++) r[i] = '0;
            r[N/2] = DW'(1);
            send(r, 1'b1);
            // alternating +1 / -1 (running sum toggles 1,0,1,0,...)
            for (int i = 0; i < N; i++) r[i] = (i % 2 == 0) ? DW'(1)
                                                            : {DW{1'b1}}; // -1
            send(r, 1'b0);
            // large positive lanes -> modular DW-bit wraparound, inclusive
            for (int i = 0; i < N; i++) r[i] = 16'h4000;   // 4 lanes overflow 16b
            send(r, 1'b0);
            // large negative lanes -> negative running sum, exclusive
            for (int i = 0; i < N; i++) r[i] = 16'hC000;   // -16384 each
            send(r, 1'b1);
        endtask
    endclass

    // Constrained-random regression: random lanes + random mode, with a fraction
    // forced to small signed magnitudes to exercise sign toggling without wrap.
    class scan_random_seq extends uvm_sequence #(scan_item);
        `uvm_object_utils(scan_random_seq)
        rand int unsigned n_vecs;
        constraint c_n { n_vecs inside {[60:150]}; }
        function new(string n = "scan_random_seq"); super.new(n); endfunction

        task body();
            for (int t = 0; t < n_vecs; t++) begin
                scan_item c = scan_item::type_id::create("c");
                start_item(c);
                if (t % 4 == 0) begin
                    // small signed values in [-8,8]: many sign flips, rare wrap
                    if (!c.randomize() with {
                        foreach (lanes[i])
                            (lanes[i] <= 16'd8) || (lanes[i] >= 16'hFFF8);
                    }) `uvm_error("RND", "randomize failed")
                end else begin
                    if (!c.randomize()) `uvm_error("RND", "randomize failed")
                end
                finish_item(c);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class scan_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(scan_smoke_vseq)
        scan_vseqr vseqr;
        function new(string n = "scan_smoke_vseq"); super.new(n); endfunction
        task body();
            scan_showcase_seq sh  = scan_showcase_seq::type_id::create("sh");
            scan_random_seq   rnd = scan_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 60; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class scan_regress_vseq extends uvm_sequence;
        `uvm_object_utils(scan_regress_vseq)
        scan_vseqr vseqr;
        function new(string n = "scan_regress_vseq"); super.new(n); endfunction
        task body();
            scan_showcase_seq sh  = scan_showcase_seq::type_id::create("sh");
            scan_corner_seq   cor = scan_corner_seq  ::type_id::create("cor");
            scan_random_seq   rnd = scan_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 150; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class scan_base_test extends uvm_test;
        `uvm_component_utils(scan_base_test)
        scan_env env;
        scan_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = scan_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual warp_scan_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(scan_cfg)::set(this, "*", "cfg", cfg);
            env = scan_env::type_id::create("env", this);
        endfunction
    endclass

    class scan_smoke_test extends scan_base_test;
        `uvm_component_utils(scan_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            scan_smoke_vseq v = scan_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class scan_regress_test extends scan_base_test;
        `uvm_component_utils(scan_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            scan_regress_vseq v = scan_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
