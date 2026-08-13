// =============================================================================
// Day32 - mesi_ref_pkg.sv
//
//   The golden model for MESI snooping coherence.
//
//   WHY IT IS SHAPED LIKE THIS
//   --------------------------
//   A coherence protocol cannot be checked the way a datapath is checked.
//   There is no "expected output" to compare against, because what each core
//   observes depends on an interleaving the testbench does not choose - the
//   bus arbiter does.  Feed the same two instruction streams in twice and the
//   caches legitimately end up in different states.
//
//   So the model checks three things that ARE deterministic, at three
//   different levels, and a bug has to survive all three:
//
//   1. THE DATA-VALUE INVARIANT (black box, order-agnostic).
//      Every bus transaction is globally serialised, and each core has one
//      access outstanding, so the order in which accesses COMPLETE is a valid
//      total order.  Against that order the rule is absolute: a load returns
//      the value of the most recent store.  arch[] carries that value.  This
//      needs no knowledge of MESI at all - it is the property coherence
//      exists to provide, and it is checked on every single completion.
//
//   2. THE STATE INVARIANTS (white box, every cycle).
//      SWMR - single-writer / multiple-reader - is the safety property the
//      protocol is built to maintain: for any address, either exactly one
//      core holds it exclusively (M or E) and no one else holds it at all, or
//      any number hold it in S and no one holds it exclusively.  Plus the
//      data invariants that hang off it: all sharers agree, a shared line
//      matches memory, and memory matches the architectural value whenever
//      nobody owns the line dirty.  These are checked against the DUTs'
//      actual tag/state arrays on every clock edge, so a protocol violation
//      is caught the cycle it appears rather than whenever it happens to
//      corrupt a load.
//
//   3. THE STATE PREDICTION (white box, transaction driven).
//      The model re-derives what every cache's state must be from the
//      OBSERVED BUS EVENT STREAM - address phases and completions - and
//      compares it to the DUT's arrays.  It is structurally nothing like the
//      RTL: no FSM, no handshake, just a table that applies the protocol's
//      transition rules.  This is what makes "the line ended up in S when it
//      should have been E" a failure instead of a silent loss of the entire
//      point of MESI.
//
//   pmem[] deserves a note.  It is the model's picture of PHYSICAL memory and
//   it is rebuilt from observed memory-port writes ALONE - the model never
//   writes it from its own idea of what should have happened.  A cache that
//   returns perfect load data forever while writing the wrong line back to
//   the wrong address is the bug class that matters most here, and only an
//   independently reconstructed memory image can see it.
// =============================================================================

package mesi_ref_pkg;

  // Geometry - must match the DUT instantiation in the testbench.
  localparam int DW    = 32;
  localparam int AW    = 8;
  localparam int NSET  = 4;
  localparam int NCORE = 2;
  localparam int IDXW  = 2;
  localparam int TAGW  = AW - IDXW;
  localparam int NADDR = 1 << AW;

  // MESI states
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // bus commands
  localparam logic [1:0] BUSRD   = 2'd0;
  localparam logic [1:0] BUSRDX  = 2'd1;
  localparam logic [1:0] BUSUPGR = 2'd2;
  localparam logic [1:0] BUSWB   = 2'd3;

  // ---------------------------------------------------------------------
  // Model state.  Flat arrays with an explicit index function - Icarus is
  // happier with these than with multi-dimensional unpacked arrays.
  // ---------------------------------------------------------------------
  logic [1:0]      rs   [NCORE*NSET];   // MESI state per core per set
  logic [TAGW-1:0] rt   [NCORE*NSET];   // resident tag
  logic [DW-1:0]   rdat [NCORE*NSET];   // cached value

  logic [DW-1:0]   arch [NADDR];        // architectural value (data-value invariant)
  logic [DW-1:0]   pmem [NADDR];        // physical memory, from observed writes only

  // ---- statistics / coverage of the properties actually exercised -------
  int unsigned n_err;
  int unsigned n_check;
  int unsigned n_cpu_read, n_cpu_write;
  int unsigned n_hit, n_miss;
  int unsigned n_busrd, n_busrdx, n_busupgr, n_buswb;
  int unsigned n_c2c;            // cache-to-cache flushes
  int unsigned n_e_install;      // read misses that installed E (nobody else had it)
  int unsigned n_s_install;      // read misses that installed S
  int unsigned n_e_silent;       // stores to an E line that used ZERO bus cycles
  int unsigned n_m_downgrade;    // M -> S caused by another core's read
  int unsigned n_inval;          // valid -> I caused by another core's write
  int unsigned n_evict_wb;       // dirty victim writebacks
  int unsigned n_upgr_killed;    // BUSUPGR that had to become BUSRDX
  int unsigned n_pred_skipped;   // hit predictions voided by a racing snoop

  string       ctx;              // scenario name, for readable failure messages

  function automatic int ix(input int c, input int s);
    ix = c*NSET + s;
  endfunction

  function automatic int idx_of(input logic [AW-1:0] a);
    idx_of = int'(a[IDXW-1:0]);
  endfunction

  function automatic logic [TAGW-1:0] tag_of(input logic [AW-1:0] a);
    tag_of = a[AW-1:IDXW];
  endfunction

  function automatic logic [AW-1:0] addr_of(input logic [TAGW-1:0] t, input int s);
    addr_of = {t, s[IDXW-1:0]};
  endfunction

  // ---------------------------------------------------------------------
  // Reporting
  // ---------------------------------------------------------------------
  function automatic void ref_err(input string msg);
    n_err = n_err + 1;
    $display("  [ERROR][%s] %s", ctx, msg);
  endfunction

  function automatic string st_name(input logic [1:0] s);
    case (s)
      ST_I:    st_name = "I";
      ST_S:    st_name = "S";
      ST_E:    st_name = "E";
      default: st_name = "M";
    endcase
  endfunction

  function automatic string cmd_name(input logic [1:0] c);
    case (c)
      BUSRD:   cmd_name = "BusRd  ";
      BUSRDX:  cmd_name = "BusRdX ";
      BUSUPGR: cmd_name = "BusUpgr";
      default: cmd_name = "BusWB  ";
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Reset / init
  // ---------------------------------------------------------------------
  function automatic void ref_reset_caches();
    int c, s;
    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        rs  [ix(c,s)] = ST_I;
        rt  [ix(c,s)] = '0;
        rdat[ix(c,s)] = '0;
      end
  endfunction

  // A hardware reset clears valid/dirty, so every store not yet written back
  // is DISCARDED.  The architectural view has to be rolled back to what
  // physical memory actually holds - modelling that honestly is the whole
  // point, because pretending the data survived is exactly how a real
  // data-loss bug reaches silicon.
  function automatic void ref_hw_reset();
    int a;
    ref_reset_caches();
    for (a = 0; a < NADDR; a = a + 1)
      arch[a] = pmem[a];
  endfunction

  function automatic void ref_init(input logic [DW-1:0] seed);
    int a;
    n_err = 0; n_check = 0;
    n_cpu_read = 0; n_cpu_write = 0; n_hit = 0; n_miss = 0;
    n_busrd = 0; n_busrdx = 0; n_busupgr = 0; n_buswb = 0;
    n_c2c = 0; n_e_install = 0; n_s_install = 0; n_e_silent = 0;
    n_m_downgrade = 0; n_inval = 0; n_evict_wb = 0; n_upgr_killed = 0;
    n_pred_skipped = 0;
    ctx = "init";
    ref_reset_caches();
    for (a = 0; a < NADDR; a = a + 1) begin
      arch[a] = seed ^ {24'h0, a[7:0]};
      pmem[a] = arch[a];
    end
  endfunction

  // ---------------------------------------------------------------------
  // Queries used to predict DUT behaviour
  // ---------------------------------------------------------------------
  function automatic logic [1:0] ref_state(input int c, input logic [AW-1:0] a);
    int s;
    s = idx_of(a);
    ref_state = (rt[ix(c,s)] == tag_of(a)) ? rs[ix(c,s)] : ST_I;
  endfunction

  // A hit is an access the cache can serve with NO bus transaction:
  //   read  - any valid state
  //   write - only an exclusive state (M or E).  A store to S needs BusUpgr,
  //           which is exactly where MESI beats MSI: E costs nothing.
  function automatic bit ref_pred_hit(input int c, input bit we, input logic [AW-1:0] a);
    logic [1:0] s;
    s = ref_state(c, a);
    if (s == ST_I)     ref_pred_hit = 1'b0;
    else if (!we)      ref_pred_hit = 1'b1;
    else               ref_pred_hit = (s == ST_M) || (s == ST_E);
  endfunction

  // ---------------------------------------------------------------------
  // Bus ADDRESS phase: apply every other core's snoop transition.
  // Returns the value the fabric's wired-OR "shared" line must carry.
  // ---------------------------------------------------------------------
  function automatic bit ref_bus_addr_phase(input int master,
                                            input logic [1:0] cmd,
                                            input logic [AW-1:0] a);
    int c, s;
    logic [1:0] cur;
    bit shared;
    shared = 1'b0;
    s = idx_of(a);

    case (cmd)
      BUSRD:   n_busrd   = n_busrd   + 1;
      BUSRDX:  n_busrdx  = n_busrdx  + 1;
      BUSUPGR: n_busupgr = n_busupgr + 1;
      default: n_buswb   = n_buswb   + 1;
    endcase

    if (cmd == BUSWB) return 1'b0;   // a writeback changes nobody else's state

    for (c = 0; c < NCORE; c = c + 1) begin
      if (c == master) continue;
      cur = ref_state(c, a);
      if (cur == ST_I) continue;
      shared = 1'b1;

      case (cmd)
        BUSRD: begin
          // an owner has to give up exclusivity and flush if dirty
          if (cur == ST_M) n_m_downgrade = n_m_downgrade + 1;
          rs[ix(c,s)] = ST_S;
        end
        BUSRDX: begin
          n_inval = n_inval + 1;
          rs[ix(c,s)] = ST_I;
        end
        BUSUPGR: begin
          // the upgrader claimed to hold a shared copy, so nobody else may
          // hold it exclusively - that would be two writers at once
          if ((cur == ST_M) || (cur == ST_E))
            ref_err($sformatf("BusUpgr addr %0d found core %0d in %s (SWMR broken)",
                              a, c, st_name(cur)));
          n_inval = n_inval + 1;
          rs[ix(c,s)] = ST_I;
        end
        default: ;
      endcase
    end
    ref_bus_addr_phase = shared;
  endfunction

  // Would this address phase produce a cache-to-cache flush?  (Called BEFORE
  // ref_bus_addr_phase, since that one applies the transitions.)
  function automatic bit ref_pred_dirty(input int master,
                                        input logic [1:0] cmd,
                                        input logic [AW-1:0] a);
    int c;
    bit d;
    d = 1'b0;
    if ((cmd == BUSRD) || (cmd == BUSRDX))
      for (c = 0; c < NCORE; c = c + 1)
        if ((c != master) && (ref_state(c, a) == ST_M)) d = 1'b1;
    ref_pred_dirty = d;
  endfunction

  // The value a flush must carry.
  function automatic logic [DW-1:0] ref_flush_data(input int master, input logic [AW-1:0] a);
    int c;
    logic [DW-1:0] v;
    v = '0;
    for (c = 0; c < NCORE; c = c + 1)
      if ((c != master) && (ref_state(c, a) == ST_M)) v = rdat[ix(c, idx_of(a))];
    ref_flush_data = v;
  endfunction

  // ---------------------------------------------------------------------
  // Bus COMPLETION: the requester installs (or drops) the line.
  // ---------------------------------------------------------------------
  function automatic void ref_bus_complete(input int master,
                                           input logic [1:0] cmd,
                                           input logic [AW-1:0] a,
                                           input bit shared,
                                           input logic [DW-1:0] data);
    int s;
    s = idx_of(a);
    case (cmd)
      BUSWB: begin
        // the dirty victim is now safely in memory; the line is dropped
        n_evict_wb = n_evict_wb + 1;
        rs[ix(master,s)] = ST_I;
      end
      BUSUPGR: begin
        rs[ix(master,s)] = ST_M;
      end
      BUSRDX: begin
        rs  [ix(master,s)] = ST_M;
        rt  [ix(master,s)] = tag_of(a);
        rdat[ix(master,s)] = data;
      end
      default: begin // BUSRD
        // E when nobody answered, S when somebody did - the MESI decision
        if (shared) n_s_install = n_s_install + 1;
        else        n_e_install = n_e_install + 1;
        rs  [ix(master,s)] = shared ? ST_S : ST_E;
        rt  [ix(master,s)] = tag_of(a);
        rdat[ix(master,s)] = data;
      end
    endcase
  endfunction

  // A BusUpgr that a racing snoop turned into a BusRdX.
  function automatic void ref_note_upgr_killed();
    n_upgr_killed = n_upgr_killed + 1;
  endfunction

  // ---------------------------------------------------------------------
  // Observed memory-port write - the ONLY thing that moves pmem[].
  // ---------------------------------------------------------------------
  function automatic void ref_mem_write(input logic [AW-1:0] a, input logic [DW-1:0] d);
    pmem[a] = d;
  endfunction

  function automatic logic [DW-1:0] ref_mem_read(input logic [AW-1:0] a);
    ref_mem_read = pmem[a];
  endfunction

  // ---------------------------------------------------------------------
  // CPU access completion - the data-value invariant.
  // ---------------------------------------------------------------------
  //   pred_valid = 0 means a snoop landed on this address between the moment
  //   the access was launched and the moment it completed, so the hit/miss
  //   prediction is legitimately void.  Those are counted, not hidden.
  // ---------------------------------------------------------------------
  function automatic void ref_cpu_complete(input int c,
                                           input bit we,
                                           input logic [AW-1:0] a,
                                           input logic [DW-1:0] wdata,
                                           input logic [DW-1:0] rdata,
                                           input bit hit,
                                           input bit pred_valid,
                                           input bit pred_hit,
                                           input int bus_txns);
    int s;
    logic [1:0] cur;
    s   = idx_of(a);
    cur = ref_state(c, a);
    n_check = n_check + 1;

    // ---- 1. hit means "no bus transaction", exactly ----
    if (hit != (bus_txns == 0))
      ref_err($sformatf("core%0d %s addr %0d: cpu_hit=%0b but %0d bus transaction(s) were issued",
                        c, we ? "WR" : "RD", a, hit, bus_txns));

    // ---- 2. hit/miss must match what the protocol says ----
    if (pred_valid) begin
      if (hit !== pred_hit)
        ref_err($sformatf("core%0d %s addr %0d: cpu_hit=%0b, model expected %0b (line was %s)",
                          c, we ? "WR" : "RD", a, hit, pred_hit, st_name(cur)));
    end else begin
      n_pred_skipped = n_pred_skipped + 1;
    end

    if (hit) n_hit = n_hit + 1; else n_miss = n_miss + 1;

    if (we) begin
      n_cpu_write = n_cpu_write + 1;

      // The silent E->M upgrade: a store landing on an exclusive-clean line
      // costs nothing.  Count it - if this never happens the run has not
      // actually verified the thing that separates MESI from MSI.
      if (pred_valid && (cur == ST_E) && hit && (bus_txns == 0))
        n_e_silent = n_e_silent + 1;

      // the cache must now own it dirty
      if (ref_state(c, a) == ST_I)
        ref_err($sformatf("core%0d WR addr %0d completed but the line is not resident", c, a));
      rs  [ix(c,s)] = ST_M;
      rt  [ix(c,s)] = tag_of(a);
      rdat[ix(c,s)] = wdata;

      arch[a] = wdata;                      // <-- the store takes global effect here
    end else begin
      n_cpu_read = n_cpu_read + 1;
      // ---- 3. THE data-value invariant ----
      if (rdata !== arch[a])
        ref_err($sformatf("core%0d RD addr %0d returned 0x%08h, expected 0x%08h (line was %s)",
                          c, a, rdata, arch[a], st_name(cur)));
      if (ref_state(c, a) == ST_I)
        ref_err($sformatf("core%0d RD addr %0d completed but the line is not resident", c, a));
    end
  endfunction

  // ---------------------------------------------------------------------
  // Pull one core's view of one address straight out of the DUT's arrays.
  // ---------------------------------------------------------------------
  function automatic logic [1:0] dut_state_at(input logic [NCORE*2*NSET-1:0]  dstate,
                                              input logic [NCORE*AW*NSET-1:0] dtag,
                                              input int c,
                                              input logic [AW-1:0] a);
    int s;
    logic [1:0]      ds;
    logic [TAGW-1:0] dt;
    s  = idx_of(a);
    ds = dstate[(c*NSET + s)*2  +: 2   ];
    dt = dtag  [(c*NSET + s)*AW +: TAGW];
    dut_state_at = ((ds != ST_I) && (dt == tag_of(a))) ? ds : ST_I;
  endfunction

  // ---------------------------------------------------------------------
  // THE SAFETY PROPERTY, checked EVERY CYCLE straight off the DUT.
  //
  // Deliberately model-free.  The model updates its architectural view when
  // an access COMPLETES (cpu_ack), but the RTL updates its tag/state arrays
  // one to two cycles earlier, in the lookup or fill cycle.  Comparing the
  // two every cycle would be comparing across that skew and would flag legal
  // behaviour.  Everything below is a structural property of the DUT's own
  // arrays at a single instant, so it holds on every edge with no skew to
  // reason about - and it is the property whose violation IS the bug:
  //
  //   SWMR   an exclusive copy (M or E) must be the only copy in existence
  //   no-2M  a line can be dirty in at most one cache
  //   agree  every core holding a line in S must hold the same bytes
  // ---------------------------------------------------------------------
  function automatic void ref_check_swmr(input logic [NCORE*2*NSET-1:0]  dstate,
                                         input logic [NCORE*AW*NSET-1:0] dtag,
                                         input logic [NCORE*DW*NSET-1:0] ddata);
    int c, c2, s;
    int n_excl, n_valid, n_dirty;
    logic [AW-1:0] a;
    logic [1:0]    sc, sc2;
    logic [DW-1:0] v, v2;
    bit            have_v;

    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        if (dstate[(c*NSET+s)*2 +: 2] == ST_I) continue;
        a = addr_of(dtag[(c*NSET+s)*AW +: TAGW], s);

        n_excl = 0; n_valid = 0; n_dirty = 0;
        have_v = 1'b0; v = '0;
        for (c2 = 0; c2 < NCORE; c2 = c2 + 1) begin
          sc2 = dut_state_at(dstate, dtag, c2, a);
          if (sc2 != ST_I)                      n_valid = n_valid + 1;
          if ((sc2 == ST_M) || (sc2 == ST_E))   n_excl  = n_excl  + 1;
          if (sc2 == ST_M)                      n_dirty = n_dirty + 1;
          if (sc2 == ST_S) begin
            v2 = ddata[(c2*NSET + idx_of(a))*DW +: DW];
            if (!have_v) begin v = v2; have_v = 1'b1; end
            else if (v2 !== v)
              ref_err($sformatf("addr %0d is shared but sharers disagree: 0x%08h vs 0x%08h",
                                a, v, v2));
          end
        end

        if ((n_excl > 0) && (n_valid > 1))
          ref_err($sformatf("SWMR broken at addr %0d: an exclusive copy coexists with %0d valid copies",
                            a, n_valid));
        if (n_excl > 1)
          ref_err($sformatf("addr %0d held exclusively by %0d cores at once", a, n_excl));
        if (n_dirty > 1)
          ref_err($sformatf("addr %0d dirty in %0d caches at once", a, n_dirty));

        sc = dut_state_at(dstate, dtag, c, a);
        if (sc == ST_I)
          ref_err($sformatf("core%0d set%0d is valid but its own address %0d reads back as I", c, s, a));
      end
  endfunction

  // ---------------------------------------------------------------------
  // The full reconciliation, run at QUIESCE points - both cores idle, the
  // bus idle, nothing in flight.  With no access in progress the model and
  // the DUT are describing the same instant, so everything can be compared:
  // state, tags, cached data, physical memory, and the architectural value.
  // ---------------------------------------------------------------------
  function automatic void ref_check_full(input logic [NCORE*2*NSET-1:0]  dstate,
                                         input logic [NCORE*AW*NSET-1:0] dtag,
                                         input logic [NCORE*DW*NSET-1:0] ddata);
    int c, c2, s, a;
    int n_dirty;
    logic [1:0]      ds, ms;
    logic [TAGW-1:0] dt;
    logic [DW-1:0]   dv;
    logic [AW-1:0]   la;

    // ---- 1. the DUT's arrays must equal the model's prediction ----
    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        ds = dstate[(c*NSET+s)*2  +: 2   ];
        dt = dtag  [(c*NSET+s)*AW +: TAGW];
        dv = ddata [(c*NSET+s)*DW +: DW  ];
        ms = rs[ix(c,s)];
        if (ds !== ms)
          ref_err($sformatf("core%0d set%0d: DUT state %s, model %s",
                            c, s, st_name(ds), st_name(ms)));
        else if (ds != ST_I) begin
          if (dt !== rt[ix(c,s)])
            ref_err($sformatf("core%0d set%0d: DUT tag 0x%0h, model 0x%0h", c, s, dt, rt[ix(c,s)]));
          else if (dv !== rdat[ix(c,s)])
            ref_err($sformatf("core%0d set%0d (addr %0d): DUT data 0x%08h, model 0x%08h",
                              c, s, addr_of(dt, s), dv, rdat[ix(c,s)]));
        end
      end

    // ---- 2. a clean copy must match memory and the architectural value ----
    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        ds = dstate[(c*NSET+s)*2  +: 2   ];
        if ((ds != ST_S) && (ds != ST_E)) continue;
        dt = dtag [(c*NSET+s)*AW +: TAGW];
        dv = ddata[(c*NSET+s)*DW +: DW  ];
        la = addr_of(dt, s);
        if (dv !== pmem[la])
          ref_err($sformatf("core%0d holds addr %0d in %s with 0x%08h but memory has 0x%08h",
                            c, la, st_name(ds), dv, pmem[la]));
        if (dv !== arch[la])
          ref_err($sformatf("core%0d holds a stale clean copy of addr %0d: 0x%08h vs architectural 0x%08h",
                            c, la, dv, arch[la]));
      end

    // ---- 3. the dirty owner is where the architectural value lives ----
    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        if (dstate[(c*NSET+s)*2 +: 2] != ST_M) continue;
        dt = dtag [(c*NSET+s)*AW +: TAGW];
        dv = ddata[(c*NSET+s)*DW +: DW  ];
        la = addr_of(dt, s);
        if (dv !== arch[la])
          ref_err($sformatf("core%0d owns addr %0d dirty with 0x%08h but the architectural value is 0x%08h",
                            c, la, dv, arch[la]));
      end

    // ---- 4. memory must be right for every address nobody owns dirty ----
    //
    // This is the check that catches a cache writing the correct data back to
    // the WRONG address: every load can keep returning perfect values while
    // DRAM quietly rots, and nothing on the response channel would notice.
    for (a = 0; a < NADDR; a = a + 1) begin
      n_dirty = 0;
      for (c2 = 0; c2 < NCORE; c2 = c2 + 1)
        if (dut_state_at(dstate, dtag, c2, a[AW-1:0]) == ST_M) n_dirty = n_dirty + 1;
      if ((n_dirty == 0) && (pmem[a[AW-1:0]] !== arch[a[AW-1:0]]))
        ref_err($sformatf("addr %0d is owned by nobody but memory has 0x%08h, architectural 0x%08h",
                          a, pmem[a[AW-1:0]], arch[a[AW-1:0]]));
    end
  endfunction

  // ---------------------------------------------------------------------
  // Model-only invariant check, used by ref_selfcheck before any DUT exists.
  // ---------------------------------------------------------------------
  function automatic void ref_check_invariants();
    int c, c2, s;
    int n_excl, n_valid, n_dirty;
    logic [AW-1:0] a;
    logic [1:0] sc;

    for (c = 0; c < NCORE; c = c + 1)
      for (s = 0; s < NSET; s = s + 1) begin
        if (rs[ix(c,s)] == ST_I) continue;
        a = addr_of(rt[ix(c,s)], s);

        // -- count how many cores hold this exact address, and how --
        n_excl = 0; n_valid = 0; n_dirty = 0;
        for (c2 = 0; c2 < NCORE; c2 = c2 + 1) begin
          sc = ref_state(c2, a);
          if (sc != ST_I)                     n_valid = n_valid + 1;
          if ((sc == ST_M) || (sc == ST_E))   n_excl  = n_excl  + 1;
          if (sc == ST_M)                     n_dirty = n_dirty + 1;
        end

        // SWMR: an exclusive copy must be the ONLY copy
        if ((n_excl > 0) && (n_valid > 1))
          ref_err($sformatf("SWMR broken at addr %0d: %0d exclusive copies among %0d valid copies",
                            a, n_excl, n_valid));
        if (n_excl > 1)
          ref_err($sformatf("addr %0d held exclusively by %0d cores at once", a, n_excl));
        if (n_dirty > 1)
          ref_err($sformatf("addr %0d dirty in %0d caches at once", a, n_dirty));

        // Sharers must agree with each other and with memory: an S or E copy
        // is clean by definition, so it has to equal what DRAM holds.
        sc = ref_state(c, a);
        if ((sc == ST_S) || (sc == ST_E)) begin
          if (rdat[ix(c,s)] !== pmem[a])
            ref_err($sformatf("core%0d holds addr %0d in %s with 0x%08h but memory has 0x%08h",
                              c, a, st_name(sc), rdat[ix(c,s)], pmem[a]));
          if (rdat[ix(c,s)] !== arch[a])
            ref_err($sformatf("core%0d holds a stale clean copy of addr %0d: 0x%08h vs architectural 0x%08h",
                              c, a, rdat[ix(c,s)], arch[a]));
        end

        // The dirty owner is the one place the architectural value lives.
        if (sc == ST_M) begin
          if (rdat[ix(c,s)] !== arch[a])
            ref_err($sformatf("core%0d owns addr %0d dirty with 0x%08h but architectural value is 0x%08h",
                              c, a, rdat[ix(c,s)], arch[a]));
        end
      end

    // Memory must be correct for every address NOT dirty in some cache.  This
    // is the check that catches a writeback to the wrong address: the load
    // path can look perfect while DRAM quietly rots.
    for (c = 0; c < NADDR; c = c + 1) begin
      n_dirty = 0;
      for (c2 = 0; c2 < NCORE; c2 = c2 + 1)
        if (ref_state(c2, c[AW-1:0]) == ST_M) n_dirty = n_dirty + 1;
      if ((n_dirty == 0) && (pmem[c[AW-1:0]] !== arch[c[AW-1:0]]))
        ref_err($sformatf("addr %0d is owned by nobody but memory has 0x%08h, architectural 0x%08h",
                          c, pmem[c[AW-1:0]], arch[c[AW-1:0]]));
    end
  endfunction

  // ---------------------------------------------------------------------
  // ref_selfcheck - re-prove the model's own rules INSIDE the simulator
  // before a single DUT result is judged.  A reference model for a protocol
  // is as easy to get subtly wrong as the RTL it is judging, so it walks the
  // canonical two-core coherence sequence and asserts every transition.
  // ---------------------------------------------------------------------
  function automatic int ref_selfcheck();
    int errs_before;
    bit sh;
    logic [AW-1:0] A, B;
    string save_ctx;

    save_ctx    = ctx;
    ctx         = "ref_selfcheck";
    errs_before = n_err;

    ref_init(32'hA5A5_0000);
    A = 8'h14;                     // set 0
    B = 8'h18;                     // set 0 too -> these two conflict

    // 1. cold read miss by core0, nobody else has it -> E (not S).  This is
    //    the transition MSI cannot make and the reason MESI exists.
    sh = ref_bus_addr_phase(0, BUSRD, A);
    if (sh !== 1'b0) ref_err("cold BusRd reported shared");
    ref_bus_complete(0, BUSRD, A, sh, pmem[A]);
    if (ref_state(0,A) != ST_E) ref_err("cold read miss did not install E");

    // 2. store to that E line is silent - no bus transaction at all
    ref_cpu_complete(0, 1'b1, A, 32'hDEAD_BEEF, '0, 1'b1, 1'b1, 1'b1, 0);
    if (ref_state(0,A) != ST_M) ref_err("silent E->M upgrade did not reach M");
    if (arch[A] !== 32'hDEAD_BEEF) ref_err("store did not take architectural effect");
    if (pmem[A] === 32'hDEAD_BEEF) ref_err("a write-back cache must NOT have updated memory yet");

    // 3. core1 reads it: the dirty owner flushes, both end in S, memory is
    //    brought up to date by the flush.
    if (!ref_pred_dirty(1, BUSRD, A)) ref_err("owner did not offer a flush");
    if (ref_flush_data(1, A) !== 32'hDEAD_BEEF) ref_err("flush carried the wrong data");
    sh = ref_bus_addr_phase(1, BUSRD, A);
    if (sh !== 1'b1) ref_err("BusRd against an owner did not report shared");
    ref_mem_write(A, 32'hDEAD_BEEF);              // the flush updates memory
    ref_bus_complete(1, BUSRD, A, sh, 32'hDEAD_BEEF);
    if (ref_state(0,A) != ST_S) ref_err("owner did not downgrade M->S");
    if (ref_state(1,A) != ST_S) ref_err("sharing read did not install S");
    ref_check_invariants();

    // 4. core1 stores: BusUpgr invalidates core0, no data moves.
    sh = ref_bus_addr_phase(1, BUSUPGR, A);
    ref_bus_complete(1, BUSUPGR, A, sh, '0);
    ref_cpu_complete(1, 1'b1, A, 32'h0BAD_F00D, '0, 1'b0, 1'b1, 1'b0, 1);
    if (ref_state(0,A) != ST_I) ref_err("BusUpgr did not invalidate the other sharer");
    if (ref_state(1,A) != ST_M) ref_err("BusUpgr did not reach M");
    ref_check_invariants();

    // 5. core0 stores: BusRdX takes the line away from core1 with a flush.
    if (!ref_pred_dirty(0, BUSRDX, A)) ref_err("BusRdX did not pull a flush from the owner");
    sh = ref_bus_addr_phase(0, BUSRDX, A);
    ref_mem_write(A, 32'h0BAD_F00D);
    ref_bus_complete(0, BUSRDX, A, sh, 32'h0BAD_F00D);
    ref_cpu_complete(0, 1'b1, A, 32'h1234_5678, '0, 1'b0, 1'b1, 1'b0, 1);
    if (ref_state(1,A) != ST_I) ref_err("BusRdX left the old owner valid");
    if (ref_state(0,A) != ST_M) ref_err("BusRdX did not reach M");
    ref_check_invariants();

    // 6. conflicting address in the same set forces a dirty eviction: the
    //    victim must be written back to ITS OWN address, not the new one.
    sh = ref_bus_addr_phase(0, BUSWB, A);
    ref_mem_write(A, 32'h1234_5678);
    ref_bus_complete(0, BUSWB, A, 1'b0, '0);
    if (ref_state(0,A) != ST_I) ref_err("writeback did not drop the victim");
    if (pmem[A] !== arch[A])    ref_err("writeback left memory stale");
    sh = ref_bus_addr_phase(0, BUSRD, B);
    ref_bus_complete(0, BUSRD, B, sh, pmem[B]);
    if (ref_state(0,B) != ST_E) ref_err("post-eviction refill did not install E");
    ref_check_invariants();

    // 7. reset discards dirty data - the architectural view rolls BACK.
    ref_cpu_complete(0, 1'b1, B, 32'hFFFF_0001, '0, 1'b1, 1'b1, 1'b1, 0);
    if (arch[B] !== 32'hFFFF_0001) ref_err("pre-reset store did not register");
    ref_hw_reset();
    if (arch[B] === 32'hFFFF_0001)
      ref_err("reset did not discard the un-written-back store");
    if (ref_state(0,B) != ST_I) ref_err("reset left a line valid");
    ref_check_invariants();

    ref_selfcheck = n_err - errs_before;
    ctx = save_ctx;
  endfunction

endpackage
