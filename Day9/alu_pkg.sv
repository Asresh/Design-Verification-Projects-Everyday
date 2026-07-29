// ============================================================================
// alu_pkg.sv - full UVM verification environment for the registered ALU.
//
// This is the primary deliverable: a complete UVM-1.2 testbench with a
// transaction, layered sequences, a driver, a monitor, an agent, an
// independent golden reference-model scoreboard, a functional-coverage
// collector, a virtual sequencer, and virtual sequences, wired up by an env
// and a small hierarchy of tests.
//
//   sequence(s) -> sequencer -> driver -> alu_if -> DUT
//                                              |
//                              monitor <-------+  (samples request + response)
//                                 |
//                 +---------------+---------------+
//                 v                               v
//            scoreboard (golden model)      coverage collector
//
//   virtual_sequencer -> {alu_sequencer}      (multi-sequence orchestration)
//
// Icarus Verilog does not implement UVM, so this package is compiled by a
// UVM-capable simulator (VCS/Questa/Verilator>=5 --uvm). See the Makefile.
// The portable, self-checking companion testbench that runs under Icarus and
// produces the committed waveform is tb_alu_dump.sv.
// ============================================================================
`ifndef ALU_PKG_SV
`define ALU_PKG_SV

package alu_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- shared opcode encoding -------------------------------------------
    typedef enum logic [3:0] {
        OP_ADD = 4'h0, OP_SUB = 4'h1, OP_AND = 4'h2, OP_OR  = 4'h3,
        OP_XOR = 4'h4, OP_SLL = 4'h5, OP_SRL = 4'h6, OP_SLT = 4'h7
    } alu_op_e;

    parameter int ALU_WIDTH = 8;
    parameter int ALU_SHW   = 3;           // $clog2(8)

    // =======================================================================
    // Transaction
    // =======================================================================
    class alu_txn extends uvm_sequence_item;
        // request
        rand alu_op_e            op;
        rand logic [ALU_WIDTH-1:0] a;
        rand logic [ALU_WIDTH-1:0] b;
        // response (filled by the monitor for observed transactions)
        logic [ALU_WIDTH-1:0]    result;
        logic                    zero, carry, overflow, negative;

        `uvm_object_utils_begin(alu_txn)
            `uvm_field_enum(alu_op_e, op, UVM_ALL_ON)
            `uvm_field_int(a,        UVM_ALL_ON)
            `uvm_field_int(b,        UVM_ALL_ON)
            `uvm_field_int(result,   UVM_ALL_ON)
            `uvm_field_int(zero,     UVM_ALL_ON)
            `uvm_field_int(carry,    UVM_ALL_ON)
            `uvm_field_int(overflow, UVM_ALL_ON)
            `uvm_field_int(negative, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "alu_txn");
            super.new(name);
        endfunction

        // Keep the whole opcode space legal and uniformly weighted.
        constraint c_op { op inside {OP_ADD, OP_SUB, OP_AND, OP_OR,
                                     OP_XOR, OP_SLL, OP_SRL, OP_SLT}; }
    endclass

    // =======================================================================
    // Golden reference model - the executable specification, kept in ONE place
    // so the scoreboard and any check reuse identical logic.
    // =======================================================================
    class alu_ref_model extends uvm_object;
        `uvm_object_utils(alu_ref_model)
        function new(string name = "alu_ref_model"); super.new(name); endfunction

        function void predict(input alu_txn t,
                              output logic [ALU_WIDTH-1:0] res,
                              output logic zero_f, output logic carry_f,
                              output logic ovf_f,  output logic neg_f);
            logic [ALU_WIDTH:0] ext;
            res = '0; carry_f = 1'b0; ovf_f = 1'b0;
            case (t.op)
                OP_ADD: begin
                    ext     = {1'b0, t.a} + {1'b0, t.b};
                    res     = ext[ALU_WIDTH-1:0];
                    carry_f = ext[ALU_WIDTH];
                    ovf_f   = (t.a[ALU_WIDTH-1] == t.b[ALU_WIDTH-1]) &&
                              (res[ALU_WIDTH-1] != t.a[ALU_WIDTH-1]);
                end
                OP_SUB: begin
                    ext     = {1'b0, t.a} - {1'b0, t.b};
                    res     = ext[ALU_WIDTH-1:0];
                    carry_f = ext[ALU_WIDTH];           // unsigned borrow (a<b)
                    ovf_f   = (t.a[ALU_WIDTH-1] != t.b[ALU_WIDTH-1]) &&
                              (res[ALU_WIDTH-1] != t.a[ALU_WIDTH-1]);
                end
                OP_AND: res = t.a & t.b;
                OP_OR:  res = t.a | t.b;
                OP_XOR: res = t.a ^ t.b;
                OP_SLL: res = t.a << t.b[ALU_SHW-1:0];
                OP_SRL: res = t.a >> t.b[ALU_SHW-1:0];
                OP_SLT: res = ($signed(t.a) < $signed(t.b))
                              ? {{(ALU_WIDTH-1){1'b0}}, 1'b1} : '0;
                default: res = '0;
            endcase
            zero_f = (res == '0);
            neg_f  = res[ALU_WIDTH-1];
        endfunction
    endclass

    // =======================================================================
    // Sequences (request layer)
    // =======================================================================
    typedef uvm_sequencer #(alu_txn) alu_sequencer;

    // Fully random N-transaction stream.
    class alu_random_seq extends uvm_sequence #(alu_txn);
        `uvm_object_utils(alu_random_seq)
        rand int unsigned n = 200;
        constraint c_n { n inside {[50:400]}; }
        function new(string name = "alu_random_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n) begin
                `uvm_do(req)
            end
        endtask
    endclass

    // Directed sweep: every opcode at least once with meaningful operands.
    class alu_directed_seq extends uvm_sequence #(alu_txn);
        `uvm_object_utils(alu_directed_seq)
        function new(string name = "alu_directed_seq"); super.new(name); endfunction
        task one(alu_op_e op, logic [ALU_WIDTH-1:0] a, logic [ALU_WIDTH-1:0] b);
            `uvm_do_with(req, {req.op == op; req.a == a; req.b == b;})
        endtask
        virtual task body();
            one(OP_ADD, 8'hF0, 8'h20);   // carry-out
            one(OP_SUB, 8'h10, 8'h20);   // borrow
            one(OP_ADD, 8'h50, 8'h50);   // signed overflow
            one(OP_AND, 8'hF0, 8'h0F);   // zero
            one(OP_OR,  8'h81, 8'h12);   // negative
            one(OP_XOR, 8'hFF, 8'h0F);
            one(OP_SLL, 8'h01, 8'h04);
            one(OP_SRL, 8'h80, 8'h03);
            one(OP_SLT, 8'hFF, 8'h01);   // signed -1 < 1
        endtask
    endclass

    // Corner-case seq: bias toward flag-raising operands (all-ones, zero,
    // sign boundaries) to hit carry/overflow/zero coverage quickly.
    class alu_corner_seq extends uvm_sequence #(alu_txn);
        `uvm_object_utils(alu_corner_seq)
        rand int unsigned n = 60;
        function new(string name = "alu_corner_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n) begin
                `uvm_do_with(req, {
                    req.a inside {8'h00, 8'h01, 8'h7F, 8'h80, 8'hFF,
                                  [8'h00:8'hFF]};
                    req.b inside {8'h00, 8'h01, 8'h7F, 8'h80, 8'hFF,
                                  [8'h00:8'hFF]};
                    req.op inside {OP_ADD, OP_SUB, OP_SLT};
                })
            end
        endtask
    endclass

    // =======================================================================
    // Driver - drives one request per clock through alu_if.
    // =======================================================================
    class alu_driver extends uvm_driver #(alu_txn);
        `uvm_component_utils(alu_driver)
        virtual alu_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual alu_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "virtual interface 'vif' not set")
        endfunction

        virtual task run_phase(uvm_phase phase);
            // idle until reset released
            vif.in_valid <= 1'b0;
            vif.opcode   <= '0;
            vif.a        <= '0;
            vif.b        <= '0;
            @(posedge vif.rst_n);
            forever begin
                alu_txn t;
                seq_item_port.get_next_item(t);
                @(posedge vif.clk);
                vif.in_valid <= 1'b1;
                vif.opcode   <= t.op;
                vif.a        <= t.a;
                vif.b        <= t.b;
                seq_item_port.item_done();
                // one-shot: drop valid if no back-to-back item is queued
                if (!seq_item_port.has_do_available()) begin
                    @(posedge vif.clk);
                    vif.in_valid <= 1'b0;
                end
            end
        endtask
    endclass

    // =======================================================================
    // Monitor - reconstructs request and response transactions and broadcasts
    // them on separate analysis ports.
    // =======================================================================
    class alu_monitor extends uvm_component;
        `uvm_component_utils(alu_monitor)
        virtual alu_if vif;
        uvm_analysis_port #(alu_txn) req_ap;   // observed requests
        uvm_analysis_port #(alu_txn) rsp_ap;   // observed responses

        function new(string name, uvm_component parent);
            super.new(name, parent);
            req_ap = new("req_ap", this);
            rsp_ap = new("rsp_ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual alu_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "virtual interface 'vif' not set")
        endfunction

        virtual task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n) begin
                    if (vif.in_valid) begin
                        alu_txn rq = alu_txn::type_id::create("rq");
                        rq.op = alu_op_e'(vif.opcode);
                        rq.a  = vif.a;
                        rq.b  = vif.b;
                        req_ap.write(rq);
                    end
                    if (vif.out_valid) begin
                        alu_txn rs = alu_txn::type_id::create("rs");
                        rs.result   = vif.result;
                        rs.zero     = vif.zero;
                        rs.carry    = vif.carry;
                        rs.overflow = vif.overflow;
                        rs.negative = vif.negative;
                        rsp_ap.write(rs);
                    end
                end
            end
        endtask
    endclass

    // =======================================================================
    // Agent
    // =======================================================================
    class alu_agent extends uvm_agent;
        `uvm_component_utils(alu_agent)
        alu_driver    drv;
        alu_monitor   mon;
        alu_sequencer sqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = alu_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = alu_driver::type_id::create("drv", this);
                sqr = alu_sequencer::type_id::create("sqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =======================================================================
    // Scoreboard - golden reference-model checker.
    //   * req stream  -> compute golden, push to expected FIFO
    //   * rsp stream  -> pop, compare result + all four flags
    // =======================================================================
    `uvm_analysis_imp_decl(_req)
    `uvm_analysis_imp_decl(_rsp)

    class alu_scoreboard extends uvm_component;
        `uvm_component_utils(alu_scoreboard)
        uvm_analysis_imp_req #(alu_txn, alu_scoreboard) req_imp;
        uvm_analysis_imp_rsp #(alu_txn, alu_scoreboard) rsp_imp;

        alu_ref_model ref_model;
        alu_txn       expected_q[$];
        int           matched = 0;
        int           mismatched = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            req_imp = new("req_imp", this);
            rsp_imp = new("rsp_imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ref_model = alu_ref_model::type_id::create("ref_model");
        endfunction

        // Each observed request becomes a golden expected response.
        function void write_req(alu_txn t);
            alu_txn e = alu_txn::type_id::create("exp");
            logic [ALU_WIDTH-1:0] res; logic zf, cf, of, nf;
            e.op = t.op; e.a = t.a; e.b = t.b;
            ref_model.predict(t, res, zf, cf, of, nf);
            e.result = res; e.zero = zf; e.carry = cf;
            e.overflow = of; e.negative = nf;
            expected_q.push_back(e);
        endfunction

        // Each observed response is checked against the oldest expectation.
        function void write_rsp(alu_txn r);
            alu_txn e;
            if (expected_q.size() == 0) begin
                `uvm_error("SCB", "response with no matching expected transaction")
                mismatched++;
                return;
            end
            e = expected_q.pop_front();
            if ((r.result   !== e.result)  || (r.zero     !== e.zero) ||
                (r.carry    !== e.carry)   || (r.overflow !== e.overflow) ||
                (r.negative !== e.negative)) begin
                mismatched++;
                `uvm_error("SCB", $sformatf(
                    "MISMATCH op=%s a=%02h b=%02h : DUT res=%02h z=%b c=%b v=%b n=%b | EXP res=%02h z=%b c=%b v=%b n=%b",
                    e.op.name(), e.a, e.b,
                    r.result, r.zero, r.carry, r.overflow, r.negative,
                    e.result, e.zero, e.carry, e.overflow, e.negative))
            end else begin
                matched++;
                `uvm_info("SCB", $sformatf("MATCH op=%s a=%02h b=%02h -> res=%02h z=%b c=%b v=%b n=%b",
                    e.op.name(), e.a, e.b, r.result, r.zero, r.carry,
                    r.overflow, r.negative), UVM_HIGH)
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (expected_q.size() != 0)
                `uvm_error("SCB", $sformatf("%0d expected responses never observed",
                                            expected_q.size()))
        endfunction

        function void report_phase(uvm_phase phase);
            if (mismatched == 0 && matched > 0 && expected_q.size() == 0)
                `uvm_info("SCB", $sformatf(
                    "checks=%0d  RESULT: *** PASS ***", matched), UVM_LOW)
            else
                `uvm_error("SCB", $sformatf(
                    "checks=%0d mismatches=%0d leftover=%0d  RESULT: *** FAIL ***",
                    matched, mismatched, expected_q.size()))
        endfunction
    endclass

    // =======================================================================
    // Functional coverage collector - subscribes to the observed request
    // stream (paired with the scoreboard's golden flags for cross coverage).
    // =======================================================================
    class alu_coverage extends uvm_subscriber #(alu_txn);
        `uvm_component_utils(alu_coverage)
        alu_ref_model ref_model;

        alu_op_e             cg_op;
        logic [ALU_WIDTH-1:0] cg_a, cg_b, cg_res;
        logic                cg_zero, cg_carry, cg_ovf, cg_neg;

        covergroup cg;
            option.per_instance = 1;
            // every opcode exercised
            cp_op: coverpoint cg_op;
            // operand corner buckets
            cp_a: coverpoint cg_a {
                bins zero   = {8'h00};
                bins one    = {8'h01};
                bins smax   = {8'h7F};
                bins smin   = {8'h80};
                bins allone = {8'hFF};
                bins mid[8] = {[8'h02:8'h7E]};
            }
            cp_b: coverpoint cg_b {
                bins zero   = {8'h00};
                bins one    = {8'h01};
                bins smax   = {8'h7F};
                bins smin   = {8'h80};
                bins allone = {8'hFF};
                bins mid[8] = {[8'h02:8'h7E]};
            }
            // every flag seen both set and clear
            cp_zero:  coverpoint cg_zero;
            cp_carry: coverpoint cg_carry;
            cp_ovf:   coverpoint cg_ovf;
            cp_neg:   coverpoint cg_neg;
            // interesting crosses
            x_op_carry: cross cp_op, cp_carry;
            x_op_ovf:   cross cp_op, cp_ovf;
            x_op_zero:  cross cp_op, cp_zero;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ref_model = alu_ref_model::type_id::create("cov_ref");
        endfunction

        function void write(alu_txn t);
            logic [ALU_WIDTH-1:0] res; logic zf, cf, of, nf;
            ref_model.predict(t, res, zf, cf, of, nf);
            cg_op = t.op; cg_a = t.a; cg_b = t.b; cg_res = res;
            cg_zero = zf; cg_carry = cf; cg_ovf = of; cg_neg = nf;
            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("functional coverage = %0.2f%%",
                                       cg.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // =======================================================================
    // Virtual sequencer - handle(s) to the leaf sequencer(s). With a single
    // agent it holds one handle, but the structure scales to multi-agent DVs.
    // =======================================================================
    class alu_vsequencer extends uvm_sequencer;
        `uvm_component_utils(alu_vsequencer)
        alu_sequencer alu_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // =======================================================================
    // Environment
    // =======================================================================
    class alu_env extends uvm_env;
        `uvm_component_utils(alu_env)
        alu_agent       agent;
        alu_scoreboard  scb;
        alu_coverage    cov;
        alu_vsequencer  vsqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = alu_agent::type_id::create("agent", this);
            scb   = alu_scoreboard::type_id::create("scb", this);
            cov   = alu_coverage::type_id::create("cov", this);
            vsqr  = alu_vsequencer::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.req_ap.connect(scb.req_imp);
            agent.mon.rsp_ap.connect(scb.rsp_imp);
            agent.mon.req_ap.connect(cov.analysis_export);
            vsqr.alu_sqr = agent.sqr;
        endfunction
    endclass

    // =======================================================================
    // Virtual sequences - orchestrate leaf sequences on the alu_sequencer.
    // =======================================================================
    class alu_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(alu_smoke_vseq)
        alu_vsequencer vsqr;
        function new(string name = "alu_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            alu_directed_seq dseq = alu_directed_seq::type_id::create("dseq");
            dseq.start(vsqr.alu_sqr);
        endtask
    endclass

    class alu_regress_vseq extends uvm_sequence;
        `uvm_object_utils(alu_regress_vseq)
        alu_vsequencer vsqr;
        function new(string name = "alu_regress_vseq"); super.new(name); endfunction
        virtual task body();
            alu_directed_seq dseq = alu_directed_seq::type_id::create("dseq");
            alu_corner_seq   cseq = alu_corner_seq::type_id::create("cseq");
            alu_random_seq   rseq = alu_random_seq::type_id::create("rseq");
            dseq.start(vsqr.alu_sqr);
            cseq.start(vsqr.alu_sqr);
            void'(rseq.randomize() with { n == 300; });
            rseq.start(vsqr.alu_sqr);
        endtask
    endclass

    // =======================================================================
    // Tests
    // =======================================================================
    class alu_base_test extends uvm_test;
        `uvm_component_utils(alu_base_test)
        alu_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = alu_env::type_id::create("env", this);
            // active agent by default
            uvm_config_db#(uvm_active_passive_enum)::set(this, "env.agent",
                                                         "is_active", UVM_ACTIVE);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class alu_smoke_test extends alu_base_test;
        `uvm_component_utils(alu_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            alu_smoke_vseq vseq = alu_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.vsqr = env.vsqr;
            vseq.start(env.vsqr);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class alu_regress_test extends alu_base_test;
        `uvm_component_utils(alu_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            alu_regress_vseq vseq = alu_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.vsqr = env.vsqr;
            vseq.start(env.vsqr);
            #400ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
`endif
