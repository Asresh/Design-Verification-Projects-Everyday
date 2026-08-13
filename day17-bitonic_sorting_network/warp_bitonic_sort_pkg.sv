// -----------------------------------------------------------------------------
// warp_bitonic_sort_pkg.sv - UVM verification environment for the GPU warp-level
// bitonic sorting network (warp_bitonic_sort.sv). Requires a UVM-capable
// simulator (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run the
// portable companion TB tb_warp_bitonic_sort_dump.sv instead (see the Makefile).
//
// Contents:
//   * bsort_item     - one input vector (N records) + sort direction
//   * bsort_obs_item - observed input vector paired with the sorted vector the
//                      pipeline produced (paired by the monitor via a FIFO, so
//                      it is robust to the exact pipeline latency)
//   * bsort_cfg      - virtual interface + knobs
//   * bsort_model    - golden reference sorter (independent re-model); reused by
//                      both the scoreboard and the coverage collector
//   * bsort_driver   - presents one input vector per cycle (zero-bubble capable)
//   * bsort_monitor  - reassembles {input vector, its sorted output}
//   * bsort_agent
//   * bsort_scoreboard - re-sorts the input and checks the DUT lane-by-lane
//                        (permutation + monotonicity implied)
//   * bsort_coverage - direction x orderedness x duplicate x extremes cross
//   * sequences      - showcase / corners / random
//   * bsort_vseqr    - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests          - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package warp_bitonic_sort_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int N     = 8;
    localparam int KEY_W = 6;
    localparam int TAG_W = 2;
    localparam int RW    = KEY_W + TAG_W;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class bsort_item extends uvm_sequence_item;
        rand bit [RW-1:0] recs [N];
        rand bit          dir;              // 0 = ascending, 1 = descending

        `uvm_object_utils_begin(bsort_item)
            `uvm_field_sarray_int(recs, UVM_ALL_ON)
            `uvm_field_int(dir, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "bsort_item"); super.new(name); endfunction

        function string convert2string();
            string s = $sformatf("dir=%0d recs=[", dir);
            foreach (recs[i]) s = {s, $sformatf("%0d:0x%02h ", i, recs[i])};
            return {s, "]"};
        endfunction
    endclass

    // Observed input vector paired with the sorted output vector it produced.
    class bsort_obs_item extends uvm_sequence_item;
        bit [RW-1:0] in_recs  [N];
        bit          in_dir;
        bit [RW-1:0] out_recs [N];
        bit          out_dir;

        `uvm_object_utils(bsort_obs_item)
        function new(string name = "bsort_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("dir=%0d in[0]=0x%02h out[0]=0x%02h out[%0d]=0x%02h",
                             in_dir, in_recs[0], out_recs[0], N-1, out_recs[N-1]);
        endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class bsort_cfg extends uvm_object;
        virtual warp_bitonic_sort_if vif;
        `uvm_object_utils(bsort_cfg)
        function new(string name = "bsort_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference sorter - independent re-implementation (insertion sort on
    // the full RW-bit records, direction-aware). Used by scoreboard + coverage.
    // =========================================================================
    class bsort_model;
        function void sort(input  bit [RW-1:0] in_recs  [N],
                           input  bit          dir,
                           output bit [RW-1:0] out_recs [N]);
            bit [RW-1:0] a [N];
            bit [RW-1:0] key;
            int          j;
            foreach (in_recs[i]) a[i] = in_recs[i];
            for (int i = 1; i < N; i++) begin
                key = a[i];
                j   = i - 1;
                while (j >= 0 && ((dir == 1'b0) ? (a[j] > key) : (a[j] < key))) begin
                    a[j+1] = a[j];
                    j = j - 1;
                end
                a[j+1] = key;
            end
            foreach (a[i]) out_recs[i] = a[i];
        endfunction

        // Number of DISTINCT key values present (a duplicate-key measure).
        function int distinct_keys(input bit [RW-1:0] in_recs [N]);
            bit [KEY_W-1:0] seen [$];
            int cnt = 0;
            foreach (in_recs[i]) begin
                bit [KEY_W-1:0] k = in_recs[i][RW-1 -: KEY_W];
                bit found = 0;
                foreach (seen[s]) if (seen[s] == k) found = 1;
                if (!found) begin seen.push_back(k); cnt++; end
            end
            return cnt;
        endfunction

        // Orderedness class of the input as-presented: 0=already asc, 1=already
        // desc, 2=neither.
        function int orderedness(input bit [RW-1:0] in_recs [N]);
            bit asc = 1, desc = 1;
            for (int i = 0; i < N-1; i++) begin
                if (in_recs[i] > in_recs[i+1]) asc  = 0;
                if (in_recs[i] < in_recs[i+1]) desc = 0;
            end
            if (asc)  return 0;
            if (desc) return 1;
            return 2;
        endfunction
    endclass

    // =========================================================================
    // Driver - presents one input vector per handshake cycle
    // =========================================================================
    class bsort_driver extends uvm_driver #(bsort_item);
        `uvm_component_utils(bsort_driver)
        bsort_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(bsort_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "bsort_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_dir   <= 1'b0;
            cfg.vif.in_data  <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                bsort_item req;
                bit [N*RW-1:0] packed_in;
                seq_item_port.get_next_item(req);
                packed_in = '0;
                foreach (req.recs[i]) packed_in[i*RW +: RW] = req.recs[i];
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_dir   <= req.dir;
                cfg.vif.drv_cb.in_data  <= packed_in;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each accepted input vector with the sorted vector that
    // later emerges (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class bsort_monitor extends uvm_monitor;
        `uvm_component_utils(bsort_monitor)
        bsort_cfg cfg;
        uvm_analysis_port #(bsort_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(bsort_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "bsort_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit [N*RW-1:0] in_q  [$];
            bit            ind_q [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    in_q.push_back(cfg.vif.mon_cb.in_data);
                    ind_q.push_back(cfg.vif.mon_cb.in_dir);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    bsort_obs_item o = bsort_obs_item::type_id::create("obs");
                    bit [N*RW-1:0] iv;
                    if (in_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input vector")
                    end else begin
                        iv       = in_q.pop_front();
                        o.in_dir = ind_q.pop_front();
                        for (int i = 0; i < N; i++)
                            o.in_recs[i] = iv[i*RW +: RW];
                        o.out_dir = cfg.vif.mon_cb.out_dir;
                        for (int i = 0; i < N; i++)
                            o.out_recs[i] = cfg.vif.mon_cb.out_data[i*RW +: RW];
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(bsort_item) bsort_sqr;

    class bsort_agent extends uvm_agent;
        `uvm_component_utils(bsort_agent)
        bsort_driver  drv;
        bsort_sqr     sqr;
        bsort_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = bsort_driver ::type_id::create("drv", this);
            sqr = bsort_sqr    ::type_id::create("sqr", this);
            mon = bsort_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-sort the input and check the DUT vector lane-by-lane.
    // Exact-vector equality proves both permutation-of-input AND monotonicity.
    // =========================================================================
    class bsort_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(bsort_scoreboard)
        uvm_analysis_imp #(bsort_obs_item, bsort_scoreboard) imp;
        bsort_model model;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void write(bsort_obs_item o);
            bit [RW-1:0] exp [N];
            bit          ok = 1;

            model.sort(o.in_recs, o.in_dir, exp);

            if (o.out_dir !== o.in_dir) begin
                ok = 0;
                `uvm_error("SB", $sformatf("DIR MISMATCH got %0d exp %0d",
                           o.out_dir, o.in_dir))
            end
            foreach (exp[k]) begin
                if (o.out_recs[k] !== exp[k]) begin
                    ok = 0;
                    `uvm_error("SB", $sformatf(
                        "LANE MISMATCH lane %0d | got 0x%02h exp 0x%02h (%s)",
                        k, o.out_recs[k], exp[k], o.convert2string()))
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
    // Coverage - direction x input-orderedness x duplicate-keys x extremes
    // =========================================================================
    class bsort_coverage extends uvm_subscriber #(bsort_obs_item);
        `uvm_component_utils(bsort_coverage)
        bsort_model cov_model;

        bit c_dir;
        int c_order;    // 0 asc, 1 desc, 2 neither
        int c_dkeys;    // number of distinct keys
        bit c_has_min;  // a min-key record present
        bit c_has_max;  // a max-key record present

        covergroup cg;
            option.per_instance = 1;
            cp_dir:   coverpoint c_dir { bins asc = {0}; bins desc = {1}; }
            cp_order: coverpoint c_order {
                bins already_asc  = {0};
                bins already_desc = {1};
                bins unordered    = {2};
            }
            cp_dkeys: coverpoint c_dkeys {
                bins all_same = {1};
                bins few      = {[2:3]};
                bins many     = {[4:N-1]};
                bins all_uniq = {N};
            }
            cp_min: coverpoint c_has_min { bins no = {0}; bins yes = {1}; }
            cp_max: coverpoint c_has_max { bins no = {0}; bins yes = {1}; }
            x_dir_order: cross cp_dir, cp_order;
            x_dir_dkeys: cross cp_dir, cp_dkeys;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cov_model = new(); cg = new();
        endfunction

        function void write(bsort_obs_item o);
            c_dir     = o.in_dir;
            c_order   = cov_model.orderedness(o.in_recs);
            c_dkeys   = cov_model.distinct_keys(o.in_recs);
            c_has_min = 0;
            c_has_max = 0;
            foreach (o.in_recs[i]) begin
                if (o.in_recs[i][RW-1 -: KEY_W] == '0)  c_has_min = 1;
                if (o.in_recs[i][RW-1 -: KEY_W] == '1)  c_has_max = 1;
            end
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class bsort_vseqr extends uvm_sequencer;
        `uvm_component_utils(bsort_vseqr)
        bsort_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class bsort_env extends uvm_env;
        `uvm_component_utils(bsort_env)
        bsort_agent      agent;
        bsort_scoreboard sb;
        bsort_coverage   cov;
        bsort_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = bsort_agent     ::type_id::create("agent", this);
            sb    = bsort_scoreboard::type_id::create("sb",    this);
            cov   = bsort_coverage  ::type_id::create("cov",   this);
            vseqr = bsort_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase: ascending sort of a reverse ramp, descending sort of an
    // ascending ramp, and an already-sorted identity.
    class bsort_showcase_seq extends uvm_sequence #(bsort_item);
        `uvm_object_utils(bsort_showcase_seq)
        function new(string n = "bsort_showcase_seq"); super.new(n); endfunction

        task send(bit [RW-1:0] r [N], bit d);
            bsort_item c = bsort_item::type_id::create("c");
            start_item(c);
            foreach (r[i]) c.recs[i] = r[i];
            c.dir = d;
            finish_item(c);
        endtask

        task body();
            bit [RW-1:0] r [N];
            // reverse ramp, ascending sort -> monotonic 0x00..0x70
            for (int i = 0; i < N; i++) r[i] = {6'((N-1-i)*4), 2'b00};
            send(r, 1'b0);
            // ascending ramp, descending sort
            for (int i = 0; i < N; i++) r[i] = {6'(i*4), 2'b00};
            send(r, 1'b1);
            // already sorted ascending (identity)
            for (int i = 0; i < N; i++) r[i] = {6'(i*4), 2'b00};
            send(r, 1'b0);
        endtask
    endclass

    // Directed corners: equal keys (tie-break by tag), all identical, min/max
    // extremes, and a single large element among zeros.
    class bsort_corner_seq extends uvm_sequence #(bsort_item);
        `uvm_object_utils(bsort_corner_seq)
        function new(string n = "bsort_corner_seq"); super.new(n); endfunction

        task send(bit [RW-1:0] r [N], bit d);
            bsort_item c = bsort_item::type_id::create("c");
            start_item(c);
            foreach (r[i]) c.recs[i] = r[i];
            c.dir = d;
            finish_item(c);
        endtask

        task body();
            bit [RW-1:0] r [N];
            // equal keys, distinct tags -> tie-break by tag
            for (int i = 0; i < N; i++) r[i] = {6'h15, 2'((N-1-i))};
            send(r, 1'b0);
            // all identical records
            for (int i = 0; i < N; i++) r[i] = {6'h2A, 2'h1};
            send(r, 1'b0);
            // min/max extremes interleaved
            for (int i = 0; i < N; i++) r[i] = (i % 2 == 0) ? {6'h00, 2'h0}
                                                            : {6'h3F, 2'h3};
            send(r, 1'b0);
            // single large element among zeros, descending
            for (int i = 0; i < N; i++) r[i] = {6'h00, 2'h0};
            r[3] = {6'h3F, 2'h0};
            send(r, 1'b1);
        endtask
    endclass

    // Constrained-random regression: random records + random direction, with a
    // fraction forced to a small key set to stress duplicate-key handling.
    class bsort_random_seq extends uvm_sequence #(bsort_item);
        `uvm_object_utils(bsort_random_seq)
        rand int unsigned n_vecs;
        constraint c_n { n_vecs inside {[60:150]}; }
        function new(string n = "bsort_random_seq"); super.new(n); endfunction

        task body();
            for (int t = 0; t < n_vecs; t++) begin
                bsort_item c = bsort_item::type_id::create("c");
                start_item(c);
                if (t % 5 == 0) begin
                    // duplicate-key stress: only a few distinct keys
                    if (!c.randomize() with {
                        foreach (recs[i]) recs[i][RW-1 -: KEY_W] inside {6'h00, 6'h14, 6'h28};
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
    class bsort_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(bsort_smoke_vseq)
        bsort_vseqr vseqr;
        function new(string n = "bsort_smoke_vseq"); super.new(n); endfunction
        task body();
            bsort_showcase_seq sh  = bsort_showcase_seq::type_id::create("sh");
            bsort_random_seq   rnd = bsort_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 60; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class bsort_regress_vseq extends uvm_sequence;
        `uvm_object_utils(bsort_regress_vseq)
        bsort_vseqr vseqr;
        function new(string n = "bsort_regress_vseq"); super.new(n); endfunction
        task body();
            bsort_showcase_seq sh  = bsort_showcase_seq::type_id::create("sh");
            bsort_corner_seq   cor = bsort_corner_seq  ::type_id::create("cor");
            bsort_random_seq   rnd = bsort_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 150; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class bsort_base_test extends uvm_test;
        `uvm_component_utils(bsort_base_test)
        bsort_env env;
        bsort_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = bsort_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual warp_bitonic_sort_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(bsort_cfg)::set(this, "*", "cfg", cfg);
            env = bsort_env::type_id::create("env", this);
        endfunction
    endclass

    class bsort_smoke_test extends bsort_base_test;
        `uvm_component_utils(bsort_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            bsort_smoke_vseq v = bsort_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class bsort_regress_test extends bsort_base_test;
        `uvm_component_utils(bsort_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            bsort_regress_vseq v = bsort_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
