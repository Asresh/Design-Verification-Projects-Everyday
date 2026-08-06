// ============================================================================
// jtag_tap_ref_pkg.sv - the golden reference model for the IEEE 1149.1 TAP.
// ----------------------------------------------------------------------------
// The model is a pure function of one TCK cycle: hand it the TAP's complete
// state before a rising edge together with the pin values sampled at that
// edge, and it returns the complete state after the following falling edge,
// including the value TDO takes and whether TDO is driven.
//
//     next = ref_tap_cycle(current, tms, tdi, pin_in, user_capture);
//
// It is written from the standard's state diagram and register descriptions,
// not from the RTL.  Deliberately so: the whole point of a reference model is
// that it is a second, independent expression of the same requirement, so
// that a disagreement means one of the two misread the specification rather
// than that both share a typo.  Structurally it is nothing like the DUT - a
// combinational function over a packed state word, no clocks, no latches, no
// gating - and that difference is what gives an agreement between them any
// weight.
//
// Cycle ordering inside the function, mirroring clause 4 of the standard:
//
//   1. act on the CURRENT state (capture / shift / IR reload in
//      Test-Logic-Reset), because the standard's register actions belong to
//      the state the controller is in when the rising edge arrives;
//   2. advance the state;
//   3. apply the falling-edge work of the NEW state (update latches, TDO).
//
// Step 3 using the new state is the subtle part, and the one a hand-written
// checker usually gets wrong: an Update-DR reached at a rising edge does its
// latching at the falling edge inside that same cycle.
//
// A packed struct is used for the state word so it can be pushed straight
// into a `bit [REF_ST_W-1:0]` queue - which is what the UVM scoreboard does,
// and what Icarus needs, since it will not hold a queue of named structs.
// ============================================================================
`timescale 1ns/1ps

package jtag_tap_ref_pkg;

    // ---- geometry, fixed to match the tb_top / dump-TB instantiation -------
    localparam int          REF_BSR_LEN  = 8;
    localparam int          REF_USER_LEN = 8;
    localparam logic [31:0] REF_IDCODE   = 32'h10DE_5097;

    // ---- the sixteen controller states ------------------------------------
    localparam logic [3:0] R_EXIT2_DR   = 4'h0;
    localparam logic [3:0] R_EXIT1_DR   = 4'h1;
    localparam logic [3:0] R_SHIFT_DR   = 4'h2;
    localparam logic [3:0] R_PAUSE_DR   = 4'h3;
    localparam logic [3:0] R_SELECT_IR  = 4'h4;
    localparam logic [3:0] R_UPDATE_DR  = 4'h5;
    localparam logic [3:0] R_CAPTURE_DR = 4'h6;
    localparam logic [3:0] R_SELECT_DR  = 4'h7;
    localparam logic [3:0] R_EXIT2_IR   = 4'h8;
    localparam logic [3:0] R_EXIT1_IR   = 4'h9;
    localparam logic [3:0] R_SHIFT_IR   = 4'hA;
    localparam logic [3:0] R_PAUSE_IR   = 4'hB;
    localparam logic [3:0] R_IDLE       = 4'hC;
    localparam logic [3:0] R_UPDATE_IR  = 4'hD;
    localparam logic [3:0] R_CAPTURE_IR = 4'hE;
    localparam logic [3:0] R_RESET      = 4'hF;

    // ---- instruction opcodes ----------------------------------------------
    localparam logic [3:0] R_EXTEST = 4'b0000;
    localparam logic [3:0] R_SAMPLE = 4'b0001;
    localparam logic [3:0] R_IDCODE_I = 4'b0010;
    localparam logic [3:0] R_USER   = 4'b1000;
    localparam logic [3:0] R_CLAMP  = 4'b1100;
    localparam logic [3:0] R_BYPASS = 4'b1111;

    // ---- selected data-register chain -------------------------------------
    localparam logic [1:0] R_CH_BYPASS = 2'd0;
    localparam logic [1:0] R_CH_IDCODE = 2'd1;
    localparam logic [1:0] R_CH_BSR    = 2'd2;
    localparam logic [1:0] R_CH_USER   = 2'd3;

    // ======================================================================
    // The complete TAP state, as it stands between one falling edge and the
    // next rising edge.  tdo / tdo_en are part of the state because they are
    // registered outputs.
    // ======================================================================
    typedef struct packed {
        logic [3:0]                state;
        logic [3:0]                ir_shift;
        logic [3:0]                ir_latched;
        logic                      bypass_r;
        logic [31:0]               idcode_r;
        logic [REF_BSR_LEN-1:0]    bsr_r;
        logic [REF_BSR_LEN-1:0]    bsr_out;
        logic [REF_USER_LEN-1:0]   user_r;
        logic [REF_USER_LEN-1:0]   user_out;
        logic                      tdo;
        logic                      tdo_en;
        logic                      pin_oe;
    } ref_tap_t;

    // 4+4+4+1+32+8+8+8+8+1+1+1
    localparam int REF_ST_W = 80;

    // ======================================================================
    // Next-state function, transcribed from the standard's state diagram.
    // ======================================================================
    function automatic logic [3:0] ref_next_state(logic [3:0] s, logic t);
        case (s)
            R_RESET     : ref_next_state = t ? R_RESET     : R_IDLE;
            R_IDLE      : ref_next_state = t ? R_SELECT_DR : R_IDLE;
            R_SELECT_DR : ref_next_state = t ? R_SELECT_IR : R_CAPTURE_DR;
            R_CAPTURE_DR: ref_next_state = t ? R_EXIT1_DR  : R_SHIFT_DR;
            R_SHIFT_DR  : ref_next_state = t ? R_EXIT1_DR  : R_SHIFT_DR;
            R_EXIT1_DR  : ref_next_state = t ? R_UPDATE_DR : R_PAUSE_DR;
            R_PAUSE_DR  : ref_next_state = t ? R_EXIT2_DR  : R_PAUSE_DR;
            R_EXIT2_DR  : ref_next_state = t ? R_UPDATE_DR : R_SHIFT_DR;
            R_UPDATE_DR : ref_next_state = t ? R_SELECT_DR : R_IDLE;
            R_SELECT_IR : ref_next_state = t ? R_RESET     : R_CAPTURE_IR;
            R_CAPTURE_IR: ref_next_state = t ? R_EXIT1_IR  : R_SHIFT_IR;
            R_SHIFT_IR  : ref_next_state = t ? R_EXIT1_IR  : R_SHIFT_IR;
            R_EXIT1_IR  : ref_next_state = t ? R_UPDATE_IR : R_PAUSE_IR;
            R_PAUSE_IR  : ref_next_state = t ? R_EXIT2_IR  : R_PAUSE_IR;
            R_EXIT2_IR  : ref_next_state = t ? R_UPDATE_IR : R_SHIFT_IR;
            R_UPDATE_IR : ref_next_state = t ? R_SELECT_DR : R_IDLE;
            default     : ref_next_state = R_RESET;
        endcase
    endfunction

    // Which chain the decoded instruction puts in the DR path.  Everything
    // that is not explicitly a longer register - CLAMP, BYPASS itself, and
    // every unimplemented opcode - lands on the one-bit BYPASS register.
    function automatic logic [1:0] ref_chain(logic [3:0] ir);
        case (ir)
            R_IDCODE_I         : ref_chain = R_CH_IDCODE;
            R_EXTEST, R_SAMPLE : ref_chain = R_CH_BSR;
            R_USER             : ref_chain = R_CH_USER;
            default            : ref_chain = R_CH_BYPASS;
        endcase
    endfunction

    // Length in bits of the register a given instruction puts in the path.
    function automatic int ref_chain_len(logic [3:0] ir);
        case (ref_chain(ir))
            R_CH_IDCODE: ref_chain_len = 32;
            R_CH_BSR   : ref_chain_len = REF_BSR_LEN;
            R_CH_USER  : ref_chain_len = REF_USER_LEN;
            default    : ref_chain_len = 1;
        endcase
    endfunction

    function automatic string ref_state_name(logic [3:0] s);
        case (s)
            R_EXIT2_DR  : ref_state_name = "Exit2-DR";
            R_EXIT1_DR  : ref_state_name = "Exit1-DR";
            R_SHIFT_DR  : ref_state_name = "Shift-DR";
            R_PAUSE_DR  : ref_state_name = "Pause-DR";
            R_SELECT_IR : ref_state_name = "Select-IR";
            R_UPDATE_DR : ref_state_name = "Update-DR";
            R_CAPTURE_DR: ref_state_name = "Capture-DR";
            R_SELECT_DR : ref_state_name = "Select-DR";
            R_EXIT2_IR  : ref_state_name = "Exit2-IR";
            R_EXIT1_IR  : ref_state_name = "Exit1-IR";
            R_SHIFT_IR  : ref_state_name = "Shift-IR";
            R_PAUSE_IR  : ref_state_name = "Pause-IR";
            R_IDLE      : ref_state_name = "Run-Test/Idle";
            R_UPDATE_IR : ref_state_name = "Update-IR";
            R_CAPTURE_IR: ref_state_name = "Capture-IR";
            default     : ref_state_name = "Test-Logic-Reset";
        endcase
    endfunction

    function automatic string ref_instr_name(logic [3:0] ir);
        case (ir)
            R_EXTEST  : ref_instr_name = "EXTEST";
            R_SAMPLE  : ref_instr_name = "SAMPLE/PRELOAD";
            R_IDCODE_I: ref_instr_name = "IDCODE";
            R_USER    : ref_instr_name = "USER";
            R_CLAMP   : ref_instr_name = "CLAMP";
            R_BYPASS  : ref_instr_name = "BYPASS";
            default   : ref_instr_name = "unimplemented->BYPASS";
        endcase
    endfunction

    // A low mask of n bits.  Used instead of a variable part-select, which is
    // not legal SystemVerilog when the width itself varies.
    function automatic logic [31:0] ref_mask(int n);
        ref_mask = (n >= 32) ? 32'hFFFF_FFFF : ((32'h1 << n) - 32'h1);
    endfunction

    function automatic logic ref_is_implemented(logic [3:0] ir);
        ref_is_implemented = (ir == R_EXTEST) || (ir == R_SAMPLE) ||
                             (ir == R_IDCODE_I) || (ir == R_USER) ||
                             (ir == R_CLAMP) || (ir == R_BYPASS);
    endfunction

    // ======================================================================
    // The state a TRST_n pulse leaves behind.
    // ======================================================================
    function automatic ref_tap_t ref_tap_reset();
        ref_tap_t s;
        s.state      = R_RESET;
        s.ir_shift   = 4'b0001;
        s.ir_latched = R_IDCODE_I;   // the standard's reset instruction
        s.bypass_r   = 1'b0;
        s.idcode_r   = {REF_IDCODE[31:1], 1'b1};
        s.bsr_r      = '0;
        s.bsr_out    = '0;
        s.user_r     = '0;
        s.user_out   = '0;
        s.tdo        = 1'b0;
        s.tdo_en     = 1'b0;
        s.pin_oe     = 1'b0;
        ref_tap_reset = s;
    endfunction

    // ======================================================================
    // One whole TCK cycle: rising edge, then falling edge.
    // ======================================================================
    function automatic ref_tap_t ref_tap_cycle(
        ref_tap_t                s,
        logic                    tms,
        logic                    tdi,
        logic [REF_BSR_LEN-1:0]  pin_in,
        logic [REF_USER_LEN-1:0] user_capture
    );
        ref_tap_t   n;
        logic [1:0] ch;
        logic [3:0] cur;

        n   = s;
        cur = s.state;
        ch  = ref_chain(s.ir_latched);   // decode from the *latched* IR

        // -------- 1. rising edge: the action of the current state ----------
        if (cur == R_CAPTURE_IR)
            n.ir_shift = 4'b0001;        // mandatory LSB=1 capture pattern
        else if (cur == R_SHIFT_IR)
            n.ir_shift = {tdi, s.ir_shift[3:1]};

        if (cur == R_CAPTURE_DR) begin
            n.bypass_r = 1'b0;
            n.idcode_r = {REF_IDCODE[31:1], 1'b1};
            n.bsr_r    = pin_in;
            n.user_r   = user_capture;
        end else if (cur == R_SHIFT_DR) begin
            // Only the selected chain moves.  An unselected register holding
            // still is a requirement, not an optimisation: PRELOAD's whole
            // purpose is that the value survives an unrelated scan.
            case (ch)
                R_CH_IDCODE: n.idcode_r = {tdi, s.idcode_r[31:1]};
                R_CH_BSR   : n.bsr_r    = {tdi, s.bsr_r[REF_BSR_LEN-1:1]};
                R_CH_USER  : n.user_r   = {tdi, s.user_r[REF_USER_LEN-1:1]};
                default    : n.bypass_r = tdi;
            endcase
        end

        // -------- 2. the state advances ------------------------------------
        n.state = ref_next_state(cur, tms);

        // -------- 3. falling edge: the work of the NEW state ---------------
        if (n.state == R_RESET)
            n.ir_latched = R_IDCODE_I;
        else if (n.state == R_UPDATE_IR)
            n.ir_latched = n.ir_shift;

        if (n.state == R_UPDATE_DR) begin
            // The update latch loads from the chain the *latched* instruction
            // selects, which is still the pre-Update-IR decode here.
            if (ch == R_CH_BSR)  n.bsr_out  = n.bsr_r;
            if (ch == R_CH_USER) n.user_out = n.user_r;
        end

        n.tdo_en = (n.state == R_SHIFT_IR) || (n.state == R_SHIFT_DR);
        if (n.state == R_SHIFT_IR)
            n.tdo = n.ir_shift[0];
        else begin
            case (ch)
                R_CH_IDCODE: n.tdo = n.idcode_r[0];
                R_CH_BSR   : n.tdo = n.bsr_r[0];
                R_CH_USER  : n.tdo = n.user_r[0];
                default    : n.tdo = n.bypass_r;
            endcase
        end

        // pin_oe is combinational in the DUT, so it settles on the new state
        // and the new latched instruction.
        n.pin_oe = ((n.ir_latched == R_EXTEST) || (n.ir_latched == R_CLAMP)) &&
                   (n.state != R_RESET);

        ref_tap_cycle = n;
    endfunction

    // ======================================================================
    // Self-check of the model itself, run before any DUT result is judged.
    // Re-proves, inside the simulator, the properties the standard makes
    // mandatory - so a broken model announces itself instead of quietly
    // agreeing with a broken DUT.  Returns the number of problems found.
    // ======================================================================
    function automatic int ref_selfcheck(logic verbose);
        int          bad;
        ref_tap_t    s;
        logic [3:0]  reach [16];
        int          nreach;
        logic        seen [16];
        logic [3:0]  st;
        logic [31:0] idc;
        int          i, j, k;

        bad = 0;

        // (a) IDCODE bit 0 must be 1.
        idc = {REF_IDCODE[31:1], 1'b1};
        if (idc[0] !== 1'b1) begin
            bad++;
            $display("REF SELFCHECK: IDCODE bit 0 is not 1");
        end

        // (b) Five TMS=1 clocks must reach Test-Logic-Reset from every state.
        for (i = 0; i < 16; i++) begin
            s = ref_tap_reset();
            s.state = i[3:0];
            for (k = 0; k < 5; k++) s = ref_tap_cycle(s, 1'b1, 1'b0, '0, '0);
            if (s.state !== R_RESET) begin
                bad++;
                $display("REF SELFCHECK: five TMS=1 clocks from %s land in %s, not Test-Logic-Reset",
                         ref_state_name(i[3:0]), ref_state_name(s.state));
            end
        end

        // (c) Every state must be reachable from Test-Logic-Reset, and the
        //     next-state function must never produce an out-of-range code.
        for (i = 0; i < 16; i++) seen[i] = 1'b0;
        reach[0] = R_RESET;
        seen[R_RESET] = 1'b1;
        nreach = 1;
        for (i = 0; i < nreach; i++) begin
            for (j = 0; j < 2; j++) begin
                st = ref_next_state(reach[i], j[0]);
                if (!seen[st]) begin
                    seen[st]      = 1'b1;
                    reach[nreach] = st;
                    nreach++;
                end
            end
        end
        if (nreach != 16) begin
            bad++;
            $display("REF SELFCHECK: only %0d of the 16 states are reachable from Test-Logic-Reset",
                     nreach);
        end

        // (d) Capture-IR must produce an LSB of 1.
        s = ref_tap_reset();
        s.state = R_CAPTURE_IR;
        s = ref_tap_cycle(s, 1'b0, 1'b0, '0, '0);   // -> Shift-IR
        if (s.ir_shift[0] !== 1'b1) begin
            bad++;
            $display("REF SELFCHECK: Capture-IR loaded 0b%04b, LSB is not 1", s.ir_shift);
        end

        // (e) Every one of the sixteen opcodes must select a real chain, and
        //     the ten unimplemented ones must all land on BYPASS.
        for (i = 0; i < 16; i++) begin
            if (!ref_is_implemented(i[3:0]) && ref_chain(i[3:0]) !== R_CH_BYPASS) begin
                bad++;
                $display("REF SELFCHECK: unimplemented opcode 0b%04b does not select BYPASS",
                         i[3:0]);
            end
            if (ref_chain_len(i[3:0]) < 1) begin
                bad++;
                $display("REF SELFCHECK: opcode 0b%04b has a zero-length chain", i[3:0]);
            end
        end

        // (f) CLAMP must select BYPASS as its data register yet still drive
        //     the boundary - the one instruction where the two disagree.
        if (ref_chain(R_CLAMP) !== R_CH_BYPASS) begin
            bad++;
            $display("REF SELFCHECK: CLAMP does not select the BYPASS register");
        end

        // (g) A scan of N bits through an N-bit chain must return the chain's
        //     captured contents bit for bit, LSB first, for every chain.
        //     This exercises the shift path end to end inside the model.
        begin
            logic [3:0]  instrs [4];
            int          lens   [4];
            logic [31:0] cap    [4];
            logic [31:0] got;
            instrs[0] = R_BYPASS;   lens[0] = 1;             cap[0] = 32'h0000_0000;
            instrs[1] = R_IDCODE_I; lens[1] = 32;            cap[1] = idc;
            instrs[2] = R_SAMPLE;   lens[2] = REF_BSR_LEN;   cap[2] = 32'h0000_00A5;
            instrs[3] = R_USER;     lens[3] = REF_USER_LEN;  cap[3] = 32'h0000_005C;
            for (i = 0; i < 4; i++) begin
                s            = ref_tap_reset();
                s.ir_latched = instrs[i];
                s.state      = R_CAPTURE_DR;
                got          = 32'h0;
                // Capture-DR -> Shift-DR
                s = ref_tap_cycle(s, 1'b0, 1'b0, cap[i][REF_BSR_LEN-1:0],
                                  cap[i][REF_USER_LEN-1:0]);
                for (k = 0; k < lens[i]; k++) begin
                    got[k] = s.tdo;                       // TDO is valid now
                    s = ref_tap_cycle(s, (k == lens[i]-1), 1'b0,
                                      cap[i][REF_BSR_LEN-1:0],
                                      cap[i][REF_USER_LEN-1:0]);
                end
                if ((got & ref_mask(lens[i])) !== (cap[i] & ref_mask(lens[i]))) begin
                    bad++;
                    $display("REF SELFCHECK: %s scan returned 0x%0h, expected 0x%0h",
                             ref_instr_name(instrs[i]), got & ref_mask(lens[i]),
                             cap[i] & ref_mask(lens[i]));
                end
            end
        end

        if (verbose)
            $display("REF SELFCHECK: %0d problem(s) in the reference model", bad);
        ref_selfcheck = bad;
    endfunction

endpackage : jtag_tap_ref_pkg
