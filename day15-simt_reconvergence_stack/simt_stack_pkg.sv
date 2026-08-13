// -----------------------------------------------------------------------------
// simt_stack_pkg.sv - UVM verification environment for the GPU SIMT
// reconvergence stack (simt_stack.sv). Requires a UVM-capable simulator
// (VCS / Questa / Verilator >= 5 with --uvm). Icarus users run the portable
// companion TB tb_simt_stack_dump.sv instead (see the Makefile).
//
// Contents:
//   * simt_cmd_item    - one control command (op + masks + PCs)
//   * simt_obs_item    - observed command + resulting TOS status (from monitor)
//   * simt_cfg         - virtual interface + knobs
//   * simt_model       - golden SHADOW STACK (independent re-implementation);
//                        reused by both the scoreboard (predictor) and coverage
//   * simt_driver      - drives one command per handshake
//   * simt_monitor     - publishes {command, resulting TOS status} pairs
//   * simt_agent
//   * simt_scoreboard  - predictor: applies each command to a shadow stack and
//                        checks the observed {tos_mask,tos_pc,sp,empty,full}
//   * simt_coverage    - op x divergence-outcome x depth
//   * sequences        - showcase / corners / random (legal-program generator)
//   * simt_vseqr       - virtual sequencer
//   * virtual sequences - smoke / regress
//   * tests            - base / smoke / regress
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package simt_stack_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- design constants (must match the DUT / interface parameters) ----
    localparam int NLANES = 8;
    localparam int PC_W   = 16;
    localparam int DEPTH  = 32;

    localparam logic [1:0] OP_INIT    = 2'd0;
    localparam logic [1:0] OP_DIVERGE = 2'd1;
    localparam logic [1:0] OP_POP     = 2'd2;

    // =========================================================================
    // Transaction objects
    // =========================================================================
    class simt_cmd_item extends uvm_sequence_item;
        rand bit [1:0]        op;
        rand bit [NLANES-1:0] in_mask;
        rand bit [PC_W-1:0]   rpc;
        rand bit [PC_W-1:0]   tpc;
        rand bit [PC_W-1:0]   fpc;

        `uvm_object_utils_begin(simt_cmd_item)
            `uvm_field_int(op,      UVM_ALL_ON)
            `uvm_field_int(in_mask, UVM_ALL_ON)
            `uvm_field_int(rpc,     UVM_ALL_ON)
            `uvm_field_int(tpc,     UVM_ALL_ON)
            `uvm_field_int(fpc,     UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "simt_cmd_item"); super.new(name); endfunction

        constraint c_op { op inside {OP_INIT, OP_DIVERGE, OP_POP}; }

        function string convert2string();
            string o;
            o = (op==OP_INIT) ? "INIT" : (op==OP_DIVERGE) ? "DIVERGE" :
                (op==OP_POP)  ? "POP"  : "??";
            return $sformatf("%-7s mask=%b rpc=0x%0h tpc=0x%0h fpc=0x%0h",
                             o, in_mask, rpc, tpc, fpc);
        endfunction
    endclass

    // Observed command paired with the TOS status it produced.
    class simt_obs_item extends uvm_sequence_item;
        bit [1:0]        op;
        bit [NLANES-1:0] in_mask;
        bit [PC_W-1:0]   rpc, tpc, fpc;
        bit              cmd_accepted;    // cmd_ready was high
        // resulting state
        bit [NLANES-1:0] tos_mask;
        bit [PC_W-1:0]   tos_pc;
        int              sp;
        bit              empty, full;

        `uvm_object_utils(simt_obs_item)
        function new(string name = "simt_obs_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("op=%0d mask=%b acc=%0b -> sp=%0d tos_mask=%b tos_pc=0x%0h empty=%0b",
                             op, in_mask, cmd_accepted, sp, tos_mask, tos_pc, empty);
        endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class simt_cfg extends uvm_object;
        virtual simt_stack_if vif;
        `uvm_object_utils(simt_cfg)
        function new(string name = "simt_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Golden shadow stack - independent re-implementation of the DUT. Applied
    // command-by-command; predicts the resulting TOS status. Used by both the
    // scoreboard (as a live predictor) and the coverage collector.
    // =========================================================================
    class simt_model;
        bit [NLANES-1:0] mask_q [$];
        bit [PC_W-1:0]   pc_q   [$];

        function void reset();
            mask_q.delete(); pc_q.delete();
        endfunction

        function int sp();      return mask_q.size(); endfunction
        function bit empty();   return (mask_q.size() == 0); endfunction
        function bit full();    return (mask_q.size() == DEPTH); endfunction

        function bit [NLANES-1:0] tos_mask();
            return (mask_q.size()==0) ? '0 : mask_q[$];
        endfunction
        function bit [PC_W-1:0] tos_pc();
            return (pc_q.size()==0) ? '0 : pc_q[$];
        endfunction

        // Would the DUT accept this command in the current state?
        function bit will_accept(bit [1:0] op, bit [NLANES-1:0] in_mask);
            bit [NLANES-1:0] cur, tset, fset;
            bit grows;
            cur   = tos_mask();
            tset  = in_mask & cur;
            fset  = cur & ~in_mask;
            grows = (op==OP_DIVERGE) && (tset!='0) && (fset!='0);
            return !(grows && ((sp()+2) > DEPTH));
        endfunction

        // Divergence outcome classification (for coverage).
        // 0=none/noop 1=grow 2=uniform-taken 3=uniform-fall
        function int diverge_kind(bit [1:0] op, bit [NLANES-1:0] in_mask);
            bit [NLANES-1:0] cur, tset, fset;
            if (op != OP_DIVERGE || empty()) return 0;
            cur  = tos_mask(); tset = in_mask & cur; fset = cur & ~in_mask;
            if ((tset!='0) && (fset!='0)) return 1;
            if (tset != '0)               return 2;
            return 3;
        endfunction

        // Apply one accepted command, mutating the shadow stack.
        function void apply(bit [1:0] op, bit [NLANES-1:0] in_mask,
                            bit [PC_W-1:0] rpc, bit [PC_W-1:0] tpc, bit [PC_W-1:0] fpc);
            bit [NLANES-1:0] cur, tset, fset;
            case (op)
                OP_INIT: begin
                    mask_q.delete(); pc_q.delete();
                    if (in_mask != '0) begin
                        mask_q.push_back(in_mask);
                        pc_q.push_back(fpc);
                    end
                end
                OP_DIVERGE: begin
                    if (mask_q.size() != 0) begin
                        cur  = mask_q[$];
                        tset = in_mask & cur;
                        fset = cur & ~in_mask;
                        if ((tset!='0) && (fset!='0)) begin
                            if ((sp()+2) <= DEPTH) begin
                                mask_q[$] = cur; pc_q[$] = rpc;     // reconv entry
                                mask_q.push_back(fset); pc_q.push_back(fpc); // fall-thru
                                mask_q.push_back(tset); pc_q.push_back(tpc); // taken (TOS)
                            end
                        end else if (tset != '0) begin
                            pc_q[$] = tpc;                           // uniform taken
                        end else begin
                            pc_q[$] = fpc;                           // uniform fall-thru
                        end
                    end
                end
                OP_POP: begin
                    if (mask_q.size() != 0) begin
                        void'(mask_q.pop_back());
                        void'(pc_q.pop_back());
                    end
                end
                default: ;
            endcase
        endfunction
    endclass

    // =========================================================================
    // Driver - drives one command per handshake
    // =========================================================================
    class simt_driver extends uvm_driver #(simt_cmd_item);
        `uvm_component_utils(simt_driver)
        simt_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(simt_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "simt_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            cfg.vif.cmd_valid <= 1'b0;
            cfg.vif.op        <= '0;
            cfg.vif.in_mask   <= '0;
            cfg.vif.rpc <= '0; cfg.vif.tpc <= '0; cfg.vif.fpc <= '0;
            @(posedge cfg.vif.rst_n);
            forever begin
                simt_cmd_item req;
                seq_item_port.get_next_item(req);
                @(cfg.vif.drv_cb);
                cfg.vif.drv_cb.cmd_valid <= 1'b1;
                cfg.vif.drv_cb.op        <= req.op;
                cfg.vif.drv_cb.in_mask   <= req.in_mask;
                cfg.vif.drv_cb.rpc       <= req.rpc;
                cfg.vif.drv_cb.tpc       <= req.tpc;
                cfg.vif.drv_cb.fpc       <= req.fpc;
                // hold until accepted
                do @(cfg.vif.drv_cb); while (cfg.vif.drv_cb.cmd_ready !== 1'b1);
                cfg.vif.drv_cb.cmd_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - publishes {accepted command, resulting TOS status}
    // The command latches at posedge T; the combinational status resulting from
    // it is sampled at posedge T+1 (handled with a one-cycle pending record so
    // back-to-back commands are all captured).
    // =========================================================================
    class simt_monitor extends uvm_monitor;
        `uvm_component_utils(simt_monitor)
        simt_cfg cfg;
        uvm_analysis_port #(simt_obs_item) ap;
        function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(simt_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "simt_cfg missing")
        endfunction

        task run_phase(uvm_phase phase);
            bit              have_pending = 0;
            bit [1:0]        p_op;
            bit [NLANES-1:0] p_mask;
            bit [PC_W-1:0]   p_rpc, p_tpc, p_fpc;
            forever begin
                @(cfg.vif.mon_cb);
                // 1) sample the status resulting from a command captured last edge
                if (have_pending) begin
                    simt_obs_item o = simt_obs_item::type_id::create("obs");
                    o.op = p_op; o.in_mask = p_mask;
                    o.rpc = p_rpc; o.tpc = p_tpc; o.fpc = p_fpc;
                    o.cmd_accepted = 1'b1;
                    o.tos_mask = cfg.vif.mon_cb.tos_mask;
                    o.tos_pc   = cfg.vif.mon_cb.tos_pc;
                    o.sp       = cfg.vif.mon_cb.sp;
                    o.empty    = cfg.vif.mon_cb.empty;
                    o.full     = cfg.vif.mon_cb.full;
                    ap.write(o);
                    have_pending = 0;
                end
                // 2) capture a command accepted at THIS edge
                if (cfg.vif.mon_cb.cmd_valid && cfg.vif.mon_cb.cmd_ready) begin
                    p_op   = cfg.vif.mon_cb.op;
                    p_mask = cfg.vif.mon_cb.in_mask;
                    p_rpc  = cfg.vif.mon_cb.rpc;
                    p_tpc  = cfg.vif.mon_cb.tpc;
                    p_fpc  = cfg.vif.mon_cb.fpc;
                    have_pending = 1;
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    typedef uvm_sequencer #(simt_cmd_item) simt_sqr;

    class simt_agent extends uvm_agent;
        `uvm_component_utils(simt_agent)
        simt_driver  drv;
        simt_sqr     sqr;
        simt_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            drv = simt_driver ::type_id::create("drv", this);
            sqr = simt_sqr    ::type_id::create("sqr", this);
            mon = simt_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - live predictor against the golden shadow stack
    // =========================================================================
    class simt_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(simt_scoreboard)
        uvm_analysis_imp #(simt_obs_item, simt_scoreboard) imp;
        simt_model model;
        int matches = 0;
        int errors  = 0;

        function new(string n, uvm_component p);
            super.new(n, p);
            imp   = new("imp", this);
            model = new();
        endfunction

        function void write(simt_obs_item o);
            bit [NLANES-1:0] exp_mask;
            bit [PC_W-1:0]   exp_pc;
            int              exp_sp;
            bit              exp_empty, exp_full;
            bit              ok = 1;

            // predict: apply the same command to the shadow stack
            model.apply(o.op, o.in_mask, o.rpc, o.tpc, o.fpc);
            exp_mask  = model.tos_mask();
            exp_pc    = model.tos_pc();
            exp_sp    = model.sp();
            exp_empty = model.empty();
            exp_full  = model.full();

            if (o.sp     !== exp_sp)    ok = 0;
            if (o.empty  !== exp_empty) ok = 0;
            if (o.full   !== exp_full)  ok = 0;
            if (!exp_empty && (o.tos_mask !== exp_mask)) ok = 0;
            if (!exp_empty && (o.tos_pc   !== exp_pc))   ok = 0;

            if (!ok) begin
                errors++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH %s | exp sp=%0d tos_mask=%b tos_pc=0x%0h empty=%0b full=%0b",
                    o.convert2string(), exp_sp, exp_mask, exp_pc, exp_empty, exp_full))
            end else begin
                matches++;
                `uvm_info("SB", $sformatf("OK %s", o.convert2string()), UVM_HIGH)
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matches > 0)
                `uvm_info("SB", $sformatf("RESULT: *** PASS *** (%0d commands checked)",
                          matches), UVM_NONE)
            else
                `uvm_error("SB", $sformatf("RESULT: *** FAIL *** (%0d errors, %0d ok)",
                           errors, matches))
        endfunction
    endclass

    // =========================================================================
    // Coverage - op x divergence-outcome x depth
    // =========================================================================
    class simt_coverage extends uvm_subscriber #(simt_obs_item);
        `uvm_component_utils(simt_coverage)
        simt_model cov_model;

        bit [1:0] c_op;
        int       c_kind;    // 0 noop, 1 grow, 2 uniform-taken, 3 uniform-fall
        int       c_depth;

        covergroup cg;
            option.per_instance = 1;
            cp_op: coverpoint c_op {
                bins init    = {OP_INIT};
                bins diverge = {OP_DIVERGE};
                bins pop     = {OP_POP};
            }
            cp_kind: coverpoint c_kind {
                bins noop          = {0};
                bins grow          = {1};
                bins uniform_taken = {2};
                bins uniform_fall  = {3};
            }
            cp_depth: coverpoint c_depth {
                bins empty = {0};
                bins one   = {1};
                bins few   = {[2:5]};
                bins deep  = {[6:DEPTH]};
            }
            x_op_depth: cross cp_op, cp_depth;
        endgroup

        function new(string n, uvm_component p);
            super.new(n, p); cov_model = new(); cg = new();
        endfunction

        function void write(simt_obs_item o);
            c_op   = o.op;
            c_kind = cov_model.diverge_kind(o.op, o.in_mask);   // classify vs pre-state
            cov_model.apply(o.op, o.in_mask, o.rpc, o.tpc, o.fpc);
            c_depth = cov_model.sp();
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class simt_vseqr extends uvm_sequencer;
        `uvm_component_utils(simt_vseqr)
        simt_sqr cmd_sqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class simt_env extends uvm_env;
        `uvm_component_utils(simt_env)
        simt_agent      agent;
        simt_scoreboard sb;
        simt_coverage   cov;
        simt_vseqr      vseqr;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            agent = simt_agent     ::type_id::create("agent", this);
            sb    = simt_scoreboard::type_id::create("sb",    this);
            cov   = simt_coverage  ::type_id::create("cov",   this);
            vseqr = simt_vseqr     ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(sb.imp);
            agent.mon.ap.connect(cov.analysis_export);
            vseqr.cmd_sqr = agent.sqr;
        endfunction
    endclass

    // =========================================================================
    // Sequences
    // =========================================================================
    // Directed showcase: launch a warp, diverge it, run both sides, reconverge.
    class simt_showcase_seq extends uvm_sequence #(simt_cmd_item);
        `uvm_object_utils(simt_showcase_seq)
        function new(string n = "simt_showcase_seq"); super.new(n); endfunction

        task send(bit [1:0] o, bit [NLANES-1:0] m,
                  bit [PC_W-1:0] r, bit [PC_W-1:0] t, bit [PC_W-1:0] f);
            simt_cmd_item c = simt_cmd_item::type_id::create("c");
            start_item(c);
            c.op = o; c.in_mask = m; c.rpc = r; c.tpc = t; c.fpc = f;
            finish_item(c);
        endtask

        task body();
            send(OP_INIT,    8'hFF, 16'h0000, 16'h0000, 16'h0010); // launch @0x10
            send(OP_DIVERGE, 8'h0F, 16'h0100, 16'h0200, 16'h0300); // {0..3} take
            send(OP_POP,     8'h00, 0, 0, 0);                      // taken done
            send(OP_POP,     8'h00, 0, 0, 0);                      // fall-thru done
            send(OP_POP,     8'h00, 0, 0, 0);                      // reconverge -> retire
        endtask
    endclass

    // Directed corners: uniform branches, nested divergence, empty warp, pop-empty.
    class simt_corner_seq extends uvm_sequence #(simt_cmd_item);
        `uvm_object_utils(simt_corner_seq)
        function new(string n = "simt_corner_seq"); super.new(n); endfunction

        task send(bit [1:0] o, bit [NLANES-1:0] m,
                  bit [PC_W-1:0] r, bit [PC_W-1:0] t, bit [PC_W-1:0] f);
            simt_cmd_item c = simt_cmd_item::type_id::create("c");
            start_item(c);
            c.op = o; c.in_mask = m; c.rpc = r; c.tpc = t; c.fpc = f;
            finish_item(c);
        endtask

        task body();
            send(OP_INIT,    8'hFF, 0, 0, 16'h0020);
            send(OP_DIVERGE, 8'hFF, 16'h0100, 16'h0500, 16'h0600); // uniform taken
            send(OP_DIVERGE, 8'h00, 16'h0100, 16'h0700, 16'h0800); // uniform fall-thru
            send(OP_DIVERGE, 8'h0F, 16'h0900, 16'h0A00, 16'h0B00); // grow: sp 1->3
            send(OP_DIVERGE, 8'h03, 16'h0C00, 16'h0D00, 16'h0E00); // nested: sp 3->5
            send(OP_POP, 8'h0, 0, 0, 0);
            send(OP_POP, 8'h0, 0, 0, 0);
            send(OP_POP, 8'h0, 0, 0, 0);
            send(OP_POP, 8'h0, 0, 0, 0);
            send(OP_POP, 8'h0, 0, 0, 0);                           // drain to empty
            send(OP_INIT, 8'h00, 0, 0, 16'h0F00);                  // empty-warp launch
            send(OP_POP,  8'h0, 0, 0, 0);                          // pop-past-empty
        endtask
    endclass

    // Constrained-random LEGAL-program generator. Tracks its own depth model to
    // choose legal ops (INIT when empty, avoid the overflow region) and
    // randomizes masks/PCs.
    class simt_random_seq extends uvm_sequence #(simt_cmd_item);
        `uvm_object_utils(simt_random_seq)
        rand int unsigned n_cmds;
        constraint c_n { n_cmds inside {[80:160]}; }
        function new(string n = "simt_random_seq"); super.new(n); endfunction

        task body();
            simt_model m = new();     // local depth/mask model to keep it legal
            m.reset();
            repeat (n_cmds) begin
                simt_cmd_item c = simt_cmd_item::type_id::create("c");
                bit [1:0] chosen;
                if (m.empty())
                    chosen = OP_INIT;
                else if ((m.sp()+2) > DEPTH)
                    chosen = OP_POP;
                else begin
                    int pick = $urandom_range(0, 3);
                    chosen = (pick <= 1) ? OP_DIVERGE : (pick == 2) ? OP_POP : OP_INIT;
                end
                start_item(c);
                if (!c.randomize() with { op == chosen; })
                    `uvm_error("RND", "randomize failed")
                finish_item(c);
                // mirror the accepted command into the local legality model
                if (m.will_accept(c.op, c.in_mask))
                    m.apply(c.op, c.in_mask, c.rpc, c.tpc, c.fpc);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class simt_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(simt_smoke_vseq)
        simt_vseqr vseqr;
        function new(string n = "simt_smoke_vseq"); super.new(n); endfunction
        task body();
            simt_showcase_seq sh  = simt_showcase_seq::type_id::create("sh");
            simt_random_seq   rnd = simt_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.cmd_sqr);
            void'(rnd.randomize() with { n_cmds == 80; });
            rnd.start(vseqr.cmd_sqr);
        endtask
    endclass

    class simt_regress_vseq extends uvm_sequence;
        `uvm_object_utils(simt_regress_vseq)
        simt_vseqr vseqr;
        function new(string n = "simt_regress_vseq"); super.new(n); endfunction
        task body();
            simt_showcase_seq sh  = simt_showcase_seq::type_id::create("sh");
            simt_corner_seq   cor = simt_corner_seq  ::type_id::create("cor");
            simt_random_seq   rnd = simt_random_seq  ::type_id::create("rnd");
            sh.start(vseqr.cmd_sqr);
            cor.start(vseqr.cmd_sqr);
            void'(rnd.randomize() with { n_cmds == 160; });
            rnd.start(vseqr.cmd_sqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class simt_base_test extends uvm_test;
        `uvm_component_utils(simt_base_test)
        simt_env env;
        simt_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction

        function void build_phase(uvm_phase phase);
            cfg = simt_cfg::type_id::create("cfg");
            if (!uvm_config_db#(virtual simt_stack_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(simt_cfg)::set(this, "*", "cfg", cfg);
            env = simt_env::type_id::create("env", this);
        endfunction
    endclass

    class simt_smoke_test extends simt_base_test;
        `uvm_component_utils(simt_smoke_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            simt_smoke_vseq v = simt_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class simt_regress_test extends simt_base_test;
        `uvm_component_utils(simt_regress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            simt_regress_vseq v = simt_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            #300ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
