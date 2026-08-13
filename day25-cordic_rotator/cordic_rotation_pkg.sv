// -----------------------------------------------------------------------------
// cordic_rotation_pkg.sv - full UVM verification environment for the
// fully-pipelined ROTATION-MODE CORDIC engine.
//
// Contents:
//   * cordic_model      - independent golden rotation reference (real-valued
//                         $cos/$sin scaled by the CORDIC gain K); reused by the
//                         scoreboard AND the coverage collector.
//   * cordic_item       - stimulus transaction ({x, y, angle}), constrained.
//   * cordic_in_txn /
//     cordic_out_txn    - monitored request / result transactions.
//   * cordic_cfg        - environment config object.
//   * cordic_driver     - drives one request per cycle (zero-bubble capable).
//   * cordic_monitor    - reconstructs request and result streams, publishes
//                         them on analysis ports (latency-independent).
//   * cordic_agent      - driver + monitor + sequencer.
//   * cordic_scoreboard - fixed-latency, in-order golden check within a small
//                         fixed-point tolerance.
//   * cordic_coverage   - angle-quadrant x fold x vector-kind coverage.
//   * cordic_vseqr      - virtual sequencer.
//   * cordic_env        - wires the agent, scoreboard, coverage together.
//   * sequences         - sincos_sweep, corner, random.
//   * virtual sequences - smoke, regress.
//   * tests             - base, smoke, regress.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). The
// portable open-source flow (Icarus) uses tb_cordic_rotation_dump.sv.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package cordic_rotation_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ---- shared geometry (must match the DUT / interface) ----
    localparam int    DW    = 16;
    localparam int    AW    = 16;
    localparam int    FRAC  = 13;
    localparam int    NITER = 16;
    localparam int    LAT   = NITER + 1;

    localparam real    SCALE = 8192.0;            // 2^FRAC
    localparam real    KGAIN = 1.6467602579;      // CORDIC processing gain
    localparam int     KINV  = 4975;              // round(2^FRAC / K) -> cos/sin
    localparam int     TOL   = 24;                // allowed |error| in LSB
    localparam int     PI_Q  = 25736;             // pi in Q2.13
    localparam int     HALFPI = 12868;            // pi/2 in Q2.13

    // =========================================================================
    // Golden reference model - independent real-valued rotation.
    // The DUT is a fixed-point shift-add recurrence; this is language-level trig.
    // =========================================================================
    class cordic_model extends uvm_object;
        `uvm_object_utils(cordic_model)
        function new(string name = "cordic_model"); super.new(name); endfunction

        function int rnd(real v);
            return (v >= 0.0) ? int'(v + 0.5) : int'(v - 0.5);
        endfunction

        // expected rotated x (K*(x*cos - y*sin)), fixed-point LSB units.
        function int exp_x(int xi, int yi, int ai);
            real a = ai / SCALE, xr = xi / SCALE, yr = yi / SCALE;
            return rnd(KGAIN * (xr * $cos(a) - yr * $sin(a)) * SCALE);
        endfunction

        // expected rotated y (K*(x*sin + y*cos)), fixed-point LSB units.
        function int exp_y(int xi, int yi, int ai);
            real a = ai / SCALE, xr = xi / SCALE, yr = yi / SCALE;
            return rnd(KGAIN * (xr * $sin(a) + yr * $cos(a)) * SCALE);
        endfunction
    endclass

    // =========================================================================
    // Transactions
    // =========================================================================
    class cordic_item extends uvm_sequence_item;
        rand int x;
        rand int y;
        rand int angle;

        // |x|,|y| <= 1.0 keeps K*|vector| well inside the Q2.13 output range;
        // angle spans the full [-pi, pi] the folded DUT supports.
        constraint c_x     { x     inside {[-8192:8192]}; }
        constraint c_y     { y     inside {[-8192:8192]}; }
        constraint c_angle { angle inside {[-PI_Q:PI_Q]}; }

        `uvm_object_utils_begin(cordic_item)
            `uvm_field_int(x,     UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(y,     UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(angle, UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "cordic_item"); super.new(name); endfunction
    endclass

    class cordic_in_txn extends uvm_sequence_item;
        int x, y, angle;
        `uvm_object_utils(cordic_in_txn)
        function new(string name = "cordic_in_txn"); super.new(name); endfunction
    endclass

    class cordic_out_txn extends uvm_sequence_item;
        int x, y, angle;
        `uvm_object_utils(cordic_out_txn)
        function new(string name = "cordic_out_txn"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class cordic_cfg extends uvm_object;
        virtual cordic_rotation_if vif;
        `uvm_object_utils(cordic_cfg)
        function new(string name = "cordic_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Driver - applies one request per cycle; zero-bubble capable.
    // =========================================================================
    class cordic_driver extends uvm_driver #(cordic_item);
        `uvm_component_utils(cordic_driver)
        virtual cordic_rotation_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cordic_rotation_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "cordic_driver: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            // idle until reset released
            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_x     <= '0;
            vif.drv_cb.in_y     <= '0;
            vif.drv_cb.in_angle <= '0;
            wait (vif.rst_n === 1'b1);
            @(vif.drv_cb);
            forever begin
                seq_item_port.get_next_item(req);
                vif.drv_cb.in_valid <= 1'b1;
                vif.drv_cb.in_x     <= req.x[DW-1:0];
                vif.drv_cb.in_y     <= req.y[DW-1:0];
                vif.drv_cb.in_angle <= req.angle[AW-1:0];
                @(vif.drv_cb);
                vif.drv_cb.in_valid <= 1'b0;   // sequence controls back-to-back
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - publishes request and result streams on analysis ports.
    // =========================================================================
    class cordic_monitor extends uvm_monitor;
        `uvm_component_utils(cordic_monitor)
        virtual cordic_rotation_if vif;
        uvm_analysis_port #(cordic_in_txn)  ap_in;
        uvm_analysis_port #(cordic_out_txn) ap_out;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_in  = new("ap_in",  this);
            ap_out = new("ap_out", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual cordic_rotation_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "cordic_monitor: virtual interface not set")
        endfunction

        function int sgn(int v, int w);       // sign-extend a w-bit field
            if (v[w-1]) return v | (~((1 << w) - 1));
            else        return v & ((1 << w) - 1);
        endfunction

        task run_phase(uvm_phase phase);
            cordic_in_txn  it;
            cordic_out_txn ot;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n !== 1'b1) continue;
                if (vif.mon_cb.in_valid === 1'b1) begin
                    it = cordic_in_txn::type_id::create("it");
                    it.x     = sgn(vif.mon_cb.in_x,     DW);
                    it.y     = sgn(vif.mon_cb.in_y,     DW);
                    it.angle = sgn(vif.mon_cb.in_angle, AW);
                    ap_in.write(it);
                end
                if (vif.mon_cb.out_valid === 1'b1) begin
                    ot = cordic_out_txn::type_id::create("ot");
                    ot.x     = sgn(vif.mon_cb.out_x,     DW);
                    ot.y     = sgn(vif.mon_cb.out_y,     DW);
                    ot.angle = sgn(vif.mon_cb.out_angle, AW);
                    ap_out.write(ot);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class cordic_agent extends uvm_agent;
        `uvm_component_utils(cordic_agent)
        cordic_driver              drv;
        cordic_monitor             mon;
        uvm_sequencer #(cordic_item) seqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv  = cordic_driver::type_id::create("drv", this);
            mon  = cordic_monitor::type_id::create("mon", this);
            seqr = uvm_sequencer#(cordic_item)::type_id::create("seqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - fixed-latency, in-order golden check within tolerance.
    // =========================================================================
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    class cordic_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(cordic_scoreboard)
        uvm_analysis_imp_in  #(cordic_in_txn,  cordic_scoreboard) sb_in;
        uvm_analysis_imp_out #(cordic_out_txn, cordic_scoreboard) sb_out;

        cordic_model model;
        int exp_x_q[$], exp_y_q[$], exp_a_q[$];
        int matched, mismatched, worst;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            sb_in  = new("sb_in",  this);
            sb_out = new("sb_out", this);
        endfunction

        function void build_phase(uvm_phase phase);
            model = cordic_model::type_id::create("model");
        endfunction

        // enqueue the golden expectation for each observed request
        function void write_in(cordic_in_txn t);
            exp_x_q.push_back(model.exp_x(t.x, t.y, t.angle));
            exp_y_q.push_back(model.exp_y(t.x, t.y, t.angle));
            exp_a_q.push_back(t.angle);
        endfunction

        // check each result in arrival order
        function void write_out(cordic_out_txn t);
            int ex, ey, ea, dx, dy;
            if (exp_x_q.size() == 0) begin
                `uvm_error("SB", "unexpected result (expected FIFO empty)")
                mismatched++;
                return;
            end
            ex = exp_x_q.pop_front();
            ey = exp_y_q.pop_front();
            ea = exp_a_q.pop_front();
            dx = (t.x > ex) ? (t.x - ex) : (ex - t.x);
            dy = (t.y > ey) ? (t.y - ey) : (ey - t.y);
            if (dx > worst) worst = dx;
            if (dy > worst) worst = dy;
            if (dx > TOL || dy > TOL) begin
                `uvm_error("SB", $sformatf(
                    "angle=%0d: x got %0d exp %0d (|d|=%0d), y got %0d exp %0d (|d|=%0d)",
                    ea, t.x, ex, dx, t.y, ey, dy))
                mismatched++;
            end else if (t.angle !== ea) begin
                `uvm_error("SB", $sformatf("angle-echo got %0d exp %0d", t.angle, ea))
                mismatched++;
            end else begin
                matched++;
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (exp_x_q.size() != 0)
                `uvm_error("SB", $sformatf("%0d expected results never arrived", exp_x_q.size()))
            `uvm_info("SB", $sformatf("matched=%0d mismatched=%0d worst|err|=%0d LSB",
                                      matched, mismatched, worst), UVM_LOW)
            if (mismatched == 0 && matched > 0 && exp_x_q.size() == 0)
                `uvm_info("SB", "RESULT: *** PASS ***", UVM_LOW)
            else
                `uvm_error("SB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // =========================================================================
    // Coverage - angle-quadrant x fold x vector-kind.
    // =========================================================================
    `uvm_analysis_imp_decl(_cin)

    class cordic_coverage extends uvm_component;
        `uvm_component_utils(cordic_coverage)
        uvm_analysis_imp_cin #(cordic_in_txn, cordic_coverage) cin;

        int  cg_angle;
        bit  cg_fold;
        int  cg_kind;    // 0 = unit +x (cos/sin gen), 1 = axis, 2 = general

        covergroup cg;
            cp_quadrant : coverpoint cg_angle {
                bins q_neg_far  = {[-PI_Q     : -HALFPI-1]};
                bins q_neg_near = {[-HALFPI   : -1]};
                bins q_zero     = {0};
                bins q_pos_near = {[1         : HALFPI]};
                bins q_pos_far  = {[HALFPI+1  : PI_Q]};
            }
            cp_fold : coverpoint cg_fold;
            cp_kind : coverpoint cg_kind { bins b[] = {0, 1, 2}; }
            x_quad_kind : cross cp_quadrant, cp_kind;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cin = new("cin", this);
            cg  = new();
        endfunction

        function void write_cin(cordic_in_txn t);
            cg_angle = t.angle;
            cg_fold  = (t.angle > HALFPI) || (t.angle < -HALFPI);
            if (t.x == KINV && t.y == 0)      cg_kind = 0;
            else if (t.x == 0 || t.y == 0)    cg_kind = 1;
            else                              cg_kind = 2;
            cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer
    // =========================================================================
    class cordic_vseqr extends uvm_sequencer;
        `uvm_component_utils(cordic_vseqr)
        uvm_sequencer #(cordic_item) seqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class cordic_env extends uvm_env;
        `uvm_component_utils(cordic_env)
        cordic_agent      agent;
        cordic_scoreboard sb;
        cordic_coverage   cov;
        cordic_vseqr      vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = cordic_agent::type_id::create("agent", this);
            sb    = cordic_scoreboard::type_id::create("sb", this);
            cov   = cordic_coverage::type_id::create("cov", this);
            vseqr = cordic_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap_in.connect(sb.sb_in);
            agent.mon.ap_out.connect(sb.sb_out);
            agent.mon.ap_in.connect(cov.cin);
            vseqr.seqr = agent.seqr;
        endfunction
    endclass

    // =========================================================================
    // Sequences
    // =========================================================================
    // Directed sin/cos sweep: x=KINV, y=0, angles across all quadrants + fold.
    class cordic_sincos_seq extends uvm_sequence #(cordic_item);
        `uvm_object_utils(cordic_sincos_seq)
        function new(string name = "cordic_sincos_seq"); super.new(name); endfunction
        task body();
            int angs[] = '{-12868, -6434, 0, 4289, 6434, 8578, 12868,
                            17157, 19302, 21447};
            foreach (angs[i]) begin
                cordic_item it = cordic_item::type_id::create("it");
                start_item(it);
                if (!it.randomize() with { x == KINV; y == 0; angle == angs[i]; })
                    `uvm_error("SINCOS", "randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    // Directed corners: identity, +/-pi, axis rotations, general vectors.
    class cordic_corner_seq extends uvm_sequence #(cordic_item);
        `uvm_object_utils(cordic_corner_seq)
        function new(string name = "cordic_corner_seq"); super.new(name); endfunction
        task body();
            int cx[]  = '{KINV, KINV,  KINV, 8192,    0, 8192, -4096,  8192};
            int cy[]  = '{   0,    0,     0,    0, 8192, 8192,  2048, -8192};
            int ca[]  = '{   0, 25736, -25736, 12868, 12868, 6434, -8578, 21447};
            foreach (cx[i]) begin
                cordic_item it = cordic_item::type_id::create("it");
                start_item(it);
                if (!it.randomize() with { x == cx[i]; y == cy[i]; angle == ca[i]; })
                    `uvm_error("CORNER", "randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    // Constrained-random rotations across the full angle range.
    class cordic_random_seq extends uvm_sequence #(cordic_item);
        `uvm_object_utils(cordic_random_seq)
        rand int n;
        constraint c_n { n inside {[200:400]}; }
        function new(string name = "cordic_random_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                cordic_item it = cordic_item::type_id::create("it");
                start_item(it);
                if (!it.randomize())
                    `uvm_error("RND", "randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class cordic_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(cordic_smoke_vseq)
        cordic_vseqr vseqr;
        function new(string name = "cordic_smoke_vseq"); super.new(name); endfunction
        task body();
            cordic_sincos_seq s = cordic_sincos_seq::type_id::create("s");
            cordic_corner_seq c = cordic_corner_seq::type_id::create("c");
            s.start(vseqr.seqr);
            c.start(vseqr.seqr);
        endtask
    endclass

    class cordic_regress_vseq extends uvm_sequence;
        `uvm_object_utils(cordic_regress_vseq)
        cordic_vseqr vseqr;
        function new(string name = "cordic_regress_vseq"); super.new(name); endfunction
        task body();
            cordic_sincos_seq s = cordic_sincos_seq::type_id::create("s");
            cordic_corner_seq c = cordic_corner_seq::type_id::create("c");
            cordic_random_seq r = cordic_random_seq::type_id::create("r");
            s.start(vseqr.seqr);
            c.start(vseqr.seqr);
            repeat (8) begin
                if (!r.randomize()) `uvm_error("REG", "randomize failed");
                r.start(vseqr.seqr);
            end
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class cordic_base_test extends uvm_test;
        `uvm_component_utils(cordic_base_test)
        cordic_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = cordic_env::type_id::create("env", this);
        endfunction
    endclass

    class cordic_smoke_test extends cordic_base_test;
        `uvm_component_utils(cordic_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            cordic_smoke_vseq v = cordic_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            repeat (LAT + 20) @(posedge env.agent.drv.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

    class cordic_regress_test extends cordic_base_test;
        `uvm_component_utils(cordic_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            cordic_regress_vseq v = cordic_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(null);
            repeat (LAT + 20) @(posedge env.agent.drv.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
