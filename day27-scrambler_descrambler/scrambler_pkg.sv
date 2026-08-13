// ============================================================================
// scrambler_pkg.sv - UVM environment for the self-synchronizing scrambler /
// descrambler link (G(x)=1+x^39+x^58, WIDTH bits/cycle).
// ----------------------------------------------------------------------------
// Contents:
//   * scr_config      - virtual-interface + knobs config object
//   * scr_txn         - sequence item {data, inject; observed scrambled/recovered}
//   * scr_driver      - one-word-per-cycle (zero-bubble) stimulus driver
//   * scr_in_monitor  - publishes the driven stimulus stream
//   * scr_out_monitor - publishes the scrambled-midpoint and recovered streams
//   * scr_scoreboard  - independent bit-serial golden model; checks the
//                       scrambled word, the descrambled word, and the
//                       self-sync RECOVERY (recovered == original once locked)
//   * scr_coverage    - data-class x inject x lock-state functional coverage
//   * scr_agent       - sequencer + driver + input monitor
//   * scr_vseqr       - virtual sequencer
//   * scr_env         - agent + output monitor + scoreboard + coverage + vseqr
//   * sequences       - all-zero / payload / random(+inject) + virtual smoke/regress
//   * tests           - scrambler_smoke_test, scrambler_regress_test
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_scrambler_dump.sv (see the Makefile).
// ============================================================================
`timescale 1ns/1ps

package scrambler_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Link parameters (must match the DUT instances in tb_top).
    localparam int unsigned WIDTH  = 8;
    localparam int unsigned LFSR_W = 58;
    localparam int unsigned TAP_A  = 39;
    localparam int unsigned TAP_B  = 58;
    localparam logic [LFSR_W-1:0] SEED_TX = {LFSR_W{1'b1}};
    localparam logic [LFSR_W-1:0] SEED_RX = '0;
    localparam int unsigned LOCK_WORDS = (LFSR_W + WIDTH - 1) / WIDTH;

    // Analysis imp declarations for the three streams into the scoreboard.
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_scr)
    `uvm_analysis_imp_decl(_des)

    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------
    class scr_config extends uvm_object;
        `uvm_object_utils(scr_config)
        virtual scrambler_if vif;
        function new(string name = "scr_config"); super.new(name); endfunction
    endclass

    // ------------------------------------------------------------------
    // Transaction
    // ------------------------------------------------------------------
    class scr_txn extends uvm_sequence_item;
        rand logic [WIDTH-1:0] data;    // payload word to transmit
        rand logic [WIDTH-1:0] inject;  // wire-error XOR mask (0 = clean)
        // observed (filled by monitors/scoreboard)
        logic [WIDTH-1:0]      scrambled;
        logic [WIDTH-1:0]      recovered;

        // by default the wire is clean; error sequences override.
        constraint c_clean { soft inject == '0; }

        `uvm_object_utils_begin(scr_txn)
            `uvm_field_int(data,      UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(inject,    UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(scrambled, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(recovered, UVM_ALL_ON | UVM_HEX)
        `uvm_object_utils_end

        function new(string name = "scr_txn"); super.new(name); endfunction
    endclass

    typedef uvm_sequencer#(scr_txn) scr_sequencer;

    // ------------------------------------------------------------------
    // Driver - one word per clock (zero-bubble while items are queued).
    // ------------------------------------------------------------------
    class scr_driver extends uvm_driver#(scr_txn);
        `uvm_component_utils(scr_driver)
        virtual scrambler_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            scr_config cfg;
            if (!uvm_config_db#(scr_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "scr_config not set")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            scr_txn req;
            // idle until reset released
            vif.in_valid    = 1'b0;
            vif.in_data     = '0;
            vif.inject_mask = '0;
            @(posedge vif.rst_n);
            forever begin
                @(vif.drv_cb);
                seq_item_port.try_next_item(req);
                if (req != null) begin
                    vif.drv_cb.in_valid    <= 1'b1;
                    vif.drv_cb.in_data     <= req.data;
                    vif.drv_cb.inject_mask <= req.inject;
                    seq_item_port.item_done();
                end else begin
                    vif.drv_cb.in_valid    <= 1'b0;
                    vif.drv_cb.inject_mask <= '0;
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Input monitor - publishes each driven word (data + inject) in order.
    // ------------------------------------------------------------------
    class scr_in_monitor extends uvm_monitor;
        `uvm_component_utils(scr_in_monitor)
        virtual scrambler_if vif;
        uvm_analysis_port#(scr_txn) ap_in;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap_in = new("ap_in", this);
        endfunction
        function void build_phase(uvm_phase phase);
            scr_config cfg;
            if (!uvm_config_db#(scr_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "scr_config not set")
            vif = cfg.vif;
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.in_valid) begin
                    scr_txn t = scr_txn::type_id::create("in_t");
                    t.data   = vif.in_data;
                    t.inject = vif.inject_mask;
                    ap_in.write(t);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Output monitor - publishes the scrambled midpoint and recovered stream.
    // ------------------------------------------------------------------
    class scr_out_monitor extends uvm_monitor;
        `uvm_component_utils(scr_out_monitor)
        virtual scrambler_if vif;
        uvm_analysis_port#(scr_txn) ap_scr;
        uvm_analysis_port#(scr_txn) ap_des;
        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_scr = new("ap_scr", this);
            ap_des = new("ap_des", this);
        endfunction
        function void build_phase(uvm_phase phase);
            scr_config cfg;
            if (!uvm_config_db#(scr_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "scr_config not set")
            vif = cfg.vif;
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.scr_valid) begin
                    scr_txn s = scr_txn::type_id::create("scr_t");
                    s.scrambled = vif.scr_data;
                    ap_scr.write(s);
                end
                if (vif.rst_n && vif.des_valid) begin
                    scr_txn d = scr_txn::type_id::create("des_t");
                    d.recovered = vif.des_data;
                    ap_des.write(d);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Scoreboard - independent bit-serial golden model + self-sync recovery.
    // ------------------------------------------------------------------
    class scr_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(scr_scoreboard)

        uvm_analysis_imp_in #(scr_txn, scr_scoreboard) imp_in;
        uvm_analysis_imp_scr#(scr_txn, scr_scoreboard) imp_scr;
        uvm_analysis_imp_des#(scr_txn, scr_scoreboard) imp_des;

        // stimulus + observed FIFOs
        scr_txn          in_q  [$];
        logic [WIDTH-1:0] scr_q [$];
        logic [WIDTH-1:0] des_q [$];

        // golden state
        logic [LFSR_W-1:0] g_tx = SEED_TX;
        logic [LFSR_W-1:0] g_rx = SEED_RX;

        int unsigned checks, errors;
        int unsigned n_locked, n_unlocked, n_inject;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp_in  = new("imp_in",  this);
            imp_scr = new("imp_scr", this);
            imp_des = new("imp_des", this);
        endfunction

        // independent bit-serial recurrence (a different implementation from
        // the RTL's parallel unroll).
        function logic [WIDTH-1:0] serial_step(ref logic [LFSR_W-1:0] st,
                                               input logic [WIDTH-1:0] din,
                                               input bit descramble);
            logic [LFSR_W-1:0] cur; logic fb, ob, fed; logic [WIDTH-1:0] o;
            cur = st;
            for (int unsigned j = 0; j < WIDTH; j++) begin
                fb  = cur[TAP_A-1] ^ cur[TAP_B-1];
                ob  = din[j] ^ fb;
                fed = descramble ? din[j] : ob;
                o[j] = ob;
                cur = {cur[LFSR_W-2:0], fed};
            end
            st = cur;
            return o;
        endfunction

        function void write_in (scr_txn t);          in_q.push_back(t);         try_check(); endfunction
        function void write_scr(scr_txn t);          scr_q.push_back(t.scrambled); try_check(); endfunction
        function void write_des(scr_txn t);          des_q.push_back(t.recovered); try_check(); endfunction

        // Consume one aligned (input, scrambled, recovered) triple.
        function void try_check();
            while (in_q.size() > 0 && scr_q.size() > 0 && des_q.size() > 0) begin
                scr_txn           t   = in_q.pop_front();
                logic [WIDTH-1:0] so  = scr_q.pop_front();
                logic [WIDTH-1:0] ro  = des_q.pop_front();
                logic [WIDTH-1:0] sp, link, rp;
                bit               locked;
                locked = (g_rx == g_tx) && (t.inject == '0);      // pre-word sync
                sp   = serial_step(g_tx, t.data, 1'b0);           // predicted scrambled
                link = so ^ t.inject;                             // what RX receives
                rp   = serial_step(g_rx, link, 1'b1);             // predicted recovered

                checks++;
                if (so !== sp) begin
                    errors++;
                    `uvm_error("SCB", $sformatf("scramble mismatch: obs=0x%02h exp=0x%02h", so, sp))
                end
                checks++;
                if (ro !== rp) begin
                    errors++;
                    `uvm_error("SCB", $sformatf("descramble mismatch: obs=0x%02h exp=0x%02h", ro, rp))
                end
                if (t.inject != '0) n_inject++;
                if (locked) begin
                    n_locked++;
                    checks++;
                    if (ro !== t.data) begin
                        errors++;
                        `uvm_error("SCB", $sformatf(
                            "recovery mismatch: recovered=0x%02h original=0x%02h", ro, t.data))
                    end
                end else begin
                    n_unlocked++;
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCB", $sformatf(
                "checks=%0d errors=%0d locked=%0d unlocked=%0d injected=%0d",
                checks, errors, n_locked, n_unlocked, n_inject), UVM_LOW)
            if (errors == 0 && checks > 0 && n_locked > 0 && n_unlocked > 0)
                `uvm_info("SCB", "RESULT: *** PASS ***", UVM_LOW)
            else
                `uvm_error("SCB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Coverage
    // ------------------------------------------------------------------
    class scr_coverage extends uvm_subscriber#(scr_txn);
        `uvm_component_utils(scr_coverage)
        logic [WIDTH-1:0] d, inj;

        covergroup cg;
            cp_data : coverpoint d {
                bins zero = {0};
                bins ff   = {8'hFF};
                bins mid  = {[1:8'hFE]};
            }
            cp_inj  : coverpoint (inj != 0) { bins clean = {0}; bins err = {1}; }
            x_di    : cross cp_data, cp_inj;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent); cg = new();
        endfunction
        function void write(scr_txn t);
            d = t.data; inj = t.inject; cg.sample();
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Agent (active): sequencer + driver + input monitor
    // ------------------------------------------------------------------
    class scr_agent extends uvm_agent;
        `uvm_component_utils(scr_agent)
        scr_sequencer   sqr;
        scr_driver      drv;
        scr_in_monitor  mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = scr_sequencer  ::type_id::create("sqr", this);
            drv = scr_driver     ::type_id::create("drv", this);
            mon = scr_in_monitor ::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Virtual sequencer
    // ------------------------------------------------------------------
    class scr_vseqr extends uvm_sequencer#(uvm_sequence_item);
        `uvm_component_utils(scr_vseqr)
        scr_sequencer seqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // ------------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------------
    class scr_env extends uvm_env;
        `uvm_component_utils(scr_env)
        scr_agent       agent;
        scr_out_monitor omon;
        scr_scoreboard  scb;
        scr_coverage    cov;
        scr_vseqr       vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            agent = scr_agent      ::type_id::create("agent", this);
            omon  = scr_out_monitor::type_id::create("omon",  this);
            scb   = scr_scoreboard ::type_id::create("scb",   this);
            cov   = scr_coverage   ::type_id::create("cov",   this);
            vseqr = scr_vseqr      ::type_id::create("vseqr", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agent.mon.ap_in.connect(scb.imp_in);
            agent.mon.ap_in.connect(cov.analysis_export);
            omon.ap_scr.connect(scb.imp_scr);
            omon.ap_des.connect(scb.imp_des);
            vseqr.seqr = agent.sqr;
        endfunction
    endclass

    // ==================================================================
    // Sequences
    // ==================================================================
    class scr_base_seq extends uvm_sequence#(scr_txn);
        `uvm_object_utils(scr_base_seq)
        function new(string name = "scr_base_seq"); super.new(name); endfunction
    endclass

    // fixed payload of bytes (clean wire).
    class scr_payload_seq extends uvm_sequence#(scr_txn);
        `uvm_object_utils(scr_payload_seq)
        logic [WIDTH-1:0] bytes[$];
        function new(string name = "scr_payload_seq"); super.new(name); endfunction
        task body();
            foreach (bytes[i]) begin
                scr_txn t = scr_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { data == bytes[i]; inject == '0; })
                    `uvm_error("RAND", "payload randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // N all-zero words (whitening showcase).
    class scr_zero_seq extends uvm_sequence#(scr_txn);
        `uvm_object_utils(scr_zero_seq)
        int unsigned n = 16;
        function new(string name = "scr_zero_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                scr_txn t = scr_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { data == '0; inject == '0; })
                    `uvm_error("RAND", "zero randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // N random words, ~rate%% of them carrying a single-bit wire error.
    class scr_rand_seq extends uvm_sequence#(scr_txn);
        `uvm_object_utils(scr_rand_seq)
        int unsigned n    = 400;
        int unsigned rate = 3;      // percent of words with an injected error
        function new(string name = "scr_rand_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                bit     err = ($urandom_range(0, 99) < rate);
                scr_txn t   = scr_txn::type_id::create("t");
                start_item(t);
                if (err) begin
                    if (!t.randomize() with {
                            inject inside {8'h01,8'h02,8'h04,8'h08,
                                           8'h10,8'h20,8'h40,8'h80}; })
                        `uvm_error("RAND", "rand(err) randomize failed")
                end else begin
                    if (!t.randomize() with { inject == '0; })
                        `uvm_error("RAND", "rand(clean) randomize failed")
                end
                finish_item(t);
            end
        endtask
    endclass

    // ---- Virtual sequences ----
    class scr_smoke_vseq extends uvm_sequence#(uvm_sequence_item);
        `uvm_object_utils(scr_smoke_vseq)
        `uvm_declare_p_sequencer(scr_vseqr)
        function new(string name = "scr_smoke_vseq"); super.new(name); endfunction
        task body();
            scr_payload_seq pay;
            scr_zero_seq    zed;
            // headline self-sync: mixed payload straight out of reset.
            pay = scr_payload_seq::type_id::create("pay");
            pay.bytes = '{8'h00,8'hFF,8'hA5,8'h5A,8'h01,8'h80,
                          8'h12,8'h34,8'h56,8'h78,8'h9A,8'hBC,
                          8'h00,8'hFF,8'hA5,8'h5A,8'h01,8'h80,
                          8'h12,8'h34,8'h56,8'h78,8'h9A,8'hBC};
            pay.start(p_sequencer.seqr);
            // all-zero whitening
            zed = scr_zero_seq::type_id::create("zed");
            zed.n = 16;
            zed.start(p_sequencer.seqr);
        endtask
    endclass

    class scr_regress_vseq extends uvm_sequence#(uvm_sequence_item);
        `uvm_object_utils(scr_regress_vseq)
        `uvm_declare_p_sequencer(scr_vseqr)
        function new(string name = "scr_regress_vseq"); super.new(name); endfunction
        task body();
            scr_payload_seq pay;
            scr_rand_seq    rnd;
            pay = scr_payload_seq::type_id::create("pay");
            pay.bytes = '{8'h00,8'hFF,8'hA5,8'h5A,8'h01,8'h80,
                          8'h12,8'h34,8'h56,8'h78,8'h9A,8'hBC};
            pay.start(p_sequencer.seqr);
            rnd = scr_rand_seq::type_id::create("rnd");
            rnd.n = 1200; rnd.rate = 3;
            rnd.start(p_sequencer.seqr);
        endtask
    endclass

    // ==================================================================
    // Tests
    // ==================================================================
    class scr_base_test extends uvm_test;
        `uvm_component_utils(scr_base_test)
        scr_env    env;
        scr_config cfg;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            env = scr_env::type_id::create("env", this);
            cfg = scr_config::type_id::create("cfg");
            if (!uvm_config_db#(virtual scrambler_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set")
            uvm_config_db#(scr_config)::set(this, "*", "cfg", cfg);
        endfunction
    endclass

    class scrambler_smoke_test extends scr_base_test;
        `uvm_component_utils(scrambler_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            scr_smoke_vseq v = scr_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.start(env.vseqr);
            repeat (20) @(posedge env.agent.mon.vif.clk);   // drain pipeline
            phase.drop_objection(this);
        endtask
    endclass

    class scrambler_regress_test extends scr_base_test;
        `uvm_component_utils(scrambler_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            scr_regress_vseq v = scr_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.start(env.vseqr);
            repeat (20) @(posedge env.agent.mon.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
