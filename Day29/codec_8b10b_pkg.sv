// ============================================================================
// codec_8b10b_pkg.sv - the UVM verification environment for the 8b/10b codec.
// ----------------------------------------------------------------------------
// Topology
//
//   c8b_vseqr (virtual sequencer)
//     +-- c8b_sequencer ------------------ c8b_driver --> [ in_valid/data/k/
//                                                            err_mask pins ]
//   c8b_agent
//     +-- c8b_in_monitor   -- req_ap  ---> scoreboard   (the request stream)
//     +-- c8b_tx_monitor   -- tx_ap   ---> scoreboard   (what went on the wire)
//     +-- c8b_rx_monitor   -- rx_ap   ---> scoreboard   (what came back off it)
//
//   c8b_scoreboard  -- resolved items --> c8b_coverage
//
// The scoreboard is the only place the reference model is stepped.  It runs
// codec_8b10b_ref_pkg::ref_link_step once per *request*, in request order,
// threading the transmitter's and the receiver's running-disparity registers
// itself, and files the result in two expectation queues - one drained by the
// transmit monitor a cycle later, one by the receive monitor a cycle after
// that.  Nothing in this file re-implements the code: the model is a flat ROM,
// and a disagreement is always the DUT's rules losing an argument with data.
//
// Coverage sits downstream of the scoreboard rather than on the request
// stream, so the symbol class that went in can be crossed with the verdict
// that came out - "did we ever inject two bit flips into a control symbol and
// see it survive as a *different* legal symbol?" is a coverage question, and
// it only makes sense once the result is known.
// ============================================================================
`timescale 1ns/1ps

package codec_8b10b_pkg;

    import uvm_pkg::*;
    import codec_8b10b_ref_pkg::*;
`include "uvm_macros.svh"

    // ---- analysis imp suffixes for the scoreboard's three inputs ----------
    `uvm_analysis_imp_decl(_req)
    `uvm_analysis_imp_decl(_tx)
    `uvm_analysis_imp_decl(_rx)

    // ---- the twelve legal control symbols, as bytes -----------------------
    // K.28.y for y = 0..7, then K.{23,27,29,30}.7.
    const bit [7:0] K_LEGAL [12] = '{8'h1C, 8'h3C, 8'h5C, 8'h7C,
                                     8'h9C, 8'hBC, 8'hDC, 8'hFC,
                                     8'hF7, 8'hFB, 8'hFD, 8'hFE};

    // The six data symbols that use the alternate D.x.A7 3b/4b encoding.
    const bit [7:0] A7_SYMS [6] = '{8'hEB, 8'hED, 8'hEE,   // D.11.7 D.13.7 D.14.7
                                    8'hF1, 8'hF2, 8'hF4};  // D.17.7 D.18.7 D.20.7

    // ======================================================================
    // config
    // ======================================================================
    class c8b_config extends uvm_object;
        `uvm_object_utils(c8b_config)
        virtual codec_8b10b_if vif;
        function new(string name = "c8b_config"); super.new(name); endfunction
    endclass

    // ======================================================================
    // transactions
    // ======================================================================
    typedef enum bit [1:0] { SYM_DATA, SYM_K, SYM_K_ILLEGAL } sym_kind_e;

    // a transmit request
    class c8b_txn extends uvm_sequence_item;
        rand bit [7:0]   data;
        rand bit         k;
        rand bit [9:0]   err_mask;
        rand sym_kind_e  kind;
        rand int unsigned nflip;   // shaping knob only; err_mask is the truth

        `uvm_object_utils_begin(c8b_txn)
            `uvm_field_int(data,     UVM_ALL_ON)
            `uvm_field_int(k,        UVM_ALL_ON)
            `uvm_field_int(err_mask, UVM_ALL_ON)
            `uvm_field_enum(sym_kind_e, kind, UVM_ALL_ON)
        `uvm_object_utils_end

        // Mostly clean traffic with an occasional corrupted symbol: a link
        // that is broken most of the time never exercises running disparity.
        constraint c_kind    { kind dist { SYM_DATA := 70, SYM_K := 27,
                                           SYM_K_ILLEGAL := 3 }; }
        constraint c_k       { k == (kind != SYM_DATA); }
        constraint c_klegal  { kind == SYM_K -> data inside {K_LEGAL}; }
        constraint c_killegal{ kind == SYM_K_ILLEGAL -> !(data inside {K_LEGAL}); }
        constraint c_nflip   { nflip dist { 0 := 80, 1 := 12, 2 := 6,
                                           [3:10] := 2 }; }
        constraint c_mask    { $countones(err_mask) == nflip; }

        function new(string name = "c8b_txn"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("%s.%0d.%0d (0x%02h) mask=%b",
                             k ? "K" : "D", data[4:0], data[7:5], data,
                             err_mask);
        endfunction
    endclass

    // what the transmit monitor saw
    class c8b_tx_item extends uvm_sequence_item;
        bit [9:0] enc_code, wire_code;
        bit       enc_rd, enc_kerr, enc_comma;
        `uvm_object_utils(c8b_tx_item)
        function new(string name = "c8b_tx_item"); super.new(name); endfunction
    endclass

    // what the receive monitor saw
    class c8b_rx_item extends uvm_sequence_item;
        bit [7:0] out_data;
        bit       out_k, out_code_err, out_disp_err, out_rd, out_comma;
        `uvm_object_utils(c8b_rx_item)
        function new(string name = "c8b_rx_item"); super.new(name); endfunction
    endclass

    // a request paired with the verdict it produced - the coverage input
    class c8b_resolved extends uvm_sequence_item;
        bit [7:0] data;
        bit       k, k_legal;
        int       nflip;
        bit       tx_rd_pre;
        bit       code_err, disp_err, comma, kerr;
        bit       recovered;   // decoded back to exactly the symbol sent
        `uvm_object_utils(c8b_resolved)
        function new(string name = "c8b_resolved"); super.new(name); endfunction
    endclass

    typedef uvm_sequencer #(c8b_txn) c8b_sequencer;

    // ======================================================================
    // driver - one symbol per cycle, zero bubbles while the sequence keeps up
    // ======================================================================
    class c8b_driver extends uvm_driver #(c8b_txn);
        `uvm_component_utils(c8b_driver)
        virtual codec_8b10b_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            c8b_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(c8b_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "c8b_config not set for driver")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            c8b_txn req;
            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_data  <= 8'h00;
            vif.drv_cb.in_k     <= 1'b0;
            vif.drv_cb.err_mask <= 10'b0;
            wait (vif.rst_n === 1'b1);
            forever begin
                @(vif.drv_cb);
                // try_next_item rather than get_next_item: when the sequence
                // has nothing ready the line must idle, not stall mid-symbol.
                seq_item_port.try_next_item(req);
                if (req == null) begin
                    vif.drv_cb.in_valid <= 1'b0;
                    vif.drv_cb.err_mask <= 10'b0;
                end else begin
                    vif.drv_cb.in_valid <= 1'b1;
                    vif.drv_cb.in_data  <= req.data;
                    vif.drv_cb.in_k     <= req.k;
                    vif.drv_cb.err_mask <= req.err_mask;
                    seq_item_port.item_done();
                end
            end
        endtask
    endclass

    // ======================================================================
    // monitors
    // ======================================================================
    class c8b_in_monitor extends uvm_monitor;
        `uvm_component_utils(c8b_in_monitor)
        virtual codec_8b10b_if vif;
        uvm_analysis_port #(c8b_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            c8b_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(c8b_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "c8b_config not set for in monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1 && vif.in_valid === 1'b1) begin
                    c8b_txn t = c8b_txn::type_id::create("t");
                    t.data     = vif.in_data;
                    t.k        = vif.in_k;
                    t.err_mask = vif.err_mask;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class c8b_tx_monitor extends uvm_monitor;
        `uvm_component_utils(c8b_tx_monitor)
        virtual codec_8b10b_if vif;
        uvm_analysis_port #(c8b_tx_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            c8b_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(c8b_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "c8b_config not set for tx monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1 && vif.enc_valid === 1'b1) begin
                    c8b_tx_item t = c8b_tx_item::type_id::create("t");
                    t.enc_code  = vif.enc_code;
                    t.wire_code = vif.wire_code;
                    t.enc_rd    = vif.enc_rd;
                    t.enc_kerr  = vif.enc_kerr;
                    t.enc_comma = vif.enc_comma;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class c8b_rx_monitor extends uvm_monitor;
        `uvm_component_utils(c8b_rx_monitor)
        virtual codec_8b10b_if vif;
        uvm_analysis_port #(c8b_rx_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            c8b_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(c8b_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "c8b_config not set for rx monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1 && vif.out_valid === 1'b1) begin
                    c8b_rx_item t = c8b_rx_item::type_id::create("t");
                    t.out_data     = vif.out_data;
                    t.out_k        = vif.out_k;
                    t.out_code_err = vif.out_code_err;
                    t.out_disp_err = vif.out_disp_err;
                    t.out_rd       = vif.out_rd;
                    t.out_comma    = vif.out_comma;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ======================================================================
    // scoreboard
    // ======================================================================
    class c8b_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(c8b_scoreboard)

        uvm_analysis_imp_req #(c8b_txn,     c8b_scoreboard) req_imp;
        uvm_analysis_imp_tx  #(c8b_tx_item, c8b_scoreboard) tx_imp;
        uvm_analysis_imp_rx  #(c8b_rx_item, c8b_scoreboard) rx_imp;

        uvm_analysis_port #(c8b_resolved) cov_ap;

        // the model's two running-disparity registers
        bit tx_rd = RD_NEG;
        bit rx_rd = RD_NEG;

        // expectations, in request order
        bit [REF_EXP_W-1:0] tx_q [$];
        bit [REF_EXP_W-1:0] rx_q [$];
        c8b_txn             req_q[$];   // kept for the coverage pairing

        int n_req = 0, n_tx = 0, n_rx = 0, n_err = 0;
        int n_clean = 0, n_disp = 0, n_code = 0, n_kerr = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            req_imp = new("req_imp", this);
            tx_imp  = new("tx_imp",  this);
            rx_imp  = new("rx_imp",  this);
            cov_ap  = new("cov_ap",  this);
        endfunction

        // ---- the model runs here, once per request, in order --------------
        function void write_req(c8b_txn t);
            ref_exp_t e;
            e = ref_link_step(t.data, t.k, t.err_mask, tx_rd, rx_rd);
            tx_rd = e.enc_rd;
            rx_rd = e.out_rd;
            tx_q.push_back(e);
            rx_q.push_back(e);
            req_q.push_back(t);
            n_req++;
        endfunction

        function void write_tx(c8b_tx_item t);
            ref_exp_t e;
            if (tx_q.size() == 0) begin
                n_err++;
                `uvm_error("TXEXTRA", "codeword on the wire with no request behind it")
                return;
            end
            e = tx_q.pop_front();
            n_tx++;
            if (t.enc_code  !== e.enc_code  || t.wire_code !== e.wire_code ||
                t.enc_rd    !== e.enc_rd    || t.enc_kerr  !== e.enc_kerr  ||
                t.enc_comma !== e.enc_comma) begin
                n_err++;
                `uvm_error("TXMISMATCH", $sformatf(
                    "transmit #%0d: got code=%b wire=%b rd=%0b kerr=%0b comma=%0b | expected code=%b wire=%b rd=%0b kerr=%0b comma=%0b",
                    n_tx, t.enc_code, t.wire_code, t.enc_rd, t.enc_kerr, t.enc_comma,
                    e.enc_code, e.wire_code, e.enc_rd, e.enc_kerr, e.enc_comma))
            end
        endfunction

        function void write_rx(c8b_rx_item t);
            ref_exp_t   e;
            c8b_txn     r;
            c8b_resolved rv;
            if (rx_q.size() == 0) begin
                n_err++;
                `uvm_error("RXEXTRA", "symbol out of the receiver with no request behind it")
                return;
            end
            e = rx_q.pop_front();
            r = req_q.pop_front();
            n_rx++;
            if (t.out_data     !== e.out_data     || t.out_k        !== e.out_k ||
                t.out_code_err !== e.out_code_err || t.out_disp_err !== e.out_disp_err ||
                t.out_rd       !== e.out_rd       || t.out_comma    !== e.out_comma) begin
                n_err++;
                `uvm_error("RXMISMATCH", $sformatf(
                    "receive #%0d (sent %s 0x%02h mask=%b): got data=%02h k=%0b code_err=%0b disp_err=%0b rd=%0b comma=%0b | expected data=%02h k=%0b code_err=%0b disp_err=%0b rd=%0b comma=%0b",
                    n_rx, r.k ? "K" : "D", r.data, r.err_mask,
                    t.out_data, t.out_k, t.out_code_err, t.out_disp_err, t.out_rd, t.out_comma,
                    e.out_data, e.out_k, e.out_code_err, e.out_disp_err, e.out_rd, e.out_comma))
            end

            // tally, then hand the resolved pair to coverage
            if      (e.out_code_err) n_code++;
            else if (e.out_disp_err) n_disp++;
            else                     n_clean++;
            if (e.enc_kerr) n_kerr++;

            rv = c8b_resolved::type_id::create("rv");
            rv.data      = r.data;
            rv.k         = r.k;
            rv.k_legal   = !e.enc_kerr;
            rv.nflip     = $countones(r.err_mask);
            rv.code_err  = e.out_code_err;
            rv.disp_err  = e.out_disp_err;
            rv.comma     = e.out_comma;
            rv.kerr      = e.enc_kerr;
            rv.recovered = !e.out_code_err && !e.out_disp_err &&
                           (e.out_data == r.data) && (e.out_k == r.k);
            cov_ap.write(rv);
        endfunction

        function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            if (tx_q.size() != 0) begin
                n_err++;
                `uvm_error("TXDRAIN", $sformatf("%0d requests never reached the wire",
                                                tx_q.size()))
            end
            if (rx_q.size() != 0) begin
                n_err++;
                `uvm_error("RXDRAIN", $sformatf("%0d codewords never came out of the receiver",
                                                rx_q.size()))
            end
            if (n_req == 0) begin
                n_err++;
                `uvm_error("NOSTIM", "no requests were driven at all")
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCOREBOARD", $sformatf(
                "%0d requests | %0d codewords checked | %0d symbols checked",
                n_req, n_tx, n_rx), UVM_LOW)
            `uvm_info("SCOREBOARD", $sformatf(
                "verdicts: %0d clean, %0d disparity error, %0d code error, %0d unencodable request",
                n_clean, n_disp, n_code, n_kerr), UVM_LOW)
            if (n_err == 0) `uvm_info("SCOREBOARD", "RESULT: *** PASS ***", UVM_NONE)
            else            `uvm_error("SCOREBOARD", $sformatf(
                                "RESULT: *** FAIL *** (%0d mismatches)", n_err))
        endfunction
    endclass

    // ======================================================================
    // coverage
    // ======================================================================
    class c8b_coverage extends uvm_subscriber #(c8b_resolved);
        `uvm_component_utils(c8b_coverage)

        c8b_resolved it;

        covergroup cg_codec;
            option.per_instance = 1;

            // what was asked for
            cp_kind: coverpoint {it.k, it.k_legal} {
                bins data        = {2'b01, 2'b00};
                bins k_legal     = {2'b11};
                bins k_illegal   = {2'b10};
            }
            // the 3b/4b half, where the alternate-encoding rule lives
            cp_y: coverpoint it.data[7:5] { bins y[] = {[0:7]}; }
            // the 5b/6b half, bucketed by the role x plays in the code
            cp_x_class: coverpoint it.data[4:0] {
                bins a7_data   = {11, 13, 14, 17, 18, 20}; // need D.x.A7
                bins k_capable = {23, 27, 29, 30};         // also K.x.7
                bins k28       = {28};                     // the comma carrier
                bins d07       = {7};                      // balanced-alternating
                bins other     = default;
            }
            // how badly the wire was corrupted
            cp_nflip: coverpoint it.nflip {
                bins clean = {0};
                bins one   = {1};
                bins two   = {2};
                bins many  = {[3:10]};
            }
            // and what the receiver made of it
            cp_verdict: coverpoint {it.code_err, it.disp_err} {
                bins clean     = {2'b00};
                bins disp_err  = {2'b01};
                bins code_err  = {2'b10};
                illegal_bins both = {2'b11};
            }
            cp_comma:     coverpoint it.comma;
            cp_recovered: coverpoint it.recovered;

            // The interesting questions are all crosses.  x_verdict is the
            // headline: did every class of symbol get seen both clean and
            // broken?  nflip_verdict answers "does a single bit flip really
            // get caught", and its clean/one cell is the one that must stay
            // small - a single flip that decodes silently is the code's known
            // residual, not a bug.
            cx_kind_verdict:  cross cp_kind,  cp_verdict;
            cx_nflip_verdict: cross cp_nflip, cp_verdict;
            cx_x_verdict:     cross cp_x_class, cp_verdict;
            cx_y_kind:        cross cp_y, cp_kind;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_codec = new();
        endfunction

        function void write(c8b_resolved t);
            it = t;
            cg_codec.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("COVERAGE", $sformatf("functional coverage: %.2f%%",
                                            cg_codec.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // ======================================================================
    // agent / virtual sequencer / env
    // ======================================================================
    class c8b_agent extends uvm_agent;
        `uvm_component_utils(c8b_agent)
        c8b_sequencer  sqr;
        c8b_driver     drv;
        c8b_in_monitor in_mon;
        c8b_tx_monitor tx_mon;
        c8b_rx_monitor rx_mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr    = c8b_sequencer::type_id::create("sqr", this);
            drv    = c8b_driver::type_id::create("drv", this);
            in_mon = c8b_in_monitor::type_id::create("in_mon", this);
            tx_mon = c8b_tx_monitor::type_id::create("tx_mon", this);
            rx_mon = c8b_rx_monitor::type_id::create("rx_mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class c8b_vseqr extends uvm_sequencer #(uvm_sequence_item);
        `uvm_component_utils(c8b_vseqr)
        c8b_sequencer sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    class c8b_env extends uvm_env;
        `uvm_component_utils(c8b_env)
        c8b_agent      agent;
        c8b_scoreboard sb;
        c8b_coverage   cov;
        c8b_vseqr      vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = c8b_agent::type_id::create("agent", this);
            sb    = c8b_scoreboard::type_id::create("sb", this);
            cov   = c8b_coverage::type_id::create("cov", this);
            vseqr = c8b_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.in_mon.ap.connect(sb.req_imp);
            agent.tx_mon.ap.connect(sb.tx_imp);
            agent.rx_mon.ap.connect(sb.rx_imp);
            sb.cov_ap.connect(cov.analysis_export);
            vseqr.sqr = agent.sqr;
        endfunction
    endclass

    // ======================================================================
    // sequences
    // ======================================================================
    class c8b_base_seq extends uvm_sequence #(c8b_txn);
        `uvm_object_utils(c8b_base_seq)
        function new(string name = "c8b_base_seq"); super.new(name); endfunction

        // one symbol, exactly as specified
        task send(bit [7:0] d, bit k, bit [9:0] mask = 10'b0);
            c8b_txn t = c8b_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { data == d; k == local::k;
                                      err_mask == mask; })
                `uvm_fatal("RAND", "directed symbol failed to randomize")
            finish_item(t);
        endtask
    endclass

    // every one of the 256 data bytes, back to back.  Because the sweep is in
    // order and running disparity is history-dependent, this also walks the
    // encoder through a long, non-repeating RD trajectory.
    class c8b_all_data_seq extends c8b_base_seq;
        `uvm_object_utils(c8b_all_data_seq)
        function new(string name = "c8b_all_data_seq"); super.new(name); endfunction
        task body();
            for (int d = 0; d < 256; d++) send(d[7:0], 1'b0);
        endtask
    endclass

    // all twelve control symbols, each seen from both running-disparity
    // states: D.0.0 is unbalanced, so interleaving it flips RD every time.
    class c8b_kcode_seq extends c8b_base_seq;
        `uvm_object_utils(c8b_kcode_seq)
        function new(string name = "c8b_kcode_seq"); super.new(name); endfunction
        task body();
            foreach (K_LEGAL[i]) begin
                send(K_LEGAL[i], 1'b1);
                send(8'h00, 1'b0);          // D.0.0, flips RD
                send(K_LEGAL[i], 1'b1);
            end
            // and two requests for control symbols that do not exist
            send(8'h00, 1'b1);
            send(8'h55, 1'b1);
        endtask
    endclass

    // the six D.x.7 symbols that need the alternate 3b/4b encoding, driven
    // from both RD states so both the A7 and the P7 branch of the rule is
    // taken for each of them.
    class c8b_a7_seq extends c8b_base_seq;
        `uvm_object_utils(c8b_a7_seq)
        function new(string name = "c8b_a7_seq"); super.new(name); endfunction
        task body();
            foreach (A7_SYMS[i]) begin
                repeat (2) begin
                    send(A7_SYMS[i], 1'b0);
                    send(8'h00, 1'b0);      // flip RD, then do it again
                    send(A7_SYMS[i], 1'b0);
                end
            end
            // D.07 and D.x.3, the two balanced-but-alternating entries
            repeat (4) begin
                send(8'h07, 1'b0);          // D.7.0
                send(8'h67, 1'b0);          // D.7.3
                send(8'h00, 1'b0);
            end
        endtask
    endclass

    // walk a single bit flip through all ten wire positions of a comma, then
    // of a data symbol, then do the same with adjacent double flips.  This is
    // the sequence that populates the error-detection coverage.
    class c8b_error_seq extends c8b_base_seq;
        `uvm_object_utils(c8b_error_seq)
        function new(string name = "c8b_error_seq"); super.new(name); endfunction
        task body();
            for (int b = 0; b < 10; b++) begin
                send(8'hBC, 1'b1, 10'b1 << b);   // K.28.5, the comma
                send(8'h55, 1'b0, 10'b1 << b);   // D.21.2, balanced both halves
                send(8'hEB, 1'b0, 10'b1 << b);   // D.11.7, an A7 symbol
            end
            for (int b = 0; b < 9; b++)
                send(8'hAA, 1'b0, 10'b11 << b);  // adjacent pairs
            // a clean run afterwards: running disparity must come back into
            // step with the transmitter on its own.
            repeat (8) send(8'hBC, 1'b1);
        endtask
    endclass

    class c8b_rand_seq extends c8b_base_seq;
        `uvm_object_utils(c8b_rand_seq)
        rand int unsigned n;
        constraint c_n { n inside {[200:400]}; }
        function new(string name = "c8b_rand_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                c8b_txn t = c8b_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_fatal("RAND", "random symbol failed to randomize")
                finish_item(t);
            end
        endtask
    endclass

    // ---- virtual sequences ------------------------------------------------
    class c8b_smoke_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(c8b_smoke_vseq)
        `uvm_declare_p_sequencer(c8b_vseqr)
        function new(string name = "c8b_smoke_vseq"); super.new(name); endfunction
        task body();
            c8b_all_data_seq s0 = c8b_all_data_seq::type_id::create("s0");
            c8b_kcode_seq    s1 = c8b_kcode_seq::type_id::create("s1");
            `uvm_info("SMOKE", "all 256 data symbols, then all 12 control symbols",
                      UVM_LOW)
            s0.start(p_sequencer.sqr);
            s1.start(p_sequencer.sqr);
        endtask
    endclass

    class c8b_regress_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(c8b_regress_vseq)
        `uvm_declare_p_sequencer(c8b_vseqr)
        function new(string name = "c8b_regress_vseq"); super.new(name); endfunction
        task body();
            c8b_all_data_seq s0 = c8b_all_data_seq::type_id::create("s0");
            c8b_kcode_seq    s1 = c8b_kcode_seq::type_id::create("s1");
            c8b_a7_seq       s2 = c8b_a7_seq::type_id::create("s2");
            c8b_error_seq    s3 = c8b_error_seq::type_id::create("s3");
            c8b_rand_seq     s4 = c8b_rand_seq::type_id::create("s4");
            s0.start(p_sequencer.sqr);
            s1.start(p_sequencer.sqr);
            s2.start(p_sequencer.sqr);
            s3.start(p_sequencer.sqr);
            repeat (4) begin
                if (!s4.randomize()) `uvm_fatal("RAND", "regression seq randomize failed")
                s4.start(p_sequencer.sqr);
            end
        endtask
    endclass

    // ======================================================================
    // tests
    // ======================================================================
    class c8b_base_test extends uvm_test;
        `uvm_component_utils(c8b_base_test)
        c8b_env    env;
        c8b_config cfg;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            cfg = c8b_config::type_id::create("cfg");
            if (!uvm_config_db#(virtual codec_8b10b_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set for the test")
            uvm_config_db#(c8b_config)::set(this, "*", "cfg", cfg);
            env = c8b_env::type_id::create("env", this);
        endfunction

        // What checks the checker: the reference model re-proves the code's
        // defining properties and replays the committed Known-Answer Table
        // before a single DUT result is judged.
        function void start_of_simulation_phase(uvm_phase phase);
            int bad;
            super.start_of_simulation_phase(phase);
            bad  = property_selfcheck(1'b1);
            bad += kat_selfcheck(1'b1);
            if (bad != 0)
                `uvm_fatal("REFMODEL", $sformatf(
                    "the reference model failed its own self-check (%0d problems) - "
                    "no DUT result can be trusted until that is fixed", bad))
        endfunction
    endclass

    class codec_8b10b_smoke_test extends c8b_base_test;
        `uvm_component_utils(codec_8b10b_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            c8b_smoke_vseq vseq = c8b_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            repeat (20) @(posedge cfg.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

    class codec_8b10b_regress_test extends c8b_base_test;
        `uvm_component_utils(codec_8b10b_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            c8b_regress_vseq vseq = c8b_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            repeat (20) @(posedge cfg.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

endpackage : codec_8b10b_pkg
