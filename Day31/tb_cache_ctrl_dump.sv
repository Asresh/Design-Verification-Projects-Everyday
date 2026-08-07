// ============================================================================
// tb_cache_ctrl_dump.sv - portable, self-checking, module-based testbench for
// the write-back cache controller.
// ----------------------------------------------------------------------------
// This is the procedural twin of the UVM environment in cache_ctrl_pkg.sv.  It
// exists because Icarus Verilog - the one simulator that is installed
// everywhere and needs no licence - implements neither the UVM class library
// nor a constraint solver, and the committed waveform has to come from a real
// simulation rather than a drawing.
//
// It checks the same things the UVM scoreboard checks, against the same
// reference model (cache_ref_pkg), and it delimits the showcase window that
// docs/make_waveform.py renders with the `mark` signal.
//
// Structure:
//   1. the model proves its own invariants (ref_selfcheck) before it is
//      allowed to judge anything;
//   2. a behavioural backing memory with programmable stall and read latency;
//   3. sixteen directed scenarios covering every FSM path and every documented
//      corner;
//   4. a long constrained-random walk with memory backpressure, periodic
//      flushes and a mid-stream reset;
//   5. a final flush followed by a word-for-word comparison of the memory the
//      DUT actually wrote against the memory the model says should be there.
//
// Step 5 is the one that matters most.  Every read matching the model proves
// the cache returns the right data; only the memory comparison proves it also
// put the right data in the right place in DRAM.
// ============================================================================
`timescale 1ns/1ps

module tb_cache_ctrl_dump;

    import cache_ref_pkg::*;

    localparam int ADDR_W     = 32;
    localparam int DATA_W     = 32;
    localparam int BYTES      = DATA_W/8;
    localparam int LINE_WORDS = REF_LINE_WORDS;
    localparam int SETS       = REF_SETS;
    localparam int NWORDS     = REF_NWORDS;

    // ---- clock / reset -----------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;           // 100 MHz

    logic rst_n;

    // ---- DUT wiring --------------------------------------------------------
    logic              cpu_req_valid;
    logic              cpu_req_ready;
    logic [ADDR_W-1:0] cpu_req_addr;
    logic              cpu_req_we;
    logic [DATA_W-1:0] cpu_req_wdata;
    logic [BYTES-1:0]  cpu_req_wstrb;

    logic              cpu_rsp_valid;
    logic [DATA_W-1:0] cpu_rsp_rdata;
    logic              cpu_rsp_hit;

    logic              flush_req;
    logic              flush_busy;
    logic              flush_done;

    logic              mem_req_valid;
    logic              mem_req_ready;
    logic              mem_req_we;
    logic [ADDR_W-1:0] mem_req_addr;
    logic [DATA_W-1:0] mem_req_wdata;
    logic              mem_rsp_valid;
    logic [DATA_W-1:0] mem_rsp_rdata;

    logic [3:0]        state;
    logic              stat_hit, stat_miss, stat_wb;

    // Marks the window docs/make_waveform.py renders.
    logic mark = 1'b0;

    cache_ctrl #(
        .ADDR_W     (ADDR_W),
        .DATA_W     (DATA_W),
        .LINE_WORDS (LINE_WORDS),
        .SETS       (SETS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .cpu_req_valid (cpu_req_valid),
        .cpu_req_ready (cpu_req_ready),
        .cpu_req_addr  (cpu_req_addr),
        .cpu_req_we    (cpu_req_we),
        .cpu_req_wdata (cpu_req_wdata),
        .cpu_req_wstrb (cpu_req_wstrb),
        .cpu_rsp_valid (cpu_rsp_valid),
        .cpu_rsp_rdata (cpu_rsp_rdata),
        .cpu_rsp_hit   (cpu_rsp_hit),
        .flush_req     (flush_req),
        .flush_busy    (flush_busy),
        .flush_done    (flush_done),
        .mem_req_valid (mem_req_valid),
        .mem_req_ready (mem_req_ready),
        .mem_req_we    (mem_req_we),
        .mem_req_addr  (mem_req_addr),
        .mem_req_wdata (mem_req_wdata),
        .mem_rsp_valid (mem_rsp_valid),
        .mem_rsp_rdata (mem_rsp_rdata),
        .state_o       (state),
        .stat_hit      (stat_hit),
        .stat_miss     (stat_miss),
        .stat_wb       (stat_wb)
    );

    // ========================================================================
    // Behavioural backing memory.
    //
    // Writes are posted (accepted and forgotten); reads answer after mem_lat
    // cycles.  mem_stall_en makes ready pseudo-random so the DUT's memory port
    // is exercised against a slave that says no.  Both are knobs the scenarios
    // turn, because "works when memory is instant and always ready" is the
    // easy half of the problem.
    // ========================================================================
    logic [DATA_W-1:0] mem [0:NWORDS-1];

    int  mem_lat      = 0;      // extra cycles before read data returns
    bit  mem_stall_en = 1'b0;   // random ready deassertion

    logic       rd_busy;
    int         rd_timer;
    int         rd_wi;

    // observed memory traffic, used for the end-of-run traffic reconciliation
    int obs_mem_writes;
    int obs_mem_reads;
    // snapshot taken at the reconciliation point, so the coverage report is
    // not confused by the showcase run that follows it
    int tot_mem_writes;
    int tot_mem_reads;

    function automatic int widx(input logic [ADDR_W-1:0] a);
        return int'(a >> 2) % NWORDS;
    endfunction

    task automatic mem_init();
        for (int i = 0; i < NWORDS; i++)
            mem[i] = ref_init_word(i);
        obs_mem_writes = 0;
        obs_mem_reads  = 0;
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_rdata <= '0;
            mem_req_ready <= 1'b1;
            rd_busy       <= 1'b0;
            rd_timer      <= 0;
            rd_wi         <= 0;
        end else begin
            mem_rsp_valid <= 1'b0;
            mem_req_ready <= mem_stall_en ? ($urandom_range(0, 3) != 0) : 1'b1;

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_we) begin
                    mem[widx(mem_req_addr)] <= mem_req_wdata;
                    obs_mem_writes          <= obs_mem_writes + 1;
                end else begin
                    rd_busy        <= 1'b1;
                    rd_wi          <= widx(mem_req_addr);
                    rd_timer       <= mem_lat;
                    obs_mem_reads  <= obs_mem_reads + 1;
                end
            end

            if (rd_busy) begin
                if (rd_timer == 0) begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_rdata <= mem[rd_wi];
                    rd_busy       <= 1'b0;
                end else begin
                    rd_timer <= rd_timer - 1;
                end
            end
        end
    end

    // ========================================================================
    // Bookkeeping / coverage counters.  Icarus has no covergroups, so the
    // intent that the UVM environment expresses with `covergroup` is counted
    // by hand here and reported at the end.  Same intent, cruder instrument.
    // ========================================================================
    int errors;
    int n_access, n_read, n_write, n_hit, n_miss, n_flush;
    bit state_seen [0:15];
    bit strb_seen  [0:15];
    bit set_touched[0:SETS-1];
    bit hit_after_miss, miss_after_hit;
    bit saw_evict, saw_flush_wb, saw_flush_idle, saw_stall, saw_reset_loss;
    bit last_was_hit, have_last;

    always @(posedge clk) if (rst_n) begin
        state_seen[state] = 1'b1;
        if (mem_req_valid && !mem_req_ready) saw_stall = 1'b1;
        if (stat_wb) saw_evict = 1'b1;
    end

    task automatic fail(input string what);
        errors++;
        $display("  [%0t] FAIL: %s", $time, what);
    endtask

    // ========================================================================
    // Bus tasks.  Everything is driven and sampled on the falling edge: the
    // DUT lives on the rising edge, so this keeps the testbench a full half
    // cycle away from every race without needing clocking blocks (which Icarus
    // supports unevenly).
    // ========================================================================
    task automatic do_reset(input int cycles);
        rst_n         = 1'b0;
        cpu_req_valid = 1'b0;
        cpu_req_addr  = '0;
        cpu_req_we    = 1'b0;
        cpu_req_wdata = '0;
        cpu_req_wstrb = '0;
        flush_req     = 1'b0;
        repeat (cycles) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        ref_hw_reset();
    endtask

    // One CPU access, checked against the model.
    task automatic access(input logic [ADDR_W-1:0] addr,
                          input logic              we,
                          input logic [DATA_W-1:0] wdata,
                          input logic [BYTES-1:0]  wstrb,
                          input string             tag_s);
        ref_rsp_t exp;
        logic [DATA_W-1:0] got_d;
        logic              got_h;
        int                guard;

        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_addr  = addr;
        cpu_req_we    = we;
        cpu_req_wdata = wdata;
        cpu_req_wstrb = wstrb;

        // ready is combinational off the state register, so its value at this
        // falling edge is exactly what the next rising edge will use.
        guard = 0;
        while (cpu_req_ready !== 1'b1) begin
            @(negedge clk);
            guard++;
            if (guard > 5000) begin
                fail($sformatf("%s: request never accepted (addr=%08h)", tag_s, addr));
                cpu_req_valid = 1'b0;
                return;
            end
        end

        @(negedge clk);
        cpu_req_valid = 1'b0;

        guard = 0;
        while (cpu_rsp_valid !== 1'b1) begin
            @(negedge clk);
            guard++;
            if (guard > 5000) begin
                fail($sformatf("%s: no response (addr=%08h)", tag_s, addr));
                return;
            end
        end

        got_d = cpu_rsp_rdata;
        got_h = cpu_rsp_hit;

        exp = ref_access(addr, we, wdata, wstrb);

        n_access++;
        if (we) n_write++; else n_read++;
        if (exp.hit) n_hit++; else n_miss++;
        strb_seen[wstrb]                        = 1'b1;
        set_touched[ref_idx(addr)]              = 1'b1;
        if (have_last && !last_was_hit && exp.hit) hit_after_miss = 1'b1;
        if (have_last &&  last_was_hit && !exp.hit) miss_after_hit = 1'b1;
        last_was_hit = exp.hit;
        have_last    = 1'b1;

        if (got_h !== exp.hit)
            fail($sformatf("%s: hit/miss mispredicted at %08h - DUT %0b, model %0b",
                           tag_s, addr, got_h, exp.hit));

        if (!we && (got_d !== exp.rdata))
            fail($sformatf("%s: read data wrong at %08h - DUT %08h, model %08h",
                           tag_s, addr, got_d, exp.rdata));
    endtask

    task automatic do_flush(input string tag_s);
        int guard;
        int n;

        @(negedge clk);
        flush_req = 1'b1;
        @(negedge clk);
        flush_req = 1'b0;

        guard = 0;
        while (flush_done !== 1'b1) begin
            @(negedge clk);
            guard++;
            if (guard > 20000) begin
                fail($sformatf("%s: flush never completed", tag_s));
                return;
            end
        end
        n = ref_flush();
        if (n == 0) saw_flush_idle = 1'b1;
        else        saw_flush_wb   = 1'b1;
        n_flush++;
        @(negedge clk);
    endtask

    // Word-for-word comparison of physical memory against the model's view of
    // what physical memory should hold.  Only meaningful right after a flush.
    task automatic check_memory(input string tag_s);
        int bad;
        bad = 0;
        for (int i = 0; i < NWORDS; i++) begin
            if (mem[i] !== ref_back_word(i)) begin
                if (bad < 8)
                    $display("  [%0t] FAIL: %s: memory word %0d (addr %04h) - DUT %08h, model %08h",
                             $time, tag_s, i, i*4, mem[i], ref_back_word(i));
                bad++;
            end
        end
        if (bad != 0) begin
            errors += bad;
            $display("  [%0t] FAIL: %s: %0d memory words differ", $time, tag_s, bad);
        end
    endtask

    // ========================================================================
    // Address helpers.  Building addresses out of (tag, set, word) rather than
    // out of hex constants is what makes the conflict scenarios say what they
    // mean.
    // ========================================================================
    function automatic logic [ADDR_W-1:0] addr_of(input int t, input int s, input int w);
        logic [ADDR_W-1:0] a;
        a = (((t * SETS) + s) * LINE_WORDS + w) * 4;
        return a;
    endfunction

    // ========================================================================
    // Scenarios
    // ========================================================================
    task automatic scen_selfcheck();
        int bad;
        $display("[1] reference-model self-check");
        bad = ref_selfcheck(1'b1);
        if (bad != 0) begin
            errors += bad;
            $display("  the reference model failed its own invariants - stopping");
        end
        ref_model_init();
    endtask

    task automatic scen_cold_miss();
        $display("[2] cold read miss - line fill, no eviction");
        access(addr_of(0,0,0), 1'b0, 32'h0, 4'h0, "cold");
    endtask

    task automatic scen_line_hits();
        $display("[3] the rest of the filled line hits");
        for (int w = 1; w < LINE_WORDS; w++)
            access(addr_of(0,0,w), 1'b0, 32'h0, 4'h0, "line-hit");
    endtask

    task automatic scen_write_hit();
        $display("[4] write hit - the line goes dirty, memory is NOT touched");
        access(addr_of(0,0,1), 1'b1, 32'hDEAD_BEEF, 4'hF, "wr-hit");
        if (mem[widx(addr_of(0,0,1))] === 32'hDEAD_BEEF)
            fail("write-back violated: the store reached memory immediately");
        access(addr_of(0,0,1), 1'b0, 32'h0, 4'h0, "wr-hit-rd");
    endtask

    task automatic scen_dirty_evict();
        $display("[5] conflicting access on a dirty line - evict then fill");
        access(addr_of(1,0,0), 1'b0, 32'h0, 4'h0, "conflict");
        if (mem[widx(addr_of(0,0,1))] !== 32'hDEAD_BEEF)
            fail("the eviction did not write the dirty word back to memory");
    endtask

    task automatic scen_write_allocate();
        $display("[6] write miss - write-allocate pulls the line in first");
        access(addr_of(2,1,2), 1'b1, 32'h1234_5678, 4'hF, "wr-alloc");
        // the other three words of the allocated line must be memory contents
        for (int w = 0; w < LINE_WORDS; w++)
            if (w != 2)
                access(addr_of(2,1,w), 1'b0, 32'h0, 4'h0, "wr-alloc-sib");
        access(addr_of(2,1,2), 1'b0, 32'h0, 4'h0, "wr-alloc-rd");
    endtask

    task automatic scen_byte_strobes();
        $display("[7] byte strobes merge into the cached word");
        access(addr_of(3,2,0), 1'b1, 32'hFFFF_FFFF, 4'b0001, "strb-0");
        access(addr_of(3,2,0), 1'b1, 32'h0000_0000, 4'b0010, "strb-1");
        access(addr_of(3,2,0), 1'b1, 32'hAAAA_AAAA, 4'b1100, "strb-2");
        access(addr_of(3,2,0), 1'b0, 32'h0, 4'h0,            "strb-rd");
        // a zero strobe is a legal, architecturally invisible store
        access(addr_of(3,2,1), 1'b1, 32'hFFFF_FFFF, 4'b0000, "strb-none");
        access(addr_of(3,2,1), 1'b0, 32'h0, 4'h0,            "strb-none-rd");
    endtask

    task automatic scen_flush_dirty();
        $display("[8] flush with several dirty lines - memory catches up");
        access(addr_of(0,3,0), 1'b1, 32'h0003_0000, 4'hF, "f-dirty");
        access(addr_of(0,4,1), 1'b1, 32'h0004_0001, 4'hF, "f-dirty");
        access(addr_of(0,5,2), 1'b1, 32'h0005_0002, 4'hF, "f-dirty");
        do_flush("flush-dirty");
        check_memory("flush-dirty");
    endtask

    task automatic scen_flush_clean();
        $display("[9] flush with nothing dirty - no memory traffic at all");
        begin
            int before_w;
            before_w = obs_mem_writes;
            do_flush("flush-clean");
            if (obs_mem_writes != before_w)
                fail("a flush of a clean cache still wrote to memory");
        end
    endtask

    task automatic scen_flush_keeps_lines();
        $display("[10] flush cleans but does not invalidate - the line still hits");
        access(addr_of(0,3,0), 1'b0, 32'h0, 4'h0, "post-flush-hit");
    endtask

    task automatic scen_thrash();
        $display("[11] index thrash - two tags fighting over one set");
        for (int i = 0; i < 16; i++) begin
            access(addr_of(i % 2 == 0 ? 4 : 5, 6, i % LINE_WORDS),
                   (i % 3 == 0), 32'h5A5A_0000 + i, 4'hF, "thrash");
        end
    endtask

    task automatic scen_backpressure();
        $display("[12] memory backpressure and non-zero read latency");
        mem_stall_en = 1'b1;
        mem_lat      = 3;
        for (int i = 0; i < 12; i++)
            access(addr_of(i % 4, 7, i % LINE_WORDS), (i % 2 == 1),
                   32'hB000_0000 + i, 4'hF, "backpressure");
        mem_stall_en = 1'b0;
        mem_lat      = 0;
    endtask

    task automatic scen_flush_during_traffic();
        $display("[13] flush requested while an access is still in flight");
        // Ask for the flush in the same cycle the request goes out; the
        // controller must finish the access, then run the flush.
        fork
            access(addr_of(6,2,0), 1'b1, 32'hF10F_10F1, 4'hF, "flush-race");
            begin
                @(negedge clk);
                flush_req = 1'b1;
                @(negedge clk);
                flush_req = 1'b0;
            end
        join
        begin
            int guard;
            guard = 0;
            while (flush_done !== 1'b1) begin
                @(negedge clk);
                guard++;
                if (guard > 20000) begin fail("flush-race: flush never completed"); return; end
            end
            void'(ref_flush());
            n_flush++;
            saw_flush_wb = 1'b1;
        end
        @(negedge clk);
        check_memory("flush-race");
    endtask

    task automatic scen_reset_loses_dirty();
        $display("[14] reset discards un-written-back stores - and must");
        begin
            logic [ADDR_W-1:0] a;
            logic [DATA_W-1:0] before_v;
            ref_rsp_t          e;
            a = addr_of(7,0,3);
            access(a, 1'b0, 32'h0, 4'h0, "reset-pre");
            before_v = ref_arch_word(ref_word_index(a));
            access(a, 1'b1, 32'h0BAD_0BAD, 4'hF, "reset-store");
            access(a, 1'b0, 32'h0, 4'h0, "reset-store-rd");
            do_reset(4);                 // ref_hw_reset() rolls the model back
            access(a, 1'b0, 32'h0, 4'h0, "reset-post");
            if (ref_arch_word(ref_word_index(a)) !== before_v)
                fail("the model did not roll the discarded store back");
            saw_reset_loss = 1'b1;
        end
    endtask

    task automatic scen_back_to_back();
        $display("[15] back-to-back requests with no idle gap");
        for (int i = 0; i < 8; i++)
            access(addr_of(0, i % SETS, i % LINE_WORDS), 1'b0, 32'h0, 4'h0, "b2b");
    endtask

    task automatic scen_all_sets();
        $display("[16] touch every set, so no index is left unexercised");
        for (int s = 0; s < SETS; s++)
            access(addr_of(1, s, 0), 1'b1, 32'h7000_0000 + s, 4'hF, "all-sets");
    endtask

    task automatic scen_random(input int n);
        logic [ADDR_W-1:0] a;
        logic              we;
        logic [BYTES-1:0]  ws;
        int                t, s, w;
        int                pt, ps;

        $display("[17] %0d constrained-random accesses with backpressure", n);
        mem_stall_en = 1'b1;
        pt = 0;
        ps = 0;
        for (int i = 0; i < n; i++) begin
            // A deliberately small tag space: with 8 tags over 8 sets, roughly
            // one access in eight conflicts, so evictions happen constantly
            // instead of once in a blue moon.
            //
            // Half the accesses stay on the previous line and only move the
            // word offset.  Without that locality term the stream is almost
            // all misses, and a bug on the hit path - the one a real workload
            // takes most often - would hardly ever be reached.
            if ($urandom_range(0, 1) == 0) begin
                t = pt;
                s = ps;
            end else begin
                t = $urandom_range(0, REF_TAGS-1);
                s = $urandom_range(0, SETS-1);
            end
            pt = t;
            ps = s;
            w  = $urandom_range(0, LINE_WORDS-1);
            a  = addr_of(t, s, w);
            we = ($urandom_range(0, 2) != 0);      // ~2/3 writes, to make dirt
            ws = we ? $urandom_range(0, 15) : 4'h0;

            mem_lat = $urandom_range(0, 4);
            access(a, we, $urandom(), ws, "random");

            if (i % 400 == 399) begin
                do_flush("random-flush");
                check_memory("random-flush");
            end
            if (i == n/2) begin
                // A reset in the middle of a dirty cache: the model has to
                // agree that the stores are gone, and everything after has to
                // stay consistent.
                do_reset(3);
            end
        end
        mem_stall_en = 1'b0;
        mem_lat      = 0;
    endtask

    // ========================================================================
    // The showcase window that becomes docs/cache_ctrl_waveform.png.
    //
    // Run with an instant, always-ready memory so the picture is about the
    // cache and not about the memory being slow.  The window contains the one
    // sequence that defines a write-back write-allocate cache:
    //
    //     write hit  ->  conflicting miss on the now-dirty line
    //                    (four memory WRITES, then four memory READS)
    //                    ->  hit in the freshly filled line
    // ========================================================================
    task automatic scen_showcase();
        $display("[18] showcase window (this is what the committed PNG shows)");
        do_reset(4);
        mem_stall_en = 1'b0;
        mem_lat      = 0;

        // warm-up outside the window: pull line (tag 0, set 0) in
        access(addr_of(0,0,0), 1'b0, 32'h0, 4'h0, "showcase-warm");

        @(negedge clk);
        mark = 1'b1;

        // 1. write hit  -> the line goes dirty, memory sees nothing
        access(addr_of(0,0,1), 1'b1, 32'hDEAD_BEEF, 4'hF, "showcase-wr");
        // 2. conflicting read -> EVICT (4 writes) then FILL (4 reads)
        access(addr_of(1,0,0), 1'b0, 32'h0, 4'h0, "showcase-evict");
        // 3. the freshly filled line hits
        access(addr_of(1,0,1), 1'b0, 32'h0, 4'h0, "showcase-hit");

        @(negedge clk);
        mark = 1'b0;
        repeat (2) @(negedge clk);

        if (mem[widx(addr_of(0,0,1))] !== 32'hDEAD_BEEF)
            fail("showcase: the evicted word never reached memory");
    endtask

    // ========================================================================
    // Coverage report - the hand-rolled stand-in for the covergroups the UVM
    // environment declares.
    // ========================================================================
    task automatic report_coverage();
        int st_hit, set_hit, strb_hit;
        st_hit = 0; set_hit = 0; strb_hit = 0;
        for (int i = 0; i < 8; i++) if (state_seen[i])   st_hit++;
        for (int i = 0; i < SETS; i++) if (set_touched[i]) set_hit++;
        for (int i = 0; i < 16; i++) if (strb_seen[i])   strb_hit++;

        $display("");
        $display("---- coverage ----------------------------------------------");
        $display("  FSM states visited     : %0d / 8", st_hit);
        for (int i = 0; i < 8; i++)
            if (!state_seen[i]) $display("      MISSING state %s", ref_state_name(i[3:0]));
        $display("  cache sets exercised   : %0d / %0d", set_hit, SETS);
        $display("  byte-strobe patterns   : %0d / 16", strb_hit);
        $display("  accesses               : %0d (%0d read, %0d write)", n_access, n_read, n_write);
        $display("  hits / misses          : %0d / %0d", n_hit, n_miss);
        $display("  flushes                : %0d", n_flush);
        $display("  memory reads / writes  : %0d / %0d (reconciled against the model)",
                 tot_mem_reads, tot_mem_writes);
        $display("  dirty eviction seen    : %0b", saw_evict);
        $display("  flush with writeback   : %0b", saw_flush_wb);
        $display("  flush with nothing to do: %0b", saw_flush_idle);
        $display("  memory backpressure    : %0b", saw_stall);
        $display("  hit-after-miss         : %0b", hit_after_miss);
        $display("  miss-after-hit         : %0b", miss_after_hit);
        $display("  reset-discards-dirty   : %0b", saw_reset_loss);

        if (st_hit != 8)      fail("not every FSM state was reached");
        if (set_hit != SETS)  fail("not every cache set was exercised");
        if (strb_hit != 16)   fail("not every byte-strobe pattern was driven");
        if (!saw_evict)       fail("no dirty eviction was ever produced");
        if (!saw_flush_wb)    fail("no flush ever wrote anything back");
        if (!saw_stall)       fail("the memory port was never back-pressured");
        if (!hit_after_miss || !miss_after_hit)
            fail("the hit/miss alternation was never exercised in both directions");
    endtask

    // ========================================================================
    // Traffic reconciliation: the number of words the DUT pushed to memory
    // must equal the number of lines the model says were written back, times
    // the line length.  This catches a cache that returns all the right data
    // while quietly writing back too much, too little, or twice.
    // ========================================================================
    task automatic check_traffic();
        int expect_w;
        tot_mem_writes = obs_mem_writes;
        tot_mem_reads  = obs_mem_reads;
        expect_w = (ref_evicts + ref_flush_wbs) * LINE_WORDS;
        if (obs_mem_writes != expect_w)
            fail($sformatf("memory write traffic: DUT wrote %0d words, model expected %0d",
                           obs_mem_writes, expect_w));
        if (obs_mem_reads != ref_fills * LINE_WORDS)
            fail($sformatf("memory read traffic: DUT read %0d words, model expected %0d",
                           obs_mem_reads, ref_fills * LINE_WORDS));
    endtask

    // ========================================================================
    // Main
    // ========================================================================
    initial begin
        $dumpfile("tb_cache_ctrl_dump.vcd");
        $dumpvars(0, tb_cache_ctrl_dump);

        errors = 0;
        mem_init();
        ref_model_init();

        $display("============================================================");
        $display(" cache_ctrl - direct-mapped write-back write-allocate cache");
        $display(" %0d sets x %0d words/line, %0d-word memory window",
                 SETS, LINE_WORDS, NWORDS);
        $display("============================================================");

        scen_selfcheck();

        do_reset(4);
        ref_model_init();

        scen_cold_miss();
        scen_line_hits();
        scen_write_hit();
        scen_dirty_evict();
        scen_write_allocate();
        scen_byte_strobes();
        scen_flush_dirty();
        scen_flush_clean();
        scen_flush_keeps_lines();
        scen_thrash();
        scen_backpressure();
        scen_flush_during_traffic();
        scen_reset_loses_dirty();
        scen_back_to_back();
        scen_all_sets();
        scen_random(2000);

        // Final flush, then the check that actually proves write-back works.
        do_flush("final");
        check_memory("final");
        check_traffic();

        // The showcase run is last so the marked window is a clean, isolated
        // piece of the VCD.  It re-initialises everything it needs.
        mem_init();
        ref_model_init();
        scen_showcase();

        report_coverage();

        $display("");
        if (errors == 0) begin
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d error(s))", errors);
        end
        $finish;
    end

    // ---- watchdog ----------------------------------------------------------
    initial begin
        #40_000_000;
        $display("RESULT: *** FAIL *** (timeout - the controller stopped making progress)");
        $finish;
    end

endmodule
