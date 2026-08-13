// =============================================================================
// Day32 - mesi_cache_pkg.sv
//
//   The UVM environment for the MESI snooping coherence system.
//
//   THREE AGENTS, BECAUSE THERE ARE THREE REAL BOUNDARIES
//     mesi_cpu_agent  x2   one per core.  Two ACTIVE agents driving the same
//                          DUT concurrently is the entire point: coherence
//                          bugs only exist between cores, and a single-agent
//                          environment cannot produce one.
//     mesi_mem_agent       its DRIVER is the backing memory (the slave side is
//                          not a passive wire), and its MONITOR is the
//                          scoreboard's only window onto what the caches
//                          actually pushed to DRAM.  The response policy is a
//                          SEQUENCE ITEM, not a config field, so a virtual
//                          sequence can run the directed scenarios against an
//                          instant memory - where a failure is unambiguously
//                          the cache - and then re-run the same design against
//                          70% stalls and 8-cycle reads.
//     mesi_bus_agent       passive.  Watches the snoop bus and the caches'
//                          tag/state arrays.
//
//   WHY THE SCOREBOARD IS CYCLE-BINNED
//   Four monitors publish into one scoreboard, and coherence checking is
//   order-sensitive: a snoop that lands in the same cycle as a completion has
//   to be applied first or the model diverges.  UVM does not order analysis
//   writes within a time step, so every event carries the cycle it was
//   observed in, and the scoreboard processes a cycle's events only once that
//   cycle is closed - in a fixed order: memory write, bus address phase, bus
//   completion, CPU completions, then the invariant checks.  That makes the
//   result independent of the order the monitors happened to run in.
//
//   Everything the scoreboard actually judges lives in mesi_ref_pkg.
// =============================================================================
`timescale 1ns/1ps

package mesi_cache_pkg;

  import uvm_pkg::*;
  import mesi_ref_pkg::*;
`include "uvm_macros.svh"

  // ---------------------------------------------------------------------
  // Transaction items
  // ---------------------------------------------------------------------

  typedef enum bit [1:0] { OP_RD, OP_WR } mesi_op_e;

  // ---- one CPU access ------------------------------------------------
  class mesi_cpu_txn extends uvm_sequence_item;
    rand mesi_op_e            op;
    rand logic [AW-1:0]       addr;
    rand logic [DW-1:0]       wdata;

    // filled in by the monitor
    int                       core_id;
    logic [DW-1:0]            rdata;
    bit                       hit;
    int unsigned              cycle;

    // filled in by the scoreboard: the MESI state this access FOUND the line
    // in.  Coverage needs it, and it has to be captured before the model
    // applies the access, so it cannot be recovered downstream.
    logic [1:0]               found_state;

    // Stimulus lives on a handful of addresses on purpose.  With three tags
    // per set in a four-set direct-mapped cache, conflict misses and
    // cross-core sharing are the common case rather than a rare corner.
    rand int unsigned         n_addrs;

    constraint c_addr    { addr < n_addrs; }
    constraint c_naddrs  { soft n_addrs == 12; }

    `uvm_object_utils_begin(mesi_cpu_txn)
      `uvm_field_enum(mesi_op_e, op, UVM_ALL_ON)
      `uvm_field_int(addr,    UVM_ALL_ON)
      `uvm_field_int(wdata,   UVM_ALL_ON | UVM_HEX)
      `uvm_field_int(rdata,   UVM_ALL_ON | UVM_HEX)
      `uvm_field_int(hit,     UVM_ALL_ON)
      `uvm_field_int(core_id, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "mesi_cpu_txn");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("core%0d %s addr=%0d wdata=0x%08h rdata=0x%08h hit=%0b",
                       core_id, (op == OP_WR) ? "WR" : "RD", addr, wdata, rdata, hit);
    endfunction
  endclass

  // ---- one bus event -------------------------------------------------
  typedef enum bit { PH_ADDR, PH_FILL } mesi_phase_e;

  class mesi_bus_txn extends uvm_sequence_item;
    mesi_phase_e      phase;
    int               master;
    logic [1:0]       cmd;
    logic [AW-1:0]    addr;
    bit               shared;      // FILL only
    bit               c2c;         // FILL only
    logic [DW-1:0]    data;        // FILL only
    int unsigned      cycle;

    `uvm_object_utils(mesi_bus_txn)
    function new(string name = "mesi_bus_txn");
      super.new(name);
    endfunction

    function string convert2string();
      if (phase == PH_ADDR)
        return $sformatf("ADDR %s addr=%0d by core%0d", cmd_name(cmd), addr, master);
      return $sformatf("FILL addr=%0d shared=%0b c2c=%0b data=0x%08h", addr, shared, c2c, data);
    endfunction
  endclass

  // ---- one observed memory access ------------------------------------
  class mesi_mem_txn extends uvm_sequence_item;
    bit            we;
    logic [AW-1:0] addr;
    logic [DW-1:0] wdata;
    int unsigned   cycle;

    `uvm_object_utils(mesi_mem_txn)
    function new(string name = "mesi_mem_txn");
      super.new(name);
    endfunction
  endclass

  // ---- a snapshot of both caches' coherence state ---------------------
  class mesi_state_txn extends uvm_sequence_item;
    logic [NCORE*2*NSET-1:0]  state_f;
    logic [NCORE*AW*NSET-1:0] tag_f;
    logic [NCORE*DW*NSET-1:0] data_f;
    bit                       quiet;   // nothing in flight anywhere
    int unsigned              cycle;

    `uvm_object_utils(mesi_state_txn)
    function new(string name = "mesi_state_txn");
      super.new(name);
    endfunction
  endclass

  // ---- the memory's response policy, as a sequence item ---------------
  //
  // Deliberately not a config field.  A regression that can only be run
  // against one memory behaviour is a regression that never finds the
  // fill/evict interaction bugs, and a policy that cannot be changed
  // mid-test forces two separate tests where one would do.
  class mesi_mem_policy extends uvm_sequence_item;
    rand int unsigned stall_pct;   // chance the memory refuses a request
    rand int unsigned read_lat;    // extra cycles before read data appears

    constraint c_sane { stall_pct <= 90; read_lat <= 12; }

    `uvm_object_utils_begin(mesi_mem_policy)
      `uvm_field_int(stall_pct, UVM_ALL_ON)
      `uvm_field_int(read_lat,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "mesi_mem_policy");
      super.new(name);
    endfunction
  endclass


  // =====================================================================
  // CPU agent
  // =====================================================================

  class mesi_cpu_cfg extends uvm_object;
    int core_id = 0;
    `uvm_object_utils(mesi_cpu_cfg)
    function new(string name = "mesi_cpu_cfg"); super.new(name); endfunction
  endclass

  typedef uvm_sequencer #(mesi_cpu_txn) mesi_cpu_sequencer;

  class mesi_cpu_driver extends uvm_driver #(mesi_cpu_txn);
    `uvm_component_utils(mesi_cpu_driver)

    virtual mesi_cpu_if vif;
    mesi_cpu_cfg        cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_cpu_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_cpu_if for the CPU driver")
      if (!uvm_config_db#(mesi_cpu_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "no mesi_cpu_cfg for the CPU driver")
    endfunction

    task run_phase(uvm_phase phase);
      vif.drv_cb.cpu_req   <= 1'b0;
      vif.drv_cb.cpu_we    <= 1'b0;
      vif.drv_cb.cpu_addr  <= '0;
      vif.drv_cb.cpu_wdata <= '0;
      @(posedge vif.rst_n);

      forever begin
        seq_item_port.get_next_item(req);
        drive(req);
        seq_item_port.item_done();
      end
    endtask

    task drive(mesi_cpu_txn t);
      // wait for the cache to be free, then hold the request steady until it
      // is taken - the DUT latches on the first idle edge
      while (vif.drv_cb.cpu_busy) @(vif.drv_cb);

      vif.drv_cb.cpu_req   <= 1'b1;
      vif.drv_cb.cpu_we    <= (t.op == OP_WR);
      vif.drv_cb.cpu_addr  <= t.addr;
      vif.drv_cb.cpu_wdata <= t.wdata;
      @(vif.drv_cb);
      vif.drv_cb.cpu_req   <= 1'b0;

      // the access is in flight; wait for it to retire before offering the
      // next one (one outstanding access per core, which is what the DUT
      // supports and what makes completion order a valid total order)
      while (!vif.drv_cb.cpu_ack) @(vif.drv_cb);
      @(vif.drv_cb);
    endtask
  endclass

  class mesi_cpu_monitor extends uvm_monitor;
    `uvm_component_utils(mesi_cpu_monitor)

    virtual mesi_cpu_if               vif;
    mesi_cpu_cfg                      cfg;
    uvm_analysis_port #(mesi_cpu_txn) ap;        // completions
    uvm_analysis_port #(mesi_cpu_txn) launch_ap; // launches

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap        = new("ap", this);
      launch_ap = new("launch_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_cpu_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_cpu_if for the CPU monitor")
      if (!uvm_config_db#(mesi_cpu_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "no mesi_cpu_cfg for the CPU monitor")
    endfunction

    task run_phase(uvm_phase phase);
      mesi_cpu_txn pend, t;
      int unsigned cyc = 0;
      bit          live = 0;

      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin
          live = 0;
          cyc  = 0;
          continue;
        end
        cyc++;

        // Capture the request as the cache latches it, and publish the launch
        // separately.  The hit/miss prediction has to be taken against the
        // model state as it stood BEFORE this cycle's bus events, so the
        // scoreboard needs the launch as its own event rather than as a field
        // it only learns about at completion time.
        if (vif.mon_cb.cpu_req && !vif.mon_cb.cpu_busy) begin
          pend          = mesi_cpu_txn::type_id::create("pend");
          pend.core_id  = cfg.core_id;
          pend.op       = vif.mon_cb.cpu_we ? OP_WR : OP_RD;
          pend.addr     = vif.mon_cb.cpu_addr;
          pend.wdata    = vif.mon_cb.cpu_wdata;
          pend.cycle    = cyc;
          live          = 1;
          launch_ap.write(pend);
        end

        // pair it with its completion
        if (vif.mon_cb.cpu_ack) begin
          if (!live) begin
            `uvm_error("CPUMON", "cpu_ack with no access outstanding")
          end else begin
            t        = pend;
            t.rdata  = vif.mon_cb.cpu_rdata;
            t.hit    = vif.mon_cb.cpu_hit;
            t.cycle  = cyc;
            ap.write(t);
            live     = 0;
          end
        end
      end
    endtask
  endclass

  class mesi_cpu_agent extends uvm_agent;
    `uvm_component_utils(mesi_cpu_agent)

    mesi_cpu_sequencer sqr;
    mesi_cpu_driver    drv;
    mesi_cpu_monitor   mon;
    mesi_cpu_cfg       cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(mesi_cpu_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "no mesi_cpu_cfg for the CPU agent")
      uvm_config_db#(mesi_cpu_cfg)::set(this, "*", "cfg", cfg);
      mon = mesi_cpu_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = mesi_cpu_sequencer::type_id::create("sqr", this);
        drv = mesi_cpu_driver   ::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE)
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass


  // =====================================================================
  // Memory agent - the driver IS the memory
  // =====================================================================

  typedef uvm_sequencer #(mesi_mem_policy) mesi_mem_sequencer;

  class mesi_mem_driver extends uvm_driver #(mesi_mem_policy);
    `uvm_component_utils(mesi_mem_driver)

    virtual mesi_mem_if vif;
    logic [DW-1:0]      mem [NADDR];

    int unsigned        stall_pct = 0;
    int unsigned        read_lat  = 0;
    int unsigned        seed      = 32'h2468_ACE0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      int a;
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_mem_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_mem_if for the memory driver")
      // the model's image and the memory's contents start identical
      for (a = 0; a < NADDR; a++) mem[a] = ref_mem_read(a[AW-1:0]);
    endfunction

    function int unsigned rnd();
      seed = seed ^ (seed << 13);
      seed = seed ^ (seed >> 17);
      seed = seed ^ (seed << 5);
      return seed;
    endfunction

    // The policy stream and the memory behaviour run concurrently: a new
    // policy takes effect from the next cycle without interrupting a
    // transfer that is already in flight.
    task run_phase(uvm_phase phase);
      fork
        policy_thread();
        memory_thread();
      join
    endtask

    task policy_thread();
      forever begin
        seq_item_port.get_next_item(req);
        stall_pct = req.stall_pct;
        read_lat  = req.read_lat;
        `uvm_info("MEMPOL",
                  $sformatf("memory policy now: %0d%% stalls, %0d-cycle reads",
                            stall_pct, read_lat), UVM_LOW)
        seq_item_port.item_done();
      end
    endtask

    task memory_thread();
      bit          rd_pend;
      logic [AW-1:0] rd_addr;
      int          rd_cnt;
      bit          stall;

      vif.drv_cb.mem_gnt    <= 1'b0;
      vif.drv_cb.mem_rvalid <= 1'b0;
      vif.drv_cb.mem_rdata  <= '0;
      rd_pend = 0;

      forever begin
        @(vif.drv_cb);
        if (!vif.rst_n) begin
          vif.drv_cb.mem_gnt    <= 1'b0;
          vif.drv_cb.mem_rvalid <= 1'b0;
          rd_pend = 0;
          continue;
        end

        vif.drv_cb.mem_rvalid <= 1'b0;
        stall = (stall_pct > 0) && ((rnd() % 100) < stall_pct);
        vif.drv_cb.mem_gnt <= vif.drv_cb.mem_req && !stall;

        if (vif.drv_cb.mem_req && !stall) begin
          if (vif.drv_cb.mem_we) begin
            mem[vif.drv_cb.mem_addr] = vif.drv_cb.mem_wdata;
          end else begin
            rd_addr = vif.drv_cb.mem_addr;
            rd_cnt  = read_lat;
            rd_pend = 1;
          end
        end

        if (rd_pend) begin
          if (rd_cnt == 0) begin
            vif.drv_cb.mem_rvalid <= 1'b1;
            vif.drv_cb.mem_rdata  <= mem[rd_addr];
            rd_pend = 0;
          end else begin
            rd_cnt--;
          end
        end
      end
    endtask
  endclass

  class mesi_mem_monitor extends uvm_monitor;
    `uvm_component_utils(mesi_mem_monitor)

    virtual mesi_mem_if               vif;
    uvm_analysis_port #(mesi_mem_txn) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_mem_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_mem_if for the memory monitor")
    endfunction

    task run_phase(uvm_phase phase);
      mesi_mem_txn t;
      int unsigned cyc = 0;
      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin cyc = 0; continue; end
        cyc++;
        if (vif.mon_cb.mem_req && vif.mon_cb.mem_gnt) begin
          t       = mesi_mem_txn::type_id::create("t");
          t.we    = vif.mon_cb.mem_we;
          t.addr  = vif.mon_cb.mem_addr;
          t.wdata = vif.mon_cb.mem_wdata;
          t.cycle = cyc;
          ap.write(t);
        end
      end
    endtask
  endclass

  class mesi_mem_agent extends uvm_agent;
    `uvm_component_utils(mesi_mem_agent)

    mesi_mem_sequencer sqr;
    mesi_mem_driver    drv;
    mesi_mem_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = mesi_mem_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = mesi_mem_sequencer::type_id::create("sqr", this);
        drv = mesi_mem_driver   ::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE)
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass


  // =====================================================================
  // Bus agent (passive)
  // =====================================================================

  class mesi_bus_monitor extends uvm_monitor;
    `uvm_component_utils(mesi_bus_monitor)

    virtual mesi_bus_if                 vif;
    uvm_analysis_port #(mesi_bus_txn)   ap;
    uvm_analysis_port #(mesi_state_txn) sp;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
      sp = new("sp", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_bus_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_bus_if for the bus monitor")
    endfunction

    task run_phase(uvm_phase phase);
      mesi_bus_txn   b;
      mesi_state_txn s;
      logic [NCORE*2*NSET-1:0]  prev_state = 'x;
      logic [NCORE*AW*NSET-1:0] prev_tag   = 'x;
      logic [NCORE*DW*NSET-1:0] prev_data  = 'x;
      int unsigned   cyc = 0;
      bit            was_quiet = 0;
      bit            quiet;

      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin
          cyc = 0;
          prev_state = 'x;
          continue;
        end
        cyc++;

        if (vif.mon_cb.bus_valid) begin
          b        = mesi_bus_txn::type_id::create("b");
          b.phase  = PH_ADDR;
          b.master = int'(vif.mon_cb.bus_master);
          b.cmd    = vif.mon_cb.bus_cmd;
          b.addr   = vif.mon_cb.bus_addr;
          b.cycle  = cyc;
          ap.write(b);
        end

        if (vif.mon_cb.bus_fill) begin
          b        = mesi_bus_txn::type_id::create("b");
          b.phase  = PH_FILL;
          b.shared = vif.mon_cb.bus_fill_shared;
          b.c2c    = vif.mon_cb.bus_c2c;
          b.data   = vif.mon_cb.bus_fill_data;
          b.cycle  = cyc;
          ap.write(b);
        end

        // Publish the coherence state whenever it moves, and whenever the
        // system falls quiet.  Every cycle would work too; this keeps the
        // traffic proportional to what actually happened.
        quiet = !vif.mon_cb.bus_busy && (vif.mon_cb.cpu_busy == '0);
        if ((vif.mon_cb.dbg_state_f !== prev_state) ||
            (vif.mon_cb.dbg_tag_f   !== prev_tag)   ||
            (vif.mon_cb.dbg_data_f  !== prev_data)  ||
            (quiet && !was_quiet)) begin
          s         = mesi_state_txn::type_id::create("s");
          s.state_f = vif.mon_cb.dbg_state_f;
          s.tag_f   = vif.mon_cb.dbg_tag_f;
          s.data_f  = vif.mon_cb.dbg_data_f;
          s.quiet   = quiet;
          s.cycle   = cyc;
          sp.write(s);
        end
        prev_state = vif.mon_cb.dbg_state_f;
        prev_tag   = vif.mon_cb.dbg_tag_f;
        prev_data  = vif.mon_cb.dbg_data_f;
        was_quiet  = quiet;
      end
    endtask
  endclass

  class mesi_bus_agent extends uvm_agent;
    `uvm_component_utils(mesi_bus_agent)
    mesi_bus_monitor mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      set_is_active(UVM_PASSIVE);
      mon = mesi_bus_monitor::type_id::create("mon", this);
    endfunction
  endclass


  // =====================================================================
  // Scoreboard
  // =====================================================================

  `uvm_analysis_imp_decl(_cpu0)
  `uvm_analysis_imp_decl(_cpu1)
  `uvm_analysis_imp_decl(_lnch0)
  `uvm_analysis_imp_decl(_lnch1)
  `uvm_analysis_imp_decl(_bus)
  `uvm_analysis_imp_decl(_mem)
  `uvm_analysis_imp_decl(_state)
  `uvm_analysis_imp_decl(_covst)

  class mesi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mesi_scoreboard)

    uvm_analysis_imp_cpu0  #(mesi_cpu_txn,   mesi_scoreboard) cpu0_imp;
    uvm_analysis_imp_cpu1  #(mesi_cpu_txn,   mesi_scoreboard) cpu1_imp;
    uvm_analysis_imp_lnch0 #(mesi_cpu_txn,   mesi_scoreboard) lnch0_imp;
    uvm_analysis_imp_lnch1 #(mesi_cpu_txn,   mesi_scoreboard) lnch1_imp;
    uvm_analysis_imp_bus   #(mesi_bus_txn,   mesi_scoreboard) bus_imp;
    uvm_analysis_imp_mem   #(mesi_mem_txn,   mesi_scoreboard) mem_imp;
    uvm_analysis_imp_state #(mesi_state_txn, mesi_scoreboard) state_imp;

    // results the coverage collector subscribes to, so that operand class can
    // cross RESULT class rather than just stimulus
    uvm_analysis_port #(mesi_cpu_txn) cov_ap;

    virtual mesi_bus_if vif;

    // ---- per-cycle bins -------------------------------------------------
    mesi_cpu_txn   lnch_q  [$];
    mesi_cpu_txn   cpu_q   [$];
    mesi_bus_txn   bus_q   [$];
    mesi_mem_txn   mem_q   [$];
    mesi_state_txn state_q [$];

    // ---- transaction in flight on the bus -------------------------------
    int            txn_master;
    logic [1:0]    txn_cmd;
    logic [AW-1:0] txn_addr;
    bit            txn_shared, txn_dirty, txn_active;
    logic [DW-1:0] txn_fdata;

    // ---- per-core hit prediction ---------------------------------------
    bit            pred_hit   [NCORE];
    bit            pred_valid [NCORE];
    int            txns       [NCORE];
    bit            live       [NCORE];
    logic [AW-1:0] live_addr  [NCORE];

    int unsigned   n_mem_w, n_mem_r, n_bus, n_cyc;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cpu0_imp  = new("cpu0_imp",  this);
      cpu1_imp  = new("cpu1_imp",  this);
      lnch0_imp = new("lnch0_imp", this);
      lnch1_imp = new("lnch1_imp", this);
      bus_imp   = new("bus_imp",   this);
      mem_imp   = new("mem_imp",   this);
      state_imp = new("state_imp", this);
      cov_ap    = new("cov_ap",    this);
    endfunction

    function void build_phase(uvm_phase phase);
      int c;
      super.build_phase(phase);
      if (!uvm_config_db#(virtual mesi_bus_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "no mesi_bus_if for the scoreboard")
      for (c = 0; c < NCORE; c++) begin
        pred_valid[c] = 0; live[c] = 0; txns[c] = 0;
      end
    endfunction

    // ---- analysis writes just bin the events ---------------------------
    function void write_cpu0(mesi_cpu_txn t);  t.core_id = 0; cpu_q.push_back(t); endfunction
    function void write_cpu1(mesi_cpu_txn t);  t.core_id = 1; cpu_q.push_back(t); endfunction
    function void write_lnch0(mesi_cpu_txn t); t.core_id = 0; lnch_q.push_back(t); endfunction
    function void write_lnch1(mesi_cpu_txn t); t.core_id = 1; lnch_q.push_back(t); endfunction
    function void write_bus (mesi_bus_txn t);  bus_q.push_back(t);                endfunction
    function void write_mem (mesi_mem_txn t);  mem_q.push_back(t);                endfunction
    function void write_state(mesi_state_txn t); state_q.push_back(t);            endfunction

    // ---------------------------------------------------------------------
    // The model is self-checked and seeded in mesi_base_test::build_phase,
    // NOT here: the memory driver copies the model's image into its own array
    // during ITS build_phase, so the image has to exist before any component
    // is built.  Seeding it in run_phase would hand the memory an array of X.
    // ---------------------------------------------------------------------
    task run_phase(uvm_phase phase);
      int unsigned closing;

      // Process a cycle's events only once that cycle is closed, in a fixed
      // order.  UVM does not order analysis writes inside a time step, and
      // coherence checking is order-sensitive.
      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) continue;
        n_cyc++;
        closing = n_cyc - 1;
        process_cycle(closing);
      end
    endtask

    function void process_cycle(int unsigned cyc);
      // ---- 0. access launches -------------------------------------------
      // Taken first, so the prediction reflects the model as it stood before
      // this cycle's bus events - and any snoop later in this same cycle can
      // then legitimately void it.
      while (lnch_q.size() && (lnch_q[0].cycle <= cyc)) begin
        mesi_cpu_txn l = lnch_q.pop_front();
        note_launch(l.core_id, (l.op == OP_WR), l.addr);
      end

      // ---- 1. memory traffic --------------------------------------------
      while (mem_q.size() && (mem_q[0].cycle <= cyc)) begin
        mesi_mem_txn m = mem_q.pop_front();
        if (m.we) begin ref_mem_write(m.addr, m.wdata); n_mem_w++; end
        else            n_mem_r++;
      end

      // ---- 2/3. bus address phase, then completion ----------------------
      while (bus_q.size() && (bus_q[0].cycle <= cyc)) begin
        mesi_bus_txn b = bus_q.pop_front();
        if (b.phase == PH_ADDR) do_bus_addr(b);
        else                    do_bus_fill(b);
      end

      // ---- 4. CPU completions -------------------------------------------
      while (cpu_q.size() && (cpu_q[0].cycle <= cyc)) begin
        mesi_cpu_txn t = cpu_q.pop_front();
        do_cpu(t);
      end

      // ---- 5. the invariants --------------------------------------------
      while (state_q.size() && (state_q[0].cycle <= cyc)) begin
        mesi_state_txn s = state_q.pop_front();
        ref_check_swmr(s.state_f, s.tag_f, s.data_f);
        if (s.quiet) ref_check_full(s.state_f, s.tag_f, s.data_f);
      end

      flush_errors();
    endfunction

    // the model reports through ref_err; surface anything new as a UVM error
    int unsigned reported;
    function void flush_errors();
      if (n_err > reported) begin
        `uvm_error("MESI", $sformatf("%0d new coherence error(s) - see the log above",
                                     n_err - reported))
        reported = n_err;
      end
    endfunction

    function void do_bus_addr(mesi_bus_txn b);
      int c;
      txn_master = b.master;
      txn_cmd    = b.cmd;
      txn_addr   = b.addr;
      txn_dirty  = ref_pred_dirty(b.master, b.cmd, b.addr);
      txn_fdata  = ref_flush_data(b.master, b.addr);

      if ((b.cmd == BUSUPGR) && (ref_state(b.master, b.addr) != ST_S))
        ref_err($sformatf("core%0d issued BusUpgr for addr %0d while holding it in %s",
                          b.master, b.addr, st_name(ref_state(b.master, b.addr))));

      txn_shared = ref_bus_addr_phase(b.master, b.cmd, b.addr);
      txn_active = 1;
      n_bus++;
      txns[b.master]++;

      // a snoop on an address another core is mid-access to voids that core's
      // hit prediction - counted, never hidden
      for (c = 0; c < NCORE; c++)
        if ((c != b.master) && live[c] && (live_addr[c] == b.addr) && (b.cmd != BUSWB))
          pred_valid[c] = 0;
    endfunction

    function void do_bus_fill(mesi_bus_txn b);
      if (!txn_active) begin
        ref_err("a bus completion arrived with no transaction outstanding");
        return;
      end
      if (b.shared !== txn_shared)
        ref_err($sformatf("%s addr %0d by core%0d: DUT shared=%0b, model %0b",
                          cmd_name(txn_cmd), txn_addr, txn_master, b.shared, txn_shared));
      if (b.c2c !== txn_dirty)
        ref_err($sformatf("%s addr %0d by core%0d: DUT cache-to-cache=%0b, model %0b",
                          cmd_name(txn_cmd), txn_addr, txn_master, b.c2c, txn_dirty));
      if (txn_dirty) begin
        if (b.data !== txn_fdata)
          ref_err($sformatf("flush of addr %0d carried 0x%08h, owner held 0x%08h",
                            txn_addr, b.data, txn_fdata));
        n_c2c++;
      end
      ref_bus_complete(txn_master, txn_cmd, txn_addr, b.shared, b.data);
      txn_active = 0;
    endfunction

    function void do_cpu(mesi_cpu_txn t);
      // capture what the access found BEFORE the model applies it
      t.found_state = ref_state(t.core_id, t.addr);
      ref_cpu_complete(t.core_id, (t.op == OP_WR), t.addr, t.wdata,
                       t.rdata, t.hit, pred_valid[t.core_id],
                       pred_hit[t.core_id], txns[t.core_id]);
      live[t.core_id] = 0;
      txns[t.core_id] = 0;
      cov_ap.write(t);
    endfunction

    // The prediction has to be taken when the access is launched, before the
    // bus can change anything.  The CPU monitor sees the launch a cycle
    // before the scoreboard closes that cycle, so it registers here.
    function void note_launch(int core, bit we, logic [AW-1:0] a);
      pred_hit  [core] = ref_pred_hit(core, we, a);
      pred_valid[core] = 1;
      txns      [core] = 0;
      live      [core] = 1;
      live_addr [core] = a;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("MESI", $sformatf(
        "\n  ---- MESI coherence scoreboard ----\n"
        "    CPU accesses checked        %0d (%0d reads, %0d writes)\n"
        "    hits / misses               %0d / %0d\n"
        "    read misses -> E / -> S     %0d / %0d\n"
        "    SILENT E->M upgrades        %0d\n"
        "    M->S downgrades             %0d\n"
        "    invalidations               %0d\n"
        "    cache-to-cache flushes      %0d\n"
        "    dirty writebacks            %0d\n"
        "    BusRd/BusRdX/BusUpgr/BusWB  %0d / %0d / %0d / %0d\n"
        "    memory reads / writes       %0d / %0d\n"
        "    predictions voided by race  %0d\n"
        "    errors                      %0d",
        n_check, n_cpu_read, n_cpu_write, n_hit, n_miss,
        n_e_install, n_s_install, n_e_silent, n_m_downgrade, n_inval,
        n_c2c, n_evict_wb, n_busrd, n_busrdx, n_busupgr, n_buswb,
        n_mem_r, n_mem_w, n_pred_skipped, n_err), UVM_NONE)

      // memory traffic must be fully accounted for by protocol events
      if (n_mem_w != (n_c2c + n_evict_wb))
        `uvm_error("MESI", $sformatf(
          "memory saw %0d writes but the protocol required %0d (%0d flushes + %0d writebacks)",
          n_mem_w, n_c2c + n_evict_wb, n_c2c, n_evict_wb))
      if (n_mem_r != (n_busrd + n_busrdx - n_c2c))
        `uvm_error("MESI", $sformatf(
          "memory saw %0d reads but the protocol required %0d",
          n_mem_r, n_busrd + n_busrdx - n_c2c))

      // a property that was never exercised is a hole, and a hole fails
      if (n_e_install   == 0) `uvm_error("HOLE", "no read miss ever installed E")
      if (n_s_install   == 0) `uvm_error("HOLE", "no read miss ever installed S")
      if (n_e_silent    == 0) `uvm_error("HOLE", "the silent E->M upgrade never happened")
      if (n_m_downgrade == 0) `uvm_error("HOLE", "no M->S downgrade ever happened")
      if (n_inval       == 0) `uvm_error("HOLE", "no invalidation ever happened")
      if (n_c2c         == 0) `uvm_error("HOLE", "no cache-to-cache flush ever happened")
      if (n_evict_wb    == 0) `uvm_error("HOLE", "no dirty writeback ever happened")
      if (n_busupgr     == 0) `uvm_error("HOLE", "no BusUpgr was ever issued")
      if (n_err          > 0) `uvm_error("MESI", $sformatf("%0d coherence errors", n_err))
    endfunction
  endclass


  // =====================================================================
  // Coverage - downstream of the scoreboard, so the state the access FOUND
  // the line in can be crossed with what the DUT did about it.
  // =====================================================================

  class mesi_coverage extends uvm_subscriber #(mesi_cpu_txn);
    `uvm_component_utils(mesi_coverage)

    // the state stream, so the MESI diagram's arcs can be enumerated
    uvm_analysis_imp_covst #(mesi_state_txn, mesi_coverage) state_imp;

    mesi_op_e   cg_op;
    logic [1:0] cg_state;      // state the line was in when the access began
    bit         cg_hit;
    int         cg_core;
    int         cg_set;
    int         cg_tag;

    // the MESI state diagram, walked per core
    logic [1:0] prev_st [NCORE][NSET];
    logic [1:0] cg_from, cg_to;
    bit         cg_moved;

    covergroup cg_access;
      option.per_instance = 1;
      option.name         = "mesi_access";

      cp_op    : coverpoint cg_op    { bins rd = {OP_RD}; bins wr = {OP_WR}; }
      cp_core  : coverpoint cg_core  { bins c[] = {[0:NCORE-1]}; }
      cp_state : coverpoint cg_state {
        bins I = {2'd0}; bins S = {2'd1}; bins E = {2'd2}; bins M = {2'd3};
      }
      cp_hit   : coverpoint cg_hit   { bins miss = {0}; bins hit = {1}; }
      cp_set   : coverpoint cg_set   { bins s[] = {[0:NSET-1]}; }
      cp_tag   : coverpoint cg_tag   { bins t[] = {[0:2]}; }

      // The interesting cross.  Every legal combination has a name a designer
      // would recognise, and the illegal ones are excluded so an unreachable
      // bin cannot quietly hold coverage down:
      //   RD x I  -> read miss          WR x I -> write miss (BusRdX)
      //   RD x S/E/M -> read hit        WR x S -> upgrade (BusUpgr)
      //   WR x E  -> THE silent upgrade WR x M -> write hit, already owned
      x_op_state_hit : cross cp_op, cp_state, cp_hit {
        ignore_bins impossible_hit_on_I  = binsof(cp_state.I) && binsof(cp_hit.hit);
        ignore_bins impossible_rd_miss   = binsof(cp_op.rd) &&
                                           (binsof(cp_state.S) || binsof(cp_state.E) ||
                                            binsof(cp_state.M)) && binsof(cp_hit.miss);
        ignore_bins impossible_wr_s_hit  = binsof(cp_op.wr) && binsof(cp_state.S) &&
                                           binsof(cp_hit.hit);
        ignore_bins impossible_wr_em_miss= binsof(cp_op.wr) &&
                                           (binsof(cp_state.E) || binsof(cp_state.M)) &&
                                           binsof(cp_hit.miss);
      }

      x_core_set : cross cp_core, cp_set;
      x_core_tag : cross cp_core, cp_tag;
    endgroup

    // Every arc of the MESI state diagram that this design can take.  Named
    // explicitly so a missing one is a reported hole rather than an unnoticed
    // gap in a wildcard bin.
    covergroup cg_transition;
      option.per_instance = 1;
      option.name         = "mesi_transitions";

      cp_arc : coverpoint {cg_from, cg_to} iff (cg_moved) {
        bins i_to_e = {4'b0010};   // read miss, nobody else had it
        bins i_to_s = {4'b0001};   // read miss, someone else had it
        bins i_to_m = {4'b0011};   // write miss (BusRdX)
        bins e_to_m = {4'b1011};   // THE silent upgrade
        bins e_to_s = {4'b1001};   // remote read
        bins e_to_i = {4'b1000};   // remote write, or eviction
        bins s_to_m = {4'b0111};   // BusUpgr
        bins s_to_i = {4'b0100};   // remote write, or eviction
        bins m_to_s = {4'b1101};   // remote read, with a flush
        bins m_to_i = {4'b1100};   // remote write or writeback, with a flush
      }
      cp_core2 : coverpoint cg_core { bins c[] = {[0:NCORE-1]}; }
      x_arc_core : cross cp_arc, cp_core2;
    endgroup

    bit have_prev = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      state_imp     = new("state_imp", this);
      cg_access     = new();
      cg_transition = new();
    endfunction

    function void write(mesi_cpu_txn t);
      cg_op    = t.op;
      cg_core  = t.core_id;
      cg_hit   = t.hit;
      cg_set   = int'(t.addr[IDXW-1:0]);
      cg_tag   = int'(t.addr[AW-1:IDXW]);
      cg_state = t.found_state;   // stamped by the scoreboard pre-update
      cg_access.sample();
    endfunction

    // Every state snapshot is diffed against the previous one, so every arc
    // the design takes is counted - including the ones no CPU access is
    // responsible for, such as a line being invalidated by the other core.
    function void write_covst(mesi_state_txn s);
      int c, st;
      logic [1:0] now;
      for (c = 0; c < NCORE; c++)
        for (st = 0; st < NSET; st++) begin
          now = s.state_f[(c*NSET + st)*2 +: 2];
          if (have_prev && (now !== prev_st[c][st])) begin
            cg_core  = c;
            cg_from  = prev_st[c][st];
            cg_to    = now;
            cg_moved = 1;
            cg_transition.sample();
          end
          prev_st[c][st] = now;
        end
      have_prev = 1;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf(
        "coverage: accesses %.1f%%, MESI state-diagram arcs %.1f%%",
        cg_access.get_coverage(), cg_transition.get_coverage()), UVM_NONE)
      if (cg_transition.get_coverage() < 100.0)
        `uvm_error("HOLE", "not every arc of the MESI state diagram was taken")
    endfunction
  endclass


  // =====================================================================
  // Environment
  // =====================================================================

  class mesi_vsequencer extends uvm_sequencer;
    `uvm_component_utils(mesi_vsequencer)
    mesi_cpu_sequencer cpu_sqr [NCORE];
    mesi_mem_sequencer mem_sqr;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class mesi_env extends uvm_env;
    `uvm_component_utils(mesi_env)

    mesi_cpu_agent  cpu [NCORE];
    mesi_mem_agent  memg;
    mesi_bus_agent  busg;
    mesi_scoreboard sb;
    mesi_coverage   cov;
    mesi_vsequencer vsqr;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      int c;
      mesi_cpu_cfg cfg;
      super.build_phase(phase);
      for (c = 0; c < NCORE; c++) begin
        cfg         = mesi_cpu_cfg::type_id::create($sformatf("cfg%0d", c));
        cfg.core_id = c;
        uvm_config_db#(mesi_cpu_cfg)::set(this, $sformatf("cpu%0d*", c), "cfg", cfg);
        cpu[c] = mesi_cpu_agent::type_id::create($sformatf("cpu%0d", c), this);
      end
      memg = mesi_mem_agent ::type_id::create("memg", this);
      busg = mesi_bus_agent ::type_id::create("busg", this);
      sb   = mesi_scoreboard::type_id::create("sb",   this);
      cov  = mesi_coverage  ::type_id::create("cov",  this);
      vsqr = mesi_vsequencer::type_id::create("vsqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      int c;
      cpu[0].mon.ap.connect(sb.cpu0_imp);
      cpu[1].mon.ap.connect(sb.cpu1_imp);
      cpu[0].mon.launch_ap.connect(sb.lnch0_imp);
      cpu[1].mon.launch_ap.connect(sb.lnch1_imp);
      memg.mon.ap.connect(sb.mem_imp);
      busg.mon.ap.connect(sb.bus_imp);
      busg.mon.sp.connect(sb.state_imp);
      busg.mon.sp.connect(cov.state_imp);
      sb.cov_ap.connect(cov.analysis_export);
      for (c = 0; c < NCORE; c++) vsqr.cpu_sqr[c] = cpu[c].sqr;
      vsqr.mem_sqr = memg.sqr;
    endfunction
  endclass


  // =====================================================================
  // Sequences
  // =====================================================================

  class mesi_cpu_base_seq extends uvm_sequence #(mesi_cpu_txn);
    `uvm_object_utils(mesi_cpu_base_seq)
    function new(string name = "mesi_cpu_base_seq"); super.new(name); endfunction

    // NOTE the argument names.  Inside a `randomize() with {}` clause an
    // identifier resolves against the OBJECT first, so an argument called
    // `op` would make `t.op == op` a tautology comparing the field with
    // itself - the constraint would silently do nothing and every directed
    // access would be randomly a read or a write.
    task access(mesi_op_e a_op, logic [AW-1:0] a_addr, logic [DW-1:0] a_data = '0);
      mesi_cpu_txn t;
      t = mesi_cpu_txn::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { op == a_op; addr == a_addr; wdata == a_data; })
        `uvm_fatal("RAND", "directed access failed to randomize")
      finish_item(t);
    endtask

    task rd(logic [AW-1:0] a);                    access(OP_RD, a);      endtask
    task wr(logic [AW-1:0] a, logic [DW-1:0] d);  access(OP_WR, a, d);   endtask
  endclass

  // ---- the five-access MESI showcase (this is the captured waveform) ----
  class mesi_showcase_c0_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_showcase_c0_seq)
    function new(string name = "mesi_showcase_c0_seq"); super.new(name); endfunction
    task body();
      rd(8'd4);                     // I -> E : nobody else has it
      wr(8'd4, 32'h1111_1111);      // E -> M : SILENT, no bus transaction
      #400ns;                       // let core1 take the line
      wr(8'd4, 32'h3333_3333);      // I -> M : BusRdX pulls it back with a flush
    endtask
  endclass

  class mesi_showcase_c1_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_showcase_c1_seq)
    function new(string name = "mesi_showcase_c1_seq"); super.new(name); endfunction
    task body();
      #200ns;
      rd(8'd4);                     // owner flushes M -> S, this core gets S
      wr(8'd4, 32'h2222_2222);      // S -> M : BusUpgr invalidates the other
    endtask
  endclass

  // ---- two cores sharing, then one writing ----
  class mesi_share_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_share_seq)
    int unsigned n = 8;      // iteration count, deliberately not rand
    function new(string name = "mesi_share_seq"); super.new(name); endfunction
    task body();
      for (int i = 0; i < n; i++) begin
        rd(8'd5);
        rd(8'd5);                   // second one must be a hit
        wr(8'd5, 32'h5000_0000 + i);
      end
    endtask
  endclass

  // ---- migratory line: both cores write the same address in turn ----
  class mesi_migratory_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_migratory_seq)
    int unsigned n = 16;     // iteration count, deliberately not rand
    function new(string name = "mesi_migratory_seq"); super.new(name); endfunction
    task body();
      for (int i = 0; i < n; i++) wr(8'd1, 32'h6000_0000 + i);
    endtask
  endclass

  // ---- conflict misses and dirty evictions ----
  class mesi_thrash_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_thrash_seq)
    int unsigned n = 18;     // iteration count, deliberately not rand
    function new(string name = "mesi_thrash_seq"); super.new(name); endfunction
    task body();
      // three tags over one set: every access evicts, and the victim is dirty
      for (int i = 0; i < n; i++) wr((i % 3) * 4 + 2, 32'h7000_0000 + i);
    endtask
  endclass

  // ---- the upgrade race: both cores hold S and both decide to store ----
  class mesi_upgrade_race_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_upgrade_race_seq)
    int unsigned n = 12;     // iteration count, deliberately not rand
    logic [DW-1:0] mark = 32'h9000_0000;
    function new(string name = "mesi_upgrade_race_seq"); super.new(name); endfunction
    task body();
      for (int i = 0; i < n; i++) begin
        rd(8'd3);                       // get into S alongside the other core
        wr(8'd3, mark + i);             // both upgrade; one has to become RFO
      end
    endtask
  endclass

  // ---- constrained-random traffic with a locality term ----
  class mesi_random_seq extends mesi_cpu_base_seq;
    `uvm_object_utils(mesi_random_seq)
    int unsigned n = 400;    // iteration count, deliberately not rand

    function new(string name = "mesi_random_seq"); super.new(name); endfunction

    task body();
      mesi_cpu_txn t;
      logic [AW-1:0] last = '0;
      for (int i = 0; i < n; i++) begin
        t = mesi_cpu_txn::type_id::create("t");
        start_item(t);
        // Without the locality term almost every access misses and the hit
        // path - where the silent E->M upgrade lives - barely runs.
        if (!t.randomize() with {
              t.addr dist { last := 45, [0:11] :/ 55 };
            })
          `uvm_fatal("RAND", "random access failed to randomize")
        finish_item(t);
        last = t.addr;
      end
    endtask
  endclass

  // ---- memory response policies ----
  class mesi_mem_fast_seq extends uvm_sequence #(mesi_mem_policy);
    `uvm_object_utils(mesi_mem_fast_seq)
    function new(string name = "mesi_mem_fast_seq"); super.new(name); endfunction
    task body();
      mesi_mem_policy p;
      p = mesi_mem_policy::type_id::create("p");
      start_item(p);
      if (!p.randomize() with { stall_pct == 0; read_lat == 0; })
        `uvm_fatal("RAND", "policy randomize failed")
      finish_item(p);
    endtask
  endclass

  class mesi_mem_hostile_seq extends uvm_sequence #(mesi_mem_policy);
    `uvm_object_utils(mesi_mem_hostile_seq)
    int unsigned rounds = 4;
    function new(string name = "mesi_mem_hostile_seq"); super.new(name); endfunction
    task body();
      mesi_mem_policy p;
      for (int i = 0; i < rounds; i++) begin
        p = mesi_mem_policy::type_id::create("p");
        start_item(p);
        if (!p.randomize() with { stall_pct inside {[20:70]}; read_lat inside {[1:8]}; })
          `uvm_fatal("RAND", "policy randomize failed")
        finish_item(p);
        #5us;
      end
    endtask
  endclass


  // =====================================================================
  // Virtual sequences
  // =====================================================================

  class mesi_base_vseq extends uvm_sequence;
    `uvm_object_utils(mesi_base_vseq)
    `uvm_declare_p_sequencer(mesi_vsequencer)
    function new(string name = "mesi_base_vseq"); super.new(name); endfunction
  endclass

  // ---- smoke: the protocol showcase against an instant memory ----------
  class mesi_smoke_vseq extends mesi_base_vseq;
    `uvm_object_utils(mesi_smoke_vseq)
    function new(string name = "mesi_smoke_vseq"); super.new(name); endfunction

    task body();
      mesi_mem_fast_seq     fast;
      mesi_showcase_c0_seq  s0;
      mesi_showcase_c1_seq  s1;
      mesi_share_seq        sh;
      mesi_migratory_seq    mg;

      fast = mesi_mem_fast_seq::type_id::create("fast");
      fast.start(p_sequencer.mem_sqr);

      s0 = mesi_showcase_c0_seq::type_id::create("s0");
      s1 = mesi_showcase_c1_seq::type_id::create("s1");
      fork
        s0.start(p_sequencer.cpu_sqr[0]);
        s1.start(p_sequencer.cpu_sqr[1]);
      join

      sh = mesi_share_seq    ::type_id::create("sh");
      mg = mesi_migratory_seq::type_id::create("mg");
      fork
        sh.start(p_sequencer.cpu_sqr[0]);
        mg.start(p_sequencer.cpu_sqr[1]);
      join
    endtask
  endclass

  // ---- regression: directed first against a cooperative memory, so a
  //      failure is unambiguously the cache, then everything again against
  //      a hostile one.
  class mesi_regress_vseq extends mesi_base_vseq;
    `uvm_object_utils(mesi_regress_vseq)
    function new(string name = "mesi_regress_vseq"); super.new(name); endfunction

    task body();
      mesi_mem_fast_seq     fast;
      mesi_mem_hostile_seq  hostile;
      mesi_showcase_c0_seq  s0;
      mesi_showcase_c1_seq  s1;
      mesi_share_seq        sh0, sh1;
      mesi_migratory_seq    mg0, mg1;
      mesi_thrash_seq       th0, th1;
      mesi_upgrade_race_seq ur0, ur1;
      mesi_random_seq       r0, r1;

      // ---- phase 1: directed, instant memory ----
      fast = mesi_mem_fast_seq::type_id::create("fast");
      fast.start(p_sequencer.mem_sqr);

      s0 = mesi_showcase_c0_seq::type_id::create("s0");
      s1 = mesi_showcase_c1_seq::type_id::create("s1");
      fork s0.start(p_sequencer.cpu_sqr[0]); s1.start(p_sequencer.cpu_sqr[1]); join

      th0 = mesi_thrash_seq::type_id::create("th0");
      th1 = mesi_thrash_seq::type_id::create("th1");
      fork th0.start(p_sequencer.cpu_sqr[0]); th1.start(p_sequencer.cpu_sqr[1]); join

      ur0 = mesi_upgrade_race_seq::type_id::create("ur0");
      ur1 = mesi_upgrade_race_seq::type_id::create("ur1");
      ur1.mark = 32'hA000_0000;   // distinct markers, so a lost update is visible
      fork ur0.start(p_sequencer.cpu_sqr[0]); ur1.start(p_sequencer.cpu_sqr[1]); join

      sh0 = mesi_share_seq   ::type_id::create("sh0");
      mg1 = mesi_migratory_seq::type_id::create("mg1");
      fork sh0.start(p_sequencer.cpu_sqr[0]); mg1.start(p_sequencer.cpu_sqr[1]); join

      // ---- phase 2: the same design against a memory that fights back.
      //      The policy sequence runs forever alongside the traffic and is
      //      killed when the traffic finishes.
      hostile = mesi_mem_hostile_seq::type_id::create("hostile");

      r0 = mesi_random_seq::type_id::create("r0");
      r1 = mesi_random_seq::type_id::create("r1");

      // The memory keeps changing its mind underneath the traffic, and stops
      // when the traffic does - the policy stream sets the conditions, the
      // CPU streams set the length of the phase.
      fork
        hostile.start(p_sequencer.mem_sqr);
      join_none
      fork
        r0.start(p_sequencer.cpu_sqr[0]);
        r1.start(p_sequencer.cpu_sqr[1]);
      join
      hostile.kill();

      // ---- back to a fast memory to drain and reconcile ----
      fast = mesi_mem_fast_seq::type_id::create("fast2");
      fast.start(p_sequencer.mem_sqr);

      sh1 = mesi_share_seq::type_id::create("sh1");
      mg0 = mesi_migratory_seq::type_id::create("mg0");
      fork sh1.start(p_sequencer.cpu_sqr[1]); mg0.start(p_sequencer.cpu_sqr[0]); join
    endtask
  endclass


  // =====================================================================
  // Tests
  // =====================================================================

  class mesi_base_test extends uvm_test;
    `uvm_component_utils(mesi_base_test)
    mesi_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      int sc;
      super.build_phase(phase);

      // The golden model re-proves its own protocol rules before anything
      // else is built - a reference model for a coherence protocol is as easy
      // to get subtly wrong as the RTL it is judging, and a model that agrees
      // with a broken DUT is worse than no model at all.
      sc = ref_selfcheck();
      if (sc != 0)
        `uvm_fatal("REFBAD",
                   $sformatf("the golden model failed its own self-check (%0d errors)", sc))
      `uvm_info("REFOK", "golden model re-proved 7 protocol properties", UVM_LOW)

      // Seeded here, before the memory agent is built: the memory driver
      // copies this image into its array during its own build_phase.
      ref_init(32'hC0DE_0000);

      env = mesi_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      uvm_top.print_topology();
    endfunction
  endclass

  class mesi_smoke_test extends mesi_base_test;
    `uvm_component_utils(mesi_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
      mesi_smoke_vseq v;
      phase.raise_objection(this);
      v = mesi_smoke_vseq::type_id::create("v");
      v.start(env.vsqr);
      #1us;
      phase.drop_objection(this);
    endtask
  endclass

  class mesi_regress_test extends mesi_base_test;
    `uvm_component_utils(mesi_regress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
      mesi_regress_vseq v;
      phase.raise_objection(this);
      v = mesi_regress_vseq::type_id::create("v");
      v.start(env.vsqr);
      #2us;
      phase.drop_objection(this);
    endtask
  endclass

endpackage
