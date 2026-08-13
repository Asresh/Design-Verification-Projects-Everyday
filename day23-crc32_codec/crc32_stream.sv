// -----------------------------------------------------------------------------
// crc32_stream.sv - byte-serial STREAMING CRC-32 (IEEE 802.3 / Ethernet FCS)
//                   GENERATOR + CHECKER.
//
// The Frame Check Sequence (FCS) is the last-line integrity guard on essentially
// every wire protocol - Ethernet, PCIe TLPs, USB, MPEG-TS, gzip/PNG payloads,
// SATA, CAN-FD. The transmitter runs a CRC over the frame and appends the 32-bit
// result; the receiver runs the SAME CRC over frame+FCS and checks the answer.
// This DUT is that block: a one-byte-per-cycle LFSR-style CRC engine that both
// GENERATES the FCS to append and CHECKS an incoming frame's residue.
//
// CRC VARIANT: CRC-32/ISO-HDLC (a.k.a. the zlib / PNG / Ethernet CRC) -
//     reflected input & output, polynomial 0x04C11DB7 (reflected form
//     0xEDB88320), init 0xFFFFFFFF, final XOR 0xFFFFFFFF. This is bit-for-bit
//     identical to Python's binascii.crc32 / zlib.crc32, which is what lets an
//     independent golden model check the block byte-for-byte. Canonical check
//     vector: CRC32("123456789") == 0xCBF43926.
//
// STREAMING PROTOCOL (one byte per accepted cycle, zero-bubble capable):
//   * in_valid & in_sop  : first byte of a frame  -> the running CRC is (re)seeded
//                          to INIT before absorbing this byte, and the per-frame
//                          MODE is latched.
//   * in_valid           : a mid-frame byte       -> absorbed into the running CRC.
//   * in_valid & in_eop  : last byte of a frame    -> after absorbing it, the
//                          result is emitted LAT cycles later on out_valid.
//   A one-byte frame simply asserts in_sop and in_eop on the same cycle.
//
// PER-FRAME MODE (latched at sop):
//   * GENERATE (0): the stream is the raw message. out_crc = running^XOROUT is
//                   the FCS the transmitter appends (little-endian on the wire).
//                   out_ok is forced 1 (not meaningful in generate mode).
//   * CHECK    (1): the stream is message||appended-FCS as seen by a receiver.
//                   out_crc = running^XOROUT is the CRC RESIDUE, which for a
//                   frame whose FCS is intact equals the constant 0x2144DF1C.
//                   out_ok = (out_crc == RESIDUE) is the frame-good flag - exactly
//                   how real Ethernet MAC RX hardware validates a frame.
//
// LATENCY: the running CRC updates combinationally-then-registered every accepted
// byte (so zero-bubble back-to-back bytes always see the up-to-date remainder);
// the final XOR + residue-compare + echo are carried through PIPE output register
// stages purely for fixed latency / timing closure. out_valid pulses exactly
// LAT = PIPE cycles after the in_eop byte.
//
// The design is parameterized, reset-safe, fully registered, and lint-friendly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module crc32_stream #(
    parameter int              DW      = 8,             // data (byte) width
    parameter int              CRCW    = 32,            // CRC width
    parameter [CRCW-1:0]       POLY    = 32'hEDB88320,  // reflected CRC-32 poly
    parameter [CRCW-1:0]       INIT    = 32'hFFFFFFFF,  // initial remainder
    parameter [CRCW-1:0]       XOROUT  = 32'hFFFFFFFF,  // final XOR
    parameter [CRCW-1:0]       RESIDUE = 32'h2144DF1C,  // good-frame check residue
    parameter int              PIPE    = 2              // output latency (>=1)
) (
    input  wire              clk,
    input  wire              rst_n,

    // streaming byte input
    input  wire              in_valid,   // byte present this cycle
    input  wire              in_sop,     // first byte of a frame (seed CRC)
    input  wire              in_eop,     // last  byte of a frame (emit next)
    input  wire              in_mode,    // 0 = GENERATE, 1 = CHECK  (latched @ sop)
    input  wire [DW-1:0]     in_data,    // the byte

    // result output (fixed latency LAT = PIPE after the in_eop byte)
    output wire              out_valid,  // 1-cycle strobe: a frame result is valid
    output wire [CRCW-1:0]   out_crc,    // GENERATE: FCS ; CHECK: residue
    output wire              out_mode,   // echoed per-frame mode
    output wire              out_ok      // CHECK: frame good (residue match); GEN: 1
);

    localparam int LAT = PIPE;

    // ---------------------------------------------------------------------------
    // One-byte reflected CRC-32 update (unrolled 8-step LFSR). Bit-identical to
    // the software reference c ^= byte; 8x (c = c&1 ? (c>>1)^POLY : c>>1).
    // ---------------------------------------------------------------------------
    function automatic [CRCW-1:0] crc_next(input [CRCW-1:0] c_in,
                                           input [DW-1:0]   d);
        logic [CRCW-1:0] c;
        begin
            c = c_in ^ {{(CRCW-DW){1'b0}}, d};
            for (int i = 0; i < DW; i++)
                c = c[0] ? ((c >> 1) ^ POLY) : (c >> 1);
            crc_next = c;
        end
    endfunction

    // ---- running-remainder state ----------------------------------------------
    logic [CRCW-1:0] crc_q;     // running CRC remainder between bytes
    logic            mode_q;    // per-frame mode latched at sop

    // combinational next remainder for THIS byte
    wire [CRCW-1:0]  base    = in_sop ? INIT : crc_q;
    wire [CRCW-1:0]  crc_c   = crc_next(base, in_data);
    wire [CRCW-1:0]  fcs_c   = crc_c ^ XOROUT;
    // mode governing this byte's frame (sop byte carries its own mode)
    wire             mode_c  = in_sop ? in_mode : mode_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_q  <= INIT;
            mode_q <= 1'b0;
        end else if (in_valid) begin
            crc_q  <= crc_c;
            if (in_sop) mode_q <= in_mode;
        end
    end

    // ---- fixed-latency output pipeline (depth PIPE) ----------------------------
    // Stage 0 forms the frame result on the in_eop byte; PIPE registers carry it.
    logic [PIPE-1:0]            v_pipe;
    logic [CRCW-1:0]           crc_pipe [PIPE-1:0];
    logic [PIPE-1:0]           mode_pipe;
    logic [PIPE-1:0]           ok_pipe;

    wire            s0_valid = in_valid & in_eop;
    wire [CRCW-1:0] s0_crc   = fcs_c;
    wire            s0_mode  = mode_c;
    wire            s0_ok    = mode_c ? (fcs_c == RESIDUE) : 1'b1;

    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_pipe    <= '0;
            mode_pipe <= '0;
            ok_pipe   <= '0;
            for (s = 0; s < PIPE; s++) crc_pipe[s] <= '0;
        end else begin
            // stage 0
            v_pipe[0]    <= s0_valid;
            crc_pipe[0]  <= s0_crc;
            mode_pipe[0] <= s0_mode;
            ok_pipe[0]   <= s0_ok;
            // stages 1..PIPE-1
            for (s = 1; s < PIPE; s++) begin
                v_pipe[s]    <= v_pipe[s-1];
                crc_pipe[s]  <= crc_pipe[s-1];
                mode_pipe[s] <= mode_pipe[s-1];
                ok_pipe[s]   <= ok_pipe[s-1];
            end
        end
    end

    assign out_valid = v_pipe[PIPE-1];
    assign out_crc   = crc_pipe[PIPE-1];
    assign out_mode  = mode_pipe[PIPE-1];
    assign out_ok    = ok_pipe[PIPE-1];

    // ---------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+CRC_SVA on a UVM sim).
    // ---------------------------------------------------------------------------
`ifdef CRC_SVA
    // out_valid appears exactly LAT cycles after an in_eop byte.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        (in_valid && in_eop) |-> ##LAT out_valid)
        else $error("FCS result did not appear LAT=%0d cycles after in_eop", LAT);

    // A result strobe must be traceable to an in_eop byte LAT cycles earlier.
    a_valid_caused: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> $past(in_valid && in_eop, LAT))
        else $error("out_valid with no in_eop LAT cycles earlier");

    // In generate mode the ok flag is always high.
    a_gen_ok: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && !out_mode) |-> out_ok)
        else $error("out_ok deasserted in GENERATE mode");

    // Result buses are fully defined whenever a result is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (!$isunknown({out_crc, out_mode, out_ok})))
        else $error("X/Z on result bus while out_valid");

    // sop/eop are never asserted without an accompanying valid byte.
    a_sop_needs_valid: assert property (@(posedge clk) disable iff (!rst_n)
        (in_sop || in_eop) |-> in_valid)
        else $error("sop/eop asserted without in_valid");
`endif

endmodule

`default_nettype wire
