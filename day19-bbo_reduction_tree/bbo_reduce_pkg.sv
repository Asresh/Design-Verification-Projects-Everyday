// -----------------------------------------------------------------------------
// bbo_reduce_pkg.sv - UVM verification environment for the streaming Best-Bid/
// Best-Offer (BBO) top-of-book reduction tree (bbo_reduce.sv). Requires a UVM-
// capable simulator (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run
// the portable companion TB tb_bbo_reduce_dump.sv instead (see the Makefile).
//
// Contents:
//   * bbo_item      - one input price ladder (N levels) + populated-level mask
//   * bbo_obs_item  - observed input ladder paired with the BBO result the
//                     pipeline produced (paired by the monitor via a FIFO, so it
//                     is robust to the exact pipeline latency)
//   * bbo_cfg       - virtual interface + knobs
//   * bbo_model     - golden reference BBO (independent re-model: lowest-index-
//                     wins argmax/argmin over the valid levels); reused by
//                     scoreboard and coverage
//   * bbo_driver    - presents one price ladder per cycle (zero-bubble capable)
//   * bbo_monitor   - reassembles {input ladder, its BBO result}
//   * bbo_agent
//   * bbo_scoreboard - re-derives the BBO and checks the DUT (value+index+any)
//   * bbo_coverage  - occupancy x max-tie x min-tie x edge-of-book cross
//   * sequences      - showcase / corners / random
//   * bbo_vseqr      - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests          - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package bbo_reduce_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int N  = 8;
    localparam int DW = 16;
    localparam int IW = 3;                  // $clog2(8)

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class bbo_item extends uvm_sequence_item;
        rand bit [DW-1:0] price [N];
        rand bit [N-1:0]  mask;

        `uvm_object_utils_begin(bbo_item)
            `uvm_field_sarray_int(price, UVM_ALL_ON)
            `uvm_field_int(mask, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "bbo_item"); super.new(name); endfunction

        function string convert2string();
            string s = $sformatf("mask=0x%02h price=[", mask);
            foreach (price[i]) s = {s, $sformatf("%0d:0x%04h ", i, price[i])};
            return {s, "]"};
        endfunction
    endclass

    // Observed input ladder paired with the BBO result it produced.
    class bbo_obs_item extends uvm_sequence_item;
        bit [DW-1:0] in_price [N];
        bit [N-1:0]  in_mask;
        bit          out_any;
        bit [DW-1:0] out_max_val;
        bit [IW-1:0] out_max_idx;
        bit [DW-1:0] out_min_val;
        bit [IW-1:0] out_min_idx;

        `uvm_object_utils(bbo_obs_item)
        function new(string name = "bbo_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("mask=0x%02h any=%0d max=0x%04h@%0d min=0x%04h@%0d",
                             in_mask, out_any, out_max_val, out_max_idx,
                             out_min_val, out_min_idx);
        endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class bbo_cfg extends uvm_object;
        virtual bbo_reduce_if vif;
        `uvm_object_utils(bbo_cfg)
        function new(string name = "bbo_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden reference BBO - independent re-implementation: a lowest-index-wins
    // argmax + argmin over the VALID levels only. Used by scoreboard + coverage.
    // =========================================================================
    class bbo_model;
        // Compute best bid (max) and best offer (min) with lowest-index tie-break.
        function void bbo(input  bit [DW-1:0] in_price [N],
                          input  bit [N-1:0]  mask,
                          output bit          any,
                          output bit [DW-1:0] mxv, output bit [IW-1:0] mxi,
                          output bit [DW-1:0] mnv, output bit [IW-1:0] mni);
            any = 1'b0;
            mxv = '0; mxi = '0; mnv = {DW{1'b1}}; mni = '0;
            for (int i = 0; i < N; i++) begin
                if (mask[i]) begin
                    if (!any) begin
                        any = 1'b1;
                        mxv = in_price[i]; mxi = IW'(i);
                        mnv = in_price[i]; mni = IW'(i);
                    end else begin
                        // strictly greater / smaller updates -> lowest index kept on a tie
                        if (in_price[i] > mxv) begin mxv = in_price[i]; mxi = IW'(i); end
                        if (in_price[i] < mnv) begin mnv = in_price[i]; mni = IW'(i); end
                    end
                end
            end
            if (!any) begin
                mxv = '0; mxi = '0; mnv = {DW{1'b1}}; mni = '0;
            end
        endfunction

        // Book occupancy class: 0 = empty, 1 = single level, 2 = a few (2..N-1),
        // 3 = full (all N populated).
        function int occupancy(input bit [N-1:0] mask);
            int c = 0;
            for (int i = 0; i < N; i++) if (mask[i]) c++;
            if (c == 0) return 0;
            if (c == 1) return 1;
            if (c == N) return 3;
            return 2;
        endfunction

        // Does the max price occur at more than one VALID level (a real tie the
        // lowest-index rule had to resolve)?
        function bit max_tied(input bit [DW-1:0] in_price [N], input bit [N-1:0] mask);
            bit [DW-1:0] mxv, mxi_v, mnv, mni_v; bit any;
            int cnt = 0;
            bbo(in_price, mask, any, mxv, mxi_v, mnv, mni_v);
            if (!any) return 1'b0;
            for (int i = 0; i < N; i++) if (mask[i] && in_price[i] == mxv) cnt++;
            return (cnt > 1);
        endfunction

        // Does the min price occur at more than one VALID level?
        function bit min_tied(input bit [DW-1:0] in_price [N], input bit [N-1:0] mask);
            bit [DW-1:0] mxv, mxi_v, mnv, mni_v; bit any;
            int cnt = 0;
            bbo(in_price, mask, any, mxv, mxi_v, mnv, mni_v);
            if (!any) return 1'b0;
            for (int i = 0; i < N; i++) if (mask[i] && in_price[i] == mnv) cnt++;
            return (cnt > 1);
        endfunction

        // Does the winning best-bid level sit at an edge of the book (level 0 or
        // level N-1)? Exercises the tree's outermost leaves.
        function bit max_at_edge(input bit [DW-1:0] in_price [N], input bit [N-1:0] mask);
            bit [DW-1:0] mxv, mnv; bit [IW-1:0] mxi, mni; bit any;
            bbo(in_price, mask, any, mxv, mxi, mnv, mni);
            if (!any) return 1'b0;
            return (mxi == 0) || (mxi == IW'(N-1));
        endfunction
    endclass

    // =========================================================================
    // Driver - presents one price ladder per handshake cycle
    // =========================================================================
    class bbo_driver extends uvm_driver #(bbo_item);
        `uvm_component_utils(bbo_driver)
        bbo_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(bbo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "bbo_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.in_valid <= 1'b0;
            cfg.vif.in_price <= '0;
            cfg.vif.in_mask  <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                bbo_item req;
                bit [N*DW-1:0] packed_in;
                seq_item_port.get_next_item(req);
                packed_in = '0;
                foreach (req.price[i]) packed_in[i*DW +: DW] = req.price[i];
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b1;
                cfg.vif.drv_cb.in_price <= packed_in;
                cfg.vif.drv_cb.in_mask  <= req.mask;
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - pairs each accepted input ladder with the BBO result that later
    // emerges (FIFO pairing -> independent of the exact pipeline latency).
    // =========================================================================
    class bbo_monitor extends uvm_monitor;
        `uvm_component_utils(bbo_monitor)
        bbo_cfg cfg;
        uvm_analysis_port #(bbo_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(bbo_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "bbo_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit [N*DW-1:0] in_q  [$];
            bit [N-1:0]    inm_q [$];
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.in_valid) begin
                    in_q.push_back(cfg.vif.mon_cb.in_price);
                    inm_q.push_back(cfg.vif.mon_cb.in_mask);
                end
                if (cfg.vif.mon_cb.out_valid) begin
                    bbo_obs_item o = bbo_obs_item::type_id::create("obs");
                    bit [N*DW-1:0] iv;
                    if (in_q.size() == 0) begin
                        `uvm_error("MON", "out_valid with no pending input ladder")
                    end else begin
                        iv         = in_q.pop_front();
                        o.in_mask  = inm_q.pop_front();
                        for (int i = 0; i < N; i++)
                            o.in_price[i] = iv[i*DW +: DW];
                        o.out_any     = cfg.vif.mon_cb.out_any;
                        o.out_max_val = cfg.vif.mon_cb.out_max_val;
                        o.out_max_idx = cfg.vif.mon_cb.out_max_idx;
                        o.out_min_val = cfg.vif.mon_cb.out_min_val;
                        o.out_min_idx = cfg.vif.mon_cb.out_min_idx;
                        ap.write(o);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(bbo_item) bbo_sqr;

    class bbo_agent extends uvm_agent;
        `uvm_component_utils(bbo_agent)
        bbo_driver  drv;
        bbo_sqr     sqr;
        bbo_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = bbo_driver ::type_id::create("drv", this);
            sqr = bbo_sqr    ::type_id::create("sqr", this);
            mon = bbo_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - re-derive the BBO and check the DUT (value + index + any).
    // =========================================================================
    class bbo_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(bbo_scoreboard)
        uvm_analysis_imp #(bbo_obs_item, bbo_scoreboard) imp;
        bbo_model model;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void write(bbo_obs_item o);
            bit          any;
            bit [DW-1:0] mxv, mnv;
            bit [IW-1:0] mxi, mni;
            bit          ok = 1;

            model.bbo(o.in_price, o.in_mask, any, mxv, mxi, mnv, mni);

            if (o.out_any !== any) begin
                ok = 0;
                `uvm_error("SB", $sformatf("ANY MISMATCH got %0d exp %0d (%s)",
                           o.out_any, any, o.convert2string()))
            end else if (any) begin
                if (o.out_max_val !== mxv || o.out_max_idx !== mxi) begin
                    ok = 0;
                    `uvm_error("SB", $sformatf(
                        "BEST-BID MISMATCH got 0x%04h@%0d exp 0x%04h@%0d (%s)",
                        o.out_max_val, o.out_max_idx, mxv, mxi, o.convert2string()))
                end
                if (o.out_min_val !== mnv || o.out_min_idx !== mni) begin
                    ok = 0;
                    `uvm_error("SB", $sformatf(
                        "BEST-OFFER MISMATCH got 0x%04h@%0d exp 0x%04h@%0d (%s)",
                        o.out_min_val, o.out_min_idx, mnv, mni, o.convert2string()))
                end
            end

            if (ok) begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end else errors++;
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d results checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - occupancy x max-tie x min-tie x max-at-edge
    // =========================================================================
    class bbo_coverage extends uvm_subscriber #(bbo_obs_item);
        `uvm_component_utils(bbo_coverage)
        bbo_model cov_model;

        int c_occ;    // 0 empty, 1 single, 2 few, 3 full
        bit c_mxtie;
        bit c_mntie;
        bit c_edge;
        bit c_any;

        covergroup cg;
            option.per_instance = 1;
            cp_occ: coverpoint c_occ {
                bins empty  = {0};
                bins single = {1};
                bins few    = {2};
                bins full   = {3};
            }
            cp_mxtie: coverpoint c_mxtie { bins no = {0}; bins yes = {1}; }
            cp_mntie: coverpoint c_mntie { bins no = {0}; bins yes = {1}; }
            cp_edge:  coverpoint c_edge  { bins no = {0}; bins yes = {1}; }
            cp_any:   coverpoint c_any   { bins empty = {0}; bins nonempty = {1}; }
            x_occ_mxtie: cross cp_occ, cp_mxtie;
            x_mxtie_mntie: cross cp_mxtie, cp_mntie;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cov_model = new(); cg = new();
        endfunction

        function void write(bbo_obs_item o);
            c_occ   = cov_model.occupancy(o.in_mask);
            c_mxtie = cov_model.max_tied(o.in_price, o.in_mask);
            c_mntie = cov_model.min_tied(o.in_price, o.in_mask);
            c_edge  = cov_model.max_at_edge(o.in_price, o.in_mask);
            c_any   = o.out_any;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class bbo_vseqr extends uvm_sequencer;
        `uvm_component_utils(bbo_vseqr)
        bbo_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class bbo_env extends uvm_env;
        `uvm_component_utils(bbo_env)
        bbo_agent      agent;
        bbo_scoreboard sb;
        bbo_coverage   cov;
        bbo_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = bbo_agent     ::type_id::create("agent", this);
            sb    = bbo_scoreboard::type_id::create("sb",    this);
            cov   = bbo_coverage  ::type_id::create("cov",   this);
            vseqr = bbo_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase: the full 8-level book (best bid 110@lvl3 with a tie at
    // lvl6 -> lowest index; best offer 100@lvl0), a single-level book, and an
    // all-equal book (max==min@lvl0).
    class bbo_showcase_seq extends uvm_sequence #(bbo_item);
        `uvm_object_utils(bbo_showcase_seq)
        function new(string n = "bbo_showcase_seq"); super.new(n); endfunction

        task send(bit [DW-1:0] p [N], bit [N-1:0] m);
            bbo_item c = bbo_item::type_id::create("c");
            start_item(c);
            foreach (p[i]) c.price[i] = p[i];
            c.mask = m;
            finish_item(c);
        endtask

        task body();
            bit [DW-1:0] p [N];
            // full book: 100,105,103,110,108,102,110,101
            p = '{16'd100,16'd105,16'd103,16'd110,16'd108,16'd102,16'd110,16'd101};
            send(p, 8'hFF);
            // single populated level (level 5)
            foreach (p[i]) p[i] = '0; p[5] = 16'd777;
            send(p, 8'b0010_0000);
            // all-equal prices -> max==min@lvl0
            foreach (p[i]) p[i] = 16'd50;
            send(p, 8'hFF);
        endtask
    endclass

    // Directed corners: empty book (identities), a max+min double tie, price
    // extremes, and a sparse mask.
    class bbo_corner_seq extends uvm_sequence #(bbo_item);
        `uvm_object_utils(bbo_corner_seq)
        function new(string n = "bbo_corner_seq"); super.new(n); endfunction

        task send(bit [DW-1:0] p [N], bit [N-1:0] m);
            bbo_item c = bbo_item::type_id::create("c");
            start_item(c);
            foreach (p[i]) c.price[i] = p[i];
            c.mask = m;
            finish_item(c);
        endtask

        task body();
            bit [DW-1:0] p [N];
            // empty book (mask 0) -> any=0, identities
            p = '{16'd11,16'd22,16'd33,16'd44,16'd55,16'd66,16'd77,16'd88};
            send(p, 8'h00);
            // max tie (9 @ lvl1,4) and min tie (2 @ lvl2,6) -> max@1, min@2
            p = '{16'd5,16'd9,16'd2,16'd5,16'd9,16'd5,16'd2,16'd5};
            send(p, 8'hFF);
            // price extremes 0x0000 and 0xFFFF both present
            p = '{16'hFFFF,16'd100,16'h0000,16'd200,16'd150,16'hFFFF,16'h0000,16'd120};
            send(p, 8'hFF);
            // sparse mask: only levels 2,3,7 populated -> max 600@7, min 250@3
            p = '{16'd999,16'd999,16'd400,16'd250,16'd999,16'd999,16'd999,16'd600};
            send(p, 8'b1000_1100);
        endtask
    endclass

    // Constrained-random regression: random prices + random mask, with a fraction
    // squeezed into a small price range to force frequent ties, and an occasional
    // empty book to exercise the identity outputs.
    class bbo_random_seq extends uvm_sequence #(bbo_item);
        `uvm_object_utils(bbo_random_seq)
        rand int unsigned n_vecs;
        constraint c_n { n_vecs inside {[80:200]}; }
        function new(string n = "bbo_random_seq"); super.new(n); endfunction

        task body();
            for (int t = 0; t < n_vecs; t++) begin
                bbo_item c = bbo_item::type_id::create("c");
                start_item(c);
                if (t % 3 == 0) begin
                    // small price range [0,20] -> many exact ties
                    if (!c.randomize() with {
                        foreach (price[i]) price[i] <= 16'd20;
                    }) `uvm_error("RND", "randomize failed")
                end else if (t % 17 == 0) begin
                    // empty book
                    if (!c.randomize() with { mask == '0; })
                        `uvm_error("RND", "randomize failed")
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
    class bbo_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(bbo_smoke_vseq)
        bbo_vseqr vseqr;
        function new(string n = "bbo_smoke_vseq"); super.new(n); endfunction
        task body();
            bbo_showcase_seq sh  = bbo_showcase_seq::type_id::create("sh");
            bbo_random_seq   rnd = bbo_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 80; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class bbo_regress_vseq extends uvm_sequence;
        `uvm_object_utils(bbo_regress_vseq)
        bbo_vseqr vseqr;
        function new(string n = "bbo_regress_vseq"); super.new(n); endfunction
        task body();
            bbo_showcase_seq sh  = bbo_showcase_seq::type_id::create("sh");
            bbo_corner_seq   cor = bbo_corner_seq  ::type_id::create("cor");
            bbo_random_seq   rnd = bbo_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_vecs == 200; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class bbo_base_test extends uvm_test;
        `uvm_component_utils(bbo_base_test)
        bbo_env env;
        bbo_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = bbo_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual bbo_reduce_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(bbo_cfg)::set(this, "*", "cfg", cfg);
            env = bbo_env::type_id::create("env", this);
        endfunction
    endclass

    class bbo_smoke_test extends bbo_base_test;
        `uvm_component_utils(bbo_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            bbo_smoke_vseq v = bbo_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

    class bbo_regress_test extends bbo_base_test;
        `uvm_component_utils(bbo_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            bbo_regress_vseq v = bbo_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
