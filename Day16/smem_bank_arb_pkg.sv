// -----------------------------------------------------------------------------
// smem_bank_arb_pkg.sv - UVM verification environment for the GPU shared-memory
// bank-conflict serializer (smem_bank_arb.sv). Requires a UVM-capable simulator
// (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run the portable
// companion TB tb_smem_bank_arb_dump.sv instead (see the Makefile).
//
// Contents:
//   * smem_req_item    - one warp shared-memory request (mask + per-lane addr)
//   * smem_obs_item    - observed request + the full serialized phase stream it
//                        produced (list of {served, bank_use} beats)
//   * smem_cfg         - virtual interface + knobs
//   * smem_model       - golden bank-conflict serializer (independent re-model);
//                        reused by both the scoreboard and the coverage collector
//   * smem_driver      - drives one warp request per handshake
//   * smem_monitor     - reassembles {request, its phase stream} per request
//   * smem_agent
//   * smem_scoreboard  - recomputes the golden phase stream and checks the DUT's
//                        {ph_served, ph_bank_use, phase count} beat-for-beat
//   * smem_coverage    - conflict-degree x active-lanes x broadcast cross
//   * sequences        - showcase / corners / random
//   * smem_vseqr       - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests            - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package smem_bank_arb_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int NLANES = 8;
    localparam int NBANKS = 8;
    localparam int ADDR_W = 16;
    localparam int MAXP   = NLANES;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class smem_req_item extends uvm_sequence_item;
        rand bit [NLANES-1:0] mask;
        rand bit [ADDR_W-1:0] addr [NLANES];

        `uvm_object_utils_begin(smem_req_item)
            `uvm_field_int(mask, UVM_ALL_ON)
            `uvm_field_sarray_int(addr, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "smem_req_item"); super.new(name); endfunction

        // Keep addresses in a modest range so bank aliasing (and thus conflicts)
        // is exercised rather than being astronomically unlikely.
        constraint c_addr { foreach (addr[i]) addr[i] inside {[0:63]}; }

        function string convert2string();
            string s = $sformatf("mask=%b addr=[", mask);
            foreach (addr[i]) s = {s, $sformatf("%0d:0x%0h ", i, addr[i])};
            return {s, "]"};
        endfunction
    endclass

    // Observed request paired with the phase stream it produced.
    class smem_obs_item extends uvm_sequence_item;
        bit [NLANES-1:0] mask;
        bit [ADDR_W-1:0] addr     [NLANES];
        bit [NLANES-1:0] served   [$];
        bit [NBANKS-1:0] bank_use [$];

        `uvm_object_utils(smem_obs_item)
        function new(string name = "smem_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("mask=%b -> %0d phase(s)", mask, served.size());
        endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class smem_cfg extends uvm_object;
        virtual smem_bank_arb_if vif;
        `uvm_object_utils(smem_cfg)
        function new(string name = "smem_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden bank-conflict serializer - independent re-implementation of the
    // DUT algorithm. Given {mask, addr}, produces the expected phase stream.
    // Used by both the scoreboard and the coverage collector.
    // =========================================================================
    class smem_model;
        // Compute the expected phase stream: one distinct address per bank per
        // phase, lowest-index pending lane wins, all same-address pending lanes
        // served together (broadcast).
        function void compute(input bit [NLANES-1:0] mask,
                              input bit [ADDR_W-1:0] addr [NLANES],
                              ref   bit [NLANES-1:0] served_o   [$],
                              ref   bit [NBANKS-1:0] bank_use_o [$]);
            bit [NLANES-1:0] pend, serv;
            bit [NBANKS-1:0] bhit;
            bit [ADDR_W-1:0] waddr [NBANKS];
            int              bnk;

            served_o.delete(); bank_use_o.delete();
            pend = mask;

            if (pend == '0) begin                 // empty request -> one empty phase
                served_o.push_back('0);
                bank_use_o.push_back('0);
                return;
            end

            while (pend != '0) begin
                bhit = '0;
                for (int b = 0; b < NBANKS; b++) waddr[b] = '0;
                for (int l = 0; l < NLANES; l++) begin
                    if (pend[l]) begin
                        bnk = addr[l] % NBANKS;
                        if (!bhit[bnk]) begin
                            bhit[bnk]  = 1'b1;
                            waddr[bnk] = addr[l];
                        end
                    end
                end
                serv = '0;
                for (int l = 0; l < NLANES; l++) begin
                    bnk = addr[l] % NBANKS;
                    if (pend[l] && bhit[bnk] && (addr[l] == waddr[bnk]))
                        serv[l] = 1'b1;
                end
                served_o.push_back(serv);
                bank_use_o.push_back(bhit);
                pend = pend & ~serv;
            end
        endfunction

        // Did any phase serve more lanes than banks it used? (broadcast occurred)
        function bit had_broadcast(input bit [NLANES-1:0] mask,
                                   input bit [ADDR_W-1:0] addr [NLANES]);
            bit [NLANES-1:0] sv [$];
            bit [NBANKS-1:0] bu [$];
            compute(mask, addr, sv, bu);
            foreach (sv[i]) if ($countones(sv[i]) > $countones(bu[i])) return 1'b1;
            return 1'b0;
        endfunction
    endclass

    // =========================================================================
    // Driver - drives one warp request per handshake
    // =========================================================================
    class smem_driver extends uvm_driver #(smem_req_item);
        `uvm_component_utils(smem_driver)
        smem_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(smem_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "smem_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.req_valid <= 1'b0;
            cfg.vif.req_mask  <= '0;
            cfg.vif.req_addr  <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                smem_req_item req;
                bit [NLANES*ADDR_W-1:0] packed_addr;
                seq_item_port.get_next_item(req);
                packed_addr = '0;
                foreach (req.addr[l]) packed_addr[l*ADDR_W +: ADDR_W] = req.addr[l];
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.req_valid <= 1'b1;
                cfg.vif.drv_cb.req_mask  <= req.mask;
                cfg.vif.drv_cb.req_addr  <= packed_addr;
                // hold until accepted
                do @(cfg.vif.drv_cb); while (cfg.vif.drv_cb.req_ready !== 1'b1);
                cfg.vif.drv_cb.req_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - reassembles {accepted request, its serialized phase stream}
    // =========================================================================
    class smem_monitor extends uvm_monitor;
        `uvm_component_utils(smem_monitor)
        smem_cfg cfg;
        uvm_analysis_port #(smem_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(smem_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "smem_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(cfg.vif.mon_cb);
                if (cfg.vif.mon_cb.req_valid && cfg.vif.mon_cb.req_ready) begin
                    smem_obs_item o = smem_obs_item::type_id::create("obs");
                    o.mask = cfg.vif.mon_cb.req_mask;
                    for (int l = 0; l < NLANES; l++)
                        o.addr[l] = cfg.vif.mon_cb.req_addr[l*ADDR_W +: ADDR_W];
                    // collect phase beats until ph_last
                    forever begin
                        @(cfg.vif.mon_cb);
                        if (cfg.vif.mon_cb.ph_valid) begin
                            o.served.push_back(cfg.vif.mon_cb.ph_served);
                            o.bank_use.push_back(cfg.vif.mon_cb.ph_bank_use);
                            if (cfg.vif.mon_cb.ph_last) break;
                        end
                    end
                    ap.write(o);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(smem_req_item) smem_sqr;

    class smem_agent extends uvm_agent;
        `uvm_component_utils(smem_agent)
        smem_driver  drv;
        smem_sqr     sqr;
        smem_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = smem_driver ::type_id::create("drv", this);
            sqr = smem_sqr    ::type_id::create("sqr", this);
            mon = smem_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - recompute the golden phase stream and check it beat-for-beat
    // =========================================================================
    class smem_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(smem_scoreboard)
        uvm_analysis_imp #(smem_obs_item, smem_scoreboard) imp;
        smem_model model;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void write(smem_obs_item o);
            bit [NLANES-1:0] exp_served   [$];
            bit [NBANKS-1:0] exp_bank_use [$];
            bit              ok = 1;

            model.compute(o.mask, o.addr, exp_served, exp_bank_use);

            if (o.served.size() != exp_served.size()) begin
                ok = 0;
                `uvm_error("SB", $sformatf(
                    "PHASE-COUNT MISMATCH %s | got %0d exp %0d",
                    o.convert2string(), o.served.size(), exp_served.size()))
            end else begin
                foreach (exp_served[k]) begin
                    if (o.served[k] !== exp_served[k]) begin
                        ok = 0;
                        `uvm_error("SB", $sformatf(
                            "SERVED MISMATCH phase %0d | got %b exp %b (mask=%b)",
                            k, o.served[k], exp_served[k], o.mask))
                    end
                    if (o.bank_use[k] !== exp_bank_use[k]) begin
                        ok = 0;
                        `uvm_error("SB", $sformatf(
                            "BANK_USE MISMATCH phase %0d | got %b exp %b (mask=%b)",
                            k, o.bank_use[k], exp_bank_use[k], o.mask))
                    end
                end
            end

            if (ok) begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end else errors++;
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d requests checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - conflict-degree x active-lanes x broadcast
    // =========================================================================
    class smem_coverage extends uvm_subscriber #(smem_obs_item);
        `uvm_component_utils(smem_coverage)
        smem_model cov_model;

        int c_degree;   // number of phases (conflict degree)
        int c_active;   // active lanes in the request
        bit c_bcast;    // a broadcast occurred

        covergroup cg;
            option.per_instance = 1;
            cp_degree: coverpoint c_degree {
                bins conflict_free = {1};
                bins low           = {[2:3]};
                bins mid           = {[4:7]};
                bins max_way       = {NLANES};
            }
            cp_active: coverpoint c_active {
                bins none = {0};
                bins one  = {1};
                bins some = {[2:NLANES-1]};
                bins full = {NLANES};
            }
            cp_bcast: coverpoint c_bcast { bins no = {0}; bins yes = {1}; }
            x_degree_active: cross cp_degree, cp_active;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cov_model = new(); cg = new();
        endfunction

        function void write(smem_obs_item o);
            c_degree = o.served.size();
            c_active = $countones(o.mask);
            c_bcast  = cov_model.had_broadcast(o.mask, o.addr);
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class smem_vseqr extends uvm_sequencer;
        `uvm_component_utils(smem_vseqr)
        smem_sqr req_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class smem_env extends uvm_env;
        `uvm_component_utils(smem_env)
        smem_agent      agent;
        smem_scoreboard sb;
        smem_coverage   cov;
        smem_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = smem_agent     ::type_id::create("agent", this);
            sb    = smem_scoreboard::type_id::create("sb",    this);
            cov   = smem_coverage  ::type_id::create("cov",   this);
            vseqr = smem_vseqr     ::type_id::create("vseqr", this);
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
    // Directed showcase: the 3-way bank-0 conflict + broadcast, plus the
    // conflict-free and full-broadcast requests.
    class smem_showcase_seq extends uvm_sequence #(smem_req_item);
        `uvm_object_utils(smem_showcase_seq)
        function new(string n = "smem_showcase_seq"); super.new(n); endfunction

        task send(bit [NLANES-1:0] m, bit [ADDR_W-1:0] a [NLANES]);
            smem_req_item c = smem_req_item::type_id::create("c");
            start_item(c);
            c.mask = m;
            foreach (a[i]) c.addr[i] = a[i];
            finish_item(c);
        endtask

        task body();
            bit [ADDR_W-1:0] a [NLANES];
            // 3-way bank-0 conflict with a broadcast pair + four parallel banks
            a = '{16'h0000,16'h0008,16'h0010,16'h0000,16'h0001,16'h0002,16'h0003,16'h0004};
            send(8'hFF, a);
            // conflict-free: eight distinct banks
            a = '{16'h0000,16'h0001,16'h0002,16'h0003,16'h0004,16'h0005,16'h0006,16'h0007};
            send(8'hFF, a);
            // full broadcast: all lanes hit the same address
            a = '{16'h0100,16'h0100,16'h0100,16'h0100,16'h0100,16'h0100,16'h0100,16'h0100};
            send(8'hFF, a);
        endtask
    endclass

    // Directed corners: worst-case 8-way conflict, partial mask, single lane,
    // and an all-inactive request (one empty phase).
    class smem_corner_seq extends uvm_sequence #(smem_req_item);
        `uvm_object_utils(smem_corner_seq)
        function new(string n = "smem_corner_seq"); super.new(n); endfunction

        task send(bit [NLANES-1:0] m, bit [ADDR_W-1:0] a [NLANES]);
            smem_req_item c = smem_req_item::type_id::create("c");
            start_item(c);
            c.mask = m;
            foreach (a[i]) c.addr[i] = a[i];
            finish_item(c);
        endtask

        task body();
            bit [ADDR_W-1:0] a [NLANES];
            // worst case: all eight lanes to bank 0, distinct addresses -> 8 phases
            a = '{16'h0000,16'h0008,16'h0010,16'h0018,16'h0020,16'h0028,16'h0030,16'h0038};
            send(8'hFF, a);
            // partial active mask (lanes 0,2,4,6) with a 2-way conflict on bank 0
            a = '{16'h0000,16'h0,16'h0008,16'h0,16'h0002,16'h0,16'h0003,16'h0};
            send(8'b01010101, a);
            // single active lane
            a = '{16'h0,16'h0,16'h0,16'h0,16'h0AA0,16'h0,16'h0,16'h0};
            send(8'b00010000, a);
            // all-inactive request -> one empty phase
            a = '{default:16'h0};
            send(8'h00, a);
        endtask
    endclass

    // Constrained-random regression: random masks and addresses.
    class smem_random_seq extends uvm_sequence #(smem_req_item);
        `uvm_object_utils(smem_random_seq)
        rand int unsigned n_reqs;
        constraint c_n { n_reqs inside {[40:120]}; }
        function new(string n = "smem_random_seq"); super.new(n); endfunction

        task body();
            repeat (n_reqs) begin
                smem_req_item c = smem_req_item::type_id::create("c");
                start_item(c);
                if (!c.randomize())
                    `uvm_error("RND", "randomize failed")
                finish_item(c);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class smem_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(smem_smoke_vseq)
        smem_vseqr vseqr;
        function new(string n = "smem_smoke_vseq"); super.new(n); endfunction
        task body();
            smem_showcase_seq sh  = smem_showcase_seq::type_id::create("sh");
            smem_random_seq   rnd = smem_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_reqs == 40; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    class smem_regress_vseq extends uvm_sequence;
        `uvm_object_utils(smem_regress_vseq)
        smem_vseqr vseqr;
        function new(string n = "smem_regress_vseq"); super.new(n); endfunction
        task body();
            smem_showcase_seq sh  = smem_showcase_seq::type_id::create("sh");
            smem_corner_seq   cor = smem_corner_seq  ::type_id::create("cor");
            smem_random_seq   rnd = smem_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.req_sqr);
            cor.start(vseqr.req_sqr);
            void'(rnd.randomize() with { n_reqs == 120; });
            rnd.start(vseqr.req_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class smem_base_test extends uvm_test;
        `uvm_component_utils(smem_base_test)
        smem_env env;
        smem_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = smem_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual smem_bank_arb_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(smem_cfg)::set(this, "*", "cfg", cfg);
            env = smem_env::type_id::create("env", this);
        endfunction
    endclass

    class smem_smoke_test extends smem_base_test;
        `uvm_component_utils(smem_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            smem_smoke_vseq v = smem_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class smem_regress_test extends smem_base_test;
        `uvm_component_utils(smem_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            smem_regress_vseq v = smem_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
