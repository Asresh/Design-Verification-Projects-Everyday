// -----------------------------------------------------------------------------
// secded_ecc_pkg.sv - UVM verification environment for the SECDED (72,64)
// extended-Hamming ECC ENCODER/DECODER.
//
// Components
//   * secded_item    - a request: op (ENCODE/DECODE), the data word, and (for
//                      DECODE) an injected-error descriptor {nflip, bit0, bit1}.
//   * secded_in_txn  - monitor-reconstructed request (op + data + received word).
//   * secded_out_txn - monitor-observed result (code + data + syndrome + sbe/dbe).
//   * secded_model   - independent golden extended-Hamming SECDED reference
//                      (encode, syndrome, correct, extract, sbe/dbe), used by
//                      both the driver (to build received codewords with faults)
//                      and the scoreboard (to predict every result).
//   * secded_driver  - drives one request per clock; for DECODE it encodes the
//                      data with the golden model and injects nflip bit errors.
//   * secded_monitor - captures requests and results from the pins; pairs them
//                      (FIFO) for the scoreboard.
//   * secded_scoreboard - recomputes the expected {code,data,syndrome,sbe,dbe}
//                      with the golden model and checks against the DUT in order.
//   * secded_coverage - op x error-class (none/single/double) and syndrome-zero
//                      cross coverage.
//   * secded_agent / secded_env / secded_vseqr + sequence/virtual-sequence lib.
//
// Sequences: showcase (encode + clean/1-bit/2-bit decode), corner (all-zero,
// all-ones, parity-bit/overall-parity/data-bit flips, back-to-back), random
// (mixed op, random data, 0/1/2 injected flips). Virtual sequences smoke/regress.
//
// Tests: secded_smoke_test, secded_regress_test (select with +UVM_TESTNAME=...).
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_secded_ecc_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package secded_ecc_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int DW    = 64;
    localparam int HAM   = 7;               // ham_bits(64)
    localparam int NBASE = DW + HAM;        // 71
    localparam int CW    = NBASE + 1;       // 72
    localparam int PIPE  = 2;
    localparam int LAT   = PIPE;

    typedef enum bit {ENC = 1'b0, DEC = 1'b1} secded_op_e;

    // =========================================================================
    // Golden reference model - independent extended-Hamming SECDED.
    // =========================================================================
    class secded_model;
        static function bit is_pow2(int p);
            return (p != 0) && ((p & (p - 1)) == 0);
        endfunction

        // Encode a DW-bit word into its CW-bit codeword (bit0 = overall parity).
        static function bit [CW-1:0] encode(bit [DW-1:0] data);
            bit [CW-1:0] base;
            bit          acc, ovp;
            int          di, p, i;
            base = '0;
            di   = 0;
            for (p = 1; p <= NBASE; p++)
                if (!is_pow2(p)) begin base[p] = data[di]; di++; end
            for (i = 0; i < HAM; i++) begin
                acc = 1'b0;
                for (p = 1; p <= NBASE; p++)
                    if (p != (1 << i) && ((p >> i) & 1)) acc ^= base[p];
                base[1 << i] = acc;
            end
            ovp = 1'b0;
            for (p = 1; p <= NBASE; p++) ovp ^= base[p];
            base[0] = ovp;
            return base;
        endfunction

        static function bit [HAM-1:0] syndrome(bit [CW-1:0] rcv);
            bit [HAM-1:0] s;
            bit           acc;
            int           i, p;
            for (i = 0; i < HAM; i++) begin
                acc = 1'b0;
                for (p = 1; p <= NBASE; p++) if ((p >> i) & 1) acc ^= rcv[p];
                s[i] = acc;
            end
            return s;
        endfunction

        // Mirror the DUT's exact correction so out_code/out_data match bit-for-bit.
        static function bit [CW-1:0] correct(bit [CW-1:0] rcv);
            bit [HAM-1:0] s;
            int           sval, i;
            bit           par;
            bit [CW-1:0]  c;
            s    = syndrome(rcv);
            sval = 0;
            for (i = 0; i < HAM; i++) if (s[i]) sval |= (1 << i);
            par  = ^rcv;
            c    = rcv;
            if (par) begin
                if (sval == 0)          c[0]    = c[0]    ^ 1'b1;
                else if (sval <= NBASE) c[sval] = c[sval] ^ 1'b1;
            end
            return c;
        endfunction

        static function bit sbe(bit [CW-1:0] rcv);
            return ^rcv;                                   // odd parity
        endfunction

        static function bit dbe(bit [CW-1:0] rcv);
            return (^rcv == 1'b0) && (syndrome(rcv) != '0); // even(>0) errors
        endfunction

        static function bit [DW-1:0] extract(bit [CW-1:0] cw);
            bit [DW-1:0] d;
            int          di, p;
            d = '0; di = 0;
            for (p = 1; p <= NBASE; p++)
                if (!is_pow2(p)) begin d[di] = cw[p]; di++; end
            return d;
        endfunction
    endclass

    // =========================================================================
    // Transaction / observed items
    // =========================================================================
    class secded_item extends uvm_sequence_item;
        rand secded_op_e     op;
        rand bit [DW-1:0]    data;
        rand int             nflip;     // DECODE: 0/1/2 injected bit errors
        rand int             bit0, bit1;

        constraint c_nflip { nflip inside {[0:2]}; }
        constraint c_bits  { bit0 inside {[0:CW-1]}; bit1 inside {[0:CW-1]};
                             (nflip == 2) -> (bit0 != bit1); }

        `uvm_object_utils_begin(secded_item)
            `uvm_field_int(op,    UVM_ALL_ON)
            `uvm_field_int(data,  UVM_ALL_ON)
            `uvm_field_int(nflip, UVM_ALL_ON)
            `uvm_field_int(bit0,  UVM_ALL_ON)
            `uvm_field_int(bit1,  UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "secded_item"); super.new(name); endfunction
    endclass

    class secded_in_txn extends uvm_sequence_item;
        secded_op_e    op;
        bit [DW-1:0]   data;      // ENCODE input word
        bit [CW-1:0]   code;      // DECODE received codeword
        `uvm_object_utils(secded_in_txn)
        function new(string name = "secded_in_txn"); super.new(name); endfunction
    endclass

    class secded_out_txn extends uvm_sequence_item;
        secded_op_e    op;
        bit [CW-1:0]   code;
        bit [DW-1:0]   data;
        bit [HAM-1:0]  syndrome;
        bit            sbe, dbe;
        `uvm_object_utils(secded_out_txn)
        function new(string name = "secded_out_txn"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Config
    // =========================================================================
    class secded_cfg extends uvm_object;
        virtual secded_ecc_if vif;
        `uvm_object_utils(secded_cfg)
        function new(string name = "secded_cfg"); super.new(name); endfunction
    endclass

    // =========================================================================
    // Driver - drives one request per clock (zero-bubble capable). For DECODE it
    // encodes the data with the golden model and injects nflip bit errors.
    // =========================================================================
    class secded_driver extends uvm_driver #(secded_item);
        `uvm_component_utils(secded_driver)
        virtual secded_ecc_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual secded_ecc_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "secded_driver: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            vif.drv_cb.in_valid <= 1'b0;
            vif.drv_cb.in_op    <= 1'b0;
            vif.drv_cb.in_data  <= '0;
            vif.drv_cb.in_code  <= '0;
            @(posedge vif.rst_n);
            @(vif.drv_cb);
            forever begin
                secded_item tr;
                bit [CW-1:0] rcv;
                seq_item_port.get_next_item(tr);
                if (tr.op == ENC) begin
                    vif.drv_cb.in_valid <= 1'b1;
                    vif.drv_cb.in_op    <= ENC;
                    vif.drv_cb.in_data  <= tr.data;
                    vif.drv_cb.in_code  <= '0;
                end else begin
                    rcv = secded_model::encode(tr.data);
                    if (tr.nflip >= 1) rcv[tr.bit0] = rcv[tr.bit0] ^ 1'b1;
                    if (tr.nflip == 2) rcv[tr.bit1] = rcv[tr.bit1] ^ 1'b1;
                    vif.drv_cb.in_valid <= 1'b1;
                    vif.drv_cb.in_op    <= DEC;
                    vif.drv_cb.in_data  <= '0;
                    vif.drv_cb.in_code  <= rcv;
                end
                @(vif.drv_cb);
                vif.drv_cb.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitor - captures requests and results, pairs them.
    // =========================================================================
    class secded_monitor extends uvm_monitor;
        `uvm_component_utils(secded_monitor)
        virtual secded_ecc_if vif;
        uvm_analysis_port #(secded_in_txn)  ap_in;
        uvm_analysis_port #(secded_out_txn) ap_out;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_in  = new("ap_in", this);
            ap_out = new("ap_out", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual secded_ecc_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "secded_monitor: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            @(posedge vif.rst_n);
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.in_valid) begin
                    secded_in_txn it = secded_in_txn::type_id::create("it");
                    it.op   = secded_op_e'(vif.mon_cb.in_op);
                    it.data = vif.mon_cb.in_data;
                    it.code = vif.mon_cb.in_code;
                    ap_in.write(it);
                end
                if (vif.mon_cb.out_valid) begin
                    secded_out_txn ot = secded_out_txn::type_id::create("ot");
                    ot.op       = secded_op_e'(vif.mon_cb.out_op);
                    ot.code     = vif.mon_cb.out_code;
                    ot.data     = vif.mon_cb.out_data;
                    ot.syndrome = vif.mon_cb.out_syndrome;
                    ot.sbe      = vif.mon_cb.out_sbe;
                    ot.dbe      = vif.mon_cb.out_dbe;
                    ap_out.write(ot);
                end
            end
        endtask
    endclass

    // =========================================================================
    // Agent
    // =========================================================================
    class secded_agent extends uvm_agent;
        `uvm_component_utils(secded_agent)
        secded_driver                    drv;
        secded_monitor                   mon;
        uvm_sequencer #(secded_item)     seqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon  = secded_monitor::type_id::create("mon", this);
            drv  = secded_driver::type_id::create("drv", this);
            seqr = uvm_sequencer#(secded_item)::type_id::create("seqr", this);
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

    class secded_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(secded_scoreboard)
        uvm_analysis_imp_in  #(secded_in_txn,  secded_scoreboard) sb_in;
        uvm_analysis_imp_out #(secded_out_txn, secded_scoreboard) sb_out;

        secded_op_e    exp_op   [$];
        bit [CW-1:0]   exp_code [$];
        bit [DW-1:0]   exp_data [$];
        bit [HAM-1:0]  exp_synd [$];
        bit            exp_sbe  [$];
        bit            exp_dbe  [$];
        int            matched, mismatched;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            sb_in   = new("sb_in",  this);
            sb_out  = new("sb_out", this);
            matched = 0; mismatched = 0;
        endfunction

        // request -> predict the expected result from the golden model
        function void write_in(secded_in_txn t);
            bit [CW-1:0] cc;
            if (t.op == ENC) begin
                exp_op.push_back(ENC);
                exp_code.push_back(secded_model::encode(t.data));
                exp_data.push_back(t.data);
                exp_synd.push_back('0);
                exp_sbe.push_back(1'b0);
                exp_dbe.push_back(1'b0);
            end else begin
                cc = secded_model::correct(t.code);
                exp_op.push_back(DEC);
                exp_code.push_back(cc);
                exp_data.push_back(secded_model::extract(cc));
                exp_synd.push_back(secded_model::syndrome(t.code));
                exp_sbe.push_back(secded_model::sbe(t.code));
                exp_dbe.push_back(secded_model::dbe(t.code));
            end
        endfunction

        // DUT result -> compare against the head of the expected FIFO
        function void write_out(secded_out_txn t);
            secded_op_e eo; bit [CW-1:0] ec; bit [DW-1:0] ed;
            bit [HAM-1:0] es; bit eb, edb;
            if (exp_op.size() == 0) begin
                mismatched++;
                `uvm_error("SB", $sformatf("unexpected result (FIFO empty) op=%0d", t.op))
                return;
            end
            eo  = exp_op.pop_front();  ec  = exp_code.pop_front();
            ed  = exp_data.pop_front(); es = exp_synd.pop_front();
            eb  = exp_sbe.pop_front();  edb = exp_dbe.pop_front();
            if (t.op !== eo || t.code !== ec || t.data !== ed ||
                t.syndrome !== es || t.sbe !== eb || t.dbe !== edb) begin
                mismatched++;
                `uvm_error("SB", $sformatf(
                    "MISMATCH DUT{op=%0d data=%016h synd=%02h sbe=%0d dbe=%0d} EXP{op=%0d data=%016h synd=%02h sbe=%0d dbe=%0d}",
                    t.op, t.data, t.syndrome, t.sbe, t.dbe, eo, ed, es, eb, edb))
            end else begin
                matched++;
                `uvm_info("SB", $sformatf("OK op=%0d data=%016h synd=%02h sbe=%0d dbe=%0d",
                                          t.op, t.data, t.syndrome, t.sbe, t.dbe), UVM_HIGH)
            end
        endfunction

        function void report_phase(uvm_phase phase);
            if (exp_op.size() != 0)
                `uvm_error("SB", $sformatf("%0d expected results never arrived", exp_op.size()))
            `uvm_info("SB", $sformatf("matched=%0d mismatched=%0d", matched, mismatched), UVM_LOW)
            if (mismatched == 0 && matched > 0)
                `uvm_info("SB", "RESULT: *** PASS ***", UVM_LOW)
            else
                `uvm_error("SB", "RESULT: *** FAIL ***")
        endfunction
    endclass

    // =========================================================================
    // Coverage - op x error-class and syndrome-zero.
    // =========================================================================
    `uvm_analysis_imp_decl(_cin)
    `uvm_analysis_imp_decl(_cout)

    class secded_coverage extends uvm_component;
        `uvm_component_utils(secded_coverage)
        uvm_analysis_imp_cin  #(secded_in_txn,  secded_coverage) cin;
        uvm_analysis_imp_cout #(secded_out_txn, secded_coverage) cout;

        secded_op_e cg_op; int cg_class; bit cg_synd_zero;

        // error class of a request: 0 none, 1 single, 2 double
        function int errclass(secded_in_txn t);
            if (t.op == ENC)                    return 0;
            if (secded_model::dbe(t.code))      return 2;
            if (secded_model::sbe(t.code))      return 1;
            return 0;
        endfunction

        covergroup cg_in;
            option.per_instance = 1;
            cp_op    : coverpoint cg_op;
            cp_class : coverpoint cg_class {
                bins none   = {0};
                bins single = {1};
                bins double = {2};
            }
            x_op_class : cross cp_op, cp_class;
        endgroup

        covergroup cg_out;
            option.per_instance = 1;
            cp_synd_zero : coverpoint cg_synd_zero;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cin  = new("cin",  this);
            cout = new("cout", this);
            cg_in  = new();
            cg_out = new();
        endfunction

        function void write_cin(secded_in_txn t);
            cg_op = t.op; cg_class = errclass(t);
            cg_in.sample();
        endfunction
        function void write_cout(secded_out_txn t);
            cg_synd_zero = (t.syndrome == '0);
            cg_out.sample();
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer
    // =========================================================================
    class secded_vseqr extends uvm_sequencer;
        `uvm_component_utils(secded_vseqr)
        uvm_sequencer #(secded_item) seqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class secded_env extends uvm_env;
        `uvm_component_utils(secded_env)
        secded_agent      agent;
        secded_scoreboard sb;
        secded_coverage   cov;
        secded_vseqr      vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = secded_agent::type_id::create("agent", this);
            sb    = secded_scoreboard::type_id::create("sb", this);
            cov   = secded_coverage::type_id::create("cov", this);
            vseqr = secded_vseqr::type_id::create("vseqr", this);
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

    // Directed showcase: encode a word, then decode it clean / 1-bit / 2-bit.
    class secded_showcase_seq extends uvm_sequence #(secded_item);
        `uvm_object_utils(secded_showcase_seq)
        function new(string name = "secded_showcase_seq"); super.new(name); endfunction

        task drive(secded_op_e op, bit [DW-1:0] d, int nf, int b0, int b1);
            secded_item tr = secded_item::type_id::create("tr");
            start_item(tr);
            tr.op = op; tr.data = d; tr.nflip = nf; tr.bit0 = b0; tr.bit1 = b1;
            finish_item(tr);
        endtask

        task body();
            bit [DW-1:0] w = 64'h0123456789ABCDEF;
            drive(ENC, w, 0, 0, 0);      // encode
            drive(DEC, w, 0, 0, 0);      // decode clean
            drive(DEC, w, 1, 20, 0);     // single-bit flip -> corrected
            drive(DEC, w, 2, 9, 40);     // double-bit flip -> detected
        endtask
    endclass

    // Directed corners.
    class secded_corner_seq extends uvm_sequence #(secded_item);
        `uvm_object_utils(secded_corner_seq)
        function new(string name = "secded_corner_seq"); super.new(name); endfunction

        task drive(secded_op_e op, bit [DW-1:0] d, int nf, int b0, int b1);
            secded_item tr = secded_item::type_id::create("tr");
            start_item(tr);
            tr.op = op; tr.data = d; tr.nflip = nf; tr.bit0 = b0; tr.bit1 = b1;
            finish_item(tr);
        endtask

        task body();
            bit [DW-1:0] w = 64'hDEADBEEF_CAFEF00D;
            drive(ENC, 64'h0, 0, 0, 0);          // encode all-zero
            drive(ENC, {DW{1'b1}}, 0, 0, 0);     // encode all-ones
            drive(DEC, w, 1, 16, 0);             // flip a Hamming parity bit
            drive(DEC, w, 1, 0, 0);              // flip the overall-parity bit
            drive(DEC, w, 1, 33, 0);             // flip a data bit
            drive(DEC, w, 0, 0, 0);              // clean back-to-back
        endtask
    endclass

    // Constrained-random: mixed op, random data, 0/1/2 injected flips.
    class secded_random_seq extends uvm_sequence #(secded_item);
        `uvm_object_utils(secded_random_seq)
        rand int n_ops;
        constraint c_n { n_ops inside {[40:120]}; }
        function new(string name = "secded_random_seq"); super.new(name); endfunction

        task body();
            for (int i = 0; i < n_ops; i++) begin
                secded_item tr = secded_item::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize())
                    `uvm_error("RND", "randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // =========================================================================
    // Virtual sequences
    // =========================================================================
    class secded_smoke_vseq extends uvm_sequence;
        `uvm_object_utils(secded_smoke_vseq)
        secded_vseqr vseqr;
        function new(string name = "secded_smoke_vseq"); super.new(name); endfunction
        task body();
            secded_showcase_seq sh = secded_showcase_seq::type_id::create("sh");
            secded_corner_seq   co = secded_corner_seq::type_id::create("co");
            sh.start(vseqr.seqr);
            co.start(vseqr.seqr);
        endtask
    endclass

    class secded_regress_vseq extends uvm_sequence;
        `uvm_object_utils(secded_regress_vseq)
        secded_vseqr vseqr;
        function new(string name = "secded_regress_vseq"); super.new(name); endfunction
        task body();
            secded_showcase_seq sh = secded_showcase_seq::type_id::create("sh");
            secded_corner_seq   co = secded_corner_seq::type_id::create("co");
            secded_random_seq   rn = secded_random_seq::type_id::create("rn");
            sh.start(vseqr.seqr);
            co.start(vseqr.seqr);
            void'(rn.randomize());
            rn.start(vseqr.seqr);
        endtask
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class secded_base_test extends uvm_test;
        `uvm_component_utils(secded_base_test)
        secded_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = secded_env::type_id::create("env", this);
        endfunction
    endclass

    class secded_smoke_test extends secded_base_test;
        `uvm_component_utils(secded_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            secded_smoke_vseq v = secded_smoke_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(env.vseqr);
            #(20*LAT*10ns);
            phase.drop_objection(this);
        endtask
    endclass

    class secded_regress_test extends secded_base_test;
        `uvm_component_utils(secded_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            secded_regress_vseq v = secded_regress_vseq::type_id::create("v");
            phase.raise_objection(this);
            v.vseqr = env.vseqr;
            v.start(env.vseqr);
            #(40*LAT*10ns);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
