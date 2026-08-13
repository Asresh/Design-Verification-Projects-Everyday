// ============================================================================
// jtag_tap.sv - IEEE 1149.1 JTAG Test Access Port (TAP) controller.
// ----------------------------------------------------------------------------
// A complete, spec-shaped TAP: the sixteen-state controller FSM, a four-bit
// instruction register, and four data-register chains (BYPASS, IDCODE, the
// boundary-scan register, and a user data register) with the instruction
// decode that selects between them.
//
// Timing, straight out of the standard (clause 4):
//
//   * TMS and TDI are sampled on the RISING edge of TCK.
//   * The controller changes state on the RISING edge of TCK.
//   * Capture and shift happen on the RISING edge of TCK, in the
//     Capture-xR / Shift-xR states.
//   * Update happens on the FALLING edge of TCK, in the Update-xR states,
//     so a parallel output never changes while the shift path is moving.
//   * TDO changes on the FALLING edge of TCK and is driven only in
//     Shift-IR / Shift-DR.
//
// Two consequences of that split are the reason this design is worth
// verifying rather than eyeballing.  First, the register action taken at a
// rising edge belongs to the state the controller was in *before* the edge,
// not the one it lands in - so a Capture-DR to Shift-DR transition captures
// on the first edge and shifts on the second.  Second, because the update
// latch loads half a cycle after the state is entered, an Update-DR that is
// immediately followed by another scan has exactly one falling edge in which
// to do its work.
//
// Three details the standard makes mandatory and a careless TAP gets wrong:
//
//   * Capture-IR must load a value whose least-significant bit is 1, so a
//     board tester can tell a live TAP from a stuck-at-0 chain.
//   * IDCODE bit 0 must be 1, for the same reason.
//   * An instruction opcode that is not implemented must select the BYPASS
//     register, never leave the DR path floating or dangling.
//
// CLAMP is included on purpose: it selects BYPASS as its data register while
// still driving the boundary from the update latch, which is the one
// instruction where "which chain is selected" and "is the boundary driving"
// disagree.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module jtag_tap #(
    // Device identification register.  Bit 0 is forced to 1 below because the
    // standard requires it; the parameter is sanity-checked at elaboration.
    parameter logic [31:0] IDCODE   = 32'h10DE_5097,
    // Boundary-scan register length (number of boundary cells).
    parameter int          BSR_LEN  = 8,
    // Length of the user-defined data register reached by the USER opcode.
    parameter int          USER_LEN = 8
) (
    input  wire                     tck,
    input  wire                     trst_n,      // asynchronous TAP reset
    input  wire                     tms,
    input  wire                     tdi,
    output logic                    tdo,
    output logic                    tdo_en,      // TDO is driven only in Shift-xR

    // ---- system side ----
    input  wire  [BSR_LEN-1:0]      pin_in,      // boundary cells' sampled input
    output logic [BSR_LEN-1:0]      pin_out,     // boundary cells' update latch
    output logic                    pin_oe,      // EXTEST / CLAMP drive the boundary
    input  wire  [USER_LEN-1:0]     user_capture,// value the user register captures
    output logic [USER_LEN-1:0]     user_out,    // user register's update latch

    // ---- observation (verification hooks, no functional role) ----
    output logic [3:0]              state_o,
    output logic [3:0]              ir_shift_o,
    output logic [3:0]              ir_latched_o
);

    // ------------------------------------------------------------------------
    // TAP controller state encoding.  This is the conventional four-bit
    // encoding from the standard's own state diagram, kept because published
    // TAP traces and debug tools use it.
    // ------------------------------------------------------------------------
    localparam logic [3:0] S_EXIT2_DR   = 4'h0;
    localparam logic [3:0] S_EXIT1_DR   = 4'h1;
    localparam logic [3:0] S_SHIFT_DR   = 4'h2;
    localparam logic [3:0] S_PAUSE_DR   = 4'h3;
    localparam logic [3:0] S_SELECT_IR  = 4'h4;
    localparam logic [3:0] S_UPDATE_DR  = 4'h5;
    localparam logic [3:0] S_CAPTURE_DR = 4'h6;
    localparam logic [3:0] S_SELECT_DR  = 4'h7;
    localparam logic [3:0] S_EXIT2_IR   = 4'h8;
    localparam logic [3:0] S_EXIT1_IR   = 4'h9;
    localparam logic [3:0] S_SHIFT_IR   = 4'hA;
    localparam logic [3:0] S_PAUSE_IR   = 4'hB;
    localparam logic [3:0] S_IDLE       = 4'hC;   // Run-Test/Idle
    localparam logic [3:0] S_UPDATE_IR  = 4'hD;
    localparam logic [3:0] S_CAPTURE_IR = 4'hE;
    localparam logic [3:0] S_RESET      = 4'hF;   // Test-Logic-Reset

    // ------------------------------------------------------------------------
    // Instruction opcodes.  Anything not listed decodes to BYPASS.
    // ------------------------------------------------------------------------
    localparam logic [3:0] I_EXTEST = 4'b0000;
    localparam logic [3:0] I_SAMPLE = 4'b0001;   // SAMPLE/PRELOAD
    localparam logic [3:0] I_IDCODE = 4'b0010;
    localparam logic [3:0] I_USER   = 4'b1000;
    localparam logic [3:0] I_CLAMP  = 4'b1100;
    localparam logic [3:0] I_BYPASS = 4'b1111;

    // Selected data-register chain.
    localparam logic [1:0] C_BYPASS = 2'd0;
    localparam logic [1:0] C_IDCODE = 2'd1;
    localparam logic [1:0] C_BSR    = 2'd2;
    localparam logic [1:0] C_USER   = 2'd3;

    // ------------------------------------------------------------------------
    // Next-state function.  Pure combinational, and deliberately written as a
    // flat table: this is the object the verification environment's reference
    // model has to agree with edge for edge.
    // ------------------------------------------------------------------------
    function automatic logic [3:0] next_state(logic [3:0] s, logic t);
        case (s)
            S_RESET     : next_state = t ? S_RESET     : S_IDLE;
            S_IDLE      : next_state = t ? S_SELECT_DR : S_IDLE;
            S_SELECT_DR : next_state = t ? S_SELECT_IR : S_CAPTURE_DR;
            S_CAPTURE_DR: next_state = t ? S_EXIT1_DR  : S_SHIFT_DR;
            S_SHIFT_DR  : next_state = t ? S_EXIT1_DR  : S_SHIFT_DR;
            S_EXIT1_DR  : next_state = t ? S_UPDATE_DR : S_PAUSE_DR;
            S_PAUSE_DR  : next_state = t ? S_EXIT2_DR  : S_PAUSE_DR;
            S_EXIT2_DR  : next_state = t ? S_UPDATE_DR : S_SHIFT_DR;
            S_UPDATE_DR : next_state = t ? S_SELECT_DR : S_IDLE;
            S_SELECT_IR : next_state = t ? S_RESET     : S_CAPTURE_IR;
            S_CAPTURE_IR: next_state = t ? S_EXIT1_IR  : S_SHIFT_IR;
            S_SHIFT_IR  : next_state = t ? S_EXIT1_IR  : S_SHIFT_IR;
            S_EXIT1_IR  : next_state = t ? S_UPDATE_IR : S_PAUSE_IR;
            S_PAUSE_IR  : next_state = t ? S_EXIT2_IR  : S_PAUSE_IR;
            S_EXIT2_IR  : next_state = t ? S_UPDATE_IR : S_SHIFT_IR;
            S_UPDATE_IR : next_state = t ? S_SELECT_DR : S_IDLE;
            default     : next_state = S_RESET;
        endcase
    endfunction

    // Instruction decode: which chain sits in the DR path.  CLAMP shares
    // BYPASS's one-bit register, which is why it is not its own chain.
    function automatic logic [1:0] dr_chain(logic [3:0] ir);
        case (ir)
            I_IDCODE               : dr_chain = C_IDCODE;
            I_EXTEST, I_SAMPLE     : dr_chain = C_BSR;
            I_USER                 : dr_chain = C_USER;
            default                : dr_chain = C_BYPASS;  // incl. CLAMP, BYPASS,
        endcase                                            // and every unimplemented
    endfunction                                            // opcode

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------
    logic [3:0]          state;
    logic [3:0]          ir_shift, ir_latched;
    logic                bypass_r;
    logic [31:0]         idcode_r;
    logic [BSR_LEN-1:0]  bsr_r,  bsr_out_r;
    logic [USER_LEN-1:0] user_r, user_out_r;
    logic [1:0]          chain;

    assign chain = dr_chain(ir_latched);

    // The bit that leaves the selected chain: always its least-significant
    // bit, because a scan chain shifts LSB-first toward TDO.
    logic dr_tdo;
    always_comb begin
        case (chain)
            C_IDCODE: dr_tdo = idcode_r[0];
            C_BSR   : dr_tdo = bsr_r[0];
            C_USER  : dr_tdo = user_r[0];
            default : dr_tdo = bypass_r;
        endcase
    end

    // ------------------------------------------------------------------------
    // Controller FSM - rising edge, asynchronously reset to Test-Logic-Reset.
    // ------------------------------------------------------------------------
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) state <= S_RESET;
        else         state <= next_state(state, tms);
    end

    // ------------------------------------------------------------------------
    // Capture and shift - rising edge.  Reading `state` inside this block
    // yields the state the controller occupied *before* this edge, which is
    // exactly the state whose action the standard says to perform here.
    //
    // Every chain is shift-gated on the decoded instruction: an unselected
    // register must hold its contents while another chain is being scanned,
    // otherwise a SAMPLE/PRELOAD would quietly corrupt the user register.
    // ------------------------------------------------------------------------
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            ir_shift <= 4'b0001;
            bypass_r <= 1'b0;
            idcode_r <= {IDCODE[31:1], 1'b1};
            bsr_r    <= '0;
            user_r   <= '0;
        end else begin
            // ---- instruction register ----
            if (state == S_CAPTURE_IR)
                // Mandatory: the captured pattern's LSB is 1, so a tester can
                // distinguish a working TAP from a chain stuck at zero.
                ir_shift <= 4'b0001;
            else if (state == S_SHIFT_IR)
                ir_shift <= {tdi, ir_shift[3:1]};

            // ---- data registers ----
            if (state == S_CAPTURE_DR) begin
                bypass_r <= 1'b0;                        // BYPASS captures 0
                idcode_r <= {IDCODE[31:1], 1'b1};
                bsr_r    <= pin_in;
                user_r   <= user_capture;
            end else if (state == S_SHIFT_DR) begin
                case (chain)
                    C_IDCODE: idcode_r <= {tdi, idcode_r[31:1]};
                    C_BSR   : bsr_r    <= (BSR_LEN == 1) ? tdi
                                        : {tdi, bsr_r[BSR_LEN-1:1]};
                    C_USER  : user_r   <= (USER_LEN == 1) ? tdi
                                        : {tdi, user_r[USER_LEN-1:1]};
                    default : bypass_r <= tdi;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------------
    // Update latches and TDO - falling edge.  `state` here is the state the
    // controller entered at the preceding rising edge, so an Update-xR loads
    // exactly one falling edge after it is reached.
    // ------------------------------------------------------------------------
    always_ff @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            // The standard's reset instruction is IDCODE when a device
            // implements it, BYPASS otherwise.
            ir_latched <= I_IDCODE;
            bsr_out_r  <= '0;
            user_out_r <= '0;
            tdo        <= 1'b0;
            tdo_en     <= 1'b0;
        end else begin
            // Holding Test-Logic-Reset re-arms the instruction register, so a
            // TAP that got there by five TMS=1 clocks is indistinguishable
            // from one that got there by TRST.
            if (state == S_RESET)
                ir_latched <= I_IDCODE;
            else if (state == S_UPDATE_IR)
                ir_latched <= ir_shift;

            if (state == S_UPDATE_DR) begin
                if (chain == C_BSR)  bsr_out_r  <= bsr_r;
                if (chain == C_USER) user_out_r <= user_r;
            end

            tdo_en <= (state == S_SHIFT_IR) || (state == S_SHIFT_DR);
            tdo    <= (state == S_SHIFT_IR) ? ir_shift[0] : dr_tdo;
        end
    end

    // ------------------------------------------------------------------------
    // System-side outputs
    // ------------------------------------------------------------------------
    assign pin_out  = bsr_out_r;
    // EXTEST and CLAMP both drive the boundary from the update latch; every
    // other instruction, and Test-Logic-Reset unconditionally, leaves the
    // system pins to the mission logic.
    assign pin_oe   = ((ir_latched == I_EXTEST) || (ir_latched == I_CLAMP)) &&
                      (state != S_RESET);
    assign user_out = user_out_r;

    assign state_o      = state;
    assign ir_shift_o   = ir_shift;
    assign ir_latched_o = ir_latched;

    // ------------------------------------------------------------------------
    // Elaboration-time checks on the mandatory constants.
    // ------------------------------------------------------------------------
    initial begin
        if (IDCODE[0] !== 1'b1)
            $display("NOTE: IDCODE parameter has bit 0 = 0; the design forces it to 1 as IEEE 1149.1 requires.");
        if (BSR_LEN < 1 || USER_LEN < 1)
            $fatal(1, "jtag_tap: BSR_LEN and USER_LEN must both be >= 1");
    end

`ifdef JTAG_SVA
    // ------------------------------------------------------------------------
    // Concurrent assertions.  Enabled with +define+JTAG_SVA on a simulator
    // with SVA support; the protocol-level properties live in jtag_tap_if.sv.
    // ------------------------------------------------------------------------

    // The FSM must never leave the sixteen legal states.
    a_state_legal: assert property (@(posedge tck) disable iff (!trst_n)
        state inside {S_EXIT2_DR, S_EXIT1_DR, S_SHIFT_DR, S_PAUSE_DR,
                      S_SELECT_IR, S_UPDATE_DR, S_CAPTURE_DR, S_SELECT_DR,
                      S_EXIT2_IR, S_EXIT1_IR, S_SHIFT_IR, S_PAUSE_IR,
                      S_IDLE, S_UPDATE_IR, S_CAPTURE_IR, S_RESET});

    // Five TMS=1 clocks reach Test-Logic-Reset from anywhere in the diagram.
    // This is the property the whole standard leans on for recoverability.
    a_five_ones_reset: assert property (@(posedge tck) disable iff (!trst_n)
        (tms [*5]) |=> (state == S_RESET));

    // Capture-IR must load a pattern with a 1 in the LSB.
    a_capture_ir_lsb: assert property (@(posedge tck) disable iff (!trst_n)
        (state == S_CAPTURE_IR) |=> ir_shift[0]);

    // An unimplemented opcode must select BYPASS, not float the DR path.
    a_unimpl_is_bypass: assert property (@(posedge tck) disable iff (!trst_n)
        !(ir_latched inside {I_EXTEST, I_SAMPLE, I_IDCODE, I_USER, I_CLAMP,
                             I_BYPASS}) |-> (chain == C_BYPASS));

    // The boundary is never driven while the TAP is in Test-Logic-Reset.
    a_no_drive_in_reset: assert property (@(posedge tck)
        (state == S_RESET) |-> !pin_oe);

    // TDO is enabled in exactly the two shift states, and nowhere else.
    // Sampled at the rising edge: tdo_en carries the value the preceding
    // falling edge gave it, and `state` still carries the state that drove it.
    a_tdo_en_only_in_shift: assert property (@(posedge tck) disable iff (!trst_n)
        tdo_en == ((state == S_SHIFT_IR) || (state == S_SHIFT_DR)));

    // Nothing on the shift path may go X once reset is released.
    a_no_x: assert property (@(posedge tck) disable iff (!trst_n)
        !$isunknown(state) && !$isunknown(ir_shift) && !$isunknown(ir_latched));
`endif

endmodule

`default_nettype wire
