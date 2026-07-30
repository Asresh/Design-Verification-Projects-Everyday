// ============================================================================
// seq_divider_pkg.sv - UVM verification environment for `seq_divider`.
//
// A complete, layered UVM 1.2 environment for the multi-cycle restoring
// divider:
//
//   * a sequence item `div_txn` (a randomized {dividend, divisor} request plus
//     the captured {quotient, remainder, dbz} result),
//   * an active DIVIDER agent with driver + monitor + sequencer:
//       - driver : honors the start/busy handshake, issues one-cycle `start`
//         pulses with operands, and waits for `done`,
//       - monitor: independently snapshots operands as a request is accepted
//         and the registered result when `done` pulses,
//   * a golden reference-model SCOREBOARD that recomputes quotient/remainder
//     with SystemVerilog `/` and `%` (and the explicit x/0 convention) and
//     also re-derives the identity dividend == q*divisor + r,
//   * a functional COVERAGE subscriber (operand magnitude buckets, the
//     divide-by-zero case, the a<b -> quotient==0 case, and their crosses),
//   * layered sequences (directed corners + showcase, divide-by-zero stress,
//     constrained-random) and a VIRTUAL SEQUENCER driving smoke / regress
//     virtual sequences,
//   * a base test plus smoke / regress tests selected by +UVM_TESTNAME.
//
// Icarus Verilog does not implement UVM; build this with VCS / Questa /
// Verilator (see the Makefile). The portable Icarus-runnable self-checking
// companion lives in tb_seq_divider_dump.sv.
// ============================================================================
`timescale 1ns/1ps

package seq_divider_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int WIDTH = 8;

    // ====================================================================
    // Sequence item.
    // ====================================================================
    class div_txn extends uvm_sequence_item;
        rand bit [WIDTH-1:0] dividend;
        rand bit [WIDTH-1:0] divisor;
        // Result, filled in by the monitor.
        bit      [WIDTH-1:0] quotient;
        bit      [WIDTH-1:0] remainder;
        bit                  dbz;

        // Bias toward legal (non-zero) divisors but keep divide-by-zero live.
        constraint c_div { divisor dist { 0 := 1, [1:255] := 15 }; }

        `uvm_object_utils_begin(div_txn)
            `uvm_field_int(dividend,  UVM_ALL_ON)
            `uvm_field_int(divisor,   UVM_ALL_ON)
            `uvm_field_int(quotient,  UVM_ALL_ON)
            `uvm_field_int(remainder, UVM_ALL_ON)
            `uvm_field_int(dbz,       UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "div_txn");
            super.new(name);
        endfunction
    endclass

    // ====================================================================
    // Sequencer.
    // ====================================================================
    typedef uvm_sequencer #(div_txn) div_sequencer;

    // ====================================================================
    // Sequences.
    // ====================================================================
    // Directed: the README showcase plus the classic corner cases.
    class div_directed_seq extends uvm_sequence #(div_txn);
        `uvm_object_utils(div_directed_seq)
        function new(string name = "div_directed_seq"); super.new(name); endfunction

        task automatic one(bit [WIDTH-1:0] a, bit [WIDTH-1:0] b, string tag);
            div_txn t = div_txn::type_id::create(tag);
            start_item(t);
            if (!t.randomize() with { dividend == a; divisor == b; })
                `uvm_error("SEQ", $sformatf("directed randomize failed (%s)", tag))
            finish_item(t);
        endtask

        virtual task body();
            one(8'd200, 8'd7,   "showcase");   // 28 r4
            one(8'd0,   8'd5,   "zero_div");    // 0  r0
            one(8'd13,  8'd1,   "div_by_1");    // 13 r0
            one(8'd5,   8'd9,   "a_lt_b");      // 0  r5
            one(8'd255, 8'd255, "max_max");     // 1  r0
            one(8'd255, 8'd1,   "max_by_1");    // 255 r0
            one(8'd42,  8'd0,   "dbz_a");       // x/0 -> dbz
            one(8'd128, 8'd0,   "dbz_b");       // x/0 -> dbz
        endtask
    endclass

    // Divide-by-zero stress: many x/0 requests (all must raise dbz).
    class div_zero_seq extends uvm_sequence #(div_txn);
        `uvm_object_utils(div_zero_seq)
        rand int unsigned n_txn = 8;
        function new(string name = "div_zero_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n_txn) begin
                div_txn t = div_txn::type_id::create("dbz");
                start_item(t);
                if (!t.randomize() with { divisor == 0; })
                    `uvm_error("SEQ", "dbz randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Constrained-random regression across the full operand space.
    class div_random_seq extends uvm_sequence #(div_txn);
        `uvm_object_utils(div_random_seq)
        rand int unsigned n_txn = 60;
        constraint c_n { n_txn inside {[40:120]}; }
        function new(string name = "div_random_seq"); super.new(name); endfunction
        virtual task body();
            repeat (n_txn) begin
                div_txn t = div_txn::type_id::create("rnd");
                start_item(t);
                if (!t.randomize())
                    `uvm_error("SEQ", "random randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // ====================================================================
    // Driver - honors the start/busy handshake.
    // ====================================================================
    class div_driver extends uvm_driver #(div_txn);
        `uvm_component_utils(div_driver)
        virtual seq_divider_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual seq_divider_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "driver: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.drv_cb.start    <= 1'b0;
            vif.drv_cb.dividend <= '0;
            vif.drv_cb.divisor  <= '0;
            @(posedge vif.rst_n);
            forever begin
                div_txn t;
                seq_item_port.get_next_item(t);
                // Wait until the DUT is idle before starting a new division.
                while (vif.drv_cb.busy) @(vif.drv_cb);
                vif.drv_cb.dividend <= t.dividend;
                vif.drv_cb.divisor  <= t.divisor;
                vif.drv_cb.start    <= 1'b1;
                @(vif.drv_cb);
                vif.drv_cb.start    <= 1'b0;
                // Wait for the one-cycle done pulse.
                do @(vif.drv_cb); while (!vif.drv_cb.done);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ====================================================================
    // Monitor - independently reconstructs each transaction from the pins.
    // ====================================================================
    class div_monitor extends uvm_component;
        `uvm_component_utils(div_monitor)
        virtual seq_divider_if vif;
        uvm_analysis_port #(div_txn) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual seq_divider_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "monitor: no vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            @(posedge vif.rst_n);
            forever begin
                div_txn t = div_txn::type_id::create("mon");
                // Capture operands on the cycle a request is accepted.
                do @(vif.mon_cb); while (!(vif.mon_cb.start && !vif.mon_cb.busy));
                t.dividend = vif.mon_cb.dividend;
                t.divisor  = vif.mon_cb.divisor;
                // Capture the registered result at `done`.
                do @(vif.mon_cb); while (!vif.mon_cb.done);
                t.quotient  = vif.mon_cb.quotient;
                t.remainder = vif.mon_cb.remainder;
                t.dbz       = vif.mon_cb.dbz;
                ap.write(t);
            end
        endtask
    endclass

    // ====================================================================
    // Agent.
    // ====================================================================
    class div_agent extends uvm_agent;
        `uvm_component_utils(div_agent)
        div_sequencer sqr;
        div_driver    drv;
        div_monitor   mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = div_sequencer::type_id::create("sqr", this);
            drv = div_driver   ::type_id::create("drv", this);
            mon = div_monitor  ::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ====================================================================
    // Scoreboard - golden reference model.
    //   Recomputes the expected quotient/remainder/dbz and, for non-x/0 cases,
    //   independently re-checks the fundamental identity
    //       dividend == quotient*divisor + remainder,  0 <= remainder < divisor
    // ====================================================================
    class div_scoreboard extends uvm_subscriber #(div_txn);
        `uvm_component_utils(div_scoreboard)
        int matched = 0, errors = 0;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void write(div_txn t);
            bit [WIDTH-1:0] eq, er;
            bit             ez;
            matched++;

            if (t.divisor == '0) begin
                ez = 1'b1;  eq = '1;  er = t.dividend;
            end else begin
                ez = 1'b0;  eq = t.dividend / t.divisor;  er = t.dividend % t.divisor;
            end

            if (t.quotient !== eq || t.remainder !== er || t.dbz !== ez) begin
                errors++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH %0d/%0d: got q=%0d r=%0d dbz=%0b  exp q=%0d r=%0d dbz=%0b",
                    t.dividend, t.divisor, t.quotient, t.remainder, t.dbz, eq, er, ez))
            end

            // Fundamental identity re-check for legal divisions.
            if (!ez) begin
                if ((t.quotient * t.divisor + t.remainder) !== t.dividend) begin
                    errors++;
                    `uvm_error("SB", $sformatf(
                        "IDENTITY FAIL %0d/%0d: q*d+r=%0d != %0d",
                        t.dividend, t.divisor,
                        t.quotient * t.divisor + t.remainder, t.dividend))
                end
                if (t.remainder >= t.divisor) begin
                    errors++;
                    `uvm_error("SB", $sformatf(
                        "REMAINDER OOR %0d/%0d: r=%0d >= divisor",
                        t.dividend, t.divisor, t.remainder))
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (errors == 0 && matched > 0)
                `uvm_info("SB", $sformatf(
                    "RESULT: *** PASS *** (%0d divisions checked)", matched), UVM_NONE)
            else
                `uvm_error("SB", $sformatf(
                    "RESULT: *** FAIL *** (matched=%0d errors=%0d)", matched, errors))
        endfunction
    endclass

    // ====================================================================
    // Functional coverage.
    // ====================================================================
    class div_coverage extends uvm_subscriber #(div_txn);
        `uvm_component_utils(div_coverage)
        div_txn tr;

        covergroup cg;
            cp_dividend : coverpoint tr.dividend {
                bins zero = {0};
                bins lo   = {[1:63]};
                bins mid  = {[64:191]};
                bins hi   = {[192:255]};
            }
            cp_divisor : coverpoint tr.divisor {
                bins zero = {0};
                bins one  = {1};
                bins lo   = {[2:63]};
                bins mid  = {[64:191]};
                bins hi   = {[192:255]};
            }
            cp_dbz  : coverpoint tr.dbz { bins clr = {0}; bins set = {1}; }
            cp_qz   : coverpoint (tr.divisor != 0 && tr.quotient == 0) {
                bins qzero = {1}; bins qnz = {0};
            }   // exercises the a < b (quotient == 0) path
            x_od : cross cp_dividend, cp_divisor;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent); cg = new();
        endfunction
        function void write(div_txn t);
            tr = t; cg.sample();
        endfunction
    endclass

    // ====================================================================
    // Virtual sequencer.
    // ====================================================================
    class div_vsequencer extends uvm_sequencer;
        `uvm_component_utils(div_vsequencer)
        div_sequencer div_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // ====================================================================
    // Environment.
    // ====================================================================
    class div_env extends uvm_env;
        `uvm_component_utils(div_env)
        div_agent        agt;
        div_scoreboard   sb;
        div_coverage     cov;
        div_vsequencer   vsqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            agt  = div_agent     ::type_id::create("agt",  this);
            sb   = div_scoreboard::type_id::create("sb",   this);
            cov  = div_coverage  ::type_id::create("cov",  this);
            vsqr = div_vsequencer::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agt.mon.ap.connect(sb.analysis_export);
            agt.mon.ap.connect(cov.analysis_export);
            vsqr.div_sqr = agt.sqr;
        endfunction
    endclass

    // ====================================================================
    // Virtual sequences.
    // ====================================================================
    class div_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(div_smoke_vseq)
        function new(string name = "div_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            div_vsequencer   v;
            div_directed_seq ds = div_directed_seq::type_id::create("ds");
            if (!$cast(v, m_sequencer)) `uvm_fatal("VSEQ", "not a vsequencer");
            ds.start(v.div_sqr);
        endtask
    endclass

    class div_regress_vseq extends uvm_sequence;
        `uvm_object_utils(div_regress_vseq)
        function new(string name = "div_regress_vseq"); super.new(name); endfunction
        virtual task body();
            div_vsequencer   v;
            div_directed_seq ds = div_directed_seq::type_id::create("ds");
            div_zero_seq     zs = div_zero_seq    ::type_id::create("zs");
            div_random_seq   rs = div_random_seq  ::type_id::create("rs");
            if (!$cast(v, m_sequencer)) `uvm_fatal("VSEQ", "not a vsequencer");
            if (!rs.randomize()) `uvm_error("VSEQ", "rs randomize failed");
            ds.start(v.div_sqr);   // directed corners + showcase
            zs.start(v.div_sqr);   // divide-by-zero stress
            rs.start(v.div_sqr);   // constrained-random regression
        endtask
    endclass

    // ====================================================================
    // Tests.
    // ====================================================================
    class div_base_test extends uvm_test;
        `uvm_component_utils(div_base_test)
        div_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            env = div_env::type_id::create("env", this);
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class div_smoke_test extends div_base_test;
        `uvm_component_utils(div_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            div_smoke_vseq vseq = div_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.drop_objection(this);
        endtask
    endclass

    class div_regress_test extends div_base_test;
        `uvm_component_utils(div_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        virtual task run_phase(uvm_phase phase);
            div_regress_vseq vseq = div_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vsqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
