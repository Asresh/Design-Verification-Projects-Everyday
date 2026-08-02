// -----------------------------------------------------------------------------
// crc32_stream_pkg.sv - UVM verification environment for the STREAMING CRC-32
// (Ethernet FCS) GENERATOR/CHECKER.
//
// Components
//   * crc_item      - a frame transaction: mode (GENERATE/CHECK) + payload bytes.
//   * crc_in_txn    - monitor-reconstructed input frame (mode + bytes streamed).
//   * crc_out_txn   - monitor-observed frame result (crc + mode + ok).
//   * crc_model     - independent golden reflected CRC-32 reference (bit-identical
//                     to the DUT and to zlib/binascii.crc32); computes the FCS and
//                     the check-mode residue/ok verdict.
//   * crc_driver    - streams each frame's bytes one per clock (sop/eop framing),
//                     zero-bubble within a frame.
//   * crc_monitor   - reconstructs input frames from the pin stream and captures
//                     frame results; pairs them (FIFO) for the scoreboard.
//   * crc_scoreboard- for every input frame recomputes the expected {crc, mode,
//                     ok} with the golden model and checks it against the DUT
//                     result in arrival order.
//   * crc_coverage  - mode x length-class and mode x ok cross coverage.
//   * crc_agent / crc_env / crc_vseqr and the sequence/virtual-sequence library.
//
// Sequences: showcase (canonical "123456789" generate + a good/bad check frame),
// corner (single-byte, all-zero, all-0xFF, back-to-back), random (mixed-mode,
// random-length, good/corrupted check frames). Virtual sequences smoke/regress.
//
// Tests: crc_smoke_test, crc_regress_test (select with +UVM_TESTNAME=...).
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_crc32_stream_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package crc32_stream_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int              DW      = 8;
    localparam int              CRCW    = 32;
    localparam [CRCW-1:0]       POLY    = 32'hEDB88320;
    localparam [CRCW-1:0]       INIT    = 32'hFFFFFFFF;
    localparam [CRCW-1:0]       XOROUT  = 32'hFFFFFFFF;
    localparam [CRCW-1:0]       RESIDUE = 32'h2144DF1C;
    localparam int              PIPE    = 2;
    localparam int              LAT     = PIPE;

    typedef enum bit {GEN = 1'b0, CHK = 1'b1} crc_mode_e;

    // =========================================================================
    // Golden reference model - reflected CRC-32, bit-identical to the DUT.
    // =========================================================================
    class crc_model;
        static function bit [CRCW-1:0] crc(bit [7:0] data[]);
            bit [CRCW-1:0] c;
            c = INIT;
            foreach (data[i]) begin
                c = c ^ {{(CRCW-DW){1'b0}}, data[i]};
                for (int k = 0; k < DW; k++)
                    c = c[0] ? ((c >> 1) ^ POLY) : (c >> 1);
            end
            return c ^ XOROUT;
        endfunction

        // Build message||little-endian-FCS as a receiver sees a good frame.
        static function void append_fcs(ref bit [7:0] b[]);
            bit [CRCW-1:0] f;
            int n;
            f = crc(b);
            n = b.size();
            b = new [n + 4] (b);
            b[n]   = f[7:0];
            b[n+1] = f[15:8];
            b[n+2] = f[23:16];
            b[n+3] = f[31:24];
        endfunction
    endclass

    // =========================================================================
    // Transaction / observed items
    // =========================================================================
    class crc_item extends uvm_sequence_item;
        rand crc_mode_e       mode;
        rand bit [7:0]        data[];       // bytes actually streamed to the DUT

        constraint c_len { data.size() inside {[1:16]}; }

        `uvm_object_utils_begin(crc_item)
            `uvm_field_int(mode, UVM_ALL_ON)
            `uvm_field_array_int(data, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "crc_item"); super.new(name); endfunction
    endclass

    class crc_in_txn extends uvm_sequence_item;
        crc_mode_e     mode;
        bit [7:0]      data[];
        `uvm_object_utils(crc_in_txn)
        function new(string name = "crc_in_txn"); super.new(name); endfunction
    endclass

    class crc_out_txn extends uvm_sequence_item;
        bit [CRCW-1:0] crc;
        crc_mode_e     mode;
        bit            ok;
        `uvm_object_utils(crc_out_txn)
        function new(string name = "crc_out_txn"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class crc_cfg extends uvm_object;
        virtual crc32_stream_if vif;
        `uvm_object_utils(crc_cfg)
        function new(string name = "crc_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Driver - streams each frame's bytes, one per clock, sop/eop framed.
    // =========================================================================
    class crc_driver extends uvm_driver #(crc_item);
        `uvm_component_utils(crc_driver)
        virtual crc32_stream_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual crc32_stream_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "crc_driver: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            // idle
            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_sop   <= 1'b0;
            vif.drv_cb.in_eop   <= 1'b0;
            vif.drv_cb.in_mode  <= 1'b0;
            vif.drv_cb.in_data  <= '0;
            @(posedge vif.rst_n);
            @(vif.drv_cb);
            forever begin
                crc_item tr;
                int n;
                seq_item_port.get_next_item(tr);
                n = tr.data.size();
                for (int i = 0; i < n; i++) begin
                    vif.drv_cb.in_valid <= 1'b1;
                    vif.drv_cb.in_sop   <= (i == 0);
                    vif.drv_cb.in_eop   <= (i == n-1);
                    vif.drv_cb.in_mode  <= tr.mode;
                    vif.drv_cb.in_data  <= tr.data[i];
                    @(vif.drv_cb);
                end
                vif.drv_cb.in_valid <= 1'b0;
                vif.drv_cb.in_sop   <= 1'b0;
                vif.drv_cb.in_eop   <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - reconstructs input frames + captures results, pairs them.
    // =========================================================================
    class crc_monitor extends uvm_monitor;
        `uvm_component_utils(crc_monitor)
        virtual crc32_stream_if vif;
        uvm_analysis_port #(crc_in_txn)  ap_in;
        uvm_analysis_port #(crc_out_txn) ap_out;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_in  = new("ap_in", this);
            ap_out = new("ap_out", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual crc32_stream_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "crc_monitor: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            bit [7:0]  acc[$];
            crc_mode_e fmode;
            @(posedge vif.rst_n);
            forever begin
                @(vif.mon_cb);
                // reconstruct an input frame from the pin stream
                if (vif.mon_cb.in_valid) begin
                    if (vif.mon_cb.in_sop) begin
                        acc.delete();
                        fmode = crc_mode_e'(vif.mon_cb.in_mode);
                    end
                    acc.push_back(vif.mon_cb.in_data);
                    if (vif.mon_cb.in_eop) begin
                        crc_in_txn it = crc_in_txn::type_id::create("it");
                        it.mode = fmode;
                        it.data = new [acc.size()];
                        foreach (acc[j]) it.data[j] = acc[j];
                        ap_in.write(it);
                    end
                end
                // capture a frame result
                if (vif.mon_cb.out_valid) begin
                    crc_out_txn ot = crc_out_txn::type_id::create("ot");
                    ot.crc  = vif.mon_cb.out_crc;
                    ot.mode = crc_mode_e'(vif.mon_cb.out_mode);
                    ot.ok   = vif.mon_cb.out_ok;
                    ap_out.write(ot);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class crc_agent extends uvm_agent;
        `uvm_component_utils(crc_agent)
        crc_driver                     drv;
        crc_monitor                    mon;
        uvm_sequencer #(crc_item)      seqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon  = crc_monitor::type_id::create("mon", this);
            drv  = crc_driver::type_id::create("drv", this);
            seqr = uvm_sequencer#(crc_item)::type_id::create("seqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard - golden-model expected vs DUT result, FIFO ordered.
    // =========================================================================
    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    class crc_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(crc_scoreboard)
        uvm_analysis_imp_in  #(crc_in_txn,  crc_scoreboard) sb_in;
        uvm_analysis_imp_out #(crc_out_txn, crc_scoreboard) sb_out;

        // expected-result FIFOs
        bit [CRCW-1:0] exp_crc  [$];
        crc_mode_e     exp_mode [$];
        bit            exp_ok   [$];
        int            matched, mismatched;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            sb_in   = new("sb_in",  this);
            sb_out  = new("sb_out", this);
            matched = 0; mismatched = 0;
        endfunction

        // input frame -> compute expected result from the golden model
        function void write_in(crc_in_txn t);
            bit [CRCW-1:0] f;
            f = crc_model::crc(t.data);
            exp_crc.push_back(f);
            exp_mode.push_back(t.mode);
            exp_ok.push_back(t.mode == CHK ? (f == RESIDUE) : 1'b1);
        endfunction

        // DUT result -> compare against the head of the expected FIFO
        function void write_out(crc_out_txn t);
            bit [CRCW-1:0] ec; crc_mode_e em; bit eo;
            if (exp_crc.size() == 0) begin
                mismatched++;
                `uvm_error("SB", $sformatf("unexpected result crc=%08h (FIFO empty)", t.crc))
                return;
            end
            ec = exp_crc.pop_front();
            em = exp_mode.pop_front();
            eo = exp_ok.pop_front();
            if (t.crc !== ec || t.mode !== em || t.ok !== eo) begin
                mismatched++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH DUT{crc=%08h mode=%0d ok=%0d} EXP{crc=%08h mode=%0d ok=%0d}",
                    t.crc, t.mode, t.ok, ec, em, eo))
            end else begin
                matched++;
                `uvm_info("SB", $sformatf("OK crc=%08h mode=%0d ok=%0d",
                                          t.crc, t.mode, t.ok), UVM_HIGH)
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (exp_crc.size() != 0)
                `uvm_error("SB", $sformatf("%0d expected results never arrived", exp_crc.size()))
            `uvm_info("SB", $sformatf("matched=%0d mismatched=%0d", matched, mismatched), UVM_LOW)
            if (mismatched == 0 && matched > 0)
                `uvm_info("SB", "RESULT: *** PASS ***", UVM_LOW)
            else
                `uvm_error("SB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // =========================================================================
    // Coverage - mode x length-class (inputs) and mode x ok (results).
    // =========================================================================
    `uvm_analysis_imp_decl(_cin)
    `uvm_analysis_imp_decl(_cout)

    class crc_coverage extends uvm_component;
        `uvm_component_utils(crc_coverage)
        uvm_analysis_imp_cin  #(crc_in_txn,  crc_coverage) cin;
        uvm_analysis_imp_cout #(crc_out_txn, crc_coverage) cout;

        crc_mode_e cg_mode; int cg_len; crc_mode_e cg_omode; bit cg_ok;

        covergroup cg_in;
            option.per_instance = 1;
            cp_mode : coverpoint cg_mode;
            cp_len  : coverpoint cg_len {
                bins one    = {1};
                bins small  = {[2:4]};
                bins medium = {[5:8]};
                bins large  = {[9:32]};
            }
            x_mode_len : cross cp_mode, cp_len;
        endgroup

        covergroup cg_out;
            option.per_instance = 1;
            cp_omode : coverpoint cg_omode;
            cp_ok    : coverpoint cg_ok;
            x_mode_ok : cross cp_omode, cp_ok;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cin  = new("cin",  this);
            cout = new("cout", this);
            cg_in  = new();
            cg_out = new();
        endfunction

        function void write_cin(crc_in_txn t);
            cg_mode = t.mode; cg_len = t.data.size();
            cg_in.sample();
        endfunction
        function void write_cout(crc_out_txn t);
            cg_omode = t.mode; cg_ok = t.ok;
            cg_out.sample();
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer
    // =========================================================================
    class crc_vseqr extends uvm_sequencer;
        `uvm_component_utils(crc_vseqr)
        uvm_sequencer #(crc_item) seqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class crc_env extends uvm_env;
        `uvm_component_utils(crc_env)
        crc_agent      agent;
        crc_scoreboard sb;
        crc_coverage   cov;
        crc_vseqr      vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = crc_agent::type_id::create("agent", this);
            sb    = crc_scoreboard::type_id::create("sb", this);
            cov   = crc_coverage::type_id::create("cov", this);
            vseqr = crc_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap_in.connect(sb.sb_in);
            agent.mon.ap_out.connect(sb.sb_out);
            agent.mon.ap_in.connect(cov.cin);
            agent.mon.ap_out.connect(cov.cout);
            vseqr.seqr = agent.seqr;
        endfunction
    endclass

    // =========================================================================
    // Sequences
    // =========================================================================

    // Directed showcase: canonical "123456789" generate + good/bad check frame.
    class crc_showcase_seq extends uvm_sequence #(crc_item);
        `uvm_object_utils(crc_showcase_seq)
        function new(string name = "crc_showcase_seq"); super.new(name); endfunction

        task body();
            crc_item tr;
            bit [7:0] m[];
            // 1) GENERATE "123456789" -> FCS 0xCBF43926
            tr = crc_item::type_id::create("tr");
            m = new [9]; foreach (m[i]) m[i] = 8'h31 + i;
            start_item(tr); tr.mode = GEN; tr.data = m; finish_item(tr);
            // 2) CHECK good: message||FCS -> ok=1, residue 0x2144DF1C
            tr = crc_item::type_id::create("tr");
            m = new [9]; foreach (m[i]) m[i] = 8'h31 + i;
            crc_model::append_fcs(m);
            start_item(tr); tr.mode = CHK; tr.data = m; finish_item(tr);
            // 3) CHECK bad: corrupt a payload byte -> ok=0
            tr = crc_item::type_id::create("tr");
            m = new [9]; foreach (m[i]) m[i] = 8'h31 + i;
            crc_model::append_fcs(m);
            m[3] = m[3] ^ 8'hFF;
            start_item(tr); tr.mode = CHK; tr.data = m; finish_item(tr);
        endtask
    endclass

    // Directed corners.
    class crc_corner_seq extends uvm_sequence #(crc_item);
        `uvm_object_utils(crc_corner_seq)
        function new(string name = "crc_corner_seq"); super.new(name); endfunction

        task drive(crc_mode_e md, bit [7:0] d[]);
            crc_item tr = crc_item::type_id::create("tr");
            start_item(tr); tr.mode = md; tr.data = d; finish_item(tr);
        endtask

        task body();
            bit [7:0] d[];
            d = new [1]; d[0] = 8'h41;                         drive(GEN, d);   // single byte
            d = new [4]; foreach (d[i]) d[i] = 8'h00;          drive(GEN, d);   // all-zero
            d = new [4]; foreach (d[i]) d[i] = 8'hFF;          drive(GEN, d);   // all-0xFF
            d = new [2]; d[0]=8'hDE; d[1]=8'hAD;               drive(GEN, d);   // b2b
            d = new [3]; d[0]=8'hBE; d[1]=8'hEF; d[2]=8'h55;   drive(GEN, d);
            d = new [1]; d[0]=8'h01;                           drive(GEN, d);
        endtask
    endclass

    // Constrained-random: mixed mode, random length, good/corrupted check frames.
    class crc_random_seq extends uvm_sequence #(crc_item);
        `uvm_object_utils(crc_random_seq)
        rand int n_frames;
        constraint c_n { n_frames inside {[20:60]}; }
        function new(string name = "crc_random_seq"); super.new(name); endfunction

        task body();
            for (int f = 0; f < n_frames; f++) begin
                crc_item tr = crc_item::type_id::create("tr");
                int len = $urandom_range(1, 12);
                bit md  = $urandom_range(0, 1);
                bit [7:0] d[] = new [len];
                foreach (d[i]) d[i] = $urandom_range(0, 255);
                if (md == CHK) begin
                    crc_model::append_fcs(d);
                    if ($urandom_range(0, 2) == 0) begin       // ~1/3 corrupted
                        int bidx = $urandom_range(0, d.size()-1);
                        d[bidx] = d[bidx] ^ (8'h01 << $urandom_range(0, 7));
                    end
                end
                start_item(tr); tr.mode = crc_mode_e'(md); tr.data = d; finish_item(tr);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class crc_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(crc_smoke_vseq)
        crc_vseqr vseqr;
        function new(string name = "crc_smoke_vseq"); super.new(name); endfunction
        task body();
            crc_showcase_seq sh = crc_showcase_seq::type_id::create("sh");
            crc_corner_seq   co = crc_corner_seq::type_id::create("co");
            sh.start(vseqr.seqr);
            co.start(vseqr.seqr);
        endtask
    endclass

    class crc_regress_vseq extends uvm_sequence;
        `uvm_object_utils(crc_regress_vseq)
        crc_vseqr vseqr;
        function new(string name = "crc_regress_vseq"); super.new(name); endfunction
        task body();
            crc_showcase_seq sh = crc_showcase_seq::type_id::create("sh");
            crc_corner_seq   co = crc_corner_seq::type_id::create("co");
            crc_random_seq   rn = crc_random_seq::type_id::create("rn");
            sh.start(vseqr.seqr);
            co.start(vseqr.seqr);
            void'(rn.randomize());
            rn.start(vseqr.seqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class crc_base_test extends uvm_test;
        `uvm_component_utils(crc_base_test)
        crc_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = crc_env::type_id::create("env", this);
        endfunction
    endclass

    class crc_smoke_test extends crc_base_test;
        `uvm_component_utils(crc_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            crc_smoke_vseq v = crc_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(env.vseqr);
            #(20*LAT*10ns);
            phase.drop_objection(this);
        endtask
    endclass

    class crc_regress_test extends crc_base_test;
        `uvm_component_utils(crc_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            crc_regress_vseq v = crc_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(env.vseqr);
            #(40*LAT*10ns);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
