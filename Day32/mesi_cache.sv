// =============================================================================
// Day32 - mesi_cache.sv
//
//   MESI snooping cache coherence.  Three synthesizable modules:
//
//     mesi_cache   one core's write-back / write-allocate L1 plus the MESI
//                  coherence FSM: a CPU port, a bus-master port, and a snoop
//                  port that watches every transaction the other caches issue.
//     mesi_bus     the shared snoop bus: round-robin arbiter, single global
//                  transaction at a time, wired-OR snoop combine, cache-to-
//                  cache flush of dirty data, and the memory port.
//     mesi_system  NCORE caches + the bus, with white-box state observability
//                  for the coherence checker.
//
//   Line = one DW-bit word, direct mapped, NSET sets.  Byte strobes and
//   multi-word line fills are deliberately out of scope (Day31 covered those)
//   so that everything here is about the coherence protocol.
//
//   BUS PROTOCOL (one transaction outstanding globally)
//     cycle T    ADDRESS phase - the granted master drives bus_valid / bus_cmd
//                / bus_addr / bus_master.  Every other cache decodes it
//                combinationally.
//     cycle T+1  SNOOP phase   - each snooper presents a registered answer
//                {snp_hit, snp_dirty, snp_data} describing the state the line
//                was in BEFORE the transaction, and applies its own state
//                transition at this edge.
//     cycle T+2+ DATA phase    - a dirty snooper's flush data goes to the
//                requester AND to memory; otherwise memory is read.  The
//                requester latches fill_data and fill_shared.
//
//   COMMANDS
//     BUSRD    read miss            -> requester gets E if nobody else has it,
//                                      S if somebody does (that is fill_shared)
//     BUSRDX   write miss (RFO)     -> requester gets M, everyone else I
//     BUSUPGR  write hit on S       -> invalidate the other sharers, no data
//     BUSWB    dirty victim eviction-> memory write, no state change elsewhere
//
//   The one property that makes this MESI and not MSI: a read miss that no
//   other cache answers installs the line in E, and a later store to an E line
//   completes with NO bus transaction at all (the silent E->M upgrade).
// =============================================================================
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// mesi_cache - one core's coherent L1.
// -----------------------------------------------------------------------------
module mesi_cache #(
  parameter int DW      = 32,   // data word width
  parameter int AW      = 8,    // word address width
  parameter int NSET     = 4,   // direct-mapped lines (power of two)
  parameter int NCORE   = 2,    // cores on the bus
  parameter int CORE_ID = 0     // this cache's id
)(
  input  logic                            clk,
  input  logic                            rst_n,

  // ---- CPU side --------------------------------------------------------
  input  logic                            cpu_req,
  input  logic                            cpu_we,
  input  logic [AW-1:0]                   cpu_addr,
  input  logic [DW-1:0]                   cpu_wdata,
  output logic                            cpu_ack,    // 1-cycle completion pulse
  output logic [DW-1:0]                   cpu_rdata,
  output logic                            cpu_hit,    // served with no bus traffic
  output logic                            cpu_busy,

  // ---- bus master request ---------------------------------------------
  output logic                            bus_req,
  input  logic                            bus_gnt,
  output logic [1:0]                      m_cmd,
  output logic [AW-1:0]                   m_addr,
  output logic [DW-1:0]                   m_wdata,

  // ---- shared bus address phase (everyone watches this) ----------------
  input  logic                            bus_valid,
  input  logic [1:0]                      bus_cmd,
  input  logic [AW-1:0]                   bus_addr,
  input  logic [$clog2(NCORE)-1:0]        bus_master,

  // ---- this cache's snoop answer, one cycle after the address phase -----
  output logic                            snp_hit,
  output logic                            snp_dirty,
  output logic [DW-1:0]                   snp_data,

  // ---- completion of my own outstanding transaction --------------------
  input  logic                            fill_valid,
  input  logic                            fill_shared,
  input  logic [DW-1:0]                   fill_data,

  // ---- white-box observability for the coherence checker ---------------
  output logic [2*NSET-1:0]               dbg_state,
  output logic [AW*NSET-1:0]              dbg_tag,
  output logic [DW*NSET-1:0]              dbg_data
);

  localparam int IDXW = $clog2(NSET);
  localparam int TAGW = AW - IDXW;
  localparam int MW   = $clog2(NCORE);

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

  // controller FSM
  localparam logic [2:0] C_IDLE   = 3'd0;
  localparam logic [2:0] C_LOOKUP = 3'd1;
  localparam logic [2:0] C_REQ    = 3'd2;
  localparam logic [2:0] C_WAIT   = 3'd3;

  // ---- tag / state / data arrays ---------------------------------------
  logic [1:0]      state_q [NSET];
  logic [TAGW-1:0] tag_q   [NSET];
  logic [DW-1:0]   data_q  [NSET];

  // ---- latched CPU request ---------------------------------------------
  logic            req_we;
  logic [AW-1:0]   req_addr;
  logic [DW-1:0]   req_wdata;

  // ---- pending bus transaction -----------------------------------------
  logic [1:0]      pend_cmd;
  logic [AW-1:0]   pend_addr;
  logic [DW-1:0]   pend_wdata;

  logic [2:0]      st;

  // ---------------------------------------------------------------------
  // Combinational snoop decode of the address phase currently on the bus.
  //
  // This has to be visible to the CPU-side FSM in the SAME cycle: if a snoop
  // is about to invalidate the very line the CPU is looking up, the lookup
  // must see the post-snoop state or it will decide "hit" on a line that no
  // longer belongs to this cache.  eff_state below is that reconciled view.
  // ---------------------------------------------------------------------
  wire [IDXW-1:0] snp_idx = bus_addr[IDXW-1:0];
  wire [TAGW-1:0] snp_tg  = bus_addr[AW-1:IDXW];

  wire snoop_active = bus_valid && (bus_master != CORE_ID[MW-1:0]) && (bus_cmd != BUSWB);
  wire snoop_match  = snoop_active && (state_q[snp_idx] != ST_I) && (tag_q[snp_idx] == snp_tg);

  logic [1:0] snoop_ns;
  always_comb begin
    snoop_ns = state_q[snp_idx];
    if (snoop_match) begin
      case (bus_cmd)
        BUSRD  : snoop_ns = ST_S;   // downgrade, keep a shared copy
        BUSRDX : snoop_ns = ST_I;   // somebody wants it for writing
        BUSUPGR: snoop_ns = ST_I;   // a sharer is upgrading to M
        default: snoop_ns = state_q[snp_idx];
      endcase
    end
  end

  // ---- the access currently being processed ----------------------------
  wire [IDXW-1:0] acc_idx = req_addr[IDXW-1:0];
  wire [TAGW-1:0] acc_tag = req_addr[AW-1:IDXW];

  // state of the accessed line reconciled with a same-cycle snoop
  wire [1:0] acc_state = (snoop_match && (snp_idx == acc_idx)) ? snoop_ns : state_q[acc_idx];
  wire       acc_hit   = (acc_state != ST_I) && (tag_q[acc_idx] == acc_tag);

  // a snoop that kills the line this cache is queued up to upgrade
  wire upgr_killed = (pend_cmd == BUSUPGR) && snoop_match &&
                     (snp_idx == acc_idx) && (snoop_ns == ST_I) &&
                     (tag_q[acc_idx] == acc_tag);

  // ---- bus master drive -------------------------------------------------
  assign bus_req = (st == C_REQ);
  assign m_cmd   = pend_cmd;
  assign m_addr  = pend_addr;
  assign m_wdata = pend_wdata;

  // ---------------------------------------------------------------------
  // Completion.
  //
  // cpu_ack is asserted DURING the cycle whose edge commits the access, not
  // a cycle later.  That is not cosmetic: it is what lets a checker line up
  // with the RTL when a snoop lands on the very access being completed.  With
  // a separate response state the cache would update its tag array on one
  // edge and announce it on a later one, and any model driven off the
  // announcement would apply a racing invalidation to the wrong version of
  // the line.  Here the announcement and the commit are the same edge.
  // ---------------------------------------------------------------------
  wire acc_writeable = (acc_state == ST_M) || (acc_state == ST_E);
  wire lookup_done   = (st == C_LOOKUP) && acc_hit && (!req_we || acc_writeable);
  wire wait_done     = (st == C_WAIT)   && fill_valid && (pend_cmd != BUSWB);

  assign cpu_busy  = (st != C_IDLE);
  assign cpu_ack   = lookup_done || wait_done;
  assign cpu_hit   = lookup_done;   // a hit is exactly "served without the bus"
  assign cpu_rdata = req_we ? req_wdata
                            : ((st == C_LOOKUP) ? data_q[acc_idx] : fill_data);

  integer i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < NSET; i = i + 1) begin
        state_q[i] <= ST_I;
        tag_q[i]   <= '0;
        data_q[i]  <= '0;
      end
      st         <= C_IDLE;
      req_we     <= 1'b0;
      req_addr   <= '0;
      req_wdata  <= '0;
      pend_cmd   <= BUSRD;
      pend_addr  <= '0;
      pend_wdata <= '0;
      snp_hit    <= 1'b0;
      snp_dirty  <= 1'b0;
      snp_data   <= '0;
    end else begin
      // ---- snoop response + snoop state transition ---------------------
      // The answer describes the line as it stood BEFORE the transition, which
      // is what a flush has to carry.
      snp_hit   <= snoop_match;
      snp_dirty <= snoop_match && (state_q[snp_idx] == ST_M) &&
                   ((bus_cmd == BUSRD) || (bus_cmd == BUSRDX));
      snp_data  <= data_q[snp_idx];

      if (snoop_match)
        state_q[snp_idx] <= snoop_ns;

      // ---- CPU-side controller -----------------------------------------
      case (st)
        C_IDLE: begin
          if (cpu_req) begin
            req_we    <= cpu_we;
            req_addr  <= cpu_addr;
            req_wdata <= cpu_wdata;
            st        <= C_LOOKUP;
          end
        end

        C_LOOKUP: begin
          if (acc_hit) begin
            if (!req_we) begin
              // read hit in S / E / M - no bus traffic
              st <= C_IDLE;
            end else if (acc_writeable) begin
              // write hit on an exclusive line.  E->M is SILENT: this is the
              // whole reason MESI exists, and it costs zero bus transactions.
              data_q[acc_idx]  <= req_wdata;
              state_q[acc_idx] <= ST_M;
              st               <= C_IDLE;
            end else begin
              // write hit on S - other sharers must be invalidated first
              pend_cmd  <= BUSUPGR;
              pend_addr <= req_addr;
              st        <= C_REQ;
            end
          end else begin
            // miss.  acc_state==M here means the RESIDENT line (different tag)
            // is dirty and has to be written back to ITS OWN address first.
            if (acc_state == ST_M) begin
              pend_cmd   <= BUSWB;
              pend_addr  <= {tag_q[acc_idx], acc_idx};
              pend_wdata <= data_q[acc_idx];
            end else begin
              pend_cmd  <= req_we ? BUSRDX : BUSRD;
              pend_addr <= req_addr;
            end
            st <= C_REQ;
          end
        end

        C_REQ: begin
          // A sharer that gets invalidated while queued for BUSUPGR no longer
          // owns a copy, so an upgrade would be a lie - it must fetch the line
          // with a full read-for-ownership instead.
          if (upgr_killed)
            pend_cmd <= BUSRDX;

          if (bus_gnt)
            st <= C_WAIT;
        end

        C_WAIT: begin
          if (fill_valid) begin
            if (pend_cmd == BUSWB) begin
              // victim is now clean in memory; drop it and issue the real access
              state_q[pend_addr[IDXW-1:0]] <= ST_I;
              pend_cmd  <= req_we ? BUSRDX : BUSRD;
              pend_addr <= req_addr;
              st        <= C_REQ;
            end else if (pend_cmd == BUSUPGR) begin
              state_q[acc_idx] <= ST_M;
              data_q[acc_idx]  <= req_wdata;
              st               <= C_IDLE;
            end else begin
              tag_q[acc_idx] <= acc_tag;
              if (req_we) begin
                // BUSRDX: fill then merge the store
                state_q[acc_idx] <= ST_M;
                data_q[acc_idx]  <= req_wdata;
              end else begin
                // BUSRD: E when nobody answered, S when somebody did
                state_q[acc_idx] <= fill_shared ? ST_S : ST_E;
                data_q[acc_idx]  <= fill_data;
              end
              st <= C_IDLE;
            end
          end
        end

        default: st <= C_IDLE;
      endcase
    end
  end

  // ---- flattened white-box view ----------------------------------------
  genvar g;
  generate
    for (g = 0; g < NSET; g = g + 1) begin : g_dbg
      assign dbg_state[2*g +: 2]  = state_q[g];
      assign dbg_tag  [AW*g +: AW] = {{(AW-TAGW){1'b0}}, tag_q[g]};
      assign dbg_data [DW*g +: DW] = data_q[g];
    end
  endgenerate

`ifdef MESI_SVA
  // A grant must never land in the same cycle a snoop rewrites the pending
  // line - if it did, the fabric would latch a command the cache has already
  // decided is wrong.  The bus arbitrates one transaction at a time, so this
  // is structurally impossible; assert it rather than assume it.
  property p_no_gnt_during_kill;
    @(posedge clk) disable iff (!rst_n) !(bus_gnt && upgr_killed);
  endproperty
  a_no_gnt_during_kill: assert property (p_no_gnt_during_kill)
    else $error("[mesi_cache %0d] grant collided with an upgrade-killing snoop", CORE_ID);

  // A cache never snoops its own transaction.
  property p_no_self_snoop;
    @(posedge clk) disable iff (!rst_n)
      (bus_valid && (bus_master == CORE_ID[MW-1:0])) |-> !snoop_match;
  endproperty
  a_no_self_snoop: assert property (p_no_self_snoop)
    else $error("[mesi_cache %0d] snooped its own transaction", CORE_ID);

  // BUSUPGR must never find this cache in M or E: the upgrader claimed to hold
  // a shared copy, so an exclusive copy elsewhere would break MESI outright.
  property p_upgr_never_exclusive;
    @(posedge clk) disable iff (!rst_n)
      (snoop_match && (bus_cmd == BUSUPGR)) |->
        ((state_q[snp_idx] != ST_M) && (state_q[snp_idx] != ST_E));
  endproperty
  a_upgr_never_exclusive: assert property (p_upgr_never_exclusive)
    else $error("[mesi_cache %0d] BUSUPGR snooped an exclusive copy", CORE_ID);

  // cpu_ack is a single-cycle pulse.
  property p_ack_pulse;
    @(posedge clk) disable iff (!rst_n) cpu_ack |=> !cpu_ack;
  endproperty
  a_ack_pulse: assert property (p_ack_pulse)
    else $error("[mesi_cache %0d] cpu_ack held for more than one cycle", CORE_ID);

  // A hit is by definition an access that used no bus transaction, so it can
  // only be reported straight out of the lookup.
  property p_hit_no_bus;
    @(posedge clk) disable iff (!rst_n) (cpu_ack && cpu_hit) |-> (st == C_LOOKUP);
  endproperty
  a_hit_no_bus: assert property (p_hit_no_bus)
    else $error("[mesi_cache %0d] reported a hit that went to the bus", CORE_ID);

  // No X on the response.
  property p_no_x;
    @(posedge clk) disable iff (!rst_n) cpu_ack |-> !$isunknown(cpu_rdata);
  endproperty
  a_no_x: assert property (p_no_x)
    else $error("[mesi_cache %0d] X on cpu_rdata", CORE_ID);
`endif

endmodule


// -----------------------------------------------------------------------------
// mesi_bus - shared snoop bus: arbiter, snoop combine, flush routing, memory
//            port.  One transaction outstanding globally.
// -----------------------------------------------------------------------------
module mesi_bus #(
  parameter int DW    = 32,
  parameter int AW    = 8,
  parameter int NCORE = 2
)(
  input  logic                        clk,
  input  logic                        rst_n,

  // ---- master requests (flattened; Icarus dislikes unpacked array ports)
  input  logic [NCORE-1:0]            bus_req,
  output logic [NCORE-1:0]            bus_gnt,
  input  logic [NCORE*2-1:0]          m_cmd_f,
  input  logic [NCORE*AW-1:0]         m_addr_f,
  input  logic [NCORE*DW-1:0]         m_wdata_f,

  // ---- broadcast address phase ----------------------------------------
  output logic                        bus_valid,
  output logic [1:0]                  bus_cmd,
  output logic [AW-1:0]               bus_addr,
  output logic [$clog2(NCORE)-1:0]    bus_master,

  // ---- snoop answers ----------------------------------------------------
  input  logic [NCORE-1:0]            snp_hit,
  input  logic [NCORE-1:0]            snp_dirty,
  input  logic [NCORE*DW-1:0]         snp_data_f,

  // ---- completion to the requesting master -----------------------------
  output logic [NCORE-1:0]            fill_valid,
  output logic                        fill_shared,
  output logic [DW-1:0]               fill_data,

  // ---- backing memory ---------------------------------------------------
  output logic                        mem_req,
  output logic                        mem_we,
  output logic [AW-1:0]               mem_addr,
  output logic [DW-1:0]               mem_wdata,
  input  logic                        mem_gnt,
  input  logic                        mem_rvalid,
  input  logic [DW-1:0]               mem_rdata,

  // ---- observability ----------------------------------------------------
  output logic                        bus_c2c,   // served cache-to-cache, not
                                                 // by memory
  output logic                        bus_busy   // a transaction is in flight
);

  localparam int MW = $clog2(NCORE);

  localparam logic [1:0] BUSRD   = 2'd0;
  localparam logic [1:0] BUSRDX  = 2'd1;
  localparam logic [1:0] BUSUPGR = 2'd2;
  localparam logic [1:0] BUSWB   = 2'd3;

  localparam logic [2:0] B_IDLE  = 3'd0;
  localparam logic [2:0] B_SNOOP = 3'd1;
  localparam logic [2:0] B_MEMW  = 3'd2;  // writeback or flush update
  localparam logic [2:0] B_MEMR  = 3'd3;  // read request out
  localparam logic [2:0] B_MEMD  = 3'd4;  // waiting for read data
  localparam logic [2:0] B_DONE  = 3'd5;

  logic [2:0]      bst;
  logic [MW-1:0]   master_q;
  logic [1:0]      cmd_q;
  logic [AW-1:0]   addr_q;
  logic [DW-1:0]   wdata_q;   // BUSWB payload, or the flushed line
  logic [DW-1:0]   data_q;    // data returned to the requester
  logic            shared_q;
  logic            c2c_q;
  logic [MW-1:0]   rr_ptr;

  // ---- round-robin winner ----------------------------------------------
  logic          any_req;
  logic [MW-1:0] winner;
  integer        k;
  logic [MW-1:0] cand;
  always_comb begin
    any_req = |bus_req;
    winner  = rr_ptr;
    for (k = NCORE-1; k >= 0; k = k - 1) begin
      cand = rr_ptr + k[MW-1:0];
      if (bus_req[cand]) winner = cand;
    end
  end

  // ---- address phase is combinational in B_IDLE ------------------------
  assign bus_valid  = (bst == B_IDLE) && any_req;
  assign bus_master = (bst == B_IDLE) ? winner : master_q;
  assign bus_cmd    = (bst == B_IDLE) ? m_cmd_f [winner*2  +: 2 ] : cmd_q;
  assign bus_addr   = (bst == B_IDLE) ? m_addr_f[winner*AW +: AW] : addr_q;

  // Grant is held for the whole transaction so nobody else can interleave.
  always_comb begin
    bus_gnt = '0;
    if (bst == B_IDLE) bus_gnt[winner]   = any_req;
    else               bus_gnt[master_q] = 1'b1;
  end

  always_comb begin
    fill_valid = '0;
    if (bst == B_DONE) fill_valid[master_q] = 1'b1;
  end
  assign fill_shared = shared_q;
  assign fill_data   = data_q;
  assign bus_c2c     = c2c_q;
  assign bus_busy    = (bst != B_IDLE);

  // ---- memory port ------------------------------------------------------
  always_comb begin
    mem_req   = 1'b0;
    mem_we    = 1'b0;
    mem_addr  = addr_q;
    mem_wdata = wdata_q;
    case (bst)
      B_MEMW: begin mem_req = 1'b1; mem_we = 1'b1; end
      B_MEMR: begin mem_req = 1'b1; mem_we = 1'b0; end
      default: ;
    endcase
  end

  // ---- snoop combine ----------------------------------------------------
  logic [NCORE-1:0] other_mask;
  logic             any_hit, any_dirty;
  logic [DW-1:0]    flush_data;
  integer           j;
  always_comb begin
    other_mask = {NCORE{1'b1}};
    other_mask[master_q] = 1'b0;
    any_hit    = |(snp_hit   & other_mask);
    any_dirty  = |(snp_dirty & other_mask);
    flush_data = '0;
    for (j = 0; j < NCORE; j = j + 1)
      if (snp_dirty[j] && other_mask[j]) flush_data = snp_data_f[j*DW +: DW];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst      <= B_IDLE;
      master_q <= '0;
      cmd_q    <= BUSRD;
      addr_q   <= '0;
      wdata_q  <= '0;
      data_q   <= '0;
      shared_q <= 1'b0;
      c2c_q    <= 1'b0;
      rr_ptr   <= '0;
    end else begin
      case (bst)
        B_IDLE: begin
          if (any_req) begin
            master_q <= winner;
            cmd_q    <= m_cmd_f  [winner*2  +: 2 ];
            addr_q   <= m_addr_f [winner*AW +: AW];
            wdata_q  <= m_wdata_f[winner*DW +: DW];
            shared_q <= 1'b0;
            c2c_q    <= 1'b0;
            bst      <= B_SNOOP;
          end
        end

        B_SNOOP: begin
          shared_q <= any_hit;
          if (cmd_q == BUSUPGR) begin
            // no data moves; the invalidations have already happened this edge
            bst <= B_DONE;
          end else if (cmd_q == BUSWB) begin
            bst <= B_MEMW;
          end else if (any_dirty) begin
            // cache-to-cache: the owner's copy goes to the requester and to
            // memory in one move, so no cache is left holding the only copy.
            data_q  <= flush_data;
            wdata_q <= flush_data;
            c2c_q   <= 1'b1;
            bst     <= B_MEMW;
          end else begin
            bst <= B_MEMR;
          end
        end

        B_MEMW: if (mem_gnt) bst <= B_DONE;

        B_MEMR: if (mem_gnt) bst <= B_MEMD;

        B_MEMD: if (mem_rvalid) begin
          data_q <= mem_rdata;
          bst    <= B_DONE;
        end

        B_DONE: begin
          rr_ptr <= master_q + 1'b1;
          bst    <= B_IDLE;
        end

        default: bst <= B_IDLE;
      endcase
    end
  end

`ifdef MESI_SVA
  // At most one cache can ever be dirty for a line - that IS the M state.
  property p_single_owner;
    @(posedge clk) disable iff (!rst_n) $countones(snp_dirty) <= 1;
  endproperty
  a_single_owner: assert property (p_single_owner)
    else $error("[mesi_bus] two caches claimed a dirty copy of the same line");

  // The address phase lasts exactly one cycle per transaction.
  property p_addr_phase_pulse;
    @(posedge clk) disable iff (!rst_n) bus_valid |=> !bus_valid;
  endproperty
  a_addr_phase_pulse: assert property (p_addr_phase_pulse)
    else $error("[mesi_bus] address phase longer than one cycle");

  // A completion always goes to exactly one master.
  property p_one_fill;
    @(posedge clk) disable iff (!rst_n) (|fill_valid) |-> ($countones(fill_valid) == 1);
  endproperty
  a_one_fill: assert property (p_one_fill)
    else $error("[mesi_bus] more than one master completed at once");

  // A cache-to-cache transfer must always update memory too (no Owned state).
  property p_c2c_writes_memory;
    @(posedge clk) disable iff (!rst_n)
      ((bst == B_SNOOP) && (cmd_q != BUSUPGR) && (cmd_q != BUSWB) && any_dirty) |=> (bst == B_MEMW);
  endproperty
  a_c2c_writes_memory: assert property (p_c2c_writes_memory)
    else $error("[mesi_bus] a flush skipped its memory update");
`endif

endmodule


// -----------------------------------------------------------------------------
// mesi_system - NCORE coherent caches on one snoop bus.
// -----------------------------------------------------------------------------
module mesi_system #(
  parameter int DW    = 32,
  parameter int AW    = 8,
  parameter int NSET  = 4,
  parameter int NCORE = 2
)(
  input  logic                        clk,
  input  logic                        rst_n,

  // ---- per-core CPU ports (flattened) ----------------------------------
  input  logic [NCORE-1:0]            cpu_req,
  input  logic [NCORE-1:0]            cpu_we,
  input  logic [NCORE*AW-1:0]         cpu_addr_f,
  input  logic [NCORE*DW-1:0]         cpu_wdata_f,
  output logic [NCORE-1:0]            cpu_ack,
  output logic [NCORE*DW-1:0]         cpu_rdata_f,
  output logic [NCORE-1:0]            cpu_hit,
  output logic [NCORE-1:0]            cpu_busy,

  // ---- backing memory ---------------------------------------------------
  output logic                        mem_req,
  output logic                        mem_we,
  output logic [AW-1:0]               mem_addr,
  output logic [DW-1:0]               mem_wdata,
  input  logic                        mem_gnt,
  input  logic                        mem_rvalid,
  input  logic [DW-1:0]               mem_rdata,

  // ---- bus observability for the monitor / checker ---------------------
  output logic                        bus_valid,
  output logic [1:0]                  bus_cmd,
  output logic [AW-1:0]               bus_addr,
  output logic [$clog2(NCORE)-1:0]    bus_master,
  output logic                        bus_fill,
  output logic                        bus_fill_shared,
  output logic [DW-1:0]               bus_fill_data,
  output logic                        bus_c2c,
  output logic                        bus_busy,

  // ---- white-box coherence state ---------------------------------------
  output logic [NCORE*2*NSET-1:0]     dbg_state_f,
  output logic [NCORE*AW*NSET-1:0]    dbg_tag_f,
  output logic [NCORE*DW*NSET-1:0]    dbg_data_f
);

  logic [NCORE-1:0]    bus_req_w, bus_gnt_w;
  logic [NCORE*2-1:0]  m_cmd_w;
  logic [NCORE*AW-1:0] m_addr_w;
  logic [NCORE*DW-1:0] m_wdata_w;
  logic [NCORE-1:0]    snp_hit_w, snp_dirty_w;
  logic [NCORE*DW-1:0] snp_data_w;
  logic [NCORE-1:0]    fill_valid_w;
  logic                fill_shared_w;
  logic [DW-1:0]       fill_data_w;

  genvar c;
  generate
    for (c = 0; c < NCORE; c = c + 1) begin : g_core
      mesi_cache #(
        .DW(DW), .AW(AW), .NSET(NSET), .NCORE(NCORE), .CORE_ID(c)
      ) u_cache (
        .clk        (clk),
        .rst_n      (rst_n),
        .cpu_req    (cpu_req[c]),
        .cpu_we     (cpu_we[c]),
        .cpu_addr   (cpu_addr_f [c*AW +: AW]),
        .cpu_wdata  (cpu_wdata_f[c*DW +: DW]),
        .cpu_ack    (cpu_ack[c]),
        .cpu_rdata  (cpu_rdata_f[c*DW +: DW]),
        .cpu_hit    (cpu_hit[c]),
        .cpu_busy   (cpu_busy[c]),
        .bus_req    (bus_req_w[c]),
        .bus_gnt    (bus_gnt_w[c]),
        .m_cmd      (m_cmd_w  [c*2  +: 2 ]),
        .m_addr     (m_addr_w [c*AW +: AW]),
        .m_wdata    (m_wdata_w[c*DW +: DW]),
        .bus_valid  (bus_valid),
        .bus_cmd    (bus_cmd),
        .bus_addr   (bus_addr),
        .bus_master (bus_master),
        .snp_hit    (snp_hit_w[c]),
        .snp_dirty  (snp_dirty_w[c]),
        .snp_data   (snp_data_w[c*DW +: DW]),
        .fill_valid (fill_valid_w[c]),
        .fill_shared(fill_shared_w),
        .fill_data  (fill_data_w),
        .dbg_state  (dbg_state_f[c*2*NSET  +: 2*NSET ]),
        .dbg_tag    (dbg_tag_f  [c*AW*NSET +: AW*NSET]),
        .dbg_data   (dbg_data_f [c*DW*NSET +: DW*NSET])
      );
    end
  endgenerate

  mesi_bus #(.DW(DW), .AW(AW), .NCORE(NCORE)) u_bus (
    .clk        (clk),
    .rst_n      (rst_n),
    .bus_req    (bus_req_w),
    .bus_gnt    (bus_gnt_w),
    .m_cmd_f    (m_cmd_w),
    .m_addr_f   (m_addr_w),
    .m_wdata_f  (m_wdata_w),
    .bus_valid  (bus_valid),
    .bus_cmd    (bus_cmd),
    .bus_addr   (bus_addr),
    .bus_master (bus_master),
    .snp_hit    (snp_hit_w),
    .snp_dirty  (snp_dirty_w),
    .snp_data_f (snp_data_w),
    .fill_valid (fill_valid_w),
    .fill_shared(fill_shared_w),
    .fill_data  (fill_data_w),
    .mem_req    (mem_req),
    .mem_we     (mem_we),
    .mem_addr   (mem_addr),
    .mem_wdata  (mem_wdata),
    .mem_gnt    (mem_gnt),
    .mem_rvalid (mem_rvalid),
    .mem_rdata  (mem_rdata),
    .bus_c2c    (bus_c2c),
    .bus_busy   (bus_busy)
  );

  assign bus_fill        = |fill_valid_w;
  assign bus_fill_shared = fill_shared_w;
  assign bus_fill_data   = fill_data_w;

endmodule
