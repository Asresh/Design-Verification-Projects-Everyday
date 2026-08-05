// ============================================================================
// fp32_add_pkg.sv - the UVM verification environment for the Day28 IEEE-754
//                   binary32 floating-point adder / subtractor.
// ----------------------------------------------------------------------------
// Topology
//
//   +--------------------------- fp_env -----------------------------------+
//   |                                                                      |
//   |  fp_vsequencer  (virtual sequences run here)                         |
//   |        |                                                             |
//   |        v                                                             |
//   |  +---------------- fp_agent ----------------+                        |
//   |  |  fp_sequencer -> fp_driver --> DUT pins  |                        |
//   |  |  fp_monitor  (ap_req, ap_rsp)            |                        |
//   |  +------------------------------------------+                        |
//   |        |  ap_req                 |  ap_rsp                           |
//   |        v                         v                                   |
//   |  +------------------ fp_scoreboard ---------------+                  |
//   |  |  pending-request FIFO  +  fp32_ref_pkg::fp_ref |                  |
//   |  |  checks z + {inv,ovf,unf,inx} in arrival order |                  |
//   |  +------------------------------------------------+                  |
//   |                        | ap_cov  (request paired with its result)    |
//   |                        v                                            |
//   |                  fp_coverage  (functional coverage)                 |
//   +----------------------------------------------------------------------+
//
// Why the coverage collector sits downstream of the scoreboard: crossing an
// OPERAND class with the RESULT class requires the request and the result to be
// paired, and the scoreboard already owns that pairing (it is the component
// that has to do it in order to check anything). Re-deriving it in a second
// subscriber would mean two copies of the same pairing logic that could drift
// apart, so the scoreboard republishes each fully-resolved transaction instead.
//
// The golden model itself lives in fp32_ref_pkg (shared with the portable
// Icarus testbench) and is self-checked against 48 numpy-generated
// Known-Answer vectors in start_of_simulation_phase - before it is allowed to
// judge a single DUT result.
//
// Requires a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm).
// For the open-source Icarus flow use tb_fp32_add_dump.sv (see the Makefile).
// ============================================================================
`timescale 1ns/1ps

package fp32_add_pkg;

    import uvm_pkg::*;
    import fp32_ref_pkg::*;
`include "uvm_macros.svh"

    // Two analysis imps into one scoreboard: one for requests, one for results.
    `uvm_analysis_imp_decl(_req)
    `uvm_analysis_imp_decl(_rsp)

    // ==================================================================
    // Transaction
    // ==================================================================
    // How the randomisation is shaped: raw uniform 32-bit operands almost never
    // land on anything interesting (a uniform bit pattern is a huge-exponent
    // normal ~99% of the time). So the fields are randomised as sign/exponent/
    // mantissa with a `kind` knob that steers each item into one of the regions
    // where floating-point addition actually goes wrong, and the packed words
    // are assembled in post_randomize().
    typedef enum bit [2:0] {
        KIND_ANY       = 3'd0,   // unconstrained exponents
        KIND_NEAR      = 3'd1,   // exponents within 2 -> cancellation / carry
        KIND_SUBNORMAL = 3'd2,   // one or both operands subnormal-or-zero
        KIND_SPECIAL   = 3'd3,   // at least one zero / inf / NaN
        KIND_TIE       = 3'd4,   // exponent gap of MW+1 -> round-to-even ties
        KIND_HUGEDIFF  = 3'd5,   // exponent gap > 30 -> sticky-bit only
        KIND_CANCEL    = 3'd6,   // same exponent, near-equal mantissa
        KIND_HUGE      = 3'd7    // both near the top of the range -> overflow
    } fp_kind_e;

    class fp_txn extends uvm_sequence_item;

        // ---- stimulus (randomised) ----
        // The exponent and mantissa fields are randomised as `int`, not as
        // packed vectors: relational constraints like "eb within 2 of ea" or
        // "mb within 8 of ma" would silently wrap around zero on an unsigned
        // vector and hand the solver an empty range. Plain ints make the
        // arithmetic honest, and post_randomize() packs the words.
        rand fp_kind_e      kind;
        rand bit            sub;              // 0: a+b   1: a-b
        rand bit            sa, sb;
        rand int            ea, eb;           // biased exponent fields, 0..255
        rand int            ma, mb;           // stored mantissa fields

        // ---- assembled operands ----
        logic [W-1:0]       a, b;

        // ---- observed result (filled by the monitor) ----
        logic [W-1:0]       z;
        logic               inv, ovf, unf, inx;

        // ---- expected result (filled by the scoreboard) ----
        logic [W-1:0]       exp_z;
        logic               exp_inv, exp_ovf, exp_unf, exp_inx;

        `uvm_object_utils_begin(fp_txn)
            `uvm_field_int(sub,   UVM_ALL_ON)
            `uvm_field_int(a,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(b,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(z,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(inv,   UVM_ALL_ON)
            `uvm_field_int(ovf,   UVM_ALL_ON)
            `uvm_field_int(unf,   UVM_ALL_ON)
            `uvm_field_int(inx,   UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "fp_txn");
            super.new(name);
        endfunction

        // Directed items are built by hand, so the default distribution only
        // matters for the random sequences.
        constraint c_kind {
            kind dist { KIND_ANY       := 12,
                        KIND_NEAR      := 20,
                        KIND_SUBNORMAL := 16,
                        KIND_SPECIAL   := 8,
                        KIND_TIE       := 12,
                        KIND_HUGEDIFF  := 12,
                        KIND_CANCEL    := 14,
                        KIND_HUGE      := 6 };
        }

        constraint c_field_range {
            ea inside {[0 : (1 << EW) - 1]};
            eb inside {[0 : (1 << EW) - 1]};
            ma inside {[0 : (1 << MW) - 1]};
            mb inside {[0 : (1 << MW) - 1]};
        }

        // Finite, nonzero region used by most of the shaped kinds.
        constraint c_kinds {
            (kind == KIND_NEAR) -> (ea inside {[1:254]} &&
                                    eb inside {[ea-2 : ea+2]} && eb inside {[1:254]});

            (kind == KIND_SUBNORMAL) -> (ea inside {[0:2]} && eb inside {[0:2]});

            (kind == KIND_SPECIAL) -> (ea inside {0, 255} || eb inside {0, 255});

            // A half-ULP gap is exactly where round-to-nearest-EVEN ties live.
            (kind == KIND_TIE) -> (ea inside {[MW+2 : 254]} &&
                                   eb == ea - (MW + 1));

            (kind == KIND_HUGEDIFF) -> (ea inside {[1:254]} && eb inside {[1:254]} &&
                                        ((ea > eb + 30) || (eb > ea + 30)));

            // Equal exponents plus a near-equal significand is the massive
            // cancellation case that needs the full leading-zero normalise.
            (kind == KIND_CANCEL) -> (ea inside {[1:254]} && eb == ea &&
                                      mb inside {[ma-8 : ma+8]});

            (kind == KIND_HUGE) -> (ea inside {[250:254]} && eb inside {[250:254]});
        }

        function void post_randomize();
            a = {sa, ea[EW-1:0], ma[MW-1:0]};
            b = {sb, eb[EW-1:0], mb[MW-1:0]};
        endfunction

        // Build a directed item.
        static function fp_txn make(logic [W-1:0] a_i, logic [W-1:0] b_i, bit sub_i,
                                    string name = "directed");
            fp_txn t = fp_txn::type_id::create(name);
            t.a = a_i; t.b = b_i; t.sub = sub_i;
            return t;
        endfunction

        function string op_str();
            return $sformatf("%s %s %s", fp_str(a), sub ? "-" : "+", fp_str(b));
        endfunction

        function string convert2string();
            return $sformatf("a=%08h b=%08h %s -> z=%08h flags{inv,ovf,unf,inx}=%b%b%b%b  (%s)",
                             a, b, sub ? "sub" : "add", z, inv, ovf, unf, inx, op_str());
        endfunction

    endclass

    // ==================================================================
    // Driver - one request per cycle, zero bubble.
    // ==================================================================
    class fp_driver extends uvm_driver #(fp_txn);
        `uvm_component_utils(fp_driver)

        virtual fp32_add_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual fp32_add_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "no virtual interface set for the driver")
        endfunction

        task run_phase(uvm_phase phase);
            fp_txn t;

            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_sub   <= 1'b0;
            vif.drv_cb.in_a     <= '0;
            vif.drv_cb.in_b     <= '0;

            wait (vif.rst_n === 1'b1);
            @(vif.drv_cb);

            forever begin
                // try_next_item (rather than get_next_item) keeps the stream
                // gapless when the sequence has work queued, and idles the
                // request bus cleanly when it does not - without ever blocking
                // the driver mid-cycle.
                seq_item_port.try_next_item(t);
                if (t == null) begin
                    vif.drv_cb.in_valid <= 1'b0;
                    @(vif.drv_cb);
                end
                else begin
                    vif.drv_cb.in_valid <= 1'b1;
                    vif.drv_cb.in_sub   <= t.sub;
                    vif.drv_cb.in_a     <= t.a;
                    vif.drv_cb.in_b     <= t.b;
                    @(vif.drv_cb);
                    seq_item_port.item_done();
                end
            end
        endtask
    endclass

    // ==================================================================
    // Monitor - publishes requests and results on separate ports. It does NOT
    // try to associate them: the DUT's latency is a design detail, so the
    // scoreboard pairs them by arrival order instead (see fp_scoreboard).
    // ==================================================================
    class fp_monitor extends uvm_monitor;
        `uvm_component_utils(fp_monitor)

        virtual fp32_add_if           vif;
        uvm_analysis_port #(fp_txn)   ap_req;
        uvm_analysis_port #(fp_txn)   ap_rsp;

        int unsigned n_req, n_rsp;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_req = new("ap_req", this);
            ap_rsp = new("ap_rsp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual fp32_add_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "no virtual interface set for the monitor")
        endfunction

        task run_phase(uvm_phase phase);
            fp_txn q, r;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n !== 1'b1) continue;

                if (vif.mon_cb.in_valid === 1'b1) begin
                    q     = fp_txn::type_id::create("req");
                    q.a   = vif.mon_cb.in_a;
                    q.b   = vif.mon_cb.in_b;
                    q.sub = vif.mon_cb.in_sub;
                    n_req++;
                    ap_req.write(q);
                end

                if (vif.mon_cb.out_valid === 1'b1) begin
                    r     = fp_txn::type_id::create("rsp");
                    r.z   = vif.mon_cb.out_z;
                    r.inv = vif.mon_cb.out_inv;
                    r.ovf = vif.mon_cb.out_ovf;
                    r.unf = vif.mon_cb.out_unf;
                    r.inx = vif.mon_cb.out_inx;
                    n_rsp++;
                    ap_rsp.write(r);
                end
            end
        endtask

        function void report_phase(uvm_phase phase);
            `uvm_info("MON", $sformatf("observed %0d requests, %0d results",
                                       n_req, n_rsp), UVM_LOW)
        endfunction
    endclass

    // ==================================================================
    // Sequencer / agent
    // ==================================================================
    typedef uvm_sequencer #(fp_txn) fp_sequencer;

    class fp_agent extends uvm_agent;
        `uvm_component_utils(fp_agent)

        fp_driver    drv;
        fp_monitor   mon;
        fp_sequencer sqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = fp_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = fp_driver::type_id::create("drv", this);
                sqr = fp_sequencer::type_id::create("sqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ==================================================================
    // Scoreboard - the reference-model check.
    // ==================================================================
    class fp_scoreboard extends uvm_component;
        `uvm_component_utils(fp_scoreboard)

        uvm_analysis_imp_req #(fp_txn, fp_scoreboard) imp_req;
        uvm_analysis_imp_rsp #(fp_txn, fp_scoreboard) imp_rsp;
        uvm_analysis_port    #(fp_txn)                ap_cov;

        fp_txn pending[$];              // requests awaiting their result

        int unsigned n_checked, n_err;
        int unsigned n_inexact, n_overflow, n_invalid, n_nan_res;
        int unsigned n_sub_res, n_zero_res, n_inf_res;
        int unsigned n_sub_operand;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp_req = new("imp_req", this);
            imp_rsp = new("imp_rsp", this);
            ap_cov  = new("ap_cov",  this);
        endfunction

        // Refuse to trust the reference model before it has proven itself
        // against the numpy-generated Known-Answer Table.
        function void start_of_simulation_phase(uvm_phase phase);
            int bad;
            super.start_of_simulation_phase(phase);
            bad = kat_selfcheck(0);
            if (bad != 0)
                `uvm_fatal("KAT", $sformatf(
                    "reference model failed %0d of %0d Known-Answer vectors - refusing to check the DUT",
                    bad, KAT_N))
            `uvm_info("KAT", $sformatf(
                "reference model reproduced all %0d numpy-generated Known-Answer vectors",
                KAT_N), UVM_LOW)
        endfunction

        function void write_req(fp_txn t);
            pending.push_back(t);
            if (fp_classify(t.a) == FPC_SUBNRM) n_sub_operand++;
            if (fp_classify(t.b) == FPC_SUBNRM) n_sub_operand++;
        endfunction

        function void write_rsp(fp_txn r);
            fp_txn     t;
            fp_res_t   e;
            fp_class_e cz;

            if (pending.size() == 0) begin
                n_err++;
                `uvm_error("SB", $sformatf(
                    "result z=%08h with no outstanding request (spurious out_valid)", r.z))
                return;
            end

            t = pending.pop_front();

            // Carry the observation over onto the request object so downstream
            // subscribers see one fully-resolved transaction.
            t.z   = r.z;
            t.inv = r.inv;
            t.ovf = r.ovf;
            t.unf = r.unf;
            t.inx = r.inx;

            e = fp_ref(t.a, t.b, t.sub);
            t.exp_z   = e.z;
            t.exp_inv = e.inv;
            t.exp_ovf = e.ovf;
            t.exp_unf = e.unf;
            t.exp_inx = e.inx;

            n_checked++;
            if ((t.z !== e.z) ||
                ({t.inv, t.ovf, t.unf, t.inx} !== {e.inv, e.ovf, e.unf, e.inx})) begin
                n_err++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH  %s\n            got      z=%08h (%s) flags=%b%b%b%b\n            expected z=%08h (%s) flags=%b%b%b%b",
                    t.op_str(),
                    t.z, fp_str(t.z), t.inv, t.ovf, t.unf, t.inx,
                    e.z, fp_str(e.z), e.inv, e.ovf, e.unf, e.inx))
            end

            // The invariant proven in the README: binary32 add/sub can never
            // round inside the subnormal range, so underflow must never fire.
            if (t.unf === 1'b1) begin
                n_err++;
                `uvm_error("SB", $sformatf(
                    "out_unf asserted for %s - underflow is unreachable for binary32 add/sub",
                    t.op_str()))
            end

            // Bookkeeping that turns into the end-of-test coverage summary.
            if (t.inx) n_inexact++;
            if (t.ovf) n_overflow++;
            if (t.inv) n_invalid++;
            cz = fp_classify(t.z);
            case (cz)
                FPC_NAN    : n_nan_res++;
                FPC_INF    : n_inf_res++;
                FPC_SUBNRM : n_sub_res++;
                FPC_ZERO   : n_zero_res++;
                default    : ;
            endcase

            ap_cov.write(t);
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            if (pending.size() != 0) begin
                n_err++;
                `uvm_error("SB", $sformatf("%0d requests never produced a result",
                                           pending.size()))
            end

            `uvm_info("SB", "----------------------------------------------------------", UVM_LOW)
            `uvm_info("SB", $sformatf("operations checked   : %0d", n_checked), UVM_LOW)
            `uvm_info("SB", $sformatf("inexact results      : %0d", n_inexact), UVM_LOW)
            `uvm_info("SB", $sformatf("overflow -> inf      : %0d", n_overflow), UVM_LOW)
            `uvm_info("SB", $sformatf("invalid  -> qNaN     : %0d", n_invalid), UVM_LOW)
            `uvm_info("SB", $sformatf("subnormal operands   : %0d", n_sub_operand), UVM_LOW)
            `uvm_info("SB", $sformatf("subnormal results    : %0d", n_sub_res), UVM_LOW)
            `uvm_info("SB", $sformatf("zero / inf / NaN res : %0d / %0d / %0d",
                                      n_zero_res, n_inf_res, n_nan_res), UVM_LOW)
            `uvm_info("SB", $sformatf("mismatches           : %0d", n_err), UVM_LOW)
            `uvm_info("SB", "----------------------------------------------------------", UVM_LOW)

            if ((n_err == 0) && (n_checked > 0))
                $display("RESULT: *** PASS ***  (%0d operations checked against the reference model)",
                         n_checked);
            else
                $display("RESULT: *** FAIL ***  (%0d operations checked, %0d mismatches)",
                         n_checked, n_err);
        endfunction
    endclass

    // ==================================================================
    // Functional coverage
    // ==================================================================
    class fp_coverage extends uvm_subscriber #(fp_txn);
        `uvm_component_utils(fp_coverage)

        fp_class_e cls_a, cls_b, cls_z;
        bit        op_sub;
        int        ediff;               // |exponent difference|, clamped
        bit        f_inx, f_ovf, f_inv;

        covergroup cg_fp;
            option.per_instance = 1;
            option.name         = "fp32_add_functional_coverage";

            cp_op: coverpoint op_sub {
                bins add = {0};
                bins sub = {1};
            }

            // Every operand class must be exercised on both inputs...
            cp_class_a: coverpoint cls_a {
                bins zero = {FPC_ZERO};   bins subnormal = {FPC_SUBNRM};
                bins normal = {FPC_NORMAL}; bins inf = {FPC_INF}; bins nan = {FPC_NAN};
            }
            cp_class_b: coverpoint cls_b {
                bins zero = {FPC_ZERO};   bins subnormal = {FPC_SUBNRM};
                bins normal = {FPC_NORMAL}; bins inf = {FPC_INF}; bins nan = {FPC_NAN};
            }
            // ...and every class must be PRODUCED, which is the harder half:
            // a subnormal or an infinity only comes out of the right stimulus.
            cp_class_z: coverpoint cls_z {
                bins zero = {FPC_ZERO};   bins subnormal = {FPC_SUBNRM};
                bins normal = {FPC_NORMAL}; bins inf = {FPC_INF}; bins nan = {FPC_NAN};
            }

            // The alignment shifter's interesting distances: 0 (no shift),
            // MW+1 = 24 (exactly the round-to-even tie distance), and past the
            // datapath width, where only the sticky bit survives.
            cp_ediff: coverpoint ediff {
                bins equal      = {0};
                bins one        = {1};
                bins small      = {[2:23]};
                bins tie_dist   = {24};
                bins wide       = {[25:26]};
                bins sticky_only= {[27:255]};
            }

            cp_inexact:  coverpoint f_inx { bins exact = {0}; bins inexact = {1}; }
            cp_overflow: coverpoint f_ovf { bins no = {0};    bins yes = {1};     }
            cp_invalid:  coverpoint f_inv { bins no = {0};    bins yes = {1};     }

            // The 5x5 operand-class matrix: this is what proves the special-case
            // priority ladder (NaN over inf over zero) was actually exercised
            // from both operand positions, not just one.
            x_class: cross cp_class_a, cp_class_b;

            // Each operation must reach each result class - subtraction
            // producing a subnormal is a different RTL path from addition
            // producing one.
            x_op_z: cross cp_op, cp_class_z;

            // Alignment distance against operation: a wide gap under
            // subtraction is the sticky-forces-round-down case.
            x_op_ediff: cross cp_op, cp_ediff;

            // Inexactness against result class: an inexact SUBNORMAL result
            // would be the (proven impossible) underflow case, so this cross
            // documents the hole deliberately.
            x_inx_z: cross cp_inexact, cp_class_z;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_fp = new();
        endfunction

        function void write(fp_txn t);
            int ea, eb;
            cls_a  = fp_classify(t.a);
            cls_b  = fp_classify(t.b);
            cls_z  = fp_classify(t.z);
            op_sub = t.sub;
            f_inx  = t.inx;
            f_ovf  = t.ovf;
            f_inv  = t.inv;

            // Effective (subnormal-aware) exponents, so a subnormal counts as 1
            // exactly the way the DUT's aligner treats it.
            ea = (t.a[W-2 -: EW] == '0) ? 1 : int'(t.a[W-2 -: EW]);
            eb = (t.b[W-2 -: EW] == '0) ? 1 : int'(t.b[W-2 -: EW]);
            ediff = (ea > eb) ? (ea - eb) : (eb - ea);

            cg_fp.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("functional coverage = %0.2f %%",
                                       cg_fp.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // ==================================================================
    // Virtual sequencer + environment
    // ==================================================================
    class fp_vsequencer extends uvm_sequencer;
        `uvm_component_utils(fp_vsequencer)

        fp_sequencer sqr;               // the one real agent sequencer

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class fp_env extends uvm_env;
        `uvm_component_utils(fp_env)

        fp_agent       agt;
        fp_scoreboard  sb;
        fp_coverage    cov;
        fp_vsequencer  vsqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt  = fp_agent::type_id::create("agt", this);
            sb   = fp_scoreboard::type_id::create("sb", this);
            cov  = fp_coverage::type_id::create("cov", this);
            vsqr = fp_vsequencer::type_id::create("vsqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agt.mon.ap_req.connect(sb.imp_req);
            agt.mon.ap_rsp.connect(sb.imp_rsp);
            sb.ap_cov.connect(cov.analysis_export);
            vsqr.sqr = agt.sqr;
        endfunction
    endclass

    // ==================================================================
    // Sequences (all run on the agent's fp_sequencer)
    // ==================================================================
    class fp_base_seq extends uvm_sequence #(fp_txn);
        `uvm_object_utils(fp_base_seq)

        function new(string name = "fp_base_seq");
            super.new(name);
        endfunction

        // Send one directed operation.
        task send(logic [W-1:0] a, logic [W-1:0] b, bit sub);
            fp_txn t = fp_txn::make(a, b, sub);
            start_item(t);
            finish_item(t);
        endtask
    endclass

    // ---- directed: replay the numpy-generated Known-Answer Table ----------
    // The same 48 vectors that pin the reference model are pushed through the
    // RTL, so the DUT is checked against hardware-IEEE answers directly and not
    // only against the model.
    class fp_kat_seq extends fp_base_seq;
        `uvm_object_utils(fp_kat_seq)

        function new(string name = "fp_kat_seq");
            super.new(name);
        endfunction

        task body();
            int i;
            if (KAT_N == 0) kat_init();
            `uvm_info("SEQ", $sformatf("KAT sequence: %0d directed vectors", KAT_N), UVM_LOW)
            for (i = 0; i < KAT_N; i++)
                send(KAT_A[i], KAT_B[i], KAT_S[i]);
        endtask
    endclass

    // ---- directed: the readable window captured in the committed waveform --
    class fp_showcase_seq extends fp_base_seq;
        `uvm_object_utils(fp_showcase_seq)

        function new(string name = "fp_showcase_seq");
            super.new(name);
        endfunction

        task body();
            `uvm_info("SEQ", "showcase: one operation per headline behaviour", UVM_LOW)
            send(FP_ONE,    FP_TWO,    1'b0);   // 1.0 + 2.0 = 3.0
            send(FP_ONE,    FP_ONE,    1'b1);   // exact cancellation -> +0
            send(FP_ONE,    FP_HALFLP, 1'b0);   // exact tie, rounds to even
            send(FP_ONE,    FP_ULP1,   1'b0);   // one ULP, exact
            send(FP_MAXSUB, FP_MINSUB, 1'b0);   // subnormal carries into normal
            send(FP_MINNRM, FP_MINSUB, 1'b1);   // drops back out of normal
            send(FP_MAXNRM, FP_MAXNRM, 1'b0);   // overflow -> +inf
            send(FP_PINF,   FP_NINF,   1'b0);   // invalid -> qNaN
            send(FP_SNAN,   FP_ONE,    1'b0);   // sNaN -> invalid, canonical qNaN
            send(FP_NZERO,  FP_NZERO,  1'b0);   // (-0) + (-0) = -0
        endtask
    endclass

    // ---- directed: the full cross-product of the named landmarks ----------
    class fp_landmark_seq extends fp_base_seq;
        `uvm_object_utils(fp_landmark_seq)

        function new(string name = "fp_landmark_seq");
            super.new(name);
        endfunction

        task body();
            logic [W-1:0] L [];
            int i, j, s;
            L = new[16];
            L[ 0] = FP_PZERO;  L[ 1] = FP_NZERO;  L[ 2] = FP_MINSUB;  L[ 3] = FP_MAXSUB;
            L[ 4] = FP_MINNRM; L[ 5] = FP_ONE;    L[ 6] = FP_MONE;    L[ 7] = FP_TWO;
            L[ 8] = FP_HALFLP; L[ 9] = FP_ULP1;   L[10] = FP_MAXNRM;  L[11] = FP_NMAXNRM;
            L[12] = FP_PINF;   L[13] = FP_NINF;   L[14] = FP_SNAN;    L[15] = FP_QNAN;

            `uvm_info("SEQ", "landmark sequence: 16 x 16 x {add,sub} = 512 directed operations",
                      UVM_LOW)
            for (i = 0; i < 16; i++)
                for (j = 0; j < 16; j++)
                    for (s = 0; s < 2; s++)
                        send(L[i], L[j], s[0]);
        endtask
    endclass

    // ---- directed: the round-to-nearest-EVEN tie campaign ------------------
    // For a normal operand with exponent e, the exact half-ULP is the power of
    // two with exponent e-(MW+1). Adding it produces a perfect tie, so the
    // result depends purely on whether the retained LSB is even - the single
    // easiest thing to get wrong in a rounder.
    class fp_tie_seq extends fp_base_seq;
        `uvm_object_utils(fp_tie_seq)

        rand int unsigned n_ops;
        constraint c_n { soft n_ops inside {[60:120]}; }

        function new(string name = "fp_tie_seq");
            super.new(name);
        endfunction

        task body();
            int i, e, e_half, e_quarter;
            bit sgn, sb_;
            logic [MW-1:0] mant;
            logic [W-1:0]  a, half, quarter, three_q;

            `uvm_info("SEQ", $sformatf("tie sequence: %0d exact-half-ULP operations", n_ops),
                      UVM_LOW)
            for (i = 0; i < n_ops; i++) begin
                e         = $urandom_range(254, MW + 2);
                e_half    = e - (MW + 1);       // 0.5 ULP of a  -> a perfect tie
                e_quarter = e - (MW + 2);       // 0.25 ULP of a
                sgn       = bit'($urandom_range(1, 0));
                sb_       = bit'($urandom_range(1, 0));

                // Alternate an even and an odd retained LSB so both tie
                // outcomes (stay put / round away) are exercised.
                mant    = MW'($urandom());
                mant[0] = bit'(i[0]);

                a       = {sgn, e[EW-1:0],         mant};
                half    = {sb_, e_half[EW-1:0],    {MW{1'b0}}};                 // tie
                quarter = {sb_, e_quarter[EW-1:0], {MW{1'b0}}};                 // below tie
                three_q = {sb_, e_quarter[EW-1:0], {1'b1, {MW-1{1'b0}}}};       // above tie

                send(a, half,    1'b0);
                send(a, half,    1'b1);
                send(a, quarter, 1'b0);
                send(a, three_q, 1'b0);
            end
        endtask
    endclass

    // ---- directed: the subnormal / gradual-underflow neighbourhood ---------
    class fp_subnormal_seq extends fp_base_seq;
        `uvm_object_utils(fp_subnormal_seq)

        rand int unsigned n_ops;
        constraint c_n { soft n_ops inside {[150:300]}; }

        function new(string name = "fp_subnormal_seq");
            super.new(name);
        endfunction

        task body();
            int i, ea, eb;
            bit sa, sb_;
            logic [W-1:0] a, b;
            `uvm_info("SEQ", $sformatf("subnormal sequence: %0d operand pairs at the exponent floor",
                                       n_ops), UVM_LOW)
            for (i = 0; i < n_ops; i++) begin
                // Exponent 0 (subnormal/zero), 1 or 2 (the smallest normals) -
                // the band where the hidden bit appears and disappears.
                ea  = $urandom_range(2, 0);
                eb  = $urandom_range(2, 0);
                sa  = bit'($urandom_range(1, 0));
                sb_ = bit'($urandom_range(1, 0));
                a   = {sa,  ea[EW-1:0], MW'($urandom())};
                b   = {sb_, eb[EW-1:0], MW'($urandom())};
                send(a, b, 1'b0);
                send(a, b, 1'b1);
            end
            // The exact boundary steps, deterministically.
            send(FP_MAXSUB, FP_MINSUB, 1'b0);
            send(FP_MINNRM, FP_MINSUB, 1'b1);
            send(FP_MINNRM, FP_MAXSUB, 1'b1);
            send(FP_MINSUB, FP_MINSUB, 1'b1);
            send(FP_MAXSUB, FP_MAXSUB, 1'b0);
        endtask
    endclass

    // ---- directed: the top of the range -> overflow ------------------------
    class fp_overflow_seq extends fp_base_seq;
        `uvm_object_utils(fp_overflow_seq)

        rand int unsigned n_ops;
        constraint c_n { soft n_ops inside {[40:80]}; }

        function new(string name = "fp_overflow_seq");
            super.new(name);
        endfunction

        task body();
            int i, ea, eb;
            bit sa, sb_;
            logic [W-1:0] a, b;
            `uvm_info("SEQ", $sformatf("overflow sequence: %0d operand pairs near the largest finite",
                                       n_ops), UVM_LOW)
            for (i = 0; i < n_ops; i++) begin
                ea  = $urandom_range(254, 250);
                eb  = $urandom_range(254, 250);
                sa  = bit'($urandom_range(1, 0));
                sb_ = bit'($urandom_range(1, 0));
                a   = {sa,  ea[EW-1:0], MW'($urandom())};
                b   = {sb_, eb[EW-1:0], MW'($urandom())};
                send(a, b, 1'b0);
                send(a, b, 1'b1);
            end
            send(FP_MAXNRM,  FP_MAXNRM, 1'b0);      // straight overflow
            send(FP_NMAXNRM, FP_MAXNRM, 1'b1);      // overflow on the negative side
            send(FP_MAXNRM,  FP_MINSUB, 1'b0);      // maximal alignment distance
        endtask
    endclass

    // ---- constrained-random regression ------------------------------------
    class fp_random_seq extends fp_base_seq;
        `uvm_object_utils(fp_random_seq)

        // `soft` so a virtual sequence can override the count with an inline
        // constraint instead of conflicting with this one.
        rand int unsigned n_ops;
        constraint c_n { soft n_ops inside {[400:800]}; }

        function new(string name = "fp_random_seq");
            super.new(name);
        endfunction

        task body();
            fp_txn t;
            int i;
            `uvm_info("SEQ", $sformatf("random sequence: %0d constrained-random operations",
                                       n_ops), UVM_LOW)
            for (i = 0; i < n_ops; i++) begin
                t = fp_txn::type_id::create($sformatf("rnd%0d", i));
                start_item(t);
                if (!t.randomize())
                    `uvm_error("SEQ", "fp_txn randomisation failed")
                finish_item(t);
            end
        endtask
    endclass

    // ==================================================================
    // Virtual sequences
    // ==================================================================
    class fp_vseq_base extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(fp_vseq_base)

        fp_vsequencer vsqr;

        function new(string name = "fp_vseq_base");
            super.new(name);
        endfunction

        task pre_start();
            if (!$cast(vsqr, m_sequencer))
                `uvm_fatal("VSEQ", "virtual sequence must run on an fp_vsequencer")
        endtask
    endclass

    // Smoke: prove the model, then walk the headline behaviours, then a short
    // random burst. Fast enough to run on every commit.
    class fp_smoke_vseq extends fp_vseq_base;
        `uvm_object_utils(fp_smoke_vseq)

        function new(string name = "fp_smoke_vseq");
            super.new(name);
        endfunction

        task body();
            fp_kat_seq      kat;
            fp_showcase_seq show;
            fp_random_seq   rnd;

            kat  = fp_kat_seq::type_id::create("kat");
            show = fp_showcase_seq::type_id::create("show");
            rnd  = fp_random_seq::type_id::create("rnd");

            kat.start(vsqr.sqr, this);
            show.start(vsqr.sqr, this);
            if (!rnd.randomize() with { n_ops inside {[100:200]}; })
                `uvm_error("VSEQ", "fp_random_seq randomisation failed")
            rnd.start(vsqr.sqr, this);
        endtask
    endclass

    // Regression: every directed campaign plus a long random tail. The corner
    // sequences run first so that a failure points at a named corner rather
    // than at an anonymous random vector.
    class fp_regress_vseq extends fp_vseq_base;
        `uvm_object_utils(fp_regress_vseq)

        function new(string name = "fp_regress_vseq");
            super.new(name);
        endfunction

        task body();
            fp_kat_seq       kat;
            fp_showcase_seq  show;
            fp_landmark_seq  land;
            fp_tie_seq       tie;
            fp_subnormal_seq sub;
            fp_overflow_seq  ovf;
            fp_random_seq    rnd;
            int              round;

            kat  = fp_kat_seq::type_id::create("kat");
            show = fp_showcase_seq::type_id::create("show");
            land = fp_landmark_seq::type_id::create("land");

            kat.start(vsqr.sqr, this);
            show.start(vsqr.sqr, this);
            land.start(vsqr.sqr, this);

            for (round = 0; round < 3; round++) begin
                tie = fp_tie_seq::type_id::create($sformatf("tie%0d", round));
                sub = fp_subnormal_seq::type_id::create($sformatf("sub%0d", round));
                ovf = fp_overflow_seq::type_id::create($sformatf("ovf%0d", round));
                rnd = fp_random_seq::type_id::create($sformatf("rnd%0d", round));

                if (!tie.randomize()) `uvm_error("VSEQ", "tie randomisation failed")
                if (!sub.randomize()) `uvm_error("VSEQ", "subnormal randomisation failed")
                if (!ovf.randomize()) `uvm_error("VSEQ", "overflow randomisation failed")
                if (!rnd.randomize()) `uvm_error("VSEQ", "random randomisation failed")

                tie.start(vsqr.sqr, this);
                sub.start(vsqr.sqr, this);
                ovf.start(vsqr.sqr, this);
                rnd.start(vsqr.sqr, this);
            end
        endtask
    endclass

    // ==================================================================
    // Tests
    // ==================================================================
    class fp32_add_base_test extends uvm_test;
        `uvm_component_utils(fp32_add_base_test)

        fp_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = fp_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            super.end_of_elaboration_phase(phase);
            uvm_top.print_topology();
        endfunction

        // Let the pipeline drain before the scoreboard's report runs, otherwise
        // the last LAT results would still be in flight.
        task drain();
            repeat (LAT + 8) @(posedge env.agt.mon.vif.clk);
        endtask
    endclass

    class fp32_add_smoke_test extends fp32_add_base_test;
        `uvm_component_utils(fp32_add_smoke_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fp_smoke_vseq vseq;
            phase.raise_objection(this);
            vseq = fp_smoke_vseq::type_id::create("smoke");
            vseq.start(env.vsqr);
            drain();
            phase.drop_objection(this);
        endtask
    endclass

    class fp32_add_regress_test extends fp32_add_base_test;
        `uvm_component_utils(fp32_add_regress_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fp_regress_vseq vseq;
            phase.raise_objection(this);
            vseq = fp_regress_vseq::type_id::create("regress");
            vseq.start(env.vsqr);
            drain();
            phase.drop_objection(this);
        endtask
    endclass

endpackage
