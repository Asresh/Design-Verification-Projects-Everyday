// ---------------------------------------------------------------------------
// Day29 - codec_8b10b : IEEE 802.3 / PCIe / SATA / DisplayPort 8b/10b line code
//
// The SerDes physical-layer block that turns an arbitrary byte stream into a
// stream the wire can actually carry:
//
//   * DC balance      - every 10-bit codeword has 4, 5 or 6 ones, and the
//                       running disparity (RD, the cumulative ones-minus-zeros
//                       count) is held to exactly -1 or +1 forever.  An
//                       AC-coupled link cannot pass a DC-wandering stream.
//   * clock recovery  - no run of more than 5 identical bits, so the receiver
//                       CDR always sees an edge.
//   * framing         - 12 control ("K") symbols live outside the 256 data
//                       codewords; three of them carry the *comma*, the unique
//                       0011111 / 1100000 pattern that can only occur aligned
//                       to a symbol boundary, which is how a receiver finds
//                       where symbols start in a raw bit stream.
//   * error detection - a single bit error on the wire almost always produces
//                       either a codeword that is not in the code, or a legal
//                       codeword arriving with the wrong polarity for the
//                       current RD.  Both are flagged.
//
// The code is a table code, but the tables are small and the *rules* around
// them carry the design: each byte is split into a 5-bit x and a 3-bit y
// (D.x.y), the two halves are encoded independently through a 5b/6b and a
// 3b/4b table, and RD is threaded through both sub-blocks in sequence.  An
// unbalanced sub-block always transmits the variant that opposes the current
// RD (the bit complement) and flips RD; a balanced sub-block leaves RD alone.
// Three exceptions carry all of the code's remaining subtlety:
//
//   * D.07 (5b/6b) and D.x.3 (3b/4b) are balanced yet still alternate between
//     two patterns, because reusing one pattern in both RD states would let a
//     6-bit run form at a codeword junction;
//   * D.x.A7 - for y == 7 only, an alternate 3b/4b pattern replaces the
//     primary one at six specific x values, again purely to stop a 6-bit run;
//   * control symbols alternate even when balanced, which is what keeps the
//     comma unique.
//
// RECEIVER ARCHITECTURE - decode, then verify by re-encoding
// ----------------------------------------------------------
// Reverse sub-block tables recover a candidate symbol in O(1).  The candidate
// is then pushed back through the *encoder's own* rules and the result is
// compared with what actually arrived:
//
//     match at the current RD  -> clean symbol
//     match at the opposite RD -> legal codeword, wrong polarity: disparity err
//     no match                 -> not a codeword at all:          code error
//
// This makes the receiver strict (it rejects sub-block combinations that no
// transmitter can ever emit, such as D.20.7 sent with the primary rather than
// the alternate 3b/4b pattern) and it makes the whole DUT depend on one shared
// rule set - which is exactly what the rule-free golden model in
// codec_8b10b_ref_pkg.sv is there to check.
//
// Timing: encoder registers its output (1 cycle), the decoder registers its
// output (1 cycle), so out_* trails in_* by LAT = 2 cycles, one symbol per
// cycle, zero bubbles.  Running disparity is only advanced on valid symbols.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Shared tables and the encode rule, used by both the encoder and the
// decoder's verification step.  Synthesizable: everything below elaborates to
// constant tables and combinational logic.
// ---------------------------------------------------------------------------
package codec_8b10b_rtl_pkg;

  // Running disparity encoding.  RD- means "the stream so far has one more
  // zero than one"; RD+ means one more one than zero.  Those are the only two
  // states the code ever occupies.
  localparam bit RD_NEG = 1'b0;
  localparam bit RD_POS = 1'b1;

  // ---- 5b/6b, RD- column, plus an "alternates even though balanced" flag ---
  // Returned as {alt, abcdei}.  a is transmitted first.
  function automatic logic [6:0] t5b6b(input logic [4:0] x);
    case (x)
      5'd0 : t5b6b = {1'b0, 6'b100111};
      5'd1 : t5b6b = {1'b0, 6'b011101};
      5'd2 : t5b6b = {1'b0, 6'b101101};
      5'd3 : t5b6b = {1'b0, 6'b110001};
      5'd4 : t5b6b = {1'b0, 6'b110101};
      5'd5 : t5b6b = {1'b0, 6'b101001};
      5'd6 : t5b6b = {1'b0, 6'b011001};
      5'd7 : t5b6b = {1'b1, 6'b111000}; // balanced, but alternates: 111000/000111
      5'd8 : t5b6b = {1'b0, 6'b111001};
      5'd9 : t5b6b = {1'b0, 6'b100101};
      5'd10: t5b6b = {1'b0, 6'b010101};
      5'd11: t5b6b = {1'b0, 6'b110100};
      5'd12: t5b6b = {1'b0, 6'b001101};
      5'd13: t5b6b = {1'b0, 6'b101100};
      5'd14: t5b6b = {1'b0, 6'b011100};
      5'd15: t5b6b = {1'b0, 6'b010111};
      5'd16: t5b6b = {1'b0, 6'b011011};
      5'd17: t5b6b = {1'b0, 6'b100011};
      5'd18: t5b6b = {1'b0, 6'b010011};
      5'd19: t5b6b = {1'b0, 6'b110010};
      5'd20: t5b6b = {1'b0, 6'b001011};
      5'd21: t5b6b = {1'b0, 6'b101010};
      5'd22: t5b6b = {1'b0, 6'b011010};
      5'd23: t5b6b = {1'b0, 6'b111010};
      5'd24: t5b6b = {1'b0, 6'b110011};
      5'd25: t5b6b = {1'b0, 6'b100110};
      5'd26: t5b6b = {1'b0, 6'b010110};
      5'd27: t5b6b = {1'b0, 6'b110110};
      5'd28: t5b6b = {1'b0, 6'b001110};
      5'd29: t5b6b = {1'b0, 6'b101110};
      5'd30: t5b6b = {1'b0, 6'b011110};
      default: t5b6b = {1'b0, 6'b101011}; // 5'd31
    endcase
  endfunction

  // K.28 is the only control-exclusive 5b/6b sub-block - the comma carrier.
  // K.23/27/29/30 reuse the data sub-block of the same x.  Control sub-blocks
  // always alternate.
  function automatic logic [6:0] t5b6b_k(input logic [4:0] x);
    logic [6:0] d;
    d        = t5b6b(x);
    t5b6b_k  = (x == 5'd28) ? {1'b1, 6'b001111} : {1'b1, d[5:0]};
  endfunction

  // ---- 3b/4b, RD- column, as {alt, fghj}.  f is transmitted first. --------
  function automatic logic [4:0] t3b4b(input logic [2:0] y);
    case (y)
      3'd0 : t3b4b = {1'b0, 4'b1011};
      3'd1 : t3b4b = {1'b0, 4'b1001};
      3'd2 : t3b4b = {1'b0, 4'b0101};
      3'd3 : t3b4b = {1'b1, 4'b1100}; // balanced, but alternates: 1100/0011
      3'd4 : t3b4b = {1'b0, 4'b1101};
      3'd5 : t3b4b = {1'b0, 4'b1010};
      3'd6 : t3b4b = {1'b0, 4'b0110};
      default: t3b4b = {1'b0, 4'b1110}; // 3'd7, the primary D.x.P7
    endcase
  endfunction

  localparam logic [3:0] A7 = 4'b0111; // the alternate D.x.A7 / K.x.7 pattern

  function automatic logic [4:0] t3b4b_k(input logic [2:0] y);
    case (y)
      3'd0 : t3b4b_k = {1'b1, 4'b1011};
      3'd1 : t3b4b_k = {1'b1, 4'b0110};
      3'd2 : t3b4b_k = {1'b1, 4'b1010};
      3'd3 : t3b4b_k = {1'b1, 4'b1100};
      3'd4 : t3b4b_k = {1'b1, 4'b1101};
      3'd5 : t3b4b_k = {1'b1, 4'b0101};
      3'd6 : t3b4b_k = {1'b1, 4'b1001};
      default: t3b4b_k = {1'b1, A7};    // 3'd7
    endcase
  endfunction

  // ---- population counts -------------------------------------------------
  function automatic logic [2:0] ones6(input logic [5:0] v);
    ones6 = 3'(v[0]) + 3'(v[1]) + 3'(v[2]) + 3'(v[3]) + 3'(v[4]) + 3'(v[5]);
  endfunction

  function automatic logic [2:0] ones4(input logic [3:0] v);
    ones4 = 3'(v[0]) + 3'(v[1]) + 3'(v[2]) + 3'(v[3]);
  endfunction

  // ---- legality of a control request -------------------------------------
  // Exactly twelve control symbols exist: K.28.0 .. K.28.7 and K.{23,27,29,30}.7
  function automatic logic k_legal(input logic [7:0] data);
    logic [4:0] x;
    logic [2:0] y;
    x = data[4:0];
    y = data[7:5];
    k_legal = (x == 5'd28) ||
              ((y == 3'd7) && (x == 5'd23 || x == 5'd27 ||
                               x == 5'd29 || x == 5'd30));
  endfunction

  // ---- is the alternate D.x.A7 encoding required? ------------------------
  // Only for y == 7, and only at six x values, chosen so the run of identical
  // bits across the sub-block boundary can never reach 6.  rd_mid is the
  // running disparity *after* the 5b/6b sub-block, not before it.
  function automatic logic use_a7(input logic [4:0] x, input logic rd_mid);
    use_a7 = (rd_mid == RD_NEG && (x == 5'd17 || x == 5'd18 || x == 5'd20)) ||
             (rd_mid == RD_POS && (x == 5'd11 || x == 5'd13 || x == 5'd14));
  endfunction

  // ---- the encode rule ---------------------------------------------------
  // Returns {codeword[9:0], rd_out}.  An illegal control request is reported
  // by k_legal() and handled by the caller; enc_f itself always produces a
  // defined value.
  function automatic logic [10:0] enc_f(input logic [7:0] data,
                                        input logic       k,
                                        input logic       rd);
    logic [4:0] x;
    logic [2:0] y;
    logic [6:0] s6;
    logic [4:0] s4;
    logic [5:0] c6n, c6;
    logic [3:0] c4n, c4;
    logic       bal6, bal4, rd_mid, rd_out;

    x = data[4:0];
    y = data[7:5];

    // 5b/6b sub-block
    s6   = k ? t5b6b_k(x) : t5b6b(x);
    c6n  = s6[5:0];
    bal6 = (ones6(c6n) == 3'd3);
    // Use the complement at RD+ for every unbalanced sub-block, and for the
    // balanced-but-alternating ones (D.07 and all control sub-blocks).
    c6   = ((rd == RD_POS) && (!bal6 || s6[6])) ? ~c6n : c6n;
    // A balanced sub-block leaves RD where it was; an unbalanced one always
    // opposes it, so RD simply flips.
    rd_mid = bal6 ? rd : ~rd;

    // 3b/4b sub-block
    if (k)                                   s4 = t3b4b_k(y);
    else if (y == 3'd7 && use_a7(x, rd_mid)) s4 = {1'b0, A7};
    else                                     s4 = t3b4b(y);
    c4n  = s4[3:0];
    bal4 = (ones4(c4n) == 3'd2);
    c4   = ((rd_mid == RD_POS) && (!bal4 || s4[4])) ? ~c4n : c4n;
    rd_out = bal4 ? rd_mid : ~rd_mid;

    enc_f = {c6, c4, rd_out};
  endfunction

  // ---- running disparity implied by a *received* codeword ----------------
  // The receiver must advance RD from the bits that actually arrived, not from
  // the bits it expected, so that a corrupted symbol cannot desynchronise RD
  // permanently.  A balanced sub-block leaves RD alone; an unbalanced one
  // drives RD to the sign of its own disparity, which self-limits RD to
  // {RD_NEG, RD_POS} even for codewords that are not in the code at all.
  function automatic logic rd_advance(input logic [9:0] cw, input logic rd);
    logic [2:0] n6, n4;
    logic       rd_mid;
    n6 = ones6(cw[9:4]);
    n4 = ones4(cw[3:0]);
    rd_mid     = (n6 == 3'd3) ? rd     : ((n6 > 3'd3) ? RD_POS : RD_NEG);
    rd_advance = (n4 == 3'd2) ? rd_mid : ((n4 > 3'd2) ? RD_POS : RD_NEG);
  endfunction

  // ---- comma detection ---------------------------------------------------
  // The comma is 7 bits and is only ever aligned to the start of a codeword,
  // which is the whole point: finding it in a raw serial stream tells the
  // receiver where the symbol boundaries are.
  function automatic logic is_comma(input logic [9:0] cw);
    is_comma = (cw[9:3] == 7'b0011111) || (cw[9:3] == 7'b1100000);
  endfunction

endpackage : codec_8b10b_rtl_pkg


// ---------------------------------------------------------------------------
// enc_8b10b - byte + K flag in, 10-bit codeword out, one per cycle
// ---------------------------------------------------------------------------
module enc_8b10b
  import codec_8b10b_rtl_pkg::*;
#(
  parameter bit INIT_RD = RD_NEG
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       in_valid,
  input  logic [7:0] in_data,
  input  logic       in_k,
  output logic       out_valid,
  output logic [9:0] out_code,
  output logic       out_rd,     // RD *after* the codeword currently on out_code
  output logic       out_kerr,   // the requested control symbol does not exist
  output logic       out_comma
);

  logic        rd_q;
  logic        kerr_c;
  logic [10:0] enc_c;
  logic [9:0]  code_c;
  logic        rd_nxt_c;

  always_comb begin
    kerr_c = in_k && !k_legal(in_data);
    enc_c  = enc_f(in_data, in_k, rd_q);
    if (kerr_c) begin
      // An unencodable request must not be allowed to put a fabricated symbol
      // on the wire, and must not disturb the link's running disparity.  The
      // all-zero word is not a codeword, so the far end reports a code error
      // too - the fault stays visible end to end.
      code_c   = 10'b0;
      rd_nxt_c = rd_q;
    end else begin
      code_c   = enc_c[10:1];
      rd_nxt_c = enc_c[0];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_kerr  <= 1'b0;
      out_code  <= 10'b0;
      rd_q      <= INIT_RD;
    end else begin
      out_valid <= in_valid;
      out_kerr  <= in_valid && kerr_c;
      if (in_valid) begin
        out_code <= code_c;
        rd_q     <= rd_nxt_c;
      end
    end
  end

  assign out_rd    = rd_q;
  assign out_comma = out_valid && is_comma(out_code);

endmodule : enc_8b10b


// ---------------------------------------------------------------------------
// dec_8b10b - 10-bit codeword in, byte + K flag + error flags out
// ---------------------------------------------------------------------------
module dec_8b10b
  import codec_8b10b_rtl_pkg::*;
#(
  parameter bit INIT_RD = RD_NEG
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       in_valid,
  input  logic [9:0] in_code,
  output logic       out_valid,
  output logic [7:0] out_data,
  output logic       out_k,
  output logic       out_code_err, // not a codeword in either RD state
  output logic       out_disp_err, // a codeword, but the wrong-polarity one
  output logic       out_rd,
  output logic       out_comma
);

  logic rd_q;

  // ---- reverse 5b/6b -----------------------------------------------------
  // Every valid 6b sub-block has 2, 3 or 4 ones.  The 2-ones patterns are
  // exactly the complements of the 4-ones ones, so complementing them first
  // collapses the search onto the RD- column and halves the table.  D.07 is
  // the one balanced code with two distinct patterns, so both are listed.
  // Returns {ok, is_k28, x[4:0]}.
  function automatic logic [6:0] r5b6b(input logic [5:0] c6);
    logic [5:0] n;
    logic [2:0] cnt;
    logic [4:0] x;
    logic       ok;
    cnt = ones6(c6);
    n   = (cnt == 3'd2) ? ~c6 : c6;
    ok  = 1'b1;
    case (n)
      6'b100111: x = 5'd0;
      6'b011101: x = 5'd1;
      6'b101101: x = 5'd2;
      6'b110001: x = 5'd3;
      6'b110101: x = 5'd4;
      6'b101001: x = 5'd5;
      6'b011001: x = 5'd6;
      6'b111000: x = 5'd7;
      6'b000111: x = 5'd7;  // D.07's other, equally balanced, pattern
      6'b111001: x = 5'd8;
      6'b100101: x = 5'd9;
      6'b010101: x = 5'd10;
      6'b110100: x = 5'd11;
      6'b001101: x = 5'd12;
      6'b101100: x = 5'd13;
      6'b011100: x = 5'd14;
      6'b010111: x = 5'd15;
      6'b011011: x = 5'd16;
      6'b100011: x = 5'd17;
      6'b010011: x = 5'd18;
      6'b110010: x = 5'd19;
      6'b001011: x = 5'd20;
      6'b101010: x = 5'd21;
      6'b011010: x = 5'd22;
      6'b111010: x = 5'd23;
      6'b110011: x = 5'd24;
      6'b100110: x = 5'd25;
      6'b010110: x = 5'd26;
      6'b110110: x = 5'd27;
      6'b001110: x = 5'd28;
      6'b101110: x = 5'd29;
      6'b011110: x = 5'd30;
      6'b101011: x = 5'd31;
      6'b001111: x = 5'd28;  // the control-only sub-block
      default  : begin x = 5'd0; ok = 1'b0; end
    endcase
    // K.28 and D.28 share x but not the sub-block pattern, so the K flag comes
    // from the pattern, not from x.
    r5b6b = {ok, (n == 6'b001111), x};
  endfunction

  // ---- reverse 3b/4b, data column ---------------------------------------
  // Unambiguous across all 14 legal data patterns.  Returns {ok, is_a7, y}.
  function automatic logic [4:0] r3b4b_d(input logic [3:0] c4);
    logic [2:0] y;
    logic       ok, a7;
    ok = 1'b1;
    a7 = 1'b0;
    case (c4)
      4'b1011, 4'b0100: y = 3'd0;
      4'b1001          : y = 3'd1;
      4'b0101          : y = 3'd2;
      4'b1100, 4'b0011: y = 3'd3;
      4'b1101, 4'b0010: y = 3'd4;
      4'b1010          : y = 3'd5;
      4'b0110          : y = 3'd6;
      4'b1110, 4'b0001: y = 3'd7;             // the primary D.x.P7
      4'b0111, 4'b1000: begin y = 3'd7; a7 = 1'b1; end // D.x.A7 / K.x.7
      default          : begin y = 3'd0; ok = 1'b0; end
    endcase
    r3b4b_d = {ok, a7, y};
  endfunction

  // ---- reverse 3b/4b, control column ------------------------------------
  // Control 3b/4b alternates even where it is balanced, so the same four bits
  // mean different y in the two RD states (0110 is K.x.1 at RD- but K.x.6 at
  // RD+).  Every control symbol has an unbalanced 5b/6b sub-block, so the
  // polarity that selects the column can be read straight off the received
  // 6b bits - no reliance on the tracked RD.  Returns {ok, y}.
  function automatic logic [3:0] r3b4b_k(input logic [3:0] c4,
                                         input logic       rd_mid);
    logic [2:0] y;
    logic       ok;
    ok = 1'b1;
    if (rd_mid == RD_NEG) begin
      case (c4)
        4'b1011: y = 3'd0;
        4'b0110: y = 3'd1;
        4'b1010: y = 3'd2;
        4'b1100: y = 3'd3;
        4'b1101: y = 3'd4;
        4'b0101: y = 3'd5;
        4'b1001: y = 3'd6;
        4'b0111: y = 3'd7;
        default: begin y = 3'd0; ok = 1'b0; end
      endcase
    end else begin
      case (c4)
        4'b0100: y = 3'd0;
        4'b1001: y = 3'd1;
        4'b0101: y = 3'd2;
        4'b0011: y = 3'd3;
        4'b0010: y = 3'd4;
        4'b1010: y = 3'd5;
        4'b0110: y = 3'd6;
        4'b1000: y = 3'd7;
        default: begin y = 3'd0; ok = 1'b0; end
      endcase
    end
    r3b4b_k = {ok, y};
  endfunction

  logic [7:0] data_c;
  logic       k_c, code_err_c, disp_err_c, rd_nxt_c;

  always_comb begin
    logic [6:0]  s6;
    logic [4:0]  s4d;
    logic [3:0]  s4k;
    logic [2:0]  n6;
    logic [4:0]  x;
    logic [2:0]  y;
    logic        ok6, k28, ok4, a7, rd_mid_bits, cand_k, cand_ok;
    logic [7:0]  cand;
    logic [10:0] e_now, e_alt;

    s6  = r5b6b(in_code[9:4]);
    ok6 = s6[6];
    k28 = s6[5];
    x   = s6[4:0];

    // Polarity entering the 3b/4b sub-block, read from the received bits.
    n6          = ones6(in_code[9:4]);
    rd_mid_bits = (n6 > 3'd3) ? RD_POS : RD_NEG; // only used when unbalanced

    y      = 3'd0;
    ok4    = 1'b0;
    a7     = 1'b0;
    cand_k = 1'b0;

    if (k28) begin
      // A control 5b/6b sub-block can only be followed by the control column.
      s4k    = r3b4b_k(in_code[3:0], rd_mid_bits);
      ok4    = s4k[3];
      y      = s4k[2:0];
      cand_k = 1'b1;
    end else begin
      s4d = r3b4b_d(in_code[3:0]);
      ok4 = s4d[4];
      a7  = s4d[3];
      y   = s4d[2:0];
      if (a7) begin
        // The alternate pattern is shared: it is D.x.A7 at the six x values
        // that need it, and K.{23,27,29,30}.7 at four others.  Anywhere else
        // it is not a codeword.
        if (x == 5'd23 || x == 5'd27 || x == 5'd29 || x == 5'd30) begin
          cand_k = 1'b1;
        end else if (!(x == 5'd11 || x == 5'd13 || x == 5'd14 ||
                       x == 5'd17 || x == 5'd18 || x == 5'd20)) begin
          ok4 = 1'b0;
        end
      end
    end

    cand    = {y, x};
    cand_ok = ok6 && ok4 && (!cand_k || k_legal(cand));

    // Verify by re-encoding the candidate through the transmit rules.  This is
    // what makes the receiver strict: a sub-block pair that no transmitter can
    // produce fails both comparisons and is reported as a code error rather
    // than being quietly accepted.
    e_now = enc_f(cand, cand_k, rd_q);
    e_alt = enc_f(cand, cand_k, ~rd_q);

    if (cand_ok && e_now[10:1] == in_code) begin
      code_err_c = 1'b0;
      disp_err_c = 1'b0;
      data_c     = cand;
      k_c        = cand_k;
    end else if (cand_ok && e_alt[10:1] == in_code) begin
      code_err_c = 1'b0;
      disp_err_c = 1'b1;   // a real codeword, but not the one RD called for
      data_c     = cand;
      k_c        = cand_k;
    end else begin
      code_err_c = 1'b1;
      disp_err_c = 1'b0;   // do not double-report a word that is not in the code
      data_c     = 8'h00;
      k_c        = 1'b0;
    end

    // RD always follows the bits that arrived, so a corrupted symbol costs at
    // most a transient RD disagreement rather than a permanent one.
    rd_nxt_c = rd_advance(in_code, rd_q);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid    <= 1'b0;
      out_data     <= 8'h00;
      out_k        <= 1'b0;
      out_code_err <= 1'b0;
      out_disp_err <= 1'b0;
      out_comma    <= 1'b0;
      rd_q         <= INIT_RD;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        out_data     <= data_c;
        out_k        <= k_c;
        out_code_err <= code_err_c;
        out_disp_err <= disp_err_c;
        out_comma    <= is_comma(in_code);
        rd_q         <= rd_nxt_c;
      end else begin
        out_code_err <= 1'b0;
        out_disp_err <= 1'b0;
        out_comma    <= 1'b0;
      end
    end
  end

  assign out_rd = rd_q;

endmodule : dec_8b10b


// ---------------------------------------------------------------------------
// codec_8b10b - the DUT: encoder, a wire with injectable bit errors, decoder
//
// err_mask is presented alongside in_data and is XORed onto the codeword that
// byte produces, so a transaction carries its own corruption and the testbench
// never has to reason about pipeline alignment.
// ---------------------------------------------------------------------------
module codec_8b10b
  import codec_8b10b_rtl_pkg::*;
#(
  parameter bit ENC_INIT_RD = RD_NEG,
  parameter bit DEC_INIT_RD = RD_NEG
) (
  input  logic       clk,
  input  logic       rst_n,

  // request
  input  logic       in_valid,
  input  logic [7:0] in_data,
  input  logic       in_k,
  input  logic [9:0] err_mask,   // bits to flip on the wire for THIS symbol

  // transmit side, 1 cycle after the request
  output logic       enc_valid,
  output logic [9:0] enc_code,   // what the transmitter produced
  output logic [9:0] wire_code,  // what the receiver actually sees
  output logic       enc_rd,
  output logic       enc_kerr,
  output logic       enc_comma,

  // receive side, 2 cycles after the request
  output logic       out_valid,
  output logic [7:0] out_data,
  output logic       out_k,
  output logic       out_code_err,
  output logic       out_disp_err,
  output logic       out_rd,
  output logic       out_comma
);

  logic [9:0] err_mask_q;

  // Delay the mask by one cycle so it lands on the codeword its own byte made.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_mask_q <= 10'b0;
    else        err_mask_q <= in_valid ? err_mask : 10'b0;
  end

  enc_8b10b #(.INIT_RD(ENC_INIT_RD)) u_enc (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .in_data   (in_data),
    .in_k      (in_k),
    .out_valid (enc_valid),
    .out_code  (enc_code),
    .out_rd    (enc_rd),
    .out_kerr  (enc_kerr),
    .out_comma (enc_comma)
  );

  assign wire_code = enc_code ^ err_mask_q;

  dec_8b10b #(.INIT_RD(DEC_INIT_RD)) u_dec (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid     (enc_valid),
    .in_code      (wire_code),
    .out_valid    (out_valid),
    .out_data     (out_data),
    .out_k        (out_k),
    .out_code_err (out_code_err),
    .out_disp_err (out_disp_err),
    .out_rd       (out_rd),
    .out_comma    (out_comma)
  );

endmodule : codec_8b10b
