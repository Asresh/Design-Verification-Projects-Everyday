// ============================================================================
// jtag_tap_pkg.sv - the UVM verification environment for the IEEE 1149.1 TAP.
// ----------------------------------------------------------------------------
// Topology
//
//   jtag_vseqr (virtual sequencer)
//     +-- jtag_sequencer ---------- jtag_driver     --> [ trst_n / tms / tdi ]
//     +-- jtag_pin_sequencer ------ jtag_pin_driver --> [ pin_in / user_capture ]
//
//   jtag_agent      (active, TAP side)
//     +-- jtag_pin_monitor  -- cyc_ap  --> jtag_scoreboard   (cycle-exact)
//     |                                \-> jtag_coverage     (state / transition)
//     +-- jtag_scan_monitor -- scan_ap --> jtag_scan_scoreboard (transaction)
//                                      \-> jtag_coverage     (instruction / chain)
//
//   jtag_pin_agent  (active, system side)
//     +-- jtag_pin_side_monitor -- pin_ap --> jtag_coverage
//
// Two agents, because a real device does not hold still while it is scanned.
// The TAP agent walks the state diagram; the pin agent keeps the mission-side
// inputs moving underneath it, so a Capture-DR has to grab whatever happened to
// be on the boundary at that exact edge.  That is what makes the virtual
// sequences do real work: they fork a scan sequence on one sequencer against a
// pin-wiggle sequence on the other, and the scoreboard has to get the
// interleaving right.
//
// Checking happens at two levels, deliberately, because they fail differently.
//
//   jtag_scoreboard      is CYCLE-EXACT.  Every rising edge it hands the pin
//                        vector to jtag_tap_ref_pkg::ref_tap_cycle and compares
//                        the model's prediction against the DUT: controller
//                        state, IR shift register, TDO, TDO's enable, the
//                        latched instruction, both update latches and the
//                        boundary drive.  Nothing is checked "eventually".
//                        This catches an off-by-an-edge that a transaction
//                        checker would sail straight past.
//
//   jtag_scan_scoreboard is TRANSACTION-LEVEL, and independent of the model.
//                        It reassembles whole scans and asks the questions the
//                        standard asks: did Capture-IR present a 1 in the LSB,
//                        did the captured DR match the source that chain reads,
//                        did the last chain_len bits shifted in reach the
//                        update latch, did the scan see the chain length the
//                        latched instruction implies?
//
// The cycle-exact checker is stronger, but it can only ever be as right as the
// reference model. The transaction checker restates the requirement in a form
// that shares no code with it, which is why both are here.
// ============================================================================
`timescale 1ns/1ps

package jtag_tap_pkg;

    import uvm_pkg::*;
    import jtag_tap_ref_pkg::*;
`include "uvm_macros.svh"

    // ---- analysis imp suffixes ---------------------------------------------
    `uvm_analysis_imp_decl(_cyc)
    `uvm_analysis_imp_decl(_scan)
    `uvm_analysis_imp_decl(_covcyc)
    `uvm_analysis_imp_decl(_covscan)
    `uvm_analysis_imp_decl(_covpin)

    // ======================================================================
    // config
    // ======================================================================
    class jtag_config extends uvm_object;
        `uvm_object_utils(jtag_config)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;
        function new(string name = "jtag_config"); super.new(name); endfunction
    endclass

    // ======================================================================
    // transactions
    // ======================================================================
    typedef enum bit [2:0] {
        JT_TRST,        // asynchronous TRST_n pulse
        JT_TMS_RESET,   // five TMS=1 clocks
        JT_IDLE,        // sit in Run-Test/Idle
        JT_SCAN_IR,     // a complete IR scan
        JT_SCAN_DR,     // a complete DR scan, optionally parked in Pause-DR
        JT_RAW          // a raw TMS/TDI stream - wander the diagram
    } jtag_kind_e;

    // A TAP-level request.  Everything a tester can ask a TAP to do.
    class jtag_txn extends uvm_sequence_item;
        rand jtag_kind_e   kind;
        rand bit [3:0]     ir;           // opcode, for JT_SCAN_IR
        rand bit [63:0]    payload;      // bits shifted in, LSB first
        rand int unsigned  extra_bits;   // scan longer than the chain by this
        rand bit           do_pause;     // park in Pause-xR mid-scan
        rand int unsigned  pause_frac;   // where to park, as a fraction
        rand int unsigned  pause_hold;   // how long to stay parked
        rand int unsigned  idle_cycles;  // for JT_IDLE
        rand bit [63:0]    raw_tms;      // for JT_RAW
        rand bit [63:0]    raw_tdi;
        rand int unsigned  raw_n;

        // derived in post_randomize, not constrained, so no solver has to
        // reason about a function of a random opcode
        int unsigned       nbits;
        int unsigned       pause_at;

        `uvm_object_utils_begin(jtag_txn)
            `uvm_field_enum(jtag_kind_e, kind, UVM_ALL_ON)
            `uvm_field_int(ir,         UVM_ALL_ON)
            `uvm_field_int(payload,    UVM_ALL_ON)
            `uvm_field_int(nbits,      UVM_ALL_ON)
            `uvm_field_int(do_pause,   UVM_ALL_ON)
            `uvm_field_int(pause_at,   UVM_ALL_ON)
            `uvm_field_int(pause_hold, UVM_ALL_ON)
        `uvm_object_utils_end

        // The shaping constraints below are `soft` on purpose.  A `dist` is a
        // hard restriction, not just a weighting - a value outside its list has
        // weight zero and cannot be chosen - so a directed sequence asking for
        // a 34-bit scan through an inline `extra_bits == 26` would collide with
        // its own weighting and fail to randomize.  Soft lets the directed
        // request win while random traffic still gets the distribution.
        //
        // Scans are the point; resets and raw walks are the seasoning.
        constraint c_kind { soft kind dist { JT_SCAN_DR := 45, JT_SCAN_IR := 30,
                                             JT_RAW     := 12, JT_IDLE    := 8,
                                             JT_TMS_RESET := 4, JT_TRST   := 1 }; }
        // Scanning a chain longer than it is proves the shift path keeps
        // rotating rather than saturating, which is a real bug class.
        constraint c_extra_rng { extra_bits inside {[0:56]}; }
        constraint c_extra  { soft extra_bits dist { 0 := 50, 1 := 15, 2 := 15,
                                                     [3:6] := 20 }; }
        constraint c_pause  { soft do_pause dist { 0 := 65, 1 := 35 }; }
        constraint c_pfrac  { pause_frac inside {[1:99]}; }
        constraint c_phold  { pause_hold inside {[0:8]}; }
        constraint c_idle   { idle_cycles inside {[1:16]}; }
        constraint c_rawn   { raw_n inside {[8:64]}; }
        // A fair coin on TMS spends most of its life bouncing between
        // Select-DR and Select-IR; weighting it down to about 38% makes the
        // walk linger in the shift and pause states, where the bugs live.
        constraint c_rawtms { soft $countones(raw_tms) inside {[18:30]}; }

        function new(string name = "jtag_txn"); super.new(name); endfunction

        function void post_randomize();
            int unsigned len;
            len   = ref_chain_len(ir);
            nbits = len + extra_bits;
            if (nbits > 64) nbits = 64;
            // Park somewhere strictly inside the scan, never at bit 0 (there
            // is nothing to preserve yet) and never past the end.
            pause_at = 1 + ((pause_frac * nbits) / 100);
            if (pause_at >= nbits) pause_at = (nbits > 1) ? nbits - 1 : 1;
            if (nbits == 1) do_pause = 1'b0;
        endfunction

        function string convert2string();
            case (kind)
                JT_SCAN_IR: return $sformatf("SCAN_IR 0b%04b (%s)", ir,
                                             ref_instr_name(ir));
                JT_SCAN_DR: return $sformatf("SCAN_DR %0d bits payload=0x%0h%s",
                                             nbits, payload,
                                             do_pause ? $sformatf(" pause@%0d for %0d",
                                                                  pause_at, pause_hold)
                                                      : "");
                JT_RAW    : return $sformatf("RAW %0d cycles tms=0x%0h", raw_n, raw_tms);
                JT_IDLE   : return $sformatf("IDLE %0d", idle_cycles);
                JT_TRST   : return "TRST_n pulse";
                default   : return "TMS reset";
            endcase
        endfunction
    endclass

    // A system-side request: what the mission logic is presenting to the
    // boundary cells and to the user register.
    class jtag_pin_txn extends uvm_sequence_item;
        rand bit [REF_BSR_LEN-1:0]  pin_in;
        rand bit [REF_USER_LEN-1:0] user_capture;
        rand int unsigned           hold;    // cycles to hold this vector

        `uvm_object_utils_begin(jtag_pin_txn)
            `uvm_field_int(pin_in,       UVM_ALL_ON)
            `uvm_field_int(user_capture, UVM_ALL_ON)
            `uvm_field_int(hold,         UVM_ALL_ON)
        `uvm_object_utils_end

        constraint c_hold { soft hold inside {[1:8]}; }
        constraint c_hold_rng { hold inside {[1:64]}; }

        function new(string name = "jtag_pin_txn"); super.new(name); endfunction
    endclass

    // One TCK cycle as the pin monitor sees it: the stimulus for this cycle
    // and the complete result of the previous one.  See the comment on mon_cb
    // in jtag_tap_if.sv for why a single rising-edge sample gives both.
    class jtag_cycle_item extends uvm_sequence_item;
        // stimulus the DUT is about to act on
        bit                      tms, tdi;
        bit [REF_BSR_LEN-1:0]    pin_in;
        bit [REF_USER_LEN-1:0]   user_capture;
        // result of the cycle that just finished
        bit [3:0]                state, ir_shift, ir_latched;
        bit                      tdo, tdo_en, pin_oe;
        bit [REF_BSR_LEN-1:0]    pin_out;
        bit [REF_USER_LEN-1:0]   user_out;
        // the first cycle after a reset: the scoreboard rearms its model here
        bit                      resync;

        `uvm_object_utils(jtag_cycle_item)
        function new(string name = "jtag_cycle_item"); super.new(name); endfunction
    endclass

    // A complete scan, reassembled from the state sequence.
    class jtag_scan_item extends uvm_sequence_item;
        bit          is_ir;          // an IR scan rather than a DR scan
        bit [3:0]    instr;          // the instruction latched during the scan
        bit [1:0]    chain;          // the chain it selected
        int unsigned nbits;          // bits actually shifted
        bit [63:0]   captured;       // what came out of TDO, LSB first
        bit [63:0]   written;        // what went in on TDI, LSB first
        bit          paused;         // the scan was parked in Pause-xR
        bit          updated;        // the scan reached Update-xR
        // the capture sources as they stood at the Capture-xR edge
        bit [REF_BSR_LEN-1:0]  pin_in_at_capture;
        bit [REF_USER_LEN-1:0] user_at_capture;
        // the latches / instruction observed after Update-xR
        bit [REF_BSR_LEN-1:0]  pin_out_after;
        bit [REF_USER_LEN-1:0] user_out_after;
        bit [3:0]              ir_after;

        `uvm_object_utils(jtag_scan_item)
        function new(string name = "jtag_scan_item"); super.new(name); endfunction
    endclass

    typedef uvm_sequencer #(jtag_txn)     jtag_sequencer;
    typedef uvm_sequencer #(jtag_pin_txn) jtag_pin_sequencer;

    // ======================================================================
    // driver - the JTAG bus-functional model
    // ======================================================================
    // Positioning invariant: every task here is entered and left immediately
    // after a rising edge.  A clocking-block drive issued there lands one
    // output skew later, so the DUT samples it at the NEXT rising edge - which
    // is the edge the following @(vif.drv_cb) returns on.  That is why
    // tck_cycle can report the TDO belonging to the very cycle it drove.
    class jtag_driver extends uvm_driver #(jtag_txn);
        `uvm_component_utils(jtag_driver)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            jtag_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(jtag_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "jtag_config not set for the TAP driver")
            vif = cfg.vif;
        endfunction

        // One TCK cycle.  Returns the TDO bit that was on the wire during the
        // low phase leading into the edge that sampled (t, d) - which is the
        // bit a real tester reads for this cycle.
        task tck_cycle(input bit t, input bit d, output bit tdo_seen);
            vif.drv_cb.tms <= t;
            vif.drv_cb.tdi <= d;
            @(vif.drv_cb);
            tdo_seen = vif.drv_cb.tdo;
        endtask

        task tck_go(input bit t, input bit d);
            bit unused;
            tck_cycle(t, d, unused);
        endtask

        // Five TMS=1 clocks reach Test-Logic-Reset from every one of the
        // sixteen states - the standard's recoverability guarantee.
        task tms_reset();
            repeat (5) tck_go(1'b1, 1'b0);
        endtask

        // An asynchronous TRST_n pulse.  Two details matter here.
        //
        // TMS is parked high across the pulse, so releasing reset cannot
        // immediately walk the controller out to Run-Test/Idle before anyone
        // has had a chance to look at it.
        //
        // Both edges of the pulse are taken on the FALLING edge of TCK.  TRST_n
        // is asynchronous, so the monitor has to read it as a plain signal
        // rather than through a clocking block; moving it at a rising edge
        // would put the monitor's sample and the driver's assignment in the
        // same timestep and let process order decide what the scoreboard sees.
        task trst_pulse();
            tck_go(1'b1, 1'b0);
            @(negedge vif.tck);
            vif.trst_n = 1'b0;
            repeat (2) @(negedge vif.tck);
            vif.trst_n = 1'b1;
            @(vif.drv_cb);                 // realign to the clocking block
        endtask

        // Shift n bits through whatever register the latched instruction put
        // in the path.  The final cycle carries TMS=1, so the last bit goes in
        // on the way out to Exit1-xR - that is how JTAG fits n bits into n
        // clocks instead of n+1.
        task shift_bits(input  bit [63:0]    dout,
                        input  int unsigned  n,
                        output bit [63:0]    din);
            bit b;
            din = 64'h0;
            for (int i = 0; i < n; i++) begin
                tck_cycle((i == n-1) ? 1'b1 : 1'b0, dout[i], b);
                din[i] = b;
            end
        endtask

        // The same shift, parked in Pause-xR after `at` bits.  Getting this
        // right needs both halves of the standard's small print: the
        // Shift -> Exit1 transition still shifts, and Exit2 -> Shift does not.
        task shift_bits_paused(input  bit [63:0]   dout,
                               input  int unsigned n,
                               input  int unsigned at,
                               input  int unsigned hold,
                               output bit [63:0]   din);
            bit b;
            din = 64'h0;
            for (int i = 0; i < at; i++) begin
                tck_cycle((i == at-1) ? 1'b1 : 1'b0, dout[i], b);
                din[i] = b;
            end
            tck_go(1'b0, 1'b0);                    // Exit1 -> Pause
            repeat (hold) tck_go(1'b0, 1'b0);      // hold
            tck_go(1'b1, 1'b0);                    // -> Exit2
            tck_go(1'b0, 1'b0);                    // -> Shift (no shift here)
            for (int i = at; i < n; i++) begin
                tck_cycle((i == n-1) ? 1'b1 : 1'b0, dout[i], b);
                din[i] = b;
            end
        endtask

        task drive(jtag_txn req);
            bit [63:0] din;
            case (req.kind)
                JT_TRST     : trst_pulse();
                JT_TMS_RESET: tms_reset();
                JT_IDLE     : repeat (req.idle_cycles) tck_go(1'b0, 1'b0);

                JT_SCAN_IR: begin
                    tck_go(1'b1, 1'b0);            // -> Select-DR-Scan
                    tck_go(1'b1, 1'b0);            // -> Select-IR-Scan
                    tck_go(1'b0, 1'b0);            // -> Capture-IR
                    tck_go(1'b0, 1'b0);            // -> Shift-IR
                    if (req.do_pause)
                        shift_bits_paused({60'h0, req.ir}, 4,
                                          (req.pause_at > 3) ? 3 : req.pause_at,
                                          req.pause_hold, din);
                    else
                        shift_bits({60'h0, req.ir}, 4, din);
                    tck_go(1'b1, 1'b0);            // Exit1-IR -> Update-IR
                    tck_go(1'b0, 1'b0);            // -> Run-Test/Idle
                end

                JT_SCAN_DR: begin
                    tck_go(1'b1, 1'b0);            // -> Select-DR-Scan
                    tck_go(1'b0, 1'b0);            // -> Capture-DR
                    tck_go(1'b0, 1'b0);            // -> Shift-DR
                    if (req.do_pause)
                        shift_bits_paused(req.payload, req.nbits, req.pause_at,
                                          req.pause_hold, din);
                    else
                        shift_bits(req.payload, req.nbits, din);
                    tck_go(1'b1, 1'b0);            // Exit1-DR -> Update-DR
                    tck_go(1'b0, 1'b0);            // -> Run-Test/Idle
                end

                JT_RAW: begin
                    // No structure at all.  The cycle-exact scoreboard is
                    // driven off the pins rather than off the testbench's
                    // intent, so an unstructured TMS stream is legal stimulus -
                    // and it reaches corners no directed scan visits: scans
                    // abandoned mid-chain, Select-IR-Scan taken straight back
                    // to Test-Logic-Reset, long stays in Pause.
                    for (int i = 0; i < req.raw_n; i++)
                        tck_go(req.raw_tms[i], req.raw_tdi[i]);
                end

                default: tck_go(1'b0, 1'b0);
            endcase
        endtask

        task run_phase(uvm_phase phase);
            jtag_txn req;
            vif.trst_n = 1'b0;
            vif.tms    = 1'b1;
            vif.tdi    = 1'b0;
            repeat (3) @(negedge vif.tck);
            vif.trst_n = 1'b1;
            @(vif.drv_cb);                 // align to the clocking block
            forever begin
                seq_item_port.get_next_item(req);
                drive(req);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ======================================================================
    // pin driver - the mission logic that will not hold still
    // ======================================================================
    class jtag_pin_driver extends uvm_driver #(jtag_pin_txn);
        `uvm_component_utils(jtag_pin_driver)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            jtag_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(jtag_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "jtag_config not set for the pin driver")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            jtag_pin_txn req;
            vif.pin_cb.pin_in       <= '0;
            vif.pin_cb.user_capture <= '0;
            @(vif.pin_cb);
            forever begin
                seq_item_port.try_next_item(req);
                if (req == null) begin
                    @(vif.pin_cb);         // nothing asked for: hold the vector
                end else begin
                    vif.pin_cb.pin_in       <= req.pin_in;
                    vif.pin_cb.user_capture <= req.user_capture;
                    repeat (req.hold) @(vif.pin_cb);
                    seq_item_port.item_done();
                end
            end
        endtask
    endclass

    // ======================================================================
    // pin-level monitor
    // ======================================================================
    class jtag_pin_monitor extends uvm_monitor;
        `uvm_component_utils(jtag_pin_monitor)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;
        uvm_analysis_port #(jtag_cycle_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            jtag_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(jtag_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "jtag_config not set for the pin monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            bit was_reset = 1'b1;
            forever begin
                @(vif.mon_cb);
                if (vif.trst_n !== 1'b1) begin
                    // Reset is asynchronous, so nothing about this cycle is
                    // predictable; note it and rejoin on the next clean edge.
                    was_reset = 1'b1;
                    continue;
                end
                begin
                    jtag_cycle_item t = jtag_cycle_item::type_id::create("t");
                    t.tms          = vif.mon_cb.tms;
                    t.tdi          = vif.mon_cb.tdi;
                    t.pin_in       = vif.mon_cb.pin_in;
                    t.user_capture = vif.mon_cb.user_capture;
                    t.state        = vif.mon_cb.state;
                    t.ir_shift     = vif.mon_cb.ir_shift;
                    t.ir_latched   = vif.mon_cb.ir_latched;
                    t.tdo          = vif.mon_cb.tdo;
                    t.tdo_en       = vif.mon_cb.tdo_en;
                    t.pin_out      = vif.mon_cb.pin_out;
                    t.pin_oe       = vif.mon_cb.pin_oe;
                    t.user_out     = vif.mon_cb.user_out;
                    t.resync       = was_reset;
                    was_reset      = 1'b0;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ======================================================================
    // scan monitor - the protocol-level view
    // ----------------------------------------------------------------------
    // Reassembles complete IR and DR scans out of the state sequence, with no
    // knowledge of what the driver intended.  It has to be built on the state
    // the DUT was in when each edge arrived (the pre-edge sample), because
    // that is the state whose action the edge performs: an edge taken with
    // Shift-DR current is an edge that shifts.
    // ======================================================================
    class jtag_scan_monitor extends uvm_monitor;
        `uvm_component_utils(jtag_scan_monitor)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;
        uvm_analysis_port #(jtag_scan_item) ap;

        int n_abandoned = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            jtag_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(jtag_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "jtag_config not set for the scan monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            bit            active = 1'b0;
            jtag_scan_item cur;
            bit [3:0]      s;

            forever begin
                @(vif.mon_cb);
                if (vif.trst_n !== 1'b1) begin
                    if (active) n_abandoned++;
                    active = 1'b0;
                    continue;
                end

                s = vif.mon_cb.state;

                // ---- a scan begins at Capture-xR ----
                if (s == R_CAPTURE_DR || s == R_CAPTURE_IR) begin
                    if (active) n_abandoned++;
                    cur                   = jtag_scan_item::type_id::create("cur");
                    cur.is_ir             = (s == R_CAPTURE_IR);
                    cur.instr             = vif.mon_cb.ir_latched;
                    cur.chain             = ref_chain(vif.mon_cb.ir_latched);
                    cur.nbits             = 0;
                    cur.captured          = 64'h0;
                    cur.written           = 64'h0;
                    cur.paused            = 1'b0;
                    cur.updated           = 1'b0;
                    cur.pin_in_at_capture = vif.mon_cb.pin_in;
                    cur.user_at_capture   = vif.mon_cb.user_capture;
                    active                = 1'b1;
                end
                else if (active) begin
                    // ---- each edge taken in Shift-xR moves one bit ----
                    if ((s == R_SHIFT_DR && !cur.is_ir) ||
                        (s == R_SHIFT_IR &&  cur.is_ir)) begin
                        if (cur.nbits < 64) begin
                            cur.captured[cur.nbits] = vif.mon_cb.tdo;
                            cur.written [cur.nbits] = vif.mon_cb.tdi;
                        end
                        cur.nbits++;
                    end
                    else if (s == R_PAUSE_DR || s == R_PAUSE_IR) begin
                        cur.paused = 1'b1;
                    end
                    // ---- an edge taken in Update-xR ends it: the latches
                    //      loaded at the falling edge inside that state, so
                    //      what is sampled here is already the new value ----
                    else if ((s == R_UPDATE_DR && !cur.is_ir) ||
                             (s == R_UPDATE_IR &&  cur.is_ir)) begin
                        cur.updated        = 1'b1;
                        cur.pin_out_after  = vif.mon_cb.pin_out;
                        cur.user_out_after = vif.mon_cb.user_out;
                        cur.ir_after       = vif.mon_cb.ir_latched;
                        active             = 1'b0;
                        ap.write(cur);
                    end
                    // ---- Test-Logic-Reset throws the scan away ----
                    else if (s == R_RESET) begin
                        n_abandoned++;
                        active = 1'b0;
                    end
                end
            end
        endtask

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCANMON", $sformatf(
                "%0d scan(s) abandoned before Update - expected: a random TMS walk starts scans it never finishes",
                n_abandoned), UVM_LOW)
        endfunction
    endclass

    // ======================================================================
    // pin-side monitor - what the mission logic was doing
    // ======================================================================
    class jtag_pin_side_monitor extends uvm_monitor;
        `uvm_component_utils(jtag_pin_side_monitor)
        virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN) vif;
        uvm_analysis_port #(jtag_pin_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            jtag_config cfg;
            super.build_phase(phase);
            if (!uvm_config_db#(jtag_config)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "jtag_config not set for the pin-side monitor")
            vif = cfg.vif;
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.trst_n === 1'b1) begin
                    jtag_pin_txn t = jtag_pin_txn::type_id::create("t");
                    t.pin_in       = vif.mon_cb.pin_in;
                    t.user_capture = vif.mon_cb.user_capture;
                    t.hold         = 1;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ======================================================================
    // the cycle-exact scoreboard
    // ======================================================================
    class jtag_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(jtag_scoreboard)

        uvm_analysis_imp_cyc #(jtag_cycle_item, jtag_scoreboard) cyc_imp;

        ref_tap_t exp;         // the model's state after the last cycle
        bit       primed = 1'b0;
        int       n_cyc = 0, n_err = 0, n_resync = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cyc_imp = new("cyc_imp", this);
        endfunction

        function void err(string tag, string msg);
            n_err++;
            `uvm_error(tag, msg)
        endfunction

        function void write_cyc(jtag_cycle_item t);
            // ---- 1. judge the cycle that just finished ---------------------
            // Skipped on the first item after a reset: at that point the model
            // has not run a cycle yet, so there is no prediction to test.
            if (primed) begin
                if (t.state !== exp.state)
                    err("STATE", $sformatf("state: DUT %s (0x%h), model %s (0x%h)",
                        ref_state_name(t.state), t.state,
                        ref_state_name(exp.state), exp.state));
                if (t.ir_shift !== exp.ir_shift)
                    err("IRSHIFT", $sformatf("IR shift register in %s: DUT 0b%04b, model 0b%04b",
                        ref_state_name(t.state), t.ir_shift, exp.ir_shift));
                if (t.tdo_en !== exp.tdo_en)
                    err("TDOEN", $sformatf("tdo_en in %s: DUT %b, model %b",
                        ref_state_name(t.state), t.tdo_en, exp.tdo_en));
                // TDO only carries meaning while it is driven; off-shift it is
                // a don't-care to whatever is downstream.
                if (exp.tdo_en && (t.tdo !== exp.tdo))
                    err("TDO", $sformatf("TDO in %s (%s): DUT %b, model %b",
                        ref_state_name(t.state), ref_instr_name(t.ir_latched),
                        t.tdo, exp.tdo));
                if (t.ir_latched !== exp.ir_latched)
                    err("IRLATCH", $sformatf("latched instruction in %s: DUT 0b%04b (%s), model 0b%04b (%s)",
                        ref_state_name(t.state), t.ir_latched,
                        ref_instr_name(t.ir_latched), exp.ir_latched,
                        ref_instr_name(exp.ir_latched)));
                if (t.pin_out !== exp.bsr_out)
                    err("PINOUT", $sformatf("boundary update latch in %s: DUT 0x%0h, model 0x%0h",
                        ref_state_name(t.state), t.pin_out, exp.bsr_out));
                if (t.user_out !== exp.user_out)
                    err("USEROUT", $sformatf("user update latch in %s: DUT 0x%0h, model 0x%0h",
                        ref_state_name(t.state), t.user_out, exp.user_out));
                if (t.pin_oe !== exp.pin_oe)
                    err("PINOE", $sformatf("boundary drive in %s (%s): DUT %b, model %b",
                        ref_state_name(t.state), ref_instr_name(t.ir_latched),
                        t.pin_oe, exp.pin_oe));
            end

            // ---- 2. rearm after a reset -----------------------------------
            if (t.resync) begin
                exp    = ref_tap_reset();
                primed = 1'b0;
                n_resync++;
                if (t.state !== R_RESET)
                    err("RESET", $sformatf(
                        "TRST_n released but the DUT is in %s, not Test-Logic-Reset",
                        ref_state_name(t.state)));
                if (t.ir_latched !== R_IDCODE_I)
                    err("RESETIR", $sformatf(
                        "reset left 0b%04b latched, not IDCODE", t.ir_latched));
            end

            // ---- 3. step the model with this cycle's stimulus --------------
            exp    = ref_tap_cycle(exp, t.tms, t.tdi, t.pin_in, t.user_capture);
            primed = 1'b1;
            n_cyc++;
        endfunction

        function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            if (n_cyc == 0) begin
                n_err++;
                `uvm_error("NOSTIM", "the scoreboard never saw a single TCK cycle")
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCOREBOARD", $sformatf(
                "%0d TCK cycles compared against the reference model, %0d reset resynchronisation(s)",
                n_cyc, n_resync), UVM_LOW)
            if (n_err == 0) `uvm_info("SCOREBOARD", "cycle-exact check: RESULT: *** PASS ***", UVM_NONE)
            else            `uvm_error("SCOREBOARD", $sformatf(
                                "cycle-exact check: RESULT: *** FAIL *** (%0d mismatches)", n_err))
        endfunction
    endclass

    // ======================================================================
    // the transaction-level scoreboard
    // ----------------------------------------------------------------------
    // Shares no code with the reference model.  It restates the standard's
    // requirements directly against reassembled scans, so that an error in the
    // model cannot hide behind an agreeing DUT.
    // ======================================================================
    class jtag_scan_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(jtag_scan_scoreboard)

        uvm_analysis_imp_scan #(jtag_scan_item, jtag_scan_scoreboard) scan_imp;

        int n_scan = 0, n_ir = 0, n_dr = 0, n_err = 0, n_short = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            scan_imp = new("scan_imp", this);
        endfunction

        function void err(string tag, string msg);
            n_err++;
            `uvm_error(tag, msg)
        endfunction

        // A low mask of n bits.
        function bit [63:0] mask(int unsigned n);
            mask = (n >= 64) ? {64{1'b1}} : ((64'h1 << n) - 64'h1);
        endfunction

        // The contents of a `len`-bit shift register after `n` bits have been
        // shifted in LSB-first: bit j of the register is written bit n-len+j.
        function bit [63:0] tail(bit [63:0] written, int unsigned n,
                                 int unsigned len);
            tail = 64'h0;
            for (int j = 0; j < len; j++)
                if (n >= len - j) tail[j] = written[n - len + j];
        endfunction

        function void write_scan(jtag_scan_item t);
            bit [63:0] want;
            int unsigned len;

            n_scan++;
            if (t.is_ir) n_ir++; else n_dr++;

            if (t.is_ir) begin
                // The standard's liveness probe: the Capture-IR pattern must
                // carry a 1 in its least-significant bit.
                if (t.nbits >= 1 && t.captured[0] !== 1'b1)
                    err("CAPIR", "Capture-IR presented a 0 in the LSB - a tester cannot tell this TAP from a dead chain");
                // Whatever the last four bits shifted in were, that is the
                // instruction that must be latched.
                if (t.nbits >= 4) begin
                    want = tail(t.written, t.nbits, 4);
                    if (t.ir_after !== want[3:0])
                        err("IRLOAD", $sformatf(
                            "a %0d-bit IR scan ending 0b%04b latched 0b%04b",
                            t.nbits, want[3:0], t.ir_after));
                end
                return;
            end

            // ---- a DR scan ----
            len = ref_chain_len(t.instr);
            if (t.nbits < len) begin
                // A short scan is legal stimulus, it just cannot be checked
                // for content: only part of the register came out.
                n_short++;
                return;
            end

            // What came out of TDO in the first `len` bits is the register's
            // captured contents, and every chain has a defined capture source.
            case (t.chain)
                R_CH_IDCODE: begin
                    want = {32'h0, REF_IDCODE[31:1], 1'b1};
                    if ((t.captured & mask(32)) !== (want & mask(32)))
                        err("IDCODE", $sformatf(
                            "IDCODE scan returned 0x%08h, expected 0x%08h",
                            t.captured[31:0], want[31:0]));
                    if (t.captured[0] !== 1'b1)
                        err("IDLSB", "IDCODE bit 0 came back as 0 - IEEE 1149.1 requires it to be 1");
                end
                R_CH_BSR: begin
                    want = {{(64-REF_BSR_LEN){1'b0}}, t.pin_in_at_capture};
                    if ((t.captured & mask(len)) !== (want & mask(len)))
                        err("BSRCAP", $sformatf(
                            "the boundary register captured 0x%0h but the pins were 0x%0h",
                            t.captured & mask(len), want & mask(len)));
                    // and what was shifted in must have reached the latch
                    want = tail(t.written, t.nbits, len);
                    if (t.pin_out_after !== want[REF_BSR_LEN-1:0])
                        err("BSRUPD", $sformatf(
                            "Update-DR left the boundary latch at 0x%0h, expected 0x%0h",
                            t.pin_out_after, want[REF_BSR_LEN-1:0]));
                end
                R_CH_USER: begin
                    want = {{(64-REF_USER_LEN){1'b0}}, t.user_at_capture};
                    if ((t.captured & mask(len)) !== (want & mask(len)))
                        err("USERCAP", $sformatf(
                            "the user register captured 0x%0h but its source was 0x%0h",
                            t.captured & mask(len), want & mask(len)));
                    want = tail(t.written, t.nbits, len);
                    if (t.user_out_after !== want[REF_USER_LEN-1:0])
                        err("USERUPD", $sformatf(
                            "Update-DR left the user latch at 0x%0h, expected 0x%0h",
                            t.user_out_after, want[REF_USER_LEN-1:0]));
                end
                default: begin
                    // BYPASS, CLAMP and every unimplemented opcode: exactly
                    // one flip-flop, captured as 0, so an n-bit scan comes back
                    // as the written pattern delayed by one position.
                    if (t.captured[0] !== 1'b0)
                        err("BYPCAP", $sformatf(
                            "BYPASS (%s) captured 1, not 0", ref_instr_name(t.instr)));
                    want = (t.written << 1) & mask(t.nbits);
                    if ((t.captured & mask(t.nbits)) !== want)
                        err("BYPASS", $sformatf(
                            "%s: a %0d-bit scan of 0x%0h returned 0x%0h, expected 0x%0h (one bit of delay)",
                            ref_instr_name(t.instr), t.nbits,
                            t.written & mask(t.nbits),
                            t.captured & mask(t.nbits), want));
                end
            endcase
        endfunction

        function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            if (n_scan == 0) begin
                n_err++;
                `uvm_error("NOSCAN", "not one complete scan was ever observed")
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCANSB", $sformatf(
                "%0d complete scans checked (%0d IR, %0d DR; %0d DR scans too short to check content)",
                n_scan, n_ir, n_dr, n_short), UVM_LOW)
            if (n_err == 0) `uvm_info("SCANSB", "transaction check: RESULT: *** PASS ***", UVM_NONE)
            else            `uvm_error("SCANSB", $sformatf(
                                "transaction check: RESULT: *** FAIL *** (%0d mismatches)", n_err))
        endfunction
    endclass

    // ======================================================================
    // functional coverage
    // ======================================================================
    class jtag_coverage extends uvm_component;
        `uvm_component_utils(jtag_coverage)

        uvm_analysis_imp_covcyc  #(jtag_cycle_item, jtag_coverage) cyc_imp;
        uvm_analysis_imp_covscan #(jtag_scan_item,  jtag_coverage) scan_imp;
        uvm_analysis_imp_covpin  #(jtag_pin_txn,    jtag_coverage) pin_imp;

        jtag_cycle_item ci;
        jtag_scan_item  si;
        jtag_pin_txn    pi;

        // Per-cycle coverage.  cx_state_tms is the important one: the sixteen
        // states crossed with the TMS value taken out of each is exactly the
        // thirty-two arcs of the standard's state diagram, so full coverage
        // here means every legal transition was actually taken.
        covergroup cg_cycle;
            option.per_instance = 1;
            cp_state: coverpoint ci.state {
                bins test_logic_reset = {4'hF};
                bins run_test_idle    = {4'hC};
                bins select_dr        = {4'h7};
                bins capture_dr       = {4'h6};
                bins shift_dr         = {4'h2};
                bins exit1_dr         = {4'h1};
                bins pause_dr         = {4'h3};
                bins exit2_dr         = {4'h0};
                bins update_dr        = {4'h5};
                bins select_ir        = {4'h4};
                bins capture_ir       = {4'hE};
                bins shift_ir         = {4'hA};
                bins exit1_ir         = {4'h9};
                bins pause_ir         = {4'hB};
                bins exit2_ir         = {4'h8};
                bins update_ir        = {4'hD};
            }
            cp_tms:    coverpoint ci.tms;
            cp_oe:     coverpoint ci.pin_oe;
            cp_tdo_en: coverpoint ci.tdo_en;
            cx_state_tms: cross cp_state, cp_tms;    // the 32 diagram arcs
        endgroup

        // Per-scan coverage: what was scanned, how long, and whether the scan
        // was parked partway through.
        covergroup cg_scan;
            option.per_instance = 1;
            cp_instr: coverpoint si.instr { bins op[] = {[0:15]}; }
            cp_chain: coverpoint si.chain {
                bins bypass = {R_CH_BYPASS};
                bins idcode = {R_CH_IDCODE};
                bins bsr    = {R_CH_BSR};
                bins user   = {R_CH_USER};
            }
            cp_is_ir:  coverpoint si.is_ir;
            cp_paused: coverpoint si.paused;
            // Exactly the chain length, one bit over, well over, and short of
            // it: the boundaries where a shift path saturates or wraps wrong.
            cp_len: coverpoint si.nbits {
                bins one       = {1};
                bins short_    = {[2:3]};
                bins nibble    = {4};
                bins byte_     = {8};
                bins nine      = {9};
                bins mid       = {[10:31]};
                bins word      = {32};
                bins over_word = {[33:64]};
                bins other     = default;
            }
            cx_instr_paused: cross cp_instr, cp_paused;
            cx_chain_len:    cross cp_chain, cp_len;
            cx_ir_paused:    cross cp_is_ir, cp_paused;
        endgroup

        // The capture sources have to be seen at their extremes too: an
        // all-zero boundary would let a stuck-at-0 capture path pass.
        covergroup cg_pin;
            option.per_instance = 1;
            cp_pin_in: coverpoint pi.pin_in {
                bins zero  = {0};
                bins ones  = {(1 << REF_BSR_LEN) - 1};
                bins other = default;
            }
            cp_user: coverpoint pi.user_capture {
                bins zero  = {0};
                bins ones  = {(1 << REF_USER_LEN) - 1};
                bins other = default;
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cyc_imp  = new("cyc_imp",  this);
            scan_imp = new("scan_imp", this);
            pin_imp  = new("pin_imp",  this);
            cg_cycle = new();
            cg_scan  = new();
            cg_pin   = new();
        endfunction

        function void write_covcyc(jtag_cycle_item t);
            ci = t;
            cg_cycle.sample();
        endfunction

        function void write_covscan(jtag_scan_item t);
            si = t;
            cg_scan.sample();
        endfunction

        function void write_covpin(jtag_pin_txn t);
            pi = t;
            cg_pin.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("COVERAGE", $sformatf("state / transition coverage : %.2f%%",
                                            cg_cycle.get_inst_coverage()), UVM_LOW)
            `uvm_info("COVERAGE", $sformatf("scan coverage               : %.2f%%",
                                            cg_scan.get_inst_coverage()), UVM_LOW)
            `uvm_info("COVERAGE", $sformatf("capture-source coverage     : %.2f%%",
                                            cg_pin.get_inst_coverage()), UVM_LOW)
        endfunction
    endclass

    // ======================================================================
    // agents
    // ======================================================================
    class jtag_agent extends uvm_agent;
        `uvm_component_utils(jtag_agent)
        jtag_sequencer    sqr;
        jtag_driver       drv;
        jtag_pin_monitor  pin_mon;
        jtag_scan_monitor scan_mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr      = jtag_sequencer::type_id::create("sqr", this);
            drv      = jtag_driver::type_id::create("drv", this);
            pin_mon  = jtag_pin_monitor::type_id::create("pin_mon", this);
            scan_mon = jtag_scan_monitor::type_id::create("scan_mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class jtag_pin_agent extends uvm_agent;
        `uvm_component_utils(jtag_pin_agent)
        jtag_pin_sequencer     sqr;
        jtag_pin_driver        drv;
        jtag_pin_side_monitor  mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = jtag_pin_sequencer::type_id::create("sqr", this);
            drv = jtag_pin_driver::type_id::create("drv", this);
            mon = jtag_pin_side_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ======================================================================
    // virtual sequencer + env
    // ======================================================================
    class jtag_vseqr extends uvm_sequencer #(uvm_sequence_item);
        `uvm_component_utils(jtag_vseqr)
        jtag_sequencer     tap_sqr;
        jtag_pin_sequencer pin_sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    class jtag_env extends uvm_env;
        `uvm_component_utils(jtag_env)
        jtag_agent           tap_agent;
        jtag_pin_agent       pin_agent;
        jtag_scoreboard      sb;
        jtag_scan_scoreboard scan_sb;
        jtag_coverage        cov;
        jtag_vseqr           vseqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            tap_agent = jtag_agent::type_id::create("tap_agent", this);
            pin_agent = jtag_pin_agent::type_id::create("pin_agent", this);
            sb        = jtag_scoreboard::type_id::create("sb", this);
            scan_sb   = jtag_scan_scoreboard::type_id::create("scan_sb", this);
            cov       = jtag_coverage::type_id::create("cov", this);
            vseqr     = jtag_vseqr::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            tap_agent.pin_mon.ap.connect(sb.cyc_imp);
            tap_agent.pin_mon.ap.connect(cov.cyc_imp);
            tap_agent.scan_mon.ap.connect(scan_sb.scan_imp);
            tap_agent.scan_mon.ap.connect(cov.scan_imp);
            pin_agent.mon.ap.connect(cov.pin_imp);
            vseqr.tap_sqr = tap_agent.sqr;
            vseqr.pin_sqr = pin_agent.sqr;
        endfunction
    endclass

    // ======================================================================
    // sequences - the TAP side
    // ======================================================================
    class jtag_base_seq extends uvm_sequence #(jtag_txn);
        `uvm_object_utils(jtag_base_seq)
        function new(string name = "jtag_base_seq"); super.new(name); endfunction

        task trst();
            jtag_txn t = jtag_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { kind == JT_TRST; })
                `uvm_fatal("RAND", "TRST item failed to randomize")
            finish_item(t);
        endtask

        task tms_reset();
            jtag_txn t = jtag_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { kind == JT_TMS_RESET; })
                `uvm_fatal("RAND", "TMS-reset item failed to randomize")
            finish_item(t);
        endtask

        task idle(int unsigned n = 1);
            jtag_txn t = jtag_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { kind == JT_IDLE; idle_cycles == n; })
                `uvm_fatal("RAND", "idle item failed to randomize")
            finish_item(t);
        endtask

        task scan_ir(bit [3:0] op, bit pause = 1'b0);
            jtag_txn t = jtag_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { kind == JT_SCAN_IR; ir == op;
                                      do_pause == pause; })
                `uvm_fatal("RAND", "IR-scan item failed to randomize")
            finish_item(t);
        endtask

        // n == 0 asks for exactly the selected chain's length; anything shorter
        // than the chain is rounded up to it, since a scan that cannot even
        // empty the register has no content to check.
        task scan_dr(bit [3:0] op, bit [63:0] data, int unsigned n = 0,
                     bit pause = 1'b0, int unsigned hold = 2);
            jtag_txn t = jtag_txn::type_id::create("t");
            int len   = ref_chain_len(op);
            int extra = (n <= len) ? 0 : (int'(n) - len);
            start_item(t);
            if (!t.randomize() with { kind == JT_SCAN_DR; ir == op;
                                      payload == data; extra_bits == extra;
                                      do_pause == pause; pause_hold == hold; })
                `uvm_fatal("RAND", "DR-scan item failed to randomize")
            finish_item(t);
        endtask

        task raw_walk();
            jtag_txn t = jtag_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { kind == JT_RAW; })
                `uvm_fatal("RAND", "raw-walk item failed to randomize")
            finish_item(t);
        endtask
    endclass

    // Reset, both ways the standard provides, and the state each leaves.
    class jtag_reset_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_reset_seq)
        function new(string name = "jtag_reset_seq"); super.new(name); endfunction
        task body();
            trst();
            idle(2);
            tms_reset();
            idle(2);
        endtask
    endclass

    // IDCODE with no IR scan in front of it: after reset the TAP must already
    // be able to identify itself, which is how a tester discovers an unknown
    // device on a board.
    class jtag_idcode_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_idcode_seq)
        function new(string name = "jtag_idcode_seq"); super.new(name); endfunction
        task body();
            trst();
            idle(1);
            scan_dr(R_IDCODE_I, 64'h0, 32);
            scan_dr(R_IDCODE_I, 64'hFFFF_FFFF, 34);   // longer than the chain
        endtask
    endclass

    // Every one of the sixteen opcodes, each followed by a scan of exactly the
    // chain it selects and one a couple of bits longer.  The ten unimplemented
    // opcodes are the point: all of them must behave as BYPASS.
    class jtag_opcode_sweep_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_opcode_sweep_seq)
        function new(string name = "jtag_opcode_sweep_seq"); super.new(name); endfunction
        task body();
            tms_reset();
            idle(1);
            for (int op = 0; op < 16; op++) begin
                scan_ir(op[3:0]);
                scan_dr(op[3:0], 64'h5A5A_5A5A_5A5A_5A5A);
                scan_dr(op[3:0], 64'h3C3C_3C3C_3C3C_3C3C,
                        ref_chain_len(op[3:0]) + 3);
            end
        endtask
    endclass

    // BYPASS is one flip-flop and nothing else: a scan comes back as the
    // pattern delayed by exactly one bit position.
    class jtag_bypass_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_bypass_seq)
        function new(string name = "jtag_bypass_seq"); super.new(name); endfunction
        task body();
            scan_ir(R_BYPASS);
            scan_dr(R_BYPASS, 64'h0000_00B5, 9);
            scan_dr(R_BYPASS, 64'hFFFF_FFFF, 16);
            scan_dr(R_BYPASS, 64'h0, 1);            // the minimum scan there is
        endtask
    endclass

    // SAMPLE/PRELOAD then EXTEST, which is the actual board-test flow: sample
    // the pins, preload the value to drive, then switch the drive on.  The
    // value EXTEST puts out has to be the one PRELOAD left behind.
    class jtag_boundary_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_boundary_seq)
        function new(string name = "jtag_boundary_seq"); super.new(name); endfunction
        task body();
            scan_ir(R_SAMPLE);
            scan_dr(R_SAMPLE, 64'h0000_005C);
            scan_ir(R_EXTEST);                       // drive turns on here
            scan_dr(R_EXTEST, 64'h0000_00E1);
            scan_dr(R_EXTEST, 64'h0000_001F, 0, 1'b1, 3);   // parked partway
            scan_ir(R_CLAMP);                        // one-bit DR, drive stays on
            scan_dr(R_CLAMP, 64'h0000_0017, 5);
            scan_ir(R_SAMPLE);                       // drive turns off again
            scan_dr(R_SAMPLE, 64'h0000_00A5);
        endtask
    endclass

    // The user register, and the proof that scanning it leaves the boundary
    // latch alone - which is the whole reason PRELOAD is useful.
    class jtag_user_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_user_seq)
        function new(string name = "jtag_user_seq"); super.new(name); endfunction
        task body();
            scan_ir(R_SAMPLE);
            scan_dr(R_SAMPLE, 64'h0000_0042);        // preload the boundary
            scan_ir(R_USER);
            scan_dr(R_USER, 64'h0000_0099);          // an unrelated chain moves
            scan_ir(R_IDCODE_I);
            scan_dr(R_IDCODE_I, 64'h0, 32);          // and another
            scan_ir(R_EXTEST);                       // 0x42 must still be there
            idle(2);
        endtask
    endclass

    // Park every scan in a Pause state.  A tester that steps away mid-chain
    // must not lose a bit, which needs both halves of the standard's small
    // print about which transitions shift and which do not.
    class jtag_pause_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_pause_seq)
        function new(string name = "jtag_pause_seq"); super.new(name); endfunction
        task body();
            scan_ir(R_SAMPLE, 1'b1);                       // Pause-IR
            scan_dr(R_SAMPLE, 64'h0000_0096, 0, 1'b1, 0);  // Pause-DR, no hold
            scan_dr(R_SAMPLE, 64'h0000_0069, 0, 1'b1, 5);  // a long park
            scan_ir(R_IDCODE_I, 1'b1);
            scan_dr(R_IDCODE_I, 64'h0, 32, 1'b1, 3);       // park a long scan
            scan_ir(R_BYPASS, 1'b1);
        endtask
    endclass

    // Unstructured TMS/TDI.  Against a cycle-exact scoreboard this is the
    // strongest stimulus in the file: it abandons scans mid-chain, takes
    // Select-IR-Scan straight back to Test-Logic-Reset, and lingers in states
    // no directed sequence bothers to visit.
    class jtag_tms_walk_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_tms_walk_seq)
        rand int unsigned n;
        constraint c_n { n inside {[20:60]}; }
        function new(string name = "jtag_tms_walk_seq"); super.new(name); endfunction
        task body();
            repeat (n) raw_walk();
            tms_reset();
            idle(1);
        endtask
    endclass

    // Fully random transactions - random opcodes, random payloads, random scan
    // lengths, random parks, the occasional reset.
    class jtag_rand_seq extends jtag_base_seq;
        `uvm_object_utils(jtag_rand_seq)
        rand int unsigned n;
        constraint c_n { n inside {[60:120]}; }
        function new(string name = "jtag_rand_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                jtag_txn t = jtag_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_fatal("RAND", "random TAP item failed to randomize")
                finish_item(t);
            end
            tms_reset();
        endtask
    endclass

    // ======================================================================
    // sequences - the system-pin side
    // ======================================================================
    class jtag_pin_hold_seq extends uvm_sequence #(jtag_pin_txn);
        `uvm_object_utils(jtag_pin_hold_seq)
        rand bit [REF_BSR_LEN-1:0]  val;
        rand bit [REF_USER_LEN-1:0] uval;
        function new(string name = "jtag_pin_hold_seq"); super.new(name); endfunction
        task body();
            jtag_pin_txn t = jtag_pin_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { pin_in == val; user_capture == uval;
                                      hold == 4; })
                `uvm_fatal("RAND", "pin-hold item failed to randomize")
            finish_item(t);
        endtask
    endclass

    // The mission logic, refusing to hold still.  Runs alongside the TAP agent
    // for the whole random phase, so a Capture-DR has to grab whatever happened
    // to be on the boundary at that exact edge.
    //
    // Both this and jtag_pin_static_seq below run forever, and the virtual
    // sequence kills them with `disable fork` when the TAP side is done.  That
    // is deliberate: a pin sequence with a fixed length would either run out
    // early and leave the boundary frozen, or outlive its phase and hold the
    // pin sequencer against the next one.  The TAP side decides how long a
    // phase lasts; the pin side just keeps up.
    class jtag_pin_wiggle_seq extends uvm_sequence #(jtag_pin_txn);
        `uvm_object_utils(jtag_pin_wiggle_seq)
        function new(string name = "jtag_pin_wiggle_seq"); super.new(name); endfunction
        task body();
            // The extremes first: an all-zero boundary would let a stuck-at-0
            // capture path pass unnoticed, and so would an all-ones one.
            begin
                jtag_pin_txn t0 = jtag_pin_txn::type_id::create("t0");
                start_item(t0);
                if (!t0.randomize() with { pin_in == 0; user_capture == 0;
                                           hold == 3; })
                    `uvm_fatal("RAND", "pin item failed to randomize")
                finish_item(t0);
            end
            begin
                jtag_pin_txn t1 = jtag_pin_txn::type_id::create("t1");
                start_item(t1);
                if (!t1.randomize() with {
                        pin_in == (1 << REF_BSR_LEN) - 1;
                        user_capture == (1 << REF_USER_LEN) - 1;
                        hold == 3; })
                    `uvm_fatal("RAND", "pin item failed to randomize")
                finish_item(t1);
            end
            forever begin
                jtag_pin_txn t = jtag_pin_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_fatal("RAND", "pin item failed to randomize")
                finish_item(t);
            end
        endtask
    endclass

    // A quiet, known boundary for the directed sequences that check exact
    // captured values: they have to be able to name what they expect to see
    // come out of TDO, which is only possible if the source holds still.
    class jtag_pin_static_seq extends uvm_sequence #(jtag_pin_txn);
        `uvm_object_utils(jtag_pin_static_seq)
        function new(string name = "jtag_pin_static_seq"); super.new(name); endfunction
        task body();
            forever begin
                jtag_pin_txn t = jtag_pin_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { pin_in == 8'hA5; user_capture == 8'h77;
                                          hold == 8; })
                    `uvm_fatal("RAND", "static pin item failed to randomize")
                finish_item(t);
            end
        endtask
    endclass

    // ======================================================================
    // virtual sequences
    // ======================================================================
    class jtag_smoke_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(jtag_smoke_vseq)
        `uvm_declare_p_sequencer(jtag_vseqr)
        function new(string name = "jtag_smoke_vseq"); super.new(name); endfunction
        task body();
            jtag_pin_static_seq  p  = jtag_pin_static_seq::type_id::create("p");
            jtag_reset_seq       s0 = jtag_reset_seq::type_id::create("s0");
            jtag_idcode_seq      s1 = jtag_idcode_seq::type_id::create("s1");
            jtag_bypass_seq      s2 = jtag_bypass_seq::type_id::create("s2");
            jtag_boundary_seq    s3 = jtag_boundary_seq::type_id::create("s3");
            `uvm_info("SMOKE", "reset, IDCODE, BYPASS, then the board-test flow, on a static boundary", UVM_LOW)
            // The pin sequence runs forever, parking a known vector on the
            // boundary so the directed checks can name the value they expect to
            // see captured.  join_any returns when the TAP branch is done and
            // disable fork retires the pin branch with it.
            fork
                p.start(p_sequencer.pin_sqr);
                begin
                    s0.start(p_sequencer.tap_sqr);
                    s1.start(p_sequencer.tap_sqr);
                    s2.start(p_sequencer.tap_sqr);
                    s3.start(p_sequencer.tap_sqr);
                end
            join_any
            disable fork;
        endtask
    endclass

    class jtag_regress_vseq extends uvm_sequence #(uvm_sequence_item);
        `uvm_object_utils(jtag_regress_vseq)
        `uvm_declare_p_sequencer(jtag_vseqr)
        function new(string name = "jtag_regress_vseq"); super.new(name); endfunction
        task body();
            jtag_pin_static_seq   ps = jtag_pin_static_seq::type_id::create("ps");
            jtag_pin_wiggle_seq   pw = jtag_pin_wiggle_seq::type_id::create("pw");
            jtag_reset_seq        s0 = jtag_reset_seq::type_id::create("s0");
            jtag_idcode_seq       s1 = jtag_idcode_seq::type_id::create("s1");
            jtag_bypass_seq       s2 = jtag_bypass_seq::type_id::create("s2");
            jtag_boundary_seq     s3 = jtag_boundary_seq::type_id::create("s3");
            jtag_user_seq         s4 = jtag_user_seq::type_id::create("s4");
            jtag_pause_seq        s5 = jtag_pause_seq::type_id::create("s5");
            jtag_opcode_sweep_seq s6 = jtag_opcode_sweep_seq::type_id::create("s6");
            jtag_tms_walk_seq     s7 = jtag_tms_walk_seq::type_id::create("s7");
            jtag_rand_seq         s8 = jtag_rand_seq::type_id::create("s8");

            // ---- phase 1: directed, against a known static boundary ----
            // The exact-value checks need to name what they expect captured,
            // so the boundary is held still for them.
            `uvm_info("REGRESS", "phase 1: directed scans against a static boundary", UVM_LOW)
            fork
                ps.start(p_sequencer.pin_sqr);
                begin
                    s0.start(p_sequencer.tap_sqr);
                    s1.start(p_sequencer.tap_sqr);
                    s2.start(p_sequencer.tap_sqr);
                    s3.start(p_sequencer.tap_sqr);
                    s4.start(p_sequencer.tap_sqr);
                    s5.start(p_sequencer.tap_sqr);
                    s6.start(p_sequencer.tap_sqr);
                end
            join_any
            disable fork;

            // ---- phase 2: two agents running against each other ----
            // From here the mission-side pins move underneath the scans, which
            // is the interleaving a single-agent testbench never produces: a
            // Capture-DR now grabs whatever the pin agent happened to be
            // presenting at that exact edge, and the scoreboard has to have
            // sampled the same thing.
            `uvm_info("REGRESS", "phase 2: random scans against a moving boundary", UVM_LOW)
            fork
                pw.start(p_sequencer.pin_sqr);
                begin
                    s7.start(p_sequencer.tap_sqr);
                    repeat (3) begin
                        if (!s8.randomize())
                            `uvm_fatal("RAND", "random sequence failed to randomize")
                        s8.start(p_sequencer.tap_sqr);
                        if (!s7.randomize())
                            `uvm_fatal("RAND", "walk sequence failed to randomize")
                        s7.start(p_sequencer.tap_sqr);
                    end
                end
            join_any
            disable fork;
        endtask
    endclass

    // ======================================================================
    // tests
    // ======================================================================
    class jtag_base_test extends uvm_test;
        `uvm_component_utils(jtag_base_test)
        jtag_env    env;
        jtag_config cfg;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            cfg = jtag_config::type_id::create("cfg");
            if (!uvm_config_db#(virtual jtag_tap_if #(REF_BSR_LEN, REF_USER_LEN))::get(
                    this, "", "vif", cfg.vif))
                `uvm_fatal("NOVIF", "virtual interface not set for the test")
            uvm_config_db#(jtag_config)::set(this, "*", "cfg", cfg);
            env = jtag_env::type_id::create("env", this);
        endfunction

        // What checks the checker.  The reference model re-proves the
        // standard's mandatory properties - five TMS=1 clocks reaching
        // Test-Logic-Reset from all sixteen states, every state reachable,
        // Capture-IR's LSB, every unimplemented opcode landing on BYPASS, and
        // an end-to-end scan of each chain - before a single DUT result is
        // judged against it.
        function void start_of_simulation_phase(uvm_phase phase);
            int bad;
            super.start_of_simulation_phase(phase);
            bad = ref_selfcheck(1'b1);
            if (bad != 0)
                `uvm_fatal("REFMODEL", $sformatf(
                    "the reference model failed its own self-check (%0d problems) - no DUT result can be trusted until that is fixed",
                    bad))
        endfunction
    endclass

    class jtag_tap_smoke_test extends jtag_base_test;
        `uvm_component_utils(jtag_tap_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            jtag_smoke_vseq vseq = jtag_smoke_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            repeat (20) @(posedge cfg.vif.tck);
            phase.drop_objection(this);
        endtask
    endclass

    class jtag_tap_regress_test extends jtag_base_test;
        `uvm_component_utils(jtag_tap_regress_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            jtag_regress_vseq vseq = jtag_regress_vseq::type_id::create("vseq");
            phase.raise_objection(this);
            vseq.start(env.vseqr);
            repeat (20) @(posedge cfg.vif.tck);
            phase.drop_objection(this);
        endtask
    endclass

endpackage : jtag_tap_pkg
