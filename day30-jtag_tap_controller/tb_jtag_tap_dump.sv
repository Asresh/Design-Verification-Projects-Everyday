// ============================================================================
// tb_jtag_tap_dump.sv - the portable, procedural twin of the UVM environment.
// ----------------------------------------------------------------------------
// Icarus Verilog has neither the UVM class library nor a constraint solver, so
// this testbench reproduces what jtag_tap_pkg's environment does using plain
// tasks and a lockstep reference model:
//
//   * a JTAG bus-functional model (step / shift_bits / scan_ir / scan_dr /
//     scan_dr_paused) that navigates the sixteen-state diagram the way a real
//     tester does - TMS driven on the falling edge, TDO read in the low phase;
//   * a CYCLE-EXACT scoreboard: every rising edge the current pin vector is
//     handed to jtag_tap_ref_pkg::ref_tap_cycle, and the model's prediction is
//     compared against the DUT twice - the controller state and IR shift
//     register just after the rising edge, then TDO, the drive enable, the
//     latched instruction and both update latches just after the falling edge.
//     Nothing is sampled loosely and nothing is checked "eventually".
//   * state and transition coverage counters, so the run reports how much of
//     the state diagram it actually walked;
//   * directed scans for every instruction, then a long random TMS/TDI walk.
//
// The random walk is where the value is.  Because the checker is cycle-exact
// and driven off the pins rather than off the testbench's intent, a completely
// unstructured TMS stream is a legal stimulus: it wanders the state diagram,
// starts scans it never finishes, parks in Pause states, re-enters
// Test-Logic-Reset from Select-IR, and the model has to predict every edge of
// it.  A directed test can only check the sequences its author thought of.
//
// The run also dumps a VCD, and marks a showcase window inside it with the
// `mark` signal so docs/make_waveform.py can find the interesting section.
// ============================================================================
`timescale 1ns/1ps

module tb_jtag_tap_dump;

    import jtag_tap_ref_pkg::*;

    localparam int          BSR_LEN  = REF_BSR_LEN;
    localparam int          USER_LEN = REF_USER_LEN;
    localparam logic [31:0] ID       = REF_IDCODE;

    // ---- pins ----
    logic                tck, trst_n, tms, tdi;
    logic                tdo, tdo_en;
    logic [BSR_LEN-1:0]  pin_in, pin_out;
    logic                pin_oe;
    logic [USER_LEN-1:0] user_capture, user_out;
    logic [3:0]          state, ir_shift, ir_latched;

    // ---- testbench bookkeeping ----
    logic       mark;          // showcase-window delimiter for the VCD renderer
    logic       chk_en;        // the cycle-exact checker is armed
    logic       pin_wiggle;    // the system-side pins are being randomised
    ref_tap_t   exp;           // the reference model's state
    int         errors;
    int         n_rise, n_fall;
    int         seed;

    // state and transition coverage: cov_trans is indexed by {state, tms}
    int         cov_state [16];
    int         cov_trans [32];
    int         cov_instr [16];

    // ------------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------------
    jtag_tap #(.IDCODE(ID), .BSR_LEN(BSR_LEN), .USER_LEN(USER_LEN)) dut (
        .tck          (tck),
        .trst_n       (trst_n),
        .tms          (tms),
        .tdi          (tdi),
        .tdo          (tdo),
        .tdo_en       (tdo_en),
        .pin_in       (pin_in),
        .pin_out      (pin_out),
        .pin_oe       (pin_oe),
        .user_capture (user_capture),
        .user_out     (user_out),
        .state_o      (state),
        .ir_shift_o   (ir_shift),
        .ir_latched_o (ir_latched)
    );

    // ------------------------------------------------------------------------
    // TCK: 20 ns period.  Rising edges at 10, 30, 50 ...  falling at 20, 40 ...
    // ------------------------------------------------------------------------
    initial tck = 1'b0;
    always #10 tck = ~tck;

    // ------------------------------------------------------------------------
    // The system-side pins.  A real device's mission logic keeps moving while
    // the TAP is scanned, and the boundary register has to capture whatever is
    // there at the Capture-DR edge - so these are wiggled independently, in
    // the low phase of TCK, well clear of the edge the DUT samples them on.
    // ------------------------------------------------------------------------
    always @(negedge tck) begin
        #2;
        if (pin_wiggle) begin
            pin_in       = $random(seed);
            user_capture = $random(seed);
        end
    end

    // ------------------------------------------------------------------------
    // The cycle-exact scoreboard.
    //
    // Rising edge: the DUT samples TMS/TDI/pin_in/user_capture right here, so
    // the same vector is fed to the model, which returns the complete state of
    // the TAP at the end of this cycle.  What is checkable immediately is
    // whatever the rising edge itself produced.
    // ------------------------------------------------------------------------
    always @(posedge tck) begin
        if (chk_en) begin
            // coverage first: the transition about to be taken
            cov_state[state]                 = cov_state[state] + 1;
            cov_trans[{state, tms}]          = cov_trans[{state, tms}] + 1;
            cov_instr[ir_latched]            = cov_instr[ir_latched] + 1;

            exp = ref_tap_cycle(exp, tms, tdi, pin_in, user_capture);
            n_rise++;
            #1;
            if (state !== exp.state) begin
                errors++;
                $display("[%0t] STATE MISMATCH: DUT %s (0x%h), model %s (0x%h)",
                         $time, ref_state_name(state), state,
                         ref_state_name(exp.state), exp.state);
            end
            if (ir_shift !== exp.ir_shift) begin
                errors++;
                $display("[%0t] IR-SHIFT MISMATCH in %s: DUT 0b%04b, model 0b%04b",
                         $time, ref_state_name(state), ir_shift, exp.ir_shift);
            end
        end
    end

    // ------------------------------------------------------------------------
    // Falling edge: TDO, the drive enable, the latched instruction and the two
    // update latches all settle here, predicted by the same model call.
    // ------------------------------------------------------------------------
    always @(negedge tck) begin
        if (chk_en) begin
            n_fall++;
            #1;
            if (tdo_en !== exp.tdo_en) begin
                errors++;
                $display("[%0t] TDO_EN MISMATCH in %s: DUT %b, model %b",
                         $time, ref_state_name(state), tdo_en, exp.tdo_en);
            end
            // TDO only carries meaning while it is driven; off-shift its value
            // is a don't-care to the outside world, so it is only judged when
            // the enable says someone is listening.
            if (exp.tdo_en && (tdo !== exp.tdo)) begin
                errors++;
                $display("[%0t] TDO MISMATCH in %s (%s): DUT %b, model %b",
                         $time, ref_state_name(state),
                         ref_instr_name(ir_latched), tdo, exp.tdo);
            end
            if (ir_latched !== exp.ir_latched) begin
                errors++;
                $display("[%0t] IR-LATCH MISMATCH in %s: DUT 0b%04b (%s), model 0b%04b (%s)",
                         $time, ref_state_name(state), ir_latched,
                         ref_instr_name(ir_latched), exp.ir_latched,
                         ref_instr_name(exp.ir_latched));
            end
            if (pin_out !== exp.bsr_out) begin
                errors++;
                $display("[%0t] PIN_OUT MISMATCH in %s: DUT 0x%02h, model 0x%02h",
                         $time, ref_state_name(state), pin_out, exp.bsr_out);
            end
            if (user_out !== exp.user_out) begin
                errors++;
                $display("[%0t] USER_OUT MISMATCH in %s: DUT 0x%02h, model 0x%02h",
                         $time, ref_state_name(state), user_out, exp.user_out);
            end
            if (pin_oe !== exp.pin_oe) begin
                errors++;
                $display("[%0t] PIN_OE MISMATCH in %s (%s): DUT %b, model %b",
                         $time, ref_state_name(state),
                         ref_instr_name(ir_latched), pin_oe, exp.pin_oe);
            end
        end
    end

    // ========================================================================
    // JTAG bus-functional model
    // ========================================================================

    // One TCK cycle.  Entered and left in the low phase, just after TDO and
    // the update latches have settled - which is exactly where a tester sits:
    // it drives TMS/TDI on the falling edge and reads TDO before the next
    // rising one.
    task step(input logic t, input logic d);
        tms = t;
        tdi = d;
        @(posedge tck);
        @(negedge tck);
        #3;                    // clear of the checker's and the pin wiggler's
    endtask                    // sampling points

    // Five TMS=1 clocks reach Test-Logic-Reset from anywhere in the diagram.
    task tms_reset();
        repeat (5) step(1'b1, 1'b0);
    endtask

    task to_idle();            // Test-Logic-Reset -> Run-Test/Idle
        step(1'b0, 1'b0);
    endtask

    task idle(input int n);
        repeat (n) step(1'b0, 1'b0);
    endtask

    // Shift n bits through whichever register is in the path.  TDO is read
    // before each cycle, TDI presented with it; the final cycle carries TMS=1
    // so the last bit is shifted in on the way out to Exit1-xR, which is how
    // JTAG gets n bits through in n clocks rather than n+1.
    task shift_bits(input  logic [63:0] dout,
                    input  int          n,
                    input  logic        leave,
                    output logic [63:0] din);
        int i;
        din = 64'h0;
        for (i = 0; i < n; i++) begin
            din[i] = tdo;
            step((i == n-1) ? leave : 1'b0, dout[i]);
        end
    endtask

    // A complete IR scan, Run-Test/Idle to Run-Test/Idle.  din comes back with
    // the Capture-IR pattern, which the standard says must have LSB=1.
    task scan_ir(input logic [3:0] ir, output logic [63:0] din);
        step(1'b1, 1'b0);      // -> Select-DR-Scan
        step(1'b1, 1'b0);      // -> Select-IR-Scan
        step(1'b0, 1'b0);      // -> Capture-IR
        step(1'b0, 1'b0);      // -> Shift-IR (the capture happened on this edge)
        shift_bits({60'h0, ir}, 4, 1'b1, din);
        step(1'b1, 1'b0);      // Exit1-IR -> Update-IR
        step(1'b0, 1'b0);      // -> Run-Test/Idle
    endtask

    // A complete DR scan of n bits, Run-Test/Idle to Run-Test/Idle.
    task scan_dr(input logic [63:0] dout, input int n, output logic [63:0] din);
        step(1'b1, 1'b0);      // -> Select-DR-Scan
        step(1'b0, 1'b0);      // -> Capture-DR
        step(1'b0, 1'b0);      // -> Shift-DR
        shift_bits(dout, n, 1'b1, din);
        step(1'b1, 1'b0);      // Exit1-DR -> Update-DR
        step(1'b0, 1'b0);      // -> Run-Test/Idle
    endtask

    // The same scan, parked in Pause-DR after `at` bits for `hold` clocks.
    // The park has to be transparent: a slow tester stepping away mid-chain
    // must not cost a bit, which means counting the shift that happens on the
    // Shift-DR -> Exit1-DR transition, and knowing that Exit2-DR -> Shift-DR
    // does not shift at all.
    task scan_dr_paused(input  logic [63:0] dout,
                        input  int          n,
                        input  int          at,
                        input  int          hold,
                        output logic [63:0] din);
        int i;
        din = 64'h0;
        step(1'b1, 1'b0);      // -> Select-DR-Scan
        step(1'b0, 1'b0);      // -> Capture-DR
        step(1'b0, 1'b0);      // -> Shift-DR
        for (i = 0; i < at; i++) begin
            din[i] = tdo;
            step((i == at-1) ? 1'b1 : 1'b0, dout[i]);   // last one -> Exit1-DR
        end
        step(1'b0, 1'b0);                     // Exit1-DR -> Pause-DR
        repeat (hold) step(1'b0, 1'b0);       // hold in Pause-DR
        step(1'b1, 1'b0);                     // -> Exit2-DR
        step(1'b0, 1'b0);                     // -> Shift-DR (no shift here)
        for (i = at; i < n; i++) begin
            din[i] = tdo;
            step((i == n-1) ? 1'b1 : 1'b0, dout[i]);
        end
        step(1'b1, 1'b0);      // Exit1-DR -> Update-DR
        step(1'b0, 1'b0);      // -> Run-Test/Idle
    endtask

    // An asynchronous TRST_n pulse, taken in the low phase, with the model
    // resynchronised to the state the standard says reset leaves behind.
    //
    // TMS is parked high across the pulse on purpose.  TRST_n is released in
    // the low phase, and the very next rising edge is a real edge for the
    // controller - with TMS low it would walk straight out to Run-Test/Idle
    // before the checker was rearmed, and the checker would then be blamed for
    // a state the tester asked for.
    task do_trst();
        chk_en = 1'b0;
        tms    = 1'b1;
        trst_n = 1'b0;
        @(negedge tck); #3;        // the reset is asynchronous - already taken
        @(negedge tck); #3;        // hold it low for a full TCK cycle
        trst_n = 1'b1;
        exp    = ref_tap_reset();
        chk_en = 1'b1;
    endtask

    // ========================================================================
    // checks
    // ========================================================================
    task expect_eq(input string what, input logic [63:0] got,
                   input logic [63:0] want);
        if (got !== want) begin
            errors++;
            $display("[%0t] CHECK FAILED - %s: got 0x%0h, expected 0x%0h",
                     $time, what, got, want);
        end else begin
            $display("[%0t]   ok  %s = 0x%0h", $time, what, want);
        end
    endtask

    // ========================================================================
    // stimulus
    // ========================================================================
    logic [63:0] rd, cap;
    logic [31:0] idc;
    int          i, k, nstate, ntrans;
    int          refbad;

    initial begin
        $dumpfile("tb_jtag_tap_dump.vcd");
        $dumpvars(0, tb_jtag_tap_dump);

        errors = 0; n_rise = 0; n_fall = 0; seed = 32'h1149_0001;
        mark = 1'b0; chk_en = 1'b0; pin_wiggle = 1'b0;
        tms = 1'b1; tdi = 1'b0; trst_n = 1'b1;
        pin_in = 8'h00; user_capture = 8'h00;
        for (i = 0; i < 16; i++) begin cov_state[i] = 0; cov_instr[i] = 0; end
        for (i = 0; i < 32; i++) cov_trans[i] = 0;
        idc = {ID[31:1], 1'b1};

        $display("============================================================");
        $display(" jtag_tap - IEEE 1149.1 TAP controller, self-checking TB");
        $display(" IDCODE = 0x%08h   BSR_LEN = %0d   USER_LEN = %0d",
                 idc, BSR_LEN, USER_LEN);
        $display("============================================================");

        // ---- what checks the checker ------------------------------------
        // The reference model re-proves the standard's mandatory properties
        // before a single DUT result is judged, so a broken model announces
        // itself instead of quietly agreeing with a broken DUT.
        $display("\n-- reference-model self-check --");
        refbad = ref_selfcheck(1'b1);
        if (refbad != 0) begin
            $display("FATAL: the reference model failed its own self-check (%0d problems) - no DUT result can be trusted",
                     refbad);
            $display("RESULT: *** FAIL ***");
            $finish;
        end

        // ---- 1. asynchronous TRST_n ------------------------------------
        $display("\n-- 1. asynchronous TRST_n --");
        @(negedge tck); #3;
        do_trst();
        expect_eq("state after TRST (Test-Logic-Reset)", state, 4'hF);
        expect_eq("reset instruction is IDCODE",         ir_latched, 4'b0010);
        expect_eq("boundary not driven in reset",        pin_oe, 1'b0);

        // ---- 2. five TMS=1 clocks reach Test-Logic-Reset ---------------
        // From Shift-DR, the deepest point of the diagram, which is the worst
        // case the standard's five-clock guarantee has to cover.
        $display("\n-- 2. five TMS=1 clocks from Shift-DR reach Test-Logic-Reset --");
        to_idle();
        step(1'b1, 1'b0); step(1'b0, 1'b0); step(1'b0, 1'b0);   // -> Shift-DR
        expect_eq("parked in Shift-DR", state, 4'h2);
        tms_reset();
        expect_eq("state after 5x TMS=1", state, 4'hF);
        expect_eq("IR re-armed to IDCODE", ir_latched, 4'b0010);

        // ---- 3. IDCODE, the instruction reset leaves loaded -------------
        // No IR scan first: after reset the TAP must already be able to hand
        // over its identification code, which is how a tester discovers an
        // unknown device.
        $display("\n-- 3. IDCODE read with no IR scan (reset default) --");
        to_idle();
        scan_dr(64'h0, 32, rd);
        expect_eq("IDCODE shifted out", rd[31:0], idc);
        expect_eq("IDCODE bit 0 is 1 (mandatory)", rd[0], 1'b1);

        // ---- 4. Capture-IR must present a 1 in the LSB ------------------
        $display("\n-- 4. Capture-IR pattern --");
        scan_ir(4'b1111, cap);                       // load BYPASS
        expect_eq("Capture-IR pattern", cap[3:0], 4'b0001);
        expect_eq("BYPASS latched", ir_latched, 4'b1111);

        // ---- 5. BYPASS is one bit of delay, nothing more ----------------
        $display("\n-- 5. BYPASS: a single flip-flop in the path --");
        // Capture-DR loads 0 into the BYPASS bit, so a scan of n+1 bits comes
        // back as the pattern delayed by exactly one position.
        scan_dr(64'h0000_00B5, 9, rd);
        expect_eq("BYPASS returns the pattern delayed one bit",
                  rd[8:0], {8'hB5, 1'b0});

        // ---- 6. an unimplemented opcode must behave as BYPASS -----------
        $display("\n-- 6. unimplemented opcode 0b0111 must select BYPASS --");
        scan_ir(4'b0111, cap);
        expect_eq("unimplemented opcode latched verbatim", ir_latched, 4'b0111);
        scan_dr(64'h0000_006D, 9, rd);
        expect_eq("unimplemented opcode scans as BYPASS",
                  rd[8:0], {8'h6D, 1'b0});
        expect_eq("unimplemented opcode does not drive the boundary",
                  pin_oe, 1'b0);

        // ---- 7. SAMPLE/PRELOAD ------------------------------------------
        $display("\n-- 7. SAMPLE/PRELOAD: capture the pins, preload the latch --");
        pin_in = 8'hA5;
        scan_ir(4'b0001, cap);
        expect_eq("SAMPLE/PRELOAD latched", ir_latched, 4'b0001);
        scan_dr(64'h0000_005C, 8, rd);
        expect_eq("SAMPLE captured the system pins", rd[7:0], 8'hA5);
        expect_eq("PRELOAD reached the update latch", pin_out, 8'h5C);
        expect_eq("SAMPLE/PRELOAD does not drive the boundary", pin_oe, 1'b0);

        // ---- 8. EXTEST drives the boundary from that same latch ---------
        $display("\n-- 8. EXTEST drives the boundary --");
        scan_ir(4'b0000, cap);
        expect_eq("EXTEST latched", ir_latched, 4'b0000);
        expect_eq("EXTEST drives the boundary", pin_oe, 1'b1);
        expect_eq("the value PRELOAD left is what EXTEST drives", pin_out, 8'h5C);
        pin_in = 8'h3C;
        scan_dr(64'h0000_00E1, 8, rd);
        expect_eq("EXTEST captured the pins", rd[7:0], 8'h3C);
        expect_eq("EXTEST updated the boundary", pin_out, 8'hE1);

        // ---- 9. CLAMP: BYPASS's register, EXTEST's drive ----------------
        // The one instruction where "which chain is selected" and "is the
        // boundary driving" disagree - a checker built on the assumption that
        // they move together fails right here.
        $display("\n-- 9. CLAMP: a one-bit DR while still driving the boundary --");
        scan_ir(4'b1100, cap);
        expect_eq("CLAMP latched", ir_latched, 4'b1100);
        expect_eq("CLAMP drives the boundary", pin_oe, 1'b1);
        expect_eq("CLAMP holds the last preloaded value", pin_out, 8'hE1);
        scan_dr(64'h0000_0017, 5, rd);
        // 0b10111 through one flip-flop, five bits wide: 0b0111_0.  Had CLAMP
        // wrongly selected the eight-bit boundary register instead, the scan
        // would have come back with the captured pin value in it.
        expect_eq("CLAMP scans through one bit, not eight",
                  rd[4:0], 5'b0_1110);
        expect_eq("a CLAMP scan leaves the boundary alone", pin_out, 8'hE1);

        // ---- 10. the user data register --------------------------------
        $display("\n-- 10. the user data register --");
        user_capture = 8'h77;
        scan_ir(4'b1000, cap);
        scan_dr(64'h0000_0099, 8, rd);
        expect_eq("USER captured its source", rd[7:0], 8'h77);
        expect_eq("USER reached its update latch", user_out, 8'h99);
        expect_eq("a USER scan leaves the boundary latch alone", pin_out, 8'hE1);

        // ---- 11. an unselected register must hold ----------------------
        // PRELOAD's entire purpose is that the value survives an unrelated
        // scan of a different chain.
        $display("\n-- 11. an unselected chain holds while another is scanned --");
        scan_ir(4'b0010, cap);                 // IDCODE
        scan_dr(64'h0, 32, rd);
        expect_eq("IDCODE still reads correctly", rd[31:0], idc);
        expect_eq("the boundary latch was untouched", pin_out, 8'hE1);
        expect_eq("the user latch was untouched",     user_out, 8'h99);

        // ---- 12. Pause-DR is transparent -------------------------------
        $display("\n-- 12. parking in Pause-DR costs no bits --");
        pin_in = 8'h96;
        scan_ir(4'b0001, cap);                 // SAMPLE/PRELOAD
        scan_dr_paused(64'h0000_0042, 8, 3, 4, rd);
        expect_eq("a paused scan still returns the captured pins", rd[7:0], 8'h96);
        expect_eq("a paused scan still reaches the update latch", pin_out, 8'h42);

        // ---- 13. Pause-IR is transparent too ---------------------------
        $display("\n-- 13. parking in Pause-IR --");
        step(1'b1, 1'b0);          // -> Select-DR
        step(1'b1, 1'b0);          // -> Select-IR
        step(1'b0, 1'b0);          // -> Capture-IR
        step(1'b0, 1'b0);          // -> Shift-IR
        cap = 64'h0;
        cap[0] = tdo; step(1'b0, 1'b1);        // IR bit 0 = 1
        cap[1] = tdo; step(1'b1, 1'b1);        // IR bit 1 = 1, -> Exit1-IR
        step(1'b0, 1'b0);                      // -> Pause-IR
        repeat (3) step(1'b0, 1'b0);           // hold
        step(1'b1, 1'b0);                      // -> Exit2-IR
        step(1'b0, 1'b0);                      // -> Shift-IR
        cap[2] = tdo; step(1'b0, 1'b1);        // IR bit 2 = 1
        cap[3] = tdo; step(1'b1, 1'b1);        // IR bit 3 = 1, -> Exit1-IR
        step(1'b1, 1'b0);                      // -> Update-IR
        step(1'b0, 1'b0);                      // -> Run-Test/Idle
        expect_eq("a paused IR scan still reads the capture pattern",
                  cap[3:0], 4'b0001);
        expect_eq("a paused IR scan still loads the opcode", ir_latched, 4'b1111);

        // ---- 14. Select-IR-Scan with TMS=1 is the short way home -------
        $display("\n-- 14. Select-IR-Scan with TMS=1 goes straight to reset --");
        step(1'b1, 1'b0);          // -> Select-DR
        step(1'b1, 1'b0);          // -> Select-IR
        step(1'b1, 1'b0);          // -> Test-Logic-Reset
        expect_eq("reached Test-Logic-Reset in three clocks", state, 4'hF);
        expect_eq("IR re-armed to IDCODE", ir_latched, 4'b0010);

        // ====================================================================
        // the showcase window the committed waveform is rendered from
        // ====================================================================
        $display("\n-- showcase window (rendered into docs/) --");
        to_idle();
        pin_in       = 8'hA5;
        user_capture = 8'h00;
        idle(1);
        mark = 1'b1;
        scan_ir(4'b0001, cap);                        // load SAMPLE/PRELOAD
        scan_dr_paused(64'h0000_005A, 8, 4, 3, rd);   // capture 0xA5, preload 0x5A
        idle(1);
        mark = 1'b0;
        expect_eq("showcase: SAMPLE captured 0xA5", rd[7:0], 8'hA5);
        expect_eq("showcase: PRELOAD landed 0x5A",  pin_out, 8'h5A);

        // ---- 15. every one of the sixteen opcodes ----------------------
        $display("\n-- 15. all sixteen opcodes, each followed by a DR scan --");
        for (i = 0; i < 16; i++) begin
            scan_ir(i[3:0], cap);
            if (cap[3:0] !== 4'b0001) begin
                errors++;
                $display("[%0t] Capture-IR pattern wrong before opcode 0b%04b: 0b%04b",
                         $time, i[3:0], cap[3:0]);
            end
            if (ir_latched !== i[3:0]) begin
                errors++;
                $display("[%0t] opcode 0b%04b did not latch (got 0b%04b)",
                         $time, i[3:0], ir_latched);
            end
            // Scan the chain this opcode selects, plus a couple of bits, so
            // the cycle-exact checker judges the chain length as well.
            scan_dr({$random(seed), $random(seed)}, ref_chain_len(i[3:0]) + 2, rd);
        end

        // ---- 16. TRST_n asserted in the middle of a scan ----------------
        $display("\n-- 16. TRST_n in the middle of a Shift-DR --");
        to_idle();
        scan_ir(4'b0010, cap);
        step(1'b1, 1'b0); step(1'b0, 1'b0); step(1'b0, 1'b0);   // -> Shift-DR
        step(1'b0, 1'b1); step(1'b0, 1'b1);                     // a few bits in
        expect_eq("mid-scan, still in Shift-DR", state, 4'h2);
        do_trst();
        expect_eq("TRST_n from Shift-DR lands in Test-Logic-Reset", state, 4'hF);
        expect_eq("and re-arms IDCODE", ir_latched, 4'b0010);
        expect_eq("and drops the boundary drive", pin_oe, 1'b0);

        // ---- 17. the random TMS/TDI walk --------------------------------
        // Unstructured stimulus against a cycle-exact model.  TMS is weighted
        // so the walk lingers - a fair coin spends most of its time bouncing
        // between Select-DR and Select-IR and rarely finishes a scan.
        $display("\n-- 17. random TMS/TDI walk, 6000 cycles, pins wiggling --");
        pin_wiggle = 1'b1;
        for (k = 0; k < 6000; k++) begin
            logic [31:0] r;
            r = $random(seed);
            step(((r % 100) < 38) ? 1'b1 : 1'b0, r[8]);
        end
        pin_wiggle = 1'b0;
        pin_in       = 8'h00;
        user_capture = 8'h00;

        // ---- 18. random full scans -------------------------------------
        // The walk covers the diagram; this covers whole transactions, with
        // random opcodes, random payloads and random pause lengths.
        $display("\n-- 18. 300 random complete scans --");
        tms_reset();
        to_idle();
        for (k = 0; k < 300; k++) begin
            logic [31:0] r;
            logic [3:0]  op;
            int          len, at, hold;
            r   = $random(seed);
            op  = r[3:0];
            scan_ir(op, cap);
            len = ref_chain_len(op) + (r[5:4]);
            if (r[6]) begin
                at   = 1 + (r[9:7] % len);
                hold = r[11:10];
                scan_dr_paused({$random(seed), $random(seed)}, len, at, hold, rd);
            end else begin
                scan_dr({$random(seed), $random(seed)}, len, rd);
            end
            if (r[12]) idle(1 + r[14:13]);
        end

        // ---- coverage report -------------------------------------------
        nstate = 0; ntrans = 0;
        for (i = 0; i < 16; i++) if (cov_state[i] > 0) nstate++;
        for (i = 0; i < 32; i++) if (cov_trans[i] > 0) ntrans++;

        $display("\n============================================================");
        $display(" state coverage");
        $display("============================================================");
        for (i = 0; i < 16; i++)
            $display("   %-17s visited %7d time(s)%s",
                     ref_state_name(i[3:0]), cov_state[i],
                     (cov_state[i] == 0) ? "   <-- NEVER VISITED" : "");
        $display(" states hit      : %0d / 16", nstate);
        $display(" transitions hit : %0d / 32", ntrans);
        $display("\n opcode coverage (cycles spent with each opcode latched)");
        for (i = 0; i < 16; i++)
            $display("   0b%04b %-22s %8d%s", i[3:0], ref_instr_name(i[3:0]),
                     cov_instr[i], (cov_instr[i] == 0) ? "   <-- NEVER LATCHED" : "");

        if (nstate != 16) begin
            errors++;
            $display("\n COVERAGE HOLE: only %0d of the 16 controller states were visited",
                     nstate);
        end
        if (ntrans != 32) begin
            errors++;
            $display("\n COVERAGE HOLE: only %0d of the 32 state transitions were taken",
                     ntrans);
        end
        for (i = 0; i < 16; i++) begin
            if (cov_instr[i] == 0) begin
                errors++;
                $display(" COVERAGE HOLE: opcode 0b%04b was never latched", i[3:0]);
            end
        end

        $display("\n============================================================");
        $display(" %0d rising edges and %0d falling edges checked against the model",
                 n_rise, n_fall);
        if (errors == 0) $display(" RESULT: *** PASS ***");
        else             $display(" RESULT: *** FAIL *** (%0d error(s))", errors);
        $display("============================================================");
        $finish;
    end

    // ---- timeout -----------------------------------------------------------
    initial begin
        #40_000_000;
        $display("TIMEOUT: the testbench did not finish");
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
