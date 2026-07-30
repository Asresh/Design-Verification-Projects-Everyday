// -----------------------------------------------------------------------------
// mac_dot_pkg.sv - Complete UVM verification environment for the mac_dot
// GPU tensor-core-style dot-product accumulation engine.
//
// Contents:
//   * mac_item            - operand-element transaction (a, b, last)
//   * mac_result_item     - completed dot-product transaction (result)
//   * mac_seq_base + sequences (showcase / corner / random-length / dbz-free)
//   * mac_sequencer       - operand-element sequencer
//   * mac_driver          - drives (a,b,last) onto the interface
//   * mac_in_monitor      - reconstructs dot-product vectors from the input stream
//   * mac_out_monitor     - captures completed results from the output stream
//   * mac_scoreboard      - golden signed dot-product reference model + checker
//   * mac_coverage        - functional coverage (vector length, signs, zeros, result sign)
//   * mac_agent           - sequencer + driver + input monitor
//   * mac_env             - agent + output monitor + scoreboard + coverage + vseqr
//   * mac_vseqr           - virtual sequencer
//   * virtual sequences   - smoke / regress
//   * tests               - mac_smoke_test / mac_regress_test
//
// A UVM-capable simulator is required (VCS / Questa / Verilator>=5 --uvm).
// Icarus users run the portable companion TB tb_mac_dot_dump.sv instead.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package mac_dot_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Design parameters mirrored here for the reference model / coverage.
    parameter int A_W    = 8;
    parameter int ACC_W  = 32;
    parameter int MAX_L  = 32;   // longest dot product the sequences generate

    // -------------------------------------------------------------------------
    // Transactions
    // -------------------------------------------------------------------------

    // One operand element of a dot product.
    class mac_item extends uvm_sequence_item;
        rand bit signed [A_W-1:0] a;
        rand bit signed [A_W-1:0] b;
        rand bit                  last;   // final element of the current vector

        `uvm_object_utils_begin(mac_item)
            `uvm_field_int(a,    UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(b,    UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(last, UVM_ALL_ON | UVM_BIN)
        `uvm_object_utils_end

        function new(string name = "mac_item");
            super.new(name);
        endfunction
    endclass

    // A completed dot-product result observed on the output stream.
    class mac_result_item extends uvm_sequence_item;
        bit signed [ACC_W-1:0] result;

        `uvm_object_utils_begin(mac_result_item)
            `uvm_field_int(result, UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "mac_result_item");
            super.new(name);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Sequencer
    // -------------------------------------------------------------------------
    typedef uvm_sequencer #(mac_item) mac_sequencer;

    // -------------------------------------------------------------------------
    // Driver
    // -------------------------------------------------------------------------
    class mac_driver extends uvm_driver #(mac_item);
        `uvm_component_utils(mac_driver)

        virtual mac_dot_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual mac_dot_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "mac_dot_if not set for driver")
        endfunction

        task run_phase(uvm_phase phase);
            // idle
            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_a     <= '0;
            vif.drv_cb.in_b     <= '0;
            vif.drv_cb.in_last  <= 1'b0;
            @(posedge vif.clk);
            wait (vif.rst_n === 1'b1);

            forever begin
                mac_item tr;
                seq_item_port.get_next_item(tr);
                @(vif.drv_cb);
                vif.drv_cb.in_valid <= 1'b1;
                vif.drv_cb.in_a     <= tr.a;
                vif.drv_cb.in_b     <= tr.b;
                vif.drv_cb.in_last  <= tr.last;
                @(vif.drv_cb);
                vif.drv_cb.in_valid <= 1'b0;
                vif.drv_cb.in_last  <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Input monitor - reconstructs each dot-product vector and publishes the
    // list of (a,b) pairs so the scoreboard can compute the golden result.
    // -------------------------------------------------------------------------
    class mac_vector_item extends uvm_sequence_item;
        bit signed [A_W-1:0] a[$];
        bit signed [A_W-1:0] b[$];

        `uvm_object_utils(mac_vector_item)
        function new(string name = "mac_vector_item");
            super.new(name);
        endfunction
    endclass

    class mac_in_monitor extends uvm_monitor;
        `uvm_component_utils(mac_in_monitor)

        virtual mac_dot_if vif;
        uvm_analysis_port #(mac_vector_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual mac_dot_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "mac_dot_if not set for in-monitor")
        endfunction

        task run_phase(uvm_phase phase);
            mac_vector_item vec = mac_vector_item::type_id::create("vec");
            forever begin
                @(vif.in_mon_cb);
                if (vif.in_mon_cb.in_valid) begin
                    vec.a.push_back(vif.in_mon_cb.in_a);
                    vec.b.push_back(vif.in_mon_cb.in_b);
                    if (vif.in_mon_cb.in_last) begin
                        ap.write(vec);
                        vec = mac_vector_item::type_id::create("vec");
                    end
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Output monitor - captures every completed result.
    // -------------------------------------------------------------------------
    class mac_out_monitor extends uvm_monitor;
        `uvm_component_utils(mac_out_monitor)

        virtual mac_dot_if vif;
        uvm_analysis_port #(mac_result_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual mac_dot_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "mac_dot_if not set for out-monitor")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(vif.out_mon_cb);
                if (vif.out_mon_cb.out_valid) begin
                    mac_result_item r = mac_result_item::type_id::create("r");
                    r.result = vif.out_mon_cb.out_result;
                    ap.write(r);
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Scoreboard - golden signed dot-product reference model.
    //
    // For every reconstructed input vector it computes the expected result and
    // enqueues it; every observed DUT result is compared against the head of the
    // expected queue. Order is preserved (the engine emits one result per vector,
    // in order). ACC_W-width 2's-complement wraparound matches the DUT exactly.
    // -------------------------------------------------------------------------
    `uvm_analysis_imp_decl(_vec)
    `uvm_analysis_imp_decl(_res)

    class mac_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(mac_scoreboard)

        uvm_analysis_imp_vec #(mac_vector_item, mac_scoreboard) vec_imp;
        uvm_analysis_imp_res #(mac_result_item, mac_scoreboard) res_imp;

        bit signed [ACC_W-1:0] expected_q[$];
        int unsigned checks = 0;
        int unsigned errors = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            vec_imp = new("vec_imp", this);
            res_imp = new("res_imp", this);
        endfunction

        // golden reference: signed dot product with ACC_W-width wraparound
        function bit signed [ACC_W-1:0] golden(mac_vector_item v);
            bit signed [ACC_W-1:0] acc = '0;
            foreach (v.a[i])
                acc = acc + (ACC_W'(signed'(v.a[i])) * ACC_W'(signed'(v.b[i])));
            return acc;
        endfunction

        function void write_vec(mac_vector_item v);
            expected_q.push_back(golden(v));
        endfunction

        function void write_res(mac_result_item r);
            bit signed [ACC_W-1:0] exp;
            checks++;
            if (expected_q.size() == 0) begin
                errors++;
                `uvm_error("SCB", $sformatf("unexpected result %0d (no pending vector)", r.result))
                return;
            end
            exp = expected_q.pop_front();
            if (r.result !== exp) begin
                errors++;
                `uvm_error("SCB", $sformatf("MISMATCH got=%0d exp=%0d", r.result, exp))
            end else begin
                `uvm_info("SCB", $sformatf("OK result=%0d", r.result), UVM_HIGH)
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (expected_q.size() != 0)
                `uvm_error("SCB", $sformatf("%0d vectors never produced a result", expected_q.size()))
            if (errors == 0 && checks > 0)
                `uvm_info("SCB", $sformatf("RESULT: *** PASS *** (%0d results checked)", checks), UVM_NONE)
            else
                `uvm_error("SCB", $sformatf("RESULT: *** FAIL *** (%0d errors / %0d checks)", errors, checks))
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Functional coverage
    // -------------------------------------------------------------------------
    class mac_coverage extends uvm_subscriber #(mac_vector_item);
        `uvm_component_utils(mac_coverage)

        int      cur_len;
        bit      any_neg_a, any_neg_b, any_zero;

        covergroup cg;
            option.per_instance = 1;
            LEN: coverpoint cur_len {
                bins one       = {1};
                bins small[]   = {[2:4]};
                bins medium    = {[5:16]};
                bins large     = {[17:MAX_L]};
            }
            NEG_A: coverpoint any_neg_a;
            NEG_B: coverpoint any_neg_b;
            ZERO:  coverpoint any_zero;
            SIGNS: cross NEG_A, NEG_B;   // both-signs, one-sign, all-positive vectors
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void write(mac_vector_item t);
            cur_len   = t.a.size();
            any_neg_a = 0; any_neg_b = 0; any_zero = 0;
            foreach (t.a[i]) begin
                if (t.a[i] < 0) any_neg_a = 1;
                if (t.b[i] < 0) any_neg_b = 1;
                if (t.a[i] == 0 || t.b[i] == 0) any_zero = 1;
            end
            cg.sample();
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Agent
    // -------------------------------------------------------------------------
    class mac_agent extends uvm_agent;
        `uvm_component_utils(mac_agent)

        mac_sequencer  sqr;
        mac_driver     drv;
        mac_in_monitor mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = mac_sequencer::type_id::create("sqr", this);
            drv = mac_driver   ::type_id::create("drv", this);
            mon = mac_in_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Virtual sequencer
    // -------------------------------------------------------------------------
    class mac_vseqr extends uvm_sequencer;
        `uvm_component_utils(mac_vseqr)
        mac_sequencer sqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Environment
    // -------------------------------------------------------------------------
    class mac_env extends uvm_env;
        `uvm_component_utils(mac_env)

        mac_agent       agt;
        mac_out_monitor omon;
        mac_scoreboard  scb;
        mac_coverage    cov;
        mac_vseqr       vseqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt   = mac_agent      ::type_id::create("agt", this);
            omon  = mac_out_monitor::type_id::create("omon", this);
            scb   = mac_scoreboard ::type_id::create("scb", this);
            cov   = mac_coverage   ::type_id::create("cov", this);
            vseqr = mac_vseqr      ::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agt.mon.ap.connect(scb.vec_imp);
            agt.mon.ap.connect(cov.analysis_export);
            omon.ap.connect(scb.res_imp);
            vseqr.sqr = agt.sqr;
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Element-level sequences
    // -------------------------------------------------------------------------

    // Base: emit one dot-product vector of a given length, marking the last elem.
    class mac_vector_seq extends uvm_sequence #(mac_item);
        `uvm_object_utils(mac_vector_seq)

        rand int unsigned len;
        bit               use_directed = 0;
        bit signed [A_W-1:0] da[$];
        bit signed [A_W-1:0] db[$];

        constraint c_len { len inside {[1:MAX_L]}; }

        function new(string name = "mac_vector_seq");
            super.new(name);
        endfunction

        task body();
            int n = use_directed ? da.size() : len;
            for (int i = 0; i < n; i++) begin
                mac_item it = mac_item::type_id::create("it");
                start_item(it);
                if (use_directed) begin
                    it.a = da[i]; it.b = db[i];
                    it.last = (i == n-1);
                end else begin
                    if (!it.randomize() with { last == (i == n-1); })
                        `uvm_error("RAND", "mac_item randomize failed")
                end
                finish_item(it);
            end
        endtask
    endclass

    // Directed showcase: a small signed vector with a clean, human-readable sum.
    class mac_showcase_seq extends uvm_sequence #(mac_item);
        `uvm_object_utils(mac_showcase_seq)
        function new(string name = "mac_showcase_seq");
            super.new(name);
        endfunction
        task body();
            mac_vector_seq v = mac_vector_seq::type_id::create("v");
            v.use_directed = 1;
            v.da = '{ 3,  5, -2,  4};
            v.db = '{ 2,  4,  7,  1};   // 6 + 20 - 14 + 4 = 16
            v.start(m_sequencer);
        endtask
    endclass

    // Corner cases: length-1, all-zero, all-negative, max-magnitude vectors.
    class mac_corner_seq extends uvm_sequence #(mac_item);
        `uvm_object_utils(mac_corner_seq)
        function new(string name = "mac_corner_seq");
            super.new(name);
        endfunction
        task body();
            mac_vector_seq v;
            // single element
            v = mac_vector_seq::type_id::create("v1");
            v.use_directed = 1; v.da = '{ 7 }; v.db = '{ 6 };
            v.start(m_sequencer);
            // all zeros -> result 0
            v = mac_vector_seq::type_id::create("v2");
            v.use_directed = 1; v.da = '{ 0, 0, 0 }; v.db = '{ 5, 9, 1 };
            v.start(m_sequencer);
            // all negative operands (product all positive)
            v = mac_vector_seq::type_id::create("v3");
            v.use_directed = 1; v.da = '{ -4, -3, -2 }; v.db = '{ -5, -6, -7 };
            v.start(m_sequencer);
            // most-negative * most-negative magnitude stress
            v = mac_vector_seq::type_id::create("v4");
            v.use_directed = 1; v.da = '{ -128, 127 }; v.db = '{ -128, -128 };
            v.start(m_sequencer);
        endtask
    endclass

    // Constrained-random regression of many random-length vectors.
    class mac_random_seq extends uvm_sequence #(mac_item);
        `uvm_object_utils(mac_random_seq)
        rand int unsigned n_vectors;
        constraint c_n { n_vectors inside {[20:60]}; }
        function new(string name = "mac_random_seq");
            super.new(name);
        endfunction
        task body();
            for (int k = 0; k < n_vectors; k++) begin
                mac_vector_seq v = mac_vector_seq::type_id::create("v");
                if (!v.randomize())
                    `uvm_error("RAND", "mac_vector_seq randomize failed")
                v.start(m_sequencer);
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Virtual sequences
    // -------------------------------------------------------------------------
    class mac_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(mac_smoke_vseq)
        function new(string name = "mac_smoke_vseq");
            super.new(name);
        endfunction
        task body();
            mac_vseqr vs;
            mac_showcase_seq sh;
            mac_corner_seq   co;
            if (!$cast(vs, m_sequencer))
                `uvm_fatal("VSEQ", "smoke vseq needs a mac_vseqr");
            sh = mac_showcase_seq::type_id::create("sh");
            co = mac_corner_seq  ::type_id::create("co");
            sh.start(vs.sqr);
            co.start(vs.sqr);
        endtask
    endclass

    class mac_regress_vseq extends uvm_sequence;
        `uvm_object_utils(mac_regress_vseq)
        function new(string name = "mac_regress_vseq");
            super.new(name);
        endfunction
        task body();
            mac_vseqr vs;
            mac_showcase_seq sh;
            mac_corner_seq   co;
            mac_random_seq   rn;
            if (!$cast(vs, m_sequencer))
                `uvm_fatal("VSEQ", "regress vseq needs a mac_vseqr");
            sh = mac_showcase_seq::type_id::create("sh");
            co = mac_corner_seq  ::type_id::create("co");
            rn = mac_random_seq  ::type_id::create("rn");
            sh.start(vs.sqr);
            co.start(vs.sqr);
            rn.start(vs.sqr);
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------
    class mac_base_test extends uvm_test;
        `uvm_component_utils(mac_base_test)
        mac_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = mac_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class mac_smoke_test extends mac_base_test;
        `uvm_component_utils(mac_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            mac_smoke_vseq vseq = mac_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class mac_regress_test extends mac_base_test;
        `uvm_component_utils(mac_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            mac_regress_vseq vseq = mac_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            #500ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
