// -----------------------------------------------------------------------------
// uart_pkg.sv  -  UVM verification environment for the uart DUT
//
// Two independent paths are verified:
//
//   TX path :  tx_driver pulses (tx_start,tx_data); tx_in_mon captures the sent
//              byte; tx_line_mon reconstructs the byte from the tx_serial line;
//              the scoreboard checks reconstructed == sent (TX serializes).
//   RX path :  rx_driver bit-bangs a byte onto rx_serial; rx_line_mon
//              reconstructs it from the line; rx_out_mon captures (rx_valid,
//              rx_data); the scoreboard checks captured == on-the-wire
//              (RX deserializes).
//
// Components:
//   transaction  : uart_txn (data + baud)
//   sequencers   : uart_tx_sequencer, uart_rx_sequencer
//   sequences    : uart_tx_seq, uart_rx_seq (directed patterns + random)
//   drivers      : uart_tx_driver, uart_rx_driver
//   monitors     : uart_tx_in_mon, uart_tx_line_mon, uart_rx_line_mon,
//                  uart_rx_out_mon
//   coverage     : uart_coverage (data patterns + baud)
//   agents       : uart_tx_agent, uart_rx_agent
//   scoreboard   : uart_scoreboard (TX sent-vs-line, RX line-vs-out)
//   vsequencer   : uart_vsequencer  + uart_baud_vseq (multi-baud regression)
//   env          : uart_env
//   tests        : uart_base_test, uart_smoke_test, uart_regress_test
// -----------------------------------------------------------------------------
package uart_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    // =========================================================================
    // Transaction
    // =========================================================================
    class uart_txn extends uvm_sequence_item;
        rand bit [7:0]  data;
        rand bit [15:0] cfg;    // baud divisor (clocks per bit)

        constraint c_cfg { cfg inside {[8:64]}; }

        `uvm_object_utils_begin(uart_txn)
            `uvm_field_int(data, UVM_ALL_ON)
            `uvm_field_int(cfg,  UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "uart_txn");
            super.new(name);
        endfunction
    endclass

    // =========================================================================
    // Sequencers
    // =========================================================================
    typedef uvm_sequencer #(uart_txn) uart_tx_sequencer;
    typedef uvm_sequencer #(uart_txn) uart_rx_sequencer;

    // =========================================================================
    // Sequences  (directed data patterns + constrained random)
    // =========================================================================
    class uart_byte_seq extends uvm_sequence #(uart_txn);
        `uvm_object_utils(uart_byte_seq)
        bit [15:0] baud = 16;
        int unsigned n_rand = 8;
        function new(string name = "uart_byte_seq"); super.new(name); endfunction

        task send(bit [7:0] d);
            uart_txn t = uart_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { data == d; cfg == baud; })
                `uvm_error(get_type_name(), "directed randomize failed")
            finish_item(t);
        endtask

        virtual task body();
            // Directed corner patterns.
            send(8'h00); send(8'hFF); send(8'hA5); send(8'h55);
            send(8'h01); send(8'h80); send(8'h7E); send(8'hC3);
            // Constrained-random payloads at the same baud.
            for (int i = 0; i < n_rand; i++) begin
                uart_txn t = uart_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { cfg == baud; })
                    `uvm_error(get_type_name(), "rand randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // Distinct type names for the two agents (identical behaviour).
    class uart_tx_seq extends uart_byte_seq;
        `uvm_object_utils(uart_tx_seq)
        function new(string name = "uart_tx_seq"); super.new(name); endfunction
    endclass
    class uart_rx_seq extends uart_byte_seq;
        `uvm_object_utils(uart_rx_seq)
        function new(string name = "uart_rx_seq"); super.new(name); endfunction
    endclass

    // =========================================================================
    // TX driver  -  pulses tx_start / tx_data, waits for tx_done
    // =========================================================================
    class uart_tx_driver extends uvm_driver #(uart_txn);
        `uvm_component_utils(uart_tx_driver)
        virtual uart_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for tx driver")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.tx_drv_cb.tx_start <= 1'b0;
            vif.tx_drv_cb.tx_data  <= 8'h00;
            forever begin
                uart_txn t;
                seq_item_port.get_next_item(t);
                wait (vif.rst_n === 1'b1);
                // Wait until the transmitter is idle.
                while (vif.tx_busy === 1'b1) @(vif.tx_drv_cb);
                @(vif.tx_drv_cb);
                vif.tx_drv_cb.tx_start <= 1'b1;
                vif.tx_drv_cb.tx_data  <= t.data;
                @(vif.tx_drv_cb);
                vif.tx_drv_cb.tx_start <= 1'b0;
                // Wait for the frame to complete.
                do @(vif.tx_drv_cb); while (vif.tx_drv_cb.tx_done !== 1'b1);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // RX driver  -  bit-bangs a byte onto rx_serial at the current baud
    // =========================================================================
    class uart_rx_driver extends uvm_driver #(uart_txn);
        `uvm_component_utils(uart_rx_driver)
        virtual uart_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for rx driver")
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.rx_drv_cb.rx_serial <= 1'b1;   // idle high
            forever begin
                uart_txn t;
                int      n;
                seq_item_port.get_next_item(t);
                wait (vif.rst_n === 1'b1);
                n = vif.cfg_clks_per_bit;
                // Start bit.
                vif.rx_drv_cb.rx_serial <= 1'b0;
                repeat (n) @(vif.rx_drv_cb);
                // Data bits, LSB first.
                for (int i = 0; i < 8; i++) begin
                    vif.rx_drv_cb.rx_serial <= t.data[i];
                    repeat (n) @(vif.rx_drv_cb);
                end
                // Stop bit + a little idle.
                vif.rx_drv_cb.rx_serial <= 1'b1;
                repeat (n) @(vif.rx_drv_cb);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // Monitors
    // =========================================================================
    // Captures the byte requested on the parallel TX interface (on tx_start).
    class uart_tx_in_mon extends uvm_monitor;
        `uvm_component_utils(uart_tx_in_mon)
        virtual uart_if vif;
        uvm_analysis_port #(uart_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for tx_in_mon")
        endfunction
        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n === 1'b1 && vif.mon_cb.tx_start) begin
                    uart_txn t = uart_txn::type_id::create("tx_sent");
                    t.data = vif.mon_cb.tx_data;
                    t.cfg  = vif.mon_cb.cfg_clks_per_bit;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // Reconstructs the byte from the tx_serial line (centre sampling).
    class uart_tx_line_mon extends uvm_monitor;
        `uvm_component_utils(uart_tx_line_mon)
        virtual uart_if vif;
        uvm_analysis_port #(uart_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for tx_line_mon")
        endfunction
        virtual task run_phase(uvm_phase phase);
            wait (vif.rst_n === 1'b1);
            forever begin
                int         n;
                bit [7:0]   b;
                @(negedge vif.tx_serial);           // start-bit edge
                n = vif.cfg_clks_per_bit;
                repeat (n/2) @(vif.mon_cb);          // -> centre of start bit
                for (int i = 0; i < 8; i++) begin
                    repeat (n) @(vif.mon_cb);        // -> centre of data bit i
                    b[i] = vif.mon_cb.tx_serial;
                end
                repeat (n) @(vif.mon_cb);            // pass through stop bit
                begin
                    uart_txn t = uart_txn::type_id::create("tx_line");
                    t.data = b;
                    t.cfg  = n;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // Reconstructs the byte from the rx_serial line (independent of the DUT RX).
    class uart_rx_line_mon extends uvm_monitor;
        `uvm_component_utils(uart_rx_line_mon)
        virtual uart_if vif;
        uvm_analysis_port #(uart_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for rx_line_mon")
        endfunction
        virtual task run_phase(uvm_phase phase);
            wait (vif.rst_n === 1'b1);
            forever begin
                int       n;
                bit [7:0] b;
                @(negedge vif.rx_serial);
                n = vif.cfg_clks_per_bit;
                repeat (n/2) @(vif.mon_cb);
                for (int i = 0; i < 8; i++) begin
                    repeat (n) @(vif.mon_cb);
                    b[i] = vif.mon_cb.rx_serial;
                end
                repeat (n) @(vif.mon_cb);
                begin
                    uart_txn t = uart_txn::type_id::create("rx_line");
                    t.data = b;
                    t.cfg  = n;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // Captures the deserialized byte on the parallel RX interface (rx_valid).
    class uart_rx_out_mon extends uvm_monitor;
        `uvm_component_utils(uart_rx_out_mon)
        virtual uart_if vif;
        uvm_analysis_port #(uart_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for rx_out_mon")
        endfunction
        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n === 1'b1 && vif.mon_cb.rx_valid) begin
                    uart_txn t = uart_txn::type_id::create("rx_out");
                    t.data = vif.mon_cb.rx_data;
                    t.cfg  = vif.mon_cb.cfg_clks_per_bit;
                    ap.write(t);
                    if (vif.mon_cb.framing_err)
                        `uvm_error(get_type_name(), "framing_err on received byte")
                end
            end
        endtask
    endclass

    // =========================================================================
    // Coverage  -  data patterns + baud
    // =========================================================================
    class uart_coverage extends uvm_subscriber #(uart_txn);
        `uvm_component_utils(uart_coverage)
        uart_txn tr;

        covergroup cg;
            option.per_instance = 1;
            cp_data : coverpoint tr.data {
                bins zero    = {8'h00};
                bins allones = {8'hFF};
                bins lsb     = {8'h01};
                bins msb     = {8'h80};
                bins alt_a   = {8'hA5};
                bins alt_5   = {8'h55};
                bins others  = default;
            }
            cp_baud : coverpoint tr.cfg {
                bins b12 = {12};
                bins b16 = {16};
                bins b20 = {20};
                bins b24 = {24};
                bins other = default;
            }
            x_data_baud : cross cp_data, cp_baud;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent); cg = new();
        endfunction
        function void write(uart_txn t);
            tr = t; cg.sample();
        endfunction
    endclass

    // =========================================================================
    // Agents
    // =========================================================================
    class uart_tx_agent extends uvm_agent;
        `uvm_component_utils(uart_tx_agent)
        uart_tx_driver    driver;
        uart_tx_sequencer sequencer;
        uart_tx_in_mon    in_mon;
        uart_tx_line_mon  line_mon;
        uart_coverage     coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            in_mon   = uart_tx_in_mon  ::type_id::create("in_mon", this);
            line_mon = uart_tx_line_mon::type_id::create("line_mon", this);
            coverage = uart_coverage   ::type_id::create("coverage", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = uart_tx_driver   ::type_id::create("driver", this);
                sequencer = uart_tx_sequencer::type_id::create("sequencer", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            in_mon.ap.connect(coverage.analysis_export);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    class uart_rx_agent extends uvm_agent;
        `uvm_component_utils(uart_rx_agent)
        uart_rx_driver    driver;
        uart_rx_sequencer sequencer;
        uart_rx_line_mon  line_mon;
        uart_rx_out_mon   out_mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            line_mon = uart_rx_line_mon::type_id::create("line_mon", this);
            out_mon  = uart_rx_out_mon ::type_id::create("out_mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = uart_rx_driver   ::type_id::create("driver", this);
                sequencer = uart_rx_sequencer::type_id::create("sequencer", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Scoreboard  -  TX: sent vs serialized ; RX: on-wire vs deserialized
    // =========================================================================
    `uvm_analysis_imp_decl(_txsent)
    `uvm_analysis_imp_decl(_txline)
    `uvm_analysis_imp_decl(_rxline)
    `uvm_analysis_imp_decl(_rxout)

    class uart_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(uart_scoreboard)
        uvm_analysis_imp_txsent #(uart_txn, uart_scoreboard) imp_txsent;
        uvm_analysis_imp_txline #(uart_txn, uart_scoreboard) imp_txline;
        uvm_analysis_imp_rxline #(uart_txn, uart_scoreboard) imp_rxline;
        uvm_analysis_imp_rxout  #(uart_txn, uart_scoreboard) imp_rxout;

        bit [7:0] tx_sent_q [$];
        bit [7:0] rx_line_q [$];
        int unsigned n_checks;
        int unsigned n_errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp_txsent = new("imp_txsent", this);
            imp_txline = new("imp_txline", this);
            imp_rxline = new("imp_rxline", this);
            imp_rxout  = new("imp_rxout",  this);
        endfunction

        // TX sent byte -> expected queue.
        function void write_txsent(uart_txn t);
            tx_sent_q.push_back(t.data);
        endfunction
        // TX serialized byte -> compare against the sent queue.
        function void write_txline(uart_txn t);
            bit [7:0] exp;
            n_checks++;
            if (tx_sent_q.size() == 0) begin
                n_errors++;
                `uvm_error(get_type_name(), "TX serialized byte with no sent byte pending")
                return;
            end
            exp = tx_sent_q.pop_front();
            if (t.data !== exp) begin
                n_errors++;
                `uvm_error(get_type_name(), $sformatf(
                    "TX mismatch: sent=0x%02h serialized=0x%02h", exp, t.data))
            end
        endfunction

        // RX on-wire byte -> expected queue.
        function void write_rxline(uart_txn t);
            rx_line_q.push_back(t.data);
        endfunction
        // RX deserialized byte -> compare against the on-wire queue.
        function void write_rxout(uart_txn t);
            bit [7:0] exp;
            n_checks++;
            if (rx_line_q.size() == 0) begin
                n_errors++;
                `uvm_error(get_type_name(), "RX deserialized byte with no on-wire byte pending")
                return;
            end
            exp = rx_line_q.pop_front();
            if (t.data !== exp) begin
                n_errors++;
                `uvm_error(get_type_name(), $sformatf(
                    "RX mismatch: on-wire=0x%02h received=0x%02h", exp, t.data))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info(get_type_name(), $sformatf(
                "scoreboard: %0d byte-checks, %0d errors (%0d TX-pending, %0d RX-pending)",
                n_checks, n_errors, tx_sent_q.size(), rx_line_q.size()), UVM_LOW)
            if (n_checks == 0)
                `uvm_error(get_type_name(), "scoreboard saw no byte checks")
            if (tx_sent_q.size() != 0 || rx_line_q.size() != 0)
                `uvm_error(get_type_name(), "unmatched bytes left in a queue")
        endfunction
    endclass

    // =========================================================================
    // Virtual sequencer + multi-baud virtual sequence
    // =========================================================================
    class uart_vsequencer extends uvm_sequencer;
        `uvm_component_utils(uart_vsequencer)
        uart_tx_sequencer tx_seqr;
        uart_rx_sequencer rx_seqr;
        virtual uart_if   vif;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class uart_vseq_base extends uvm_sequence;
        `uvm_object_utils(uart_vseq_base)
        `uvm_declare_p_sequencer(uart_vsequencer)
        function new(string name = "uart_vseq_base"); super.new(name); endfunction
    endclass

    // Smoke: one baud, TX and RX streams in parallel.
    class uart_smoke_vseq extends uart_vseq_base;
        `uvm_object_utils(uart_smoke_vseq)
        function new(string name = "uart_smoke_vseq"); super.new(name); endfunction
        virtual task body();
            uart_tx_seq ts = uart_tx_seq::type_id::create("ts");
            uart_rx_seq rs = uart_rx_seq::type_id::create("rs");
            ts.baud = 16; rs.baud = 16;
            p_sequencer.vif.cfg_clks_per_bit = 16;
            fork
                ts.start(p_sequencer.tx_seqr);
                rs.start(p_sequencer.rx_seqr);
            join
        endtask
    endclass

    // Regression: sweep several baud divisors; at each, run TX + RX streams.
    class uart_regress_vseq extends uart_vseq_base;
        `uvm_object_utils(uart_regress_vseq)
        function new(string name = "uart_regress_vseq"); super.new(name); endfunction
        virtual task body();
            bit [15:0] bauds [] = '{16, 24, 12, 20};
            foreach (bauds[k]) begin
                uart_tx_seq ts = uart_tx_seq::type_id::create("ts");
                uart_rx_seq rs = uart_rx_seq::type_id::create("rs");
                ts.baud = bauds[k]; rs.baud = bauds[k];
                p_sequencer.vif.cfg_clks_per_bit = bauds[k];
                fork
                    ts.start(p_sequencer.tx_seqr);
                    rs.start(p_sequencer.rx_seqr);
                join
            end
        endtask
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class uart_env extends uvm_env;
        `uvm_component_utils(uart_env)
        uart_tx_agent   tx_agent;
        uart_rx_agent   rx_agent;
        uart_scoreboard scoreboard;
        uart_vsequencer vseqr;
        virtual uart_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for env")
            tx_agent   = uart_tx_agent  ::type_id::create("tx_agent", this);
            rx_agent   = uart_rx_agent  ::type_id::create("rx_agent", this);
            scoreboard = uart_scoreboard::type_id::create("scoreboard", this);
            vseqr      = uart_vsequencer::type_id::create("vseqr", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            tx_agent.in_mon.ap.connect(scoreboard.imp_txsent);
            tx_agent.line_mon.ap.connect(scoreboard.imp_txline);
            rx_agent.line_mon.ap.connect(scoreboard.imp_rxline);
            rx_agent.out_mon.ap.connect(scoreboard.imp_rxout);
            vseqr.tx_seqr = tx_agent.sequencer;
            vseqr.rx_seqr = rx_agent.sequencer;
            vseqr.vif     = vif;
        endfunction
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class uart_base_test extends uvm_test;
        `uvm_component_utils(uart_base_test)
        uart_env env;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = uart_env::type_id::create("env", this);
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class uart_smoke_test extends uart_base_test;
        `uvm_component_utils(uart_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            uart_smoke_vseq vs = uart_smoke_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            #20000;   // let the last frame drain
            phase.drop_objection(this);
        endtask
    endclass

    class uart_regress_test extends uart_base_test;
        `uvm_component_utils(uart_regress_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            uart_regress_vseq vs = uart_regress_vseq::type_id::create("vs");
            phase.raise_objection(this);
            vs.start(env.vseqr);
            #20000;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
