// ============================================================================
// cache_ctrl_pkg.sv - the UVM verification environment for the write-back,
// write-allocate, direct-mapped cache controller.
// ----------------------------------------------------------------------------
// Two agents, because there are two independent things to control:
//
//   cpu_agent   ACTIVE, the master side.  Drives loads, stores, flushes and
//               resets, and monitors the request/response pair.
//
//   mem_agent   ACTIVE and RESPONDING, the slave side.  Its driver *is* the
//               backing memory: it answers reads, absorbs posted writes, and
//               applies whatever ready/latency policy the current sequence
//               asks for.  Its monitor reports every memory transaction to
//               the scoreboard, which is how the scoreboard learns what the
//               cache actually wrote to DRAM.
//
// The virtual sequencer exists so a test can coordinate the two: "make memory
// slow and hostile, THEN run the conflict thrash" is a statement about both
// agents at once, and it belongs in one virtual sequence rather than being
// smeared across two independent sequences that hope to line up.
//
// The scoreboard holds two models:
//
//   cache_ref_pkg   the golden architectural model - what every read must
//                   return, and what memory must eventually contain.
//   dut_back[]      a mirror of physical memory rebuilt purely from observed
//                   memory writes.  Nothing else feeds it.
//
// Comparing those two after a flush is the check that gives the whole
// environment its teeth: it is the only one that can tell a cache that
// returns the right data from a cache that returns the right data and
// corrupts DRAM behind your back.
// ============================================================================
`timescale 1ns/1ps

package cache_ctrl_pkg;

    import uvm_pkg::*;
    import cache_ref_pkg::*;
`include "uvm_macros.svh"

    localparam int ADDR_W = 32;
    localparam int DATA_W = 32;
    localparam int BYTES  = DATA_W/8;

    // ========================================================================
    // Configuration
    // ========================================================================
    class cache_config extends uvm_object;
        `uvm_object_utils(cache_config)

        virtual cache_ctrl_if vif;

        // how hard the memory pushes back, set by the memory policy sequence
        int unsigned mem_stall_pct = 0;    // 0..99
        int unsigned mem_lat_min   = 0;
        int unsigned mem_lat_max   = 0;

        function new(string name = "cache_config");
            super.new(name);
        endfunction
    endclass

    // ========================================================================
    // The CPU-side transaction.
    //
    // Addresses are randomised as (tag, set, word) rather than as a flat 32-bit
    // number.  That is not cosmetic: the interesting stimulus for a
    // direct-mapped cache is "same set, different tag", and that is trivial to
    // constrain in this form and awkward in any other.
    // ========================================================================
    typedef enum bit [1:0] { OP_READ, OP_WRITE, OP_FLUSH, OP_RESET } cache_op_e;

    class cache_txn extends uvm_sequence_item;

        rand cache_op_e          op;
        rand bit [2:0]           tag_sel;    // 0..REF_TAGS-1
        rand bit [2:0]           set_sel;    // 0..REF_SETS-1
        rand bit [1:0]           word_sel;   // 0..REF_LINE_WORDS-1
        rand bit [DATA_W-1:0]    wdata;
        rand bit [BYTES-1:0]     wstrb;
        rand int unsigned        pre_delay;  // idle cycles before the request

        // knobs a sequence turns
        int unsigned             tag_limit  = REF_TAGS - 1;
        bit                      lock_set   = 0;
        bit [2:0]                locked_set = 0;

        // filled in by the monitor / predicted by the scoreboard
        bit [ADDR_W-1:0]         addr;
        bit [DATA_W-1:0]         rsp_data;
        bit                      rsp_hit;

        `uvm_object_utils_begin(cache_txn)
            `uvm_field_enum(cache_op_e, op, UVM_ALL_ON)
            `uvm_field_int(tag_sel,   UVM_ALL_ON)
            `uvm_field_int(set_sel,   UVM_ALL_ON)
            `uvm_field_int(word_sel,  UVM_ALL_ON)
            `uvm_field_int(wdata,     UVM_ALL_ON)
            `uvm_field_int(wstrb,     UVM_ALL_ON)
            `uvm_field_int(addr,      UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(rsp_data,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(rsp_hit,   UVM_ALL_ON)
        `uvm_object_utils_end

        constraint c_op       { op inside {OP_READ, OP_WRITE}; }
        constraint c_tag      { tag_sel <= tag_limit; }
        constraint c_set      { lock_set -> (set_sel == locked_set); }
        constraint c_delay    { pre_delay inside {[0:3]};
                                pre_delay dist {0 := 70, [1:3] := 30}; }
        // A read carries no strobes; a write with a zero strobe is legal and
        // architecturally invisible, and is worth generating sometimes.
        constraint c_strb     { (op == OP_READ) -> (wstrb == 4'h0);
                                (op == OP_WRITE) -> wstrb dist {4'h0 := 5,
                                                                4'hF := 50,
                                                                [4'h1:4'hE] := 45}; }

        function new(string name = "cache_txn");
            super.new(name);
        endfunction

        // (tag, set, word) -> byte address, the same packing the reference
        // model and the DUT's address decode use.
        function void post_randomize();
            addr = addr_of(int'(tag_sel), int'(set_sel), int'(word_sel));
        endfunction

        static function bit [ADDR_W-1:0] addr_of(int t, int s, int w);
            bit [ADDR_W-1:0] a;
            a = (((t * REF_SETS) + s) * REF_LINE_WORDS + w) * BYTES;
            return a;
        endfunction

        function string convert2string();
            case (op)
                OP_FLUSH: return "FLUSH";
                OP_RESET: return "RESET";
                OP_READ:  return $sformatf("RD  addr=%08h", addr);
                default:  return $sformatf("WR  addr=%08h data=%08h strb=%04b",
                                           addr, wdata, wstrb);
            endcase
        endfunction
    endclass

    // ========================================================================
    // What the memory monitor reports.
    // ========================================================================
    class mem_txn extends uvm_sequence_item;
        rand bit                 we;
        rand bit [ADDR_W-1:0]    addr;
        rand bit [DATA_W-1:0]    data;

        `uvm_object_utils_begin(mem_txn)
            `uvm_field_int(we,   UVM_ALL_ON)
            `uvm_field_int(addr, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
        `uvm_object_utils_end

        function new(string name = "mem_txn");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("MEM %s addr=%08h data=%08h",
                             we ? "WR" : "RD", addr, data);
        endfunction
    endclass

    // ========================================================================
    // The item that sets the memory slave's behaviour.  Making the response
    // policy a sequence item rather than a config field means a test can
    // change it mid-run - "get hostile after the cache warms up" - which is
    // exactly when a fill/evict interaction bug shows up.
    // ========================================================================
    class mem_policy_txn extends uvm_sequence_item;
        rand int unsigned stall_pct;
        rand int unsigned lat_min;
        rand int unsigned lat_max;
        rand int unsigned hold_cycles;   // how long this policy stays in force

        `uvm_object_utils_begin(mem_policy_txn)
            `uvm_field_int(stall_pct,   UVM_ALL_ON)
            `uvm_field_int(lat_min,     UVM_ALL_ON)
            `uvm_field_int(lat_max,     UVM_ALL_ON)
            `uvm_field_int(hold_cycles, UVM_ALL_ON)
        `uvm_object_utils_end

        constraint c_pol { stall_pct   inside {[0:80]};
                           lat_min     inside {[0:4]};
                           lat_max     inside {[0:8]};
                           lat_max     >= lat_min;
                           hold_cycles inside {[50:400]}; }

        function new(string name = "mem_policy_txn");
            super.new(name);
        endfunction
    endclass

    // ========================================================================
    // CPU-side driver.
    //
    // It also owns rst_n, because asserting reset while the cache is full of
    // dirty lines is one of the behaviours under test, and a reset that can
    // only happen at time zero would never reach it.
    // ========================================================================
    class cache_driver extends uvm_driver #(cache_txn);
        `uvm_component_utils(cache_driver)

        virtual cache_ctrl_if vif;
        cache_config          cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(cache_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cache_config not set for the CPU driver")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            cache_txn tr;
            idle();
            forever begin
                seq_item_port.get_next_item(tr);
                case (tr.op)
                    OP_RESET: do_reset(tr);
                    OP_FLUSH: do_flush(tr);
                    default:  do_access(tr);
                endcase
                seq_item_port.item_done();
            end
        endtask

        task idle();
            vif.rst_n                <= 1'b0;
            vif.cpu_cb.cpu_req_valid <= 1'b0;
            // the rest of the request payload, so nothing starts life as X
            vif.cpu_cb.cpu_req_addr  <= '0;
            vif.cpu_cb.cpu_req_we    <= 1'b0;
            vif.cpu_cb.cpu_req_wdata <= '0;
            vif.cpu_cb.cpu_req_wstrb <= '0;
            vif.cpu_cb.flush_req     <= 1'b0;
            @(vif.cpu_cb);
            vif.rst_n <= 1'b1;
        endtask

        // Asynchronous assertion, synchronous release: the shape a real reset
        // controller produces, and the one that actually stresses the design.
        task do_reset(cache_txn tr);
            `uvm_info("DRV", "asserting rst_n", UVM_MEDIUM)
            vif.cpu_cb.cpu_req_valid <= 1'b0;
            vif.cpu_cb.flush_req     <= 1'b0;
            #3ns;
            vif.rst_n = 1'b0;
            repeat (4) @(vif.cpu_cb);
            vif.rst_n <= 1'b1;
            @(vif.cpu_cb);
        endtask

        task do_flush(cache_txn tr);
            vif.cpu_cb.flush_req <= 1'b1;
            @(vif.cpu_cb);
            vif.cpu_cb.flush_req <= 1'b0;
            // wait for the completion pulse
            do @(vif.cpu_cb); while (vif.cpu_cb.flush_done !== 1'b1);
        endtask

        task do_access(cache_txn tr);
            repeat (tr.pre_delay) @(vif.cpu_cb);

            vif.cpu_cb.cpu_req_valid <= 1'b1;
            vif.cpu_cb.cpu_req_addr  <= tr.addr;
            vif.cpu_cb.cpu_req_we    <= (tr.op == OP_WRITE);
            vif.cpu_cb.cpu_req_wdata <= tr.wdata;
            vif.cpu_cb.cpu_req_wstrb <= tr.wstrb;

            // hold the request until the cycle it is taken
            do @(vif.cpu_cb); while (vif.cpu_cb.cpu_req_ready !== 1'b1);

            vif.cpu_cb.cpu_req_valid <= 1'b0;
            vif.cpu_cb.cpu_req_we    <= 1'b0;
            vif.cpu_cb.cpu_req_wstrb <= '0;

            // one access in flight, so the driver waits for the answer before
            // it offers another
            do @(vif.cpu_cb); while (vif.cpu_cb.cpu_rsp_valid !== 1'b1);
        endtask
    endclass

    // ========================================================================
    // Memory-side responder: the backing-memory model.
    //
    // Word-addressed, initialised from cache_ref_pkg::ref_init_word so that it
    // and the reference model agree at power-up without either one having been
    // told what the other chose.
    // ========================================================================
    class mem_responder extends uvm_driver #(mem_policy_txn);
        `uvm_component_utils(mem_responder)

        virtual cache_ctrl_if vif;
        cache_config          cfg;

        bit [DATA_W-1:0] mem [0:REF_NWORDS-1];

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(cache_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cache_config not set for the memory responder")
            vif = cfg.vif;
            foreach (mem[i]) mem[i] = ref_init_word(i);
        endfunction

        function int widx(bit [ADDR_W-1:0] a);
            return int'(a >> 2) % REF_NWORDS;
        endfunction

        task run_phase(uvm_phase phase);
            fork
                serve();
                policy();
            join
        endtask

        // Consume policy items forever; each one stays in force for its own
        // hold_cycles.  If no sequence is running, the defaults in cfg apply.
        task policy();
            mem_policy_txn p;
            forever begin
                seq_item_port.get_next_item(p);
                cfg.mem_stall_pct = p.stall_pct;
                cfg.mem_lat_min   = p.lat_min;
                cfg.mem_lat_max   = p.lat_max;
                `uvm_info("MEM", $sformatf("policy: stall=%0d%% lat=%0d..%0d for %0d cycles",
                                           p.stall_pct, p.lat_min, p.lat_max, p.hold_cycles),
                          UVM_HIGH)
                seq_item_port.item_done();
                repeat (p.hold_cycles) @(vif.mem_cb);
            end
        endtask

        task serve();
            bit          rd_busy;
            int          rd_wi;
            int          rd_timer;
            int unsigned lat;
            bit          ready_now;
            bit          took;

            vif.mem_cb.mem_req_ready <= 1'b1;
            vif.mem_cb.mem_rsp_valid <= 1'b0;
            vif.mem_cb.mem_rsp_rdata <= '0;
            rd_busy  = 1'b0;
            rd_timer = 0;

            forever begin
                @(vif.mem_cb);

                if (vif.rst_n !== 1'b1) begin
                    rd_busy = 1'b0;
                    vif.mem_cb.mem_rsp_valid <= 1'b0;
                    vif.mem_cb.mem_req_ready <= 1'b1;
                    continue;
                end

                // The value the DUT actually saw at this edge.  Reading the
                // pin rather than the clocking-block output matters: the
                // output holds what this process last scheduled, which is a
                // cycle ahead of what the design sampled.
                ready_now = vif.mem_req_ready;
                took      = vif.mem_cb.mem_req_valid && ready_now;

                vif.mem_cb.mem_rsp_valid <= 1'b0;
                vif.mem_cb.mem_req_ready <=
                    ($urandom_range(0, 99) >= cfg.mem_stall_pct);

                if (took) begin
                    if (vif.mem_cb.mem_req_we) begin
                        // posted write: accepted and forgotten
                        mem[widx(vif.mem_cb.mem_req_addr)] = vif.mem_cb.mem_req_wdata;
                    end else begin
                        lat      = (cfg.mem_lat_max > cfg.mem_lat_min)
                                   ? $urandom_range(cfg.mem_lat_min, cfg.mem_lat_max)
                                   : cfg.mem_lat_min;
                        rd_busy  = 1'b1;
                        rd_wi    = widx(vif.mem_cb.mem_req_addr);
                        rd_timer = int'(lat);
                    end
                end

                if (rd_busy && !took) begin
                    if (rd_timer == 0) begin
                        vif.mem_cb.mem_rsp_valid <= 1'b1;
                        vif.mem_cb.mem_rsp_rdata <= mem[rd_wi];
                        rd_busy = 1'b0;
                    end else begin
                        rd_timer--;
                    end
                end
            end
        endtask
    endclass

    // ========================================================================
    // CPU-side monitor.
    //
    // It reconstructs a complete access - request payload plus the response it
    // eventually got - and publishes one item per access.  It also publishes a
    // FLUSH item when a flush completes and a RESET item when reset falls, so
    // the scoreboard sees the maintenance events on the same ordered stream as
    // the accesses.  Ordering the events on one stream is what lets the
    // scoreboard apply them to the model in the right order without having to
    // reason about time.
    // ========================================================================
    class cache_monitor extends uvm_monitor;
        `uvm_component_utils(cache_monitor)

        virtual cache_ctrl_if      vif;
        cache_config               cfg;
        uvm_analysis_port #(cache_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(cache_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cache_config not set for the CPU monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            fork
                mon_access();
                mon_flush();
                mon_reset();
            join
        endtask

        task mon_access();
            cache_txn tr;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n === 1'b1 &&
                    vif.mon_cb.cpu_req_valid === 1'b1 &&
                    vif.mon_cb.cpu_req_ready === 1'b1) begin

                    tr       = cache_txn::type_id::create("tr");
                    tr.op    = vif.mon_cb.cpu_req_we ? OP_WRITE : OP_READ;
                    tr.addr  = vif.mon_cb.cpu_req_addr;
                    tr.wdata = vif.mon_cb.cpu_req_wdata;
                    tr.wstrb = vif.mon_cb.cpu_req_wstrb;

                    // wait for the answer, but give up if reset swallows it
                    fork : wait_rsp
                        begin
                            do @(vif.mon_cb); while (vif.mon_cb.cpu_rsp_valid !== 1'b1);
                            tr.rsp_data = vif.mon_cb.cpu_rsp_rdata;
                            tr.rsp_hit  = vif.mon_cb.cpu_rsp_hit;
                            ap.write(tr);
                        end
                        begin
                            @(negedge vif.rst_n);
                            `uvm_info("MON", "reset swallowed an in-flight access",
                                      UVM_MEDIUM)
                        end
                    join_any
                    disable fork;
                end
            end
        endtask

        task mon_flush();
            cache_txn tr;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n === 1'b1 && vif.mon_cb.flush_done === 1'b1) begin
                    tr    = cache_txn::type_id::create("ftr");
                    tr.op = OP_FLUSH;
                    ap.write(tr);
                end
            end
        endtask

        task mon_reset();
            cache_txn tr;
            forever begin
                @(negedge vif.rst_n);
                tr    = cache_txn::type_id::create("rtr");
                tr.op = OP_RESET;
                ap.write(tr);
            end
        endtask
    endclass

    // ========================================================================
    // Memory-side monitor: every transaction that crosses the memory port.
    // ========================================================================
    class mem_monitor extends uvm_monitor;
        `uvm_component_utils(mem_monitor)

        virtual cache_ctrl_if      vif;
        cache_config               cfg;
        uvm_analysis_port #(mem_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(cache_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cache_config not set for the memory monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            mem_txn tr;
            bit [ADDR_W-1:0] pend_addr;
            bit              pend;

            pend = 0;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n !== 1'b1) begin
                    pend = 0;
                    continue;
                end

                if (vif.mon_cb.mem_req_valid && vif.mon_cb.mem_req_ready) begin
                    if (vif.mon_cb.mem_req_we) begin
                        tr      = mem_txn::type_id::create("mwr");
                        tr.we   = 1'b1;
                        tr.addr = vif.mon_cb.mem_req_addr;
                        tr.data = vif.mon_cb.mem_req_wdata;
                        ap.write(tr);
                    end else begin
                        pend_addr = vif.mon_cb.mem_req_addr;
                        pend      = 1;
                    end
                end

                if (pend && vif.mon_cb.mem_rsp_valid) begin
                    tr      = mem_txn::type_id::create("mrd");
                    tr.we   = 1'b0;
                    tr.addr = pend_addr;
                    tr.data = vif.mon_cb.mem_rsp_rdata;
                    ap.write(tr);
                    pend    = 0;
                end
            end
        endtask
    endclass

    // ========================================================================
    // Scoreboard
    // ========================================================================
    `uvm_analysis_imp_decl(_cpu)
    `uvm_analysis_imp_decl(_mem)

    class cache_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(cache_scoreboard)

        uvm_analysis_imp_cpu #(cache_txn, cache_scoreboard) cpu_imp;
        uvm_analysis_imp_mem #(mem_txn,   cache_scoreboard) mem_imp;

        // physical memory as rebuilt from observed memory writes ALONE
        bit [DATA_W-1:0] dut_back [0:REF_NWORDS-1];

        int n_access, n_read, n_write, n_hit, n_miss, n_flush, n_reset;
        int n_mem_rd, n_mem_wr;
        int n_data_err, n_hit_err, n_mem_err, n_traffic_err;
        bit any_flush_compared;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cpu_imp = new("cpu_imp", this);
            mem_imp = new("mem_imp", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ref_model_init();
            foreach (dut_back[i]) dut_back[i] = ref_init_word(i);
        endfunction

        function int widx(bit [ADDR_W-1:0] a);
            return int'(a >> 2) % REF_NWORDS;
        endfunction

        // ---- CPU stream ---------------------------------------------------
        function void write_cpu(cache_txn tr);
            ref_rsp_t exp;

            case (tr.op)
                OP_RESET: begin
                    // The DUT throws away every dirty line here.  The model has
                    // to throw away the same stores, or every later read is
                    // judged against data the hardware could not possibly still
                    // have.
                    ref_hw_reset();
                    n_reset++;
                end

                OP_FLUSH: begin
                    void'(ref_flush());
                    n_flush++;
                    compare_memory($sformatf("after flush #%0d", n_flush));
                    any_flush_compared = 1;
                end

                default: begin
                    if (!ref_addr_in_window(tr.addr)) begin
                        `uvm_error("SCB", $sformatf(
                            "access outside the modelled window: %08h", tr.addr))
                        return;
                    end

                    exp = ref_access(tr.addr, (tr.op == OP_WRITE), tr.wdata, tr.wstrb);

                    n_access++;
                    if (tr.op == OP_WRITE) n_write++; else n_read++;
                    if (exp.hit) n_hit++; else n_miss++;

                    if (tr.rsp_hit !== exp.hit) begin
                        n_hit_err++;
                        `uvm_error("SCB", $sformatf(
                            "hit/miss mispredicted at %08h: DUT %0b, model %0b",
                            tr.addr, tr.rsp_hit, exp.hit))
                    end

                    if ((tr.op == OP_READ) && (tr.rsp_data !== exp.rdata)) begin
                        n_data_err++;
                        `uvm_error("SCB", $sformatf(
                            "read data wrong at %08h: DUT %08h, model %08h",
                            tr.addr, tr.rsp_data, exp.rdata))
                    end
                end
            endcase
        endfunction

        // ---- memory stream ------------------------------------------------
        function void write_mem(mem_txn tr);
            if (tr.we) begin
                dut_back[widx(tr.addr)] = tr.data;
                n_mem_wr++;
            end else begin
                n_mem_rd++;
            end
        endfunction

        // ---- the check that actually proves write-back ---------------------
        function void compare_memory(string whn);
            int bad;
            bad = 0;
            for (int i = 0; i < REF_NWORDS; i++) begin
                if (dut_back[i] !== ref_back_word(i)) begin
                    if (bad < 8)
                        `uvm_error("SCB", $sformatf(
                            "%s: memory word %0d (addr %04h) - DUT wrote %08h, model expects %08h",
                            whn, i, i*4, dut_back[i], ref_back_word(i)))
                    bad++;
                end
            end
            if (bad != 0) begin
                n_mem_err += bad;
                `uvm_error("SCB", $sformatf("%s: %0d memory words differ", whn, bad))
            end
        endfunction

        // ---- traffic reconciliation ---------------------------------------
        function void check_traffic();
            int exp_wr, exp_rd;
            exp_wr = (ref_evicts + ref_flush_wbs) * REF_LINE_WORDS;
            exp_rd = ref_fills * REF_LINE_WORDS;
            if (n_mem_wr != exp_wr) begin
                n_traffic_err++;
                `uvm_error("SCB", $sformatf(
                    "memory WRITE traffic: DUT moved %0d words, model expects %0d",
                    n_mem_wr, exp_wr))
            end
            if (n_mem_rd != exp_rd) begin
                n_traffic_err++;
                `uvm_error("SCB", $sformatf(
                    "memory READ traffic: DUT moved %0d words, model expects %0d",
                    n_mem_rd, exp_rd))
            end
        endfunction

        function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            check_traffic();
            if (!any_flush_compared)
                `uvm_error("SCB", "no flush ever happened, so memory was never compared")
            if (n_access == 0)
                `uvm_error("SCB", "the scoreboard saw no accesses at all")
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCB", $sformatf(
                "\n  accesses        : %0d (%0d read, %0d write)\n  hits / misses   : %0d / %0d\n  flushes / resets: %0d / %0d\n  memory rd / wr  : %0d / %0d\n  data errors     : %0d\n  hit-predict errs: %0d\n  memory errors   : %0d\n  traffic errors  : %0d",
                n_access, n_read, n_write, n_hit, n_miss, n_flush, n_reset,
                n_mem_rd, n_mem_wr, n_data_err, n_hit_err, n_mem_err,
                n_traffic_err), UVM_NONE)

            if (n_data_err == 0 && n_hit_err == 0 && n_mem_err == 0 &&
                n_traffic_err == 0 && n_access > 0 &&
                (uvm_report_server::get_server()).get_severity_count(UVM_ERROR) == 0 &&
                (uvm_report_server::get_server()).get_severity_count(UVM_FATAL) == 0)
                `uvm_info("SCB", "RESULT: *** PASS ***", UVM_NONE)
            else
                `uvm_info("SCB", "RESULT: *** FAIL ***", UVM_NONE)
        endfunction
    endclass

    // ========================================================================
    // Functional coverage.
    //
    // The intent is stated here rather than in the scoreboard on purpose: a
    // coverage collector that also checks is a coverage collector that stops
    // being read.
    // ========================================================================
    class cache_coverage extends uvm_component;
        `uvm_component_utils(cache_coverage)

        cache_txn cur;
        mem_txn   mcur;
        bit       prev_valid;
        bit       prev_hit;

        uvm_analysis_imp_cpu #(cache_txn, cache_coverage) cpu_imp;
        uvm_analysis_imp_mem #(mem_txn,   cache_coverage) mem_imp;

        covergroup cg_access;
            option.per_instance = 1;
            option.name         = "cache_access";

            cp_op: coverpoint cur.op {
                bins rd = {OP_READ};
                bins wr = {OP_WRITE};
                bins fl = {OP_FLUSH};
                bins rs = {OP_RESET};
            }
            cp_hit: coverpoint cur.rsp_hit iff (cur.op == OP_READ || cur.op == OP_WRITE) {
                bins hit  = {1};
                bins miss = {0};
            }
            // Every set must be exercised: a direct-mapped cache with a decode
            // bug typically works perfectly for seven sets out of eight.
            cp_set: coverpoint cur.addr[6:4] iff (cur.op == OP_READ || cur.op == OP_WRITE) {
                bins s[] = {[0:7]};
            }
            cp_word: coverpoint cur.addr[3:2] iff (cur.op == OP_READ || cur.op == OP_WRITE) {
                bins w[] = {[0:3]};
            }
            cp_tag: coverpoint cur.addr[9:7] iff (cur.op == OP_READ || cur.op == OP_WRITE) {
                bins t[] = {[0:7]};
            }
            cp_strb: coverpoint cur.wstrb iff (cur.op == OP_WRITE) {
                bins none = {4'h0};
                bins full = {4'hF};
                bins part[] = {[4'h1:4'hE]};
            }
            // A store that misses is the write-allocate path; a load that
            // misses is the plain fill path.  Both must be hit.
            x_op_hit: cross cp_op, cp_hit {
                ignore_bins non_access = binsof(cp_op) intersect {OP_FLUSH, OP_RESET};
            }
            x_set_hit: cross cp_set, cp_hit;

            // Alternation matters: a cache that gets hit and miss right in
            // isolation can still corrupt state on the transition between them.
            cp_seq: coverpoint {prev_hit, cur.rsp_hit}
                    iff (prev_valid && (cur.op == OP_READ || cur.op == OP_WRITE)) {
                bins miss_miss = {2'b00};
                bins miss_hit  = {2'b01};
                bins hit_miss  = {2'b10};
                bins hit_hit   = {2'b11};
            }
        endgroup

        covergroup cg_mem;
            option.per_instance = 1;
            option.name         = "cache_memory_port";

            cp_dir: coverpoint mcur.we { bins rd = {0}; bins wr = {1}; }
            // Every word of a line must be moved in both directions, or a
            // burst that drops its first or last beat goes unnoticed.
            cp_woff: coverpoint mcur.addr[3:2] { bins w[] = {[0:3]}; }
            x_dir_woff: cross cp_dir, cp_woff;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cpu_imp = new("cpu_imp", this);
            mem_imp = new("mem_imp", this);
            cg_access = new();
            cg_mem    = new();
        endfunction

        function void write_cpu(cache_txn tr);
            cur = tr;
            cg_access.sample();
            if (tr.op == OP_READ || tr.op == OP_WRITE) begin
                prev_hit   = tr.rsp_hit;
                prev_valid = 1;
            end else if (tr.op == OP_RESET) begin
                prev_valid = 0;
            end
        endfunction

        function void write_mem(mem_txn tr);
            mcur = tr;
            cg_mem.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("COV", $sformatf(
                "functional coverage: access %.1f%%, memory port %.1f%%",
                cg_access.get_coverage(), cg_mem.get_coverage()), UVM_NONE)
        endfunction
    endclass

    // ========================================================================
    // Agents
    // ========================================================================
    typedef uvm_sequencer #(cache_txn)      cache_sequencer;
    typedef uvm_sequencer #(mem_policy_txn) mem_sequencer;

    class cache_agent extends uvm_agent;
        `uvm_component_utils(cache_agent)

        cache_driver    drv;
        cache_sequencer sqr;
        cache_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = cache_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = cache_driver::type_id::create("drv", this);
                sqr = cache_sequencer::type_id::create("sqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class mem_agent extends uvm_agent;
        `uvm_component_utils(mem_agent)

        mem_responder drv;
        mem_sequencer sqr;
        mem_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = mem_monitor::type_id::create("mon", this);
            drv = mem_responder::type_id::create("drv", this);
            sqr = mem_sequencer::type_id::create("sqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ========================================================================
    // Virtual sequencer and environment
    // ========================================================================
    class cache_vseqr extends uvm_sequencer #(uvm_sequence_item);
        `uvm_component_utils(cache_vseqr)

        cache_sequencer cpu_sqr;
        mem_sequencer   mem_sqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class cache_env extends uvm_env;
        `uvm_component_utils(cache_env)

        cache_agent      cpu_ag;
        mem_agent        mem_ag;
        cache_scoreboard scb;
        cache_coverage   cov;
        cache_vseqr      vseqr;
        cache_config     cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(cache_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cache_config not set for the environment")
            uvm_config_db#(cache_config)::set(this, "*", "cfg", cfg);

            cpu_ag = cache_agent::type_id::create("cpu_ag", this);
            mem_ag = mem_agent::type_id::create("mem_ag", this);
            scb    = cache_scoreboard::type_id::create("scb", this);
            cov    = cache_coverage::type_id::create("cov", this);
            vseqr  = cache_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            cpu_ag.mon.ap.connect(scb.cpu_imp);
            cpu_ag.mon.ap.connect(cov.cpu_imp);
            mem_ag.mon.ap.connect(scb.mem_imp);
            mem_ag.mon.ap.connect(cov.mem_imp);
            vseqr.cpu_sqr = cpu_ag.sqr;
            vseqr.mem_sqr = mem_ag.sqr;
        endfunction
    endclass

    // ========================================================================
    // CPU-side sequences
    // ========================================================================
    class cache_base_seq extends uvm_sequence #(cache_txn);
        `uvm_object_utils(cache_base_seq)

        function new(string name = "cache_base_seq");
            super.new(name);
        endfunction

        // A single directed access, addressed the way the scenarios think:
        // by (tag, set, word).
        task acc(int t, int s, int w, bit we, bit [DATA_W-1:0] d, bit [BYTES-1:0] st);
            cache_txn tr;
            tr = cache_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { op == (we ? OP_WRITE : OP_READ);
                                       tag_sel  == t;
                                       set_sel  == s;
                                       word_sel == w;
                                       wdata    == d;
                                       wstrb    == st; })
                `uvm_fatal("RAND", "directed access randomize() failed")
            finish_item(tr);
        endtask

        task flush();
            cache_txn tr;
            tr = cache_txn::type_id::create("ftr");
            start_item(tr);
            tr.op = OP_FLUSH;
            finish_item(tr);
        endtask

        task hw_reset();
            cache_txn tr;
            tr = cache_txn::type_id::create("rtr");
            start_item(tr);
            tr.op = OP_RESET;
            finish_item(tr);
        endtask
    endclass

    // Reset, then let the cache come up cold.
    class cache_reset_seq extends cache_base_seq;
        `uvm_object_utils(cache_reset_seq)
        function new(string name = "cache_reset_seq"); super.new(name); endfunction
        task body();
            hw_reset();
        endtask
    endclass

    // Cold miss, then the three siblings that must now hit.
    class cache_cold_seq extends cache_base_seq;
        `uvm_object_utils(cache_cold_seq)
        rand int unsigned t_sel;
        rand int unsigned s_sel;
        constraint c { t_sel inside {[0:REF_TAGS-1]}; s_sel inside {[0:REF_SETS-1]}; }
        function new(string name = "cache_cold_seq"); super.new(name); endfunction
        task body();
            for (int w = 0; w < REF_LINE_WORDS; w++)
                acc(int'(t_sel), int'(s_sel), w, 1'b0, '0, 4'h0);
        endtask
    endclass

    // Write hit, then read it back: the store must be visible without ever
    // having reached memory.
    class cache_wr_hit_seq extends cache_base_seq;
        `uvm_object_utils(cache_wr_hit_seq)
        function new(string name = "cache_wr_hit_seq"); super.new(name); endfunction
        task body();
            acc(0, 1, 0, 1'b0, '0, 4'h0);                    // pull the line in
            acc(0, 1, 1, 1'b1, 32'hDEAD_BEEF, 4'hF);         // dirty it
            acc(0, 1, 1, 1'b0, '0, 4'h0);                    // read it back
        endtask
    endclass

    // The write-allocate path: a store that misses.
    class cache_wr_alloc_seq extends cache_base_seq;
        `uvm_object_utils(cache_wr_alloc_seq)
        function new(string name = "cache_wr_alloc_seq"); super.new(name); endfunction
        task body();
            acc(2, 3, 2, 1'b1, 32'h1234_5678, 4'hF);
            for (int w = 0; w < REF_LINE_WORDS; w++)
                acc(2, 3, w, 1'b0, '0, 4'h0);
        endtask
    endclass

    // Two tags fighting over one set: every access evicts the previous line.
    class cache_thrash_seq extends cache_base_seq;
        `uvm_object_utils(cache_thrash_seq)
        rand int unsigned n;
        rand int unsigned s_sel;
        constraint c { n inside {[8:32]}; s_sel inside {[0:REF_SETS-1]}; }
        function new(string name = "cache_thrash_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < int'(n); i++)
                acc((i % 2) ? 4 : 5, int'(s_sel), i % REF_LINE_WORDS,
                    (i % 3 == 0), 32'h5A5A_0000 + i, 4'hF);
        endtask
    endclass

    // Every byte-strobe pattern into one word, so partial stores are proven to
    // merge rather than overwrite.
    class cache_strobe_seq extends cache_base_seq;
        `uvm_object_utils(cache_strobe_seq)
        function new(string name = "cache_strobe_seq"); super.new(name); endfunction
        task body();
            for (int st = 0; st < 16; st++) begin
                acc(3, 4, 0, 1'b1, 32'hA5A5_0000 + st, st[BYTES-1:0]);
                acc(3, 4, 0, 1'b0, '0, 4'h0);
            end
        endtask
    endclass

    // Dirty a few lines, then flush and let the scoreboard compare memory.
    class cache_flush_seq extends cache_base_seq;
        `uvm_object_utils(cache_flush_seq)
        function new(string name = "cache_flush_seq"); super.new(name); endfunction
        task body();
            acc(0, 5, 0, 1'b1, 32'h0005_0000, 4'hF);
            acc(0, 6, 1, 1'b1, 32'h0006_0001, 4'hF);
            acc(0, 7, 2, 1'b1, 32'h0007_0002, 4'hF);
            flush();
            flush();                     // second flush must move nothing
            acc(0, 5, 0, 1'b0, '0, 4'h0); // flush cleans, it does not invalidate
        endtask
    endclass

    // Constrained-random traffic with locality.  Without the locality term the
    // stream is nearly all misses and the hit path barely gets exercised.
    class cache_random_seq extends cache_base_seq;
        `uvm_object_utils(cache_random_seq)

        rand int unsigned n;
        constraint c_n { n inside {[100:400]}; }

        function new(string name = "cache_random_seq"); super.new(name); endfunction

        task body();
            cache_txn tr;
            int pt, ps;
            pt = 0; ps = 0;
            for (int i = 0; i < int'(n); i++) begin
                tr = cache_txn::type_id::create("tr");
                start_item(tr);
                if ($urandom_range(0, 1) == 0) begin
                    // stay on the previous line, move only the word offset
                    if (!tr.randomize() with { op inside {OP_READ, OP_WRITE};
                                               tag_sel == pt;
                                               set_sel == ps; })
                        `uvm_fatal("RAND", "local access randomize() failed")
                end else begin
                    if (!tr.randomize() with { op inside {OP_READ, OP_WRITE}; })
                        `uvm_fatal("RAND", "random access randomize() failed")
                    pt = int'(tr.tag_sel);
                    ps = int'(tr.set_sel);
                end
                finish_item(tr);
            end
        endtask
    endclass

    // ========================================================================
    // Memory-side sequences
    // ========================================================================
    class mem_fast_seq extends uvm_sequence #(mem_policy_txn);
        `uvm_object_utils(mem_fast_seq)
        function new(string name = "mem_fast_seq"); super.new(name); endfunction
        task body();
            mem_policy_txn p;
            forever begin
                p = mem_policy_txn::type_id::create("p");
                start_item(p);
                if (!p.randomize() with { stall_pct == 0; lat_min == 0;
                                          lat_max == 0; hold_cycles == 400; })
                    `uvm_fatal("RAND", "mem_fast randomize() failed")
                finish_item(p);
            end
        endtask
    endclass

    class mem_hostile_seq extends uvm_sequence #(mem_policy_txn);
        `uvm_object_utils(mem_hostile_seq)
        function new(string name = "mem_hostile_seq"); super.new(name); endfunction
        task body();
            mem_policy_txn p;
            forever begin
                p = mem_policy_txn::type_id::create("p");
                start_item(p);
                if (!p.randomize() with { stall_pct inside {[20:70]};
                                          lat_min inside {[0:2]};
                                          lat_max inside {[2:8]}; })
                    `uvm_fatal("RAND", "mem_hostile randomize() failed")
                finish_item(p);
            end
        endtask
    endclass

    // ========================================================================
    // Virtual sequences - the layer where the two agents are coordinated.
    // ========================================================================
    class cache_smoke_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(cache_smoke_vseq)

        cache_vseqr vsqr;

        function new(string name = "cache_smoke_vseq"); super.new(name); endfunction

        task body();
            cache_reset_seq   rst;
            cache_cold_seq    cold;
            cache_wr_hit_seq  wrh;
            cache_thrash_seq  thr;
            cache_flush_seq   fl;
            mem_fast_seq      mfast;

            if (!$cast(vsqr, m_sequencer))
                `uvm_fatal("VSEQ", "smoke vseq must run on the virtual sequencer")

            mfast = mem_fast_seq::type_id::create("mfast");
            // The memory policy runs for the whole test in the background; it
            // never ends, so it must not be joined.
            fork mfast.start(vsqr.mem_sqr); join_none
            #1ns;

            rst = cache_reset_seq::type_id::create("rst");
            rst.start(vsqr.cpu_sqr);

            cold = cache_cold_seq::type_id::create("cold");
            if (!cold.randomize() with { t_sel == 0; s_sel == 0; })
                `uvm_fatal("RAND", "cold randomize() failed")
            cold.start(vsqr.cpu_sqr);

            wrh = cache_wr_hit_seq::type_id::create("wrh");
            wrh.start(vsqr.cpu_sqr);

            thr = cache_thrash_seq::type_id::create("thr");
            if (!thr.randomize() with { n == 12; s_sel == 2; })
                `uvm_fatal("RAND", "thrash randomize() failed")
            thr.start(vsqr.cpu_sqr);

            fl = cache_flush_seq::type_id::create("fl");
            fl.start(vsqr.cpu_sqr);
        endtask
    endclass

    class cache_regress_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(cache_regress_vseq)

        cache_vseqr vsqr;

        function new(string name = "cache_regress_vseq"); super.new(name); endfunction

        task body();
            cache_reset_seq    rst;
            cache_cold_seq     cold;
            cache_wr_hit_seq   wrh;
            cache_wr_alloc_seq wra;
            cache_strobe_seq   stb;
            cache_thrash_seq   thr;
            cache_flush_seq    fl;
            cache_random_seq   rnd;
            mem_fast_seq       mfast;
            mem_hostile_seq    mhost;

            if (!$cast(vsqr, m_sequencer))
                `uvm_fatal("VSEQ", "regress vseq must run on the virtual sequencer")

            // ---- phase 1: an easy memory, so a failure here is the cache ---
            mfast = mem_fast_seq::type_id::create("mfast");
            fork mfast.start(vsqr.mem_sqr); join_none
            #1ns;

            rst = cache_reset_seq::type_id::create("rst");
            rst.start(vsqr.cpu_sqr);

            for (int s = 0; s < REF_SETS; s++) begin
                cold = cache_cold_seq::type_id::create($sformatf("cold%0d", s));
                if (!cold.randomize() with { t_sel == 0; s_sel == s; })
                    `uvm_fatal("RAND", "cold randomize() failed")
                cold.start(vsqr.cpu_sqr);
            end

            wrh = cache_wr_hit_seq::type_id::create("wrh");
            wrh.start(vsqr.cpu_sqr);

            wra = cache_wr_alloc_seq::type_id::create("wra");
            wra.start(vsqr.cpu_sqr);

            stb = cache_strobe_seq::type_id::create("stb");
            stb.start(vsqr.cpu_sqr);

            fl = cache_flush_seq::type_id::create("fl0");
            fl.start(vsqr.cpu_sqr);

            // ---- phase 2: the same design against a hostile memory ---------
            // Killing the easy policy and starting the hostile one mid-test is
            // the point of having the policy be a sequence at all.
            mfast.kill();
            mhost = mem_hostile_seq::type_id::create("mhost");
            fork mhost.start(vsqr.mem_sqr); join_none
            #1ns;

            for (int r = 0; r < 4; r++) begin
                thr = cache_thrash_seq::type_id::create($sformatf("thr%0d", r));
                if (!thr.randomize() with { n inside {[16:32]}; })
                    `uvm_fatal("RAND", "thrash randomize() failed")
                thr.start(vsqr.cpu_sqr);

                rnd = cache_random_seq::type_id::create($sformatf("rnd%0d", r));
                if (!rnd.randomize() with { n inside {[150:300]}; })
                    `uvm_fatal("RAND", "random randomize() failed")
                rnd.start(vsqr.cpu_sqr);

                fl = cache_flush_seq::type_id::create($sformatf("fl%0d", r+1));
                fl.start(vsqr.cpu_sqr);

                if (r == 1) begin
                    // A reset with a cache full of dirty lines.  The stores are
                    // supposed to be lost, and the scoreboard has to agree.
                    rnd = cache_random_seq::type_id::create("rnd_dirty");
                    if (!rnd.randomize() with { n == 60; })
                        `uvm_fatal("RAND", "random randomize() failed")
                    rnd.start(vsqr.cpu_sqr);

                    rst = cache_reset_seq::type_id::create("rst_mid");
                    rst.start(vsqr.cpu_sqr);
                end
            end

            // A final flush, so the end-of-test memory comparison is meaningful.
            fl = cache_flush_seq::type_id::create("fl_final");
            fl.start(vsqr.cpu_sqr);
        endtask
    endclass

    // ========================================================================
    // Tests
    // ========================================================================
    class cache_base_test extends uvm_test;
        `uvm_component_utils(cache_base_test)

        cache_env    env;
        cache_config cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            cfg = cache_config::type_id::create("cfg");
            if (!uvm_config_db#(virtual cache_ctrl_if)::get(this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual cache_ctrl_if not set in the config DB")
            uvm_config_db#(cache_config)::set(this, "*", "cfg", cfg);
            env = cache_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            super.end_of_elaboration_phase(phase);
            uvm_top.print_topology();
        endfunction
    endclass

    class cache_ctrl_smoke_test extends cache_base_test;
        `uvm_component_utils(cache_ctrl_smoke_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            cache_smoke_vseq vseq;
            phase.raise_objection(this);
            vseq = cache_smoke_vseq::type_id::create("smoke");
            vseq.start(env.vseqr);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

    class cache_ctrl_regress_test extends cache_base_test;
        `uvm_component_utils(cache_ctrl_regress_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            cache_regress_vseq vseq;
            phase.raise_objection(this);
            vseq = cache_regress_vseq::type_id::create("regress");
            vseq.start(env.vseqr);
            #200ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage : cache_ctrl_pkg
