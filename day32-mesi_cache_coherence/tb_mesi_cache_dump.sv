// =============================================================================
// Day32 - tb_mesi_cache_dump.sv
//
//   Portable, self-checking testbench for the MESI snooping coherence system.
//   This is the procedural twin of the UVM environment in mesi_cache_pkg.sv:
//   Icarus implements neither the UVM class library nor a constraint solver,
//   so this file exists to make the design verifiable with an open-source
//   toolchain and to capture the committed waveform.  It drives the same
//   stimulus, uses the same golden model, and applies the same checks.
//
//   WHAT IT CHECKS
//     - ref_selfcheck()   re-proves the golden model's own protocol rules
//                         inside the simulator before any DUT result is judged
//     - every cycle       SWMR, no-two-dirty, and sharer agreement, read
//                         straight out of both caches' tag/state arrays
//     - every completion  the data-value invariant (a load returns the most
//                         recent store in completion order), hit == "no bus
//                         transaction", and hit/miss against the protocol
//     - every bus phase   the wired-OR shared line, the cache-to-cache flush
//                         decision, and the flushed data value
//     - every quiesce     full model/DUT reconciliation: state, tags, cached
//                         data, physical memory rebuilt from observed memory
//                         writes alone, and the architectural value
//
//   Prints "RESULT: *** PASS ***" only if every check passed AND every
//   coherence property below was actually exercised - a coverage hole fails
//   the run.
// =============================================================================
`timescale 1ns/1ps

module tb_mesi_cache_dump;

  import mesi_ref_pkg::*;

  localparam int CLKP  = 10;
  localparam int NADDRS = 12;    // stimulus works over addresses 0..11, which
                                 // is 3 tags per set in a 4-set direct-mapped
                                 // cache: conflict misses are the common case,
                                 // not a rare corner

  // ---------------------------------------------------------------------
  // clock / reset
  // ---------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n;
  always #(CLKP/2) clk = ~clk;

  // ---------------------------------------------------------------------
  // DUT connections
  // ---------------------------------------------------------------------
  logic [NCORE-1:0]    cpu_req, cpu_we;
  logic [NCORE*AW-1:0] cpu_addr_f;
  logic [NCORE*DW-1:0] cpu_wdata_f;
  logic [NCORE-1:0]    cpu_ack, cpu_hit, cpu_busy;
  logic [NCORE*DW-1:0] cpu_rdata_f;

  logic                mem_req, mem_we;
  logic [AW-1:0]       mem_addr;
  logic [DW-1:0]       mem_wdata;
  logic                mem_gnt, mem_rvalid;
  logic [DW-1:0]       mem_rdata;

  logic                bus_valid;
  logic [1:0]          bus_cmd;
  logic [AW-1:0]       bus_addr;
  logic [$clog2(NCORE)-1:0] bus_master;
  logic                bus_fill, bus_fill_shared, bus_c2c, bus_busy;
  logic [DW-1:0]       bus_fill_data;

  logic [NCORE*2*NSET-1:0]  dbg_state_f;
  logic [NCORE*AW*NSET-1:0] dbg_tag_f;
  logic [NCORE*DW*NSET-1:0] dbg_data_f;

  mesi_system #(.DW(DW), .AW(AW), .NSET(NSET), .NCORE(NCORE)) dut (
    .clk(clk), .rst_n(rst_n),
    .cpu_req(cpu_req), .cpu_we(cpu_we),
    .cpu_addr_f(cpu_addr_f), .cpu_wdata_f(cpu_wdata_f),
    .cpu_ack(cpu_ack), .cpu_rdata_f(cpu_rdata_f),
    .cpu_hit(cpu_hit), .cpu_busy(cpu_busy),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_gnt(mem_gnt),
    .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
    .bus_valid(bus_valid), .bus_cmd(bus_cmd), .bus_addr(bus_addr),
    .bus_master(bus_master), .bus_fill(bus_fill),
    .bus_fill_shared(bus_fill_shared), .bus_fill_data(bus_fill_data),
    .bus_c2c(bus_c2c), .bus_busy(bus_busy),
    .dbg_state_f(dbg_state_f), .dbg_tag_f(dbg_tag_f), .dbg_data_f(dbg_data_f)
  );

  // ---- waveform-friendly aliases --------------------------------------
  // The MESI state of set 0 in each cache is the signal the whole design is
  // about, so give it a name a waveform viewer can show on its own.
  wire [1:0]    c0_set0_state = dbg_state_f[0*2*NSET +: 2];
  wire [1:0]    c1_set0_state = dbg_state_f[1*2*NSET +: 2];

  wire          c0_req  = cpu_req[0];
  wire          c0_we   = cpu_we[0];
  wire          c0_ack  = cpu_ack[0];
  wire          c0_hit  = cpu_hit[0];
  wire [AW-1:0] c0_addr = cpu_addr_f [0*AW +: AW];
  wire [DW-1:0] c0_rd   = cpu_rdata_f[0*DW +: DW];

  wire          c1_req  = cpu_req[1];
  wire          c1_we   = cpu_we[1];
  wire          c1_ack  = cpu_ack[1];
  wire          c1_hit  = cpu_hit[1];
  wire [AW-1:0] c1_addr = cpu_addr_f [1*AW +: AW];
  wire [DW-1:0] c1_rd   = cpu_rdata_f[1*DW +: DW];

  // ---------------------------------------------------------------------
  // pseudo-random source (xorshift - reproducible, and available on every
  // simulator, unlike $urandom)
  // ---------------------------------------------------------------------
  int unsigned rnd_state = 32'h1357_9BDF;
  function automatic int unsigned rnd();
    rnd_state = rnd_state ^ (rnd_state << 13);
    rnd_state = rnd_state ^ (rnd_state >> 17);
    rnd_state = rnd_state ^ (rnd_state << 5);
    rnd = rnd_state;
  endfunction

  // ---------------------------------------------------------------------
  // Backing memory model.  Not part of the DUT: its write port is the
  // scoreboard's ONLY window onto what the caches actually pushed to DRAM.
  // Configurable stall rate and read latency, because fill/evict interaction
  // bugs live where the memory is slow and uncooperative.
  // ---------------------------------------------------------------------
  logic [DW-1:0] mem [NADDR];
  int            mem_stall_pct = 0;
  int            mem_lat       = 0;

  logic          mem_stall;
  logic          rd_pend;
  logic [AW-1:0] rd_addr;
  int            rd_cnt;

  assign mem_gnt = mem_req && !mem_stall;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_stall  <= 1'b0;
      mem_rvalid <= 1'b0;
      rd_pend    <= 1'b0;
      rd_cnt     <= 0;
      rd_addr    <= '0;
      mem_rdata  <= '0;
    end else begin
      mem_rvalid <= 1'b0;
      mem_stall  <= (mem_stall_pct > 0) && ((rnd() % 100) < mem_stall_pct);

      if (mem_req && mem_gnt) begin
        if (mem_we) mem[mem_addr] <= mem_wdata;
        else begin
          rd_addr <= mem_addr;
          rd_cnt  <= mem_lat;
          rd_pend <= 1'b1;
        end
      end

      if (rd_pend) begin
        if (rd_cnt == 0) begin
          mem_rvalid <= 1'b1;
          mem_rdata  <= mem[rd_addr];
          rd_pend    <= 1'b0;
        end else begin
          rd_cnt <= rd_cnt - 1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Per-core access bookkeeping.  Written by the drivers mid-cycle (1ns
  // after an edge) and read by the monitor at the edge, so the two never
  // race.
  // ---------------------------------------------------------------------
  bit            acc_pending    [NCORE];
  bit            acc_we         [NCORE];
  logic [AW-1:0] acc_addr       [NCORE];
  logic [DW-1:0] acc_wdata      [NCORE];
  bit            acc_pred_hit   [NCORE];
  bit            acc_pred_valid [NCORE];
  int            acc_txns       [NCORE];

  // transaction currently on the bus
  int            txn_master;
  logic [1:0]    txn_cmd;
  logic [AW-1:0] txn_addr;
  bit            txn_shared, txn_dirty, txn_active;
  logic [DW-1:0] txn_fdata;

  bit          mon_en = 1'b0;
  int unsigned n_cycles, n_mem_w, n_mem_r, n_bus_txn;
  int          mc;

  // ---------------------------------------------------------------------
  // Monitor + scoreboard
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && mon_en) begin
      n_cycles = n_cycles + 1;

      // ---- A. structural coherence invariants, straight off the DUT ----
      ref_check_swmr(dbg_state_f, dbg_tag_f, dbg_data_f);

      // ---- B. observed memory traffic ---------------------------------
      if (mem_req && mem_gnt) begin
        if (mem_we) begin
          ref_mem_write(mem_addr, mem_wdata);
          n_mem_w = n_mem_w + 1;
        end else begin
          n_mem_r = n_mem_r + 1;
        end
      end

      // ---- C. bus ADDRESS phase ---------------------------------------
      if (bus_valid) begin
        txn_master = int'(bus_master);
        txn_cmd    = bus_cmd;
        txn_addr   = bus_addr;
        txn_dirty  = ref_pred_dirty (txn_master, txn_cmd, txn_addr);
        txn_fdata  = ref_flush_data (txn_master, txn_addr);

        // an upgrade is only legal from a shared copy: upgrading from I would
        // be claiming a line this cache does not hold, and from M/E it would
        // be pointless work that also breaks the other caches' assumptions
        if ((txn_cmd == BUSUPGR) && (ref_state(txn_master, txn_addr) != ST_S))
          ref_err($sformatf("core%0d issued BusUpgr for addr %0d while holding it in %s",
                            txn_master, txn_addr,
                            st_name(ref_state(txn_master, txn_addr))));

        txn_shared = ref_bus_addr_phase(txn_master, txn_cmd, txn_addr);
        txn_active = 1'b1;
        n_bus_txn  = n_bus_txn + 1;
        acc_txns[txn_master] = acc_txns[txn_master] + 1;

        // A snoop landing on an address another core is mid-access to makes
        // that core's hit/miss prediction legitimately void.  Counted, not
        // hidden - the total is printed at the end of the run.
        for (mc = 0; mc < NCORE; mc = mc + 1)
          if ((mc != txn_master) && acc_pending[mc] &&
              (acc_addr[mc] == txn_addr) && (txn_cmd != BUSWB))
            acc_pred_valid[mc] = 1'b0;
      end

      // ---- D. bus COMPLETION -------------------------------------------
      if (bus_fill) begin
        if (!txn_active)
          ref_err("a bus completion arrived with no transaction outstanding");

        // the wired-OR "somebody else has it" line decides E vs S
        if (bus_fill_shared !== txn_shared)
          ref_err($sformatf("%s addr %0d by core%0d: DUT shared=%0b, model %0b",
                            cmd_name(txn_cmd), txn_addr, txn_master,
                            bus_fill_shared, txn_shared));

        // a dirty owner must supply the line instead of memory
        if (bus_c2c !== txn_dirty)
          ref_err($sformatf("%s addr %0d by core%0d: DUT cache-to-cache=%0b, model %0b",
                            cmd_name(txn_cmd), txn_addr, txn_master, bus_c2c, txn_dirty));
        if (txn_dirty) begin
          if (bus_fill_data !== txn_fdata)
            ref_err($sformatf("flush of addr %0d carried 0x%08h, owner held 0x%08h",
                              txn_addr, bus_fill_data, txn_fdata));
          n_c2c = n_c2c + 1;
        end

        ref_bus_complete(txn_master, txn_cmd, txn_addr, bus_fill_shared, bus_fill_data);
        txn_active = 1'b0;
      end

      // ---- E. CPU completions ------------------------------------------
      for (mc = 0; mc < NCORE; mc = mc + 1)
        if (cpu_ack[mc]) begin
          if (!acc_pending[mc])
            ref_err($sformatf("core%0d acknowledged an access nobody launched", mc));
          ref_cpu_complete(mc, acc_we[mc], acc_addr[mc], acc_wdata[mc],
                           cpu_rdata_f[mc*DW +: DW], cpu_hit[mc],
                           acc_pred_valid[mc], acc_pred_hit[mc], acc_txns[mc]);
          acc_pending[mc] = 1'b0;
        end
    end
  end

  // ---------------------------------------------------------------------
  // Drivers
  // ---------------------------------------------------------------------
  task automatic tick();
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic do_access(input int c, input bit we,
                           input logic [AW-1:0] a, input logic [DW-1:0] d);
    begin
      while (cpu_busy[c] || acc_pending[c]) tick();

      acc_we        [c] = we;
      acc_addr      [c] = a;
      acc_wdata     [c] = d;
      acc_txns      [c] = 0;
      acc_pred_hit  [c] = ref_pred_hit(c, we, a);
      acc_pred_valid[c] = 1'b1;
      acc_pending   [c] = 1'b1;

      cpu_req[c]              = 1'b1;
      cpu_we [c]              = we;
      cpu_addr_f [c*AW +: AW] = a;
      cpu_wdata_f[c*DW +: DW] = d;

      tick();                        // this edge latched the request
      cpu_req[c] = 1'b0;

      while (acc_pending[c]) tick();
    end
  endtask

  task automatic rd(input int c, input logic [AW-1:0] a);
    do_access(c, 1'b0, a, '0);
  endtask

  task automatic wr(input int c, input logic [AW-1:0] a, input logic [DW-1:0] d);
    do_access(c, 1'b1, a, d);
  endtask

  task automatic do_reset(input int ncyc);
    begin
      mon_en  = 1'b0;
      rst_n   = 1'b0;
      cpu_req = '0;
      repeat (ncyc) @(posedge clk);
      #1;
      ref_hw_reset();                // reset DISCARDS every un-written-back store
      for (mc = 0; mc < NCORE; mc = mc + 1) acc_pending[mc] = 1'b0;
      txn_active = 1'b0;
      rst_n      = 1'b1;
      tick();
      mon_en = 1'b1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Scenario plumbing
  // ---------------------------------------------------------------------
  int unsigned err_at_scenario_start;
  int          n_scenarios;

  task automatic scenario(input string name);
    begin
      ctx                   = name;
      err_at_scenario_start = n_err;
      n_scenarios           = n_scenarios + 1;
    end
  endtask

  task automatic quiesce();
    begin
      while (cpu_busy[0] || cpu_busy[1] || bus_busy ||
             acc_pending[0] || acc_pending[1]) tick();
      repeat (3) tick();
    end
  endtask

  task automatic endscenario();
    begin
      quiesce();
      ref_check_full(dbg_state_f, dbg_tag_f, dbg_data_f);
      $display("  %-34s %s   [core0 %s%s%s%s | core1 %s%s%s%s]",
               ctx,
               (n_err == err_at_scenario_start) ? "ok  " : "FAIL",
               st_name(dbg_state_f[0*2*NSET+0 +: 2]), st_name(dbg_state_f[0*2*NSET+2 +: 2]),
               st_name(dbg_state_f[0*2*NSET+4 +: 2]), st_name(dbg_state_f[0*2*NSET+6 +: 2]),
               st_name(dbg_state_f[1*2*NSET+0 +: 2]), st_name(dbg_state_f[1*2*NSET+2 +: 2]),
               st_name(dbg_state_f[1*2*NSET+4 +: 2]), st_name(dbg_state_f[1*2*NSET+6 +: 2]));
    end
  endtask

  // ---------------------------------------------------------------------
  // Random regression
  // ---------------------------------------------------------------------
  logic [AW-1:0] last_addr [NCORE];

  task automatic random_stream(input int c, input int n);
    int i;
    int unsigned r;
    logic [AW-1:0] a;
    begin
      for (i = 0; i < n; i = i + 1) begin
        r = rnd();
        // A locality term matters here: with uniformly random addresses over
        // three tags per set almost every access misses, and the hit path -
        // the one a real workload takes most often, and the only path where
        // the silent E->M upgrade lives - barely runs.
        if (((r >> 8) % 100) < 45) a = last_addr[c];
        else                       a = (r % NADDRS);
        last_addr[c] = a;
        do_access(c, r[0], a, rnd());
        // stagger the two cores so their accesses interleave rather than
        // marching in lockstep
        if (((r >> 16) % 4) == 0) tick();
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Coverage gate - a property that was never exercised is a hole, and a
  // hole fails the run.
  // ---------------------------------------------------------------------
  int n_holes;
  task automatic want(input string what, input int unsigned count);
    begin
      $display("    %-46s %0d", what, count);
      if (count == 0) begin
        n_holes = n_holes + 1;
        $display("      ^^ COVERAGE HOLE: never exercised");
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------
  int sc_err;
  int i;

  initial begin
    $dumpfile("tb_mesi_cache_dump.vcd");
    $dumpvars(0, tb_mesi_cache_dump);

    cpu_req     = '0;
    cpu_we      = '0;
    cpu_addr_f  = '0;
    cpu_wdata_f = '0;
    n_cycles = 0; n_mem_w = 0; n_mem_r = 0; n_bus_txn = 0;
    n_scenarios = 0; n_holes = 0;
    for (i = 0; i < NCORE; i = i + 1) begin
      acc_pending[i] = 1'b0; last_addr[i] = '0; acc_txns[i] = 0;
    end

    $display("");
    $display("=====================================================================");
    $display(" Day32 - MESI snooping cache coherence : self-checking testbench");
    $display("=====================================================================");
    $display(" %0d cores, %0d sets, 1 word/line, %0d-bit data, %0d-bit address",
             NCORE, NSET, DW, AW);
    $display("");

    // ---- 0. the model proves its own rules before judging anything ----
    $display(" [0] reference model self-check");
    sc_err = ref_selfcheck();
    if (sc_err != 0) begin
      $display("  reference model FAILED its own self-check (%0d errors) - aborting", sc_err);
      $display("RESULT: *** FAIL ***");
      $finish;
    end
    $display("  golden model re-proved 7 protocol properties        ok");
    $display("");

    // seed memory to match the model's image
    ref_init(32'hC0DE_0000);
    for (i = 0; i < NADDR; i = i + 1) mem[i] = ref_mem_read(i[AW-1:0]);

    do_reset(4);

    // =================================================================
    // [1] The MESI showcase - this is the window the committed waveform
    //     captures, and it is the whole protocol in five accesses.
    // =================================================================
    $display(" [1] directed coherence scenarios");

    scenario("cold read miss installs E");
      rd(0, 8'd4);                  // nobody else has it -> Exclusive, not Shared
    endscenario();

    scenario("store on E is SILENT (no bus)");
      wr(0, 8'd4, 32'h1111_1111);   // E -> M with zero bus transactions
    endscenario();

    scenario("remote read flushes M -> S");
      rd(1, 8'd4);                  // owner flushes, both end Shared, DRAM updated
    endscenario();

    scenario("store on S issues BusUpgr");
      wr(1, 8'd4, 32'h2222_2222);   // core0 invalidated, no data moves
    endscenario();

    scenario("store on I issues BusRdX");
      wr(0, 8'd4, 32'h3333_3333);   // pulls the line back with a flush
    endscenario();

    // =================================================================
    // [2] The rest of the protocol surface
    // =================================================================
    scenario("read hit needs no bus");
      rd(0, 8'd4); rd(0, 8'd4);
    endscenario();

    scenario("two readers both land in S");
      rd(0, 8'd5); rd(1, 8'd5);
    endscenario();

    scenario("read hit on S needs no bus");
      rd(0, 8'd5); rd(1, 8'd5);
    endscenario();

    scenario("clean victim evicts silently");
      rd(0, 8'd9);                  // set 1, tag 2 - displaces the clean line
    endscenario();

    scenario("dirty victim writes back first");
      wr(0, 8'd6, 32'h4444_4444);   // set 2, dirty
      rd(0, 8'd10);                 // same set, other tag -> BusWB then BusRd
    endscenario();

    scenario("writeback goes to the victim's own address");
      wr(0, 8'd7, 32'hAAAA_0001);
      wr(0, 8'd11, 32'hAAAA_0002);  // evicts addr 7, must write back to 7
      rd(1, 8'd7);                  // and 7 must read back as AAAA_0001
    endscenario();

    scenario("remote store invalidates a sharer");
      rd(0, 8'd0); rd(1, 8'd0);
      wr(1, 8'd0, 32'h5555_5555);
      rd(0, 8'd0);                  // core0 must refetch and see the new value
    endscenario();

    scenario("migratory line ping-pong");
      for (i = 0; i < 8; i = i + 1) begin
        wr(i[0], 8'd1, 32'h6000_0000 + i);
      end
    endscenario();

    scenario("index thrash across three tags");
      for (i = 0; i < 9; i = i + 1) begin
        wr(0, (i % 3) * 4 + 2, 32'h7000_0000 + i);
      end
    endscenario();

    scenario("every set touched from both cores");
      for (i = 0; i < NSET; i = i + 1) begin
        rd(0, i[AW-1:0]);
        wr(1, i[AW-1:0], 32'h8000_0000 + i);
        rd(0, i[AW-1:0]);
      end
    endscenario();

    // =================================================================
    // [3] The race: both cores hold S and both decide to store.  One wins
    //     the arbiter; the loser's queued BusUpgr is a lie by the time it
    //     is granted - it no longer holds a copy - and must become a full
    //     BusRdX.  Getting this wrong silently produces two writers.
    // =================================================================
    scenario("concurrent upgrade race on a shared line");
      for (i = 0; i < 12; i = i + 1) begin
        rd(0, 8'd3);
        rd(1, 8'd3);
        quiesce();
        fork
          wr(0, 8'd3, 32'h9000_0000 + i);
          wr(1, 8'd3, 32'hA000_0000 + i);
        join
      end
    endscenario();

    scenario("concurrent access to the same set, different tags");
      for (i = 0; i < 12; i = i + 1) begin
        fork
          wr(0, 8'd2,  32'hB000_0000 + i);
          wr(1, 8'd6,  32'hC000_0000 + i);
        join
      end
    endscenario();

    // =================================================================
    // [4] Reset honestly discards dirty data
    // =================================================================
    scenario("reset discards un-written-back stores");
      wr(0, 8'd8, 32'hDEAD_0001);   // dirty in core0's cache, NOT in memory
      quiesce();
      do_reset(3);
      rd(1, 8'd8);                  // must return the OLD memory value
    endscenario();

    // =================================================================
    // [5] Constrained-random regression, first against a cooperative
    //     memory then against a hostile one
    // =================================================================
    $display("");
    $display(" [2] constrained-random regression");

    scenario("random, zero-latency memory");
      mem_stall_pct = 0; mem_lat = 0;
      fork
        random_stream(0, 400);
        random_stream(1, 400);
      join
    endscenario();

    scenario("random, memory stalls 40% with 3-cycle reads");
      mem_stall_pct = 40; mem_lat = 3;
      fork
        random_stream(0, 400);
        random_stream(1, 400);
      join
    endscenario();

    scenario("random, memory stalls 70% with 8-cycle reads");
      mem_stall_pct = 70; mem_lat = 8;
      fork
        random_stream(0, 300);
        random_stream(1, 300);
      join
    endscenario();

    scenario("random with a mid-stream reset");
      mem_stall_pct = 25; mem_lat = 2;
      fork
        random_stream(0, 150);
        random_stream(1, 150);
      join
      quiesce();
      do_reset(3);
      fork
        random_stream(0, 150);
        random_stream(1, 150);
      join
    endscenario();

    quiesce();

    // =================================================================
    // Report
    // =================================================================
    $display("");
    $display(" [3] what the run actually exercised");
    want("read misses installing E (exclusive, unshared)", n_e_install);
    want("read misses installing S (someone else had it)", n_s_install);
    want("SILENT E->M upgrades (zero bus transactions)",   n_e_silent);
    want("M->S downgrades caused by a remote read",        n_m_downgrade);
    want("invalidations caused by a remote store",         n_inval);
    want("cache-to-cache flushes (owner supplied data)",   n_c2c);
    want("dirty victim writebacks",                        n_evict_wb);
    want("BusRd  transactions",                            n_busrd);
    want("BusRdX transactions",                            n_busrdx);
    want("BusUpgr transactions",                           n_busupgr);
    want("BusWB  transactions",                            n_buswb);
    want("cache hits",                                     n_hit);
    want("cache misses",                                   n_miss);

    // ---- traffic reconciliation ------------------------------------
    //
    // Checking the CPU port is not enough: a cache can return perfect load
    // data forever while writing back twice, dropping a writeback, or
    // fetching from memory when another cache already owned the line, and
    // nothing on the response channel would ever notice.  Every memory
    // access must be accounted for by a protocol event.
    //   writes = one per dirty eviction + one per cache-to-cache flush
    //            (a flush updates DRAM too - there is no Owned state here)
    //   reads  = one per line fetch that no cache was able to supply
    $display("");
    $display(" [3b] memory traffic reconciliation");
    if (n_mem_w != (n_c2c + n_evict_wb))
      ref_err($sformatf("memory saw %0d writes, but the protocol required %0d (%0d flushes + %0d writebacks)",
                        n_mem_w, n_c2c + n_evict_wb, n_c2c, n_evict_wb));
    if (n_mem_r != (n_busrd + n_busrdx - n_c2c))
      ref_err($sformatf("memory saw %0d reads, but the protocol required %0d (%0d fetches - %0d supplied by a cache)",
                        n_mem_r, n_busrd + n_busrdx - n_c2c, n_busrd + n_busrdx, n_c2c));
    $display("    writes  %0d  ==  %0d flushes + %0d writebacks", n_mem_w, n_c2c, n_evict_wb);
    $display("    reads   %0d  ==  %0d fetches - %0d supplied cache-to-cache",
             n_mem_r, n_busrd + n_busrdx, n_c2c);

    $display("");
    $display(" [4] summary");
    $display("    scenarios                     %0d", n_scenarios);
    $display("    cycles monitored              %0d", n_cycles);
    $display("    CPU accesses checked          %0d  (%0d reads, %0d writes)",
             n_check, n_cpu_read, n_cpu_write);
    $display("    bus transactions              %0d", n_bus_txn);
    $display("    memory reads / writes         %0d / %0d", n_mem_r, n_mem_w);
    $display("    hit predictions voided by a racing snoop   %0d", n_pred_skipped);
    $display("    errors                        %0d", n_err);
    $display("    coverage holes                %0d", n_holes);
    $display("");

    if ((n_err == 0) && (n_holes == 0) && (n_check > 0)) begin
      $display("RESULT: *** PASS ***");
    end else begin
      $display("RESULT: *** FAIL ***");
    end
    $display("");
    $finish;
  end

  // ---------------------------------------------------------------------
  // watchdog
  // ---------------------------------------------------------------------
  initial begin
    #3_000_000;
    $display("");
    $display("  [ERROR] timeout - the system stopped making progress");
    $display("RESULT: *** FAIL ***");
    $finish;
  end

endmodule
