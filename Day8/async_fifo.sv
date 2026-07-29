// ============================================================================
// async_fifo.sv - Parameterized dual-clock (CDC) asynchronous FIFO
// ----------------------------------------------------------------------------
// Classic Cummings-style asynchronous FIFO:
//   * Independent write (wr_clk) and read (rd_clk) clock domains, each with its
//     own active-low asynchronous reset.
//   * Binary + Gray-code pointers, AW+1 bits wide (the extra MSB distinguishes
//     the full and empty wrap conditions).
//   * Gray-coded pointers are crossed between domains through 2-flop
//     synchronizers so that at most one bit changes per clock -> metastability
//     resolves to a valid (possibly stale, never corrupt) pointer value.
//   * First-word-fall-through (FWFT) read: rd_data continuously presents the
//     entry at the read pointer; asserting rd_en while !rd_empty advances the
//     pointer so the next word "falls through" on the following read clock.
//   * full is generated in the write domain, empty in the read domain; both are
//     registered so downstream logic sees glitch-free flags.
//
// The design is synthesizable, reset-safe in both domains, and lint-clean.
// ============================================================================
module async_fifo #(
    parameter int DW = 8,          // data width
    parameter int AW = 4           // address width -> depth = 2**AW
) (
    // ---- write clock domain ----
    input  logic          wr_clk,
    input  logic          wr_rst_n,
    input  logic          wr_en,
    input  logic [DW-1:0] wr_data,
    output logic          wr_full,

    // ---- read clock domain ----
    input  logic          rd_clk,
    input  logic          rd_rst_n,
    input  logic          rd_en,
    output logic [DW-1:0] rd_data,
    output logic          rd_empty
);

    localparam int DEPTH = 1 << AW;

    // The full-condition part-select rd_gray_s2[AW-2:0] requires AW >= 2
    // (a depth-2 FIFO, AW=1, would underflow the slice). Flag misuse early.
    // synthesis translate_off
    initial if (AW < 2)
        $fatal(1, "async_fifo: AW must be >= 2 (got %0d)", AW);
    // synthesis translate_on

    // Dual-port memory: write port in wr_clk domain, combinational read port.
    logic [DW-1:0] mem [0:DEPTH-1];

    // Pointers (AW+1 bits; MSB is the wrap bit).
    logic [AW:0] wr_bin,  wr_bin_nxt,  wr_gray,  wr_gray_nxt;
    logic [AW:0] rd_bin,  rd_bin_nxt,  rd_gray,  rd_gray_nxt;

    // Cross-domain 2-flop synchronizers.
    logic [AW:0] wr_gray_s1, wr_gray_s2;   // write Gray pointer -> read domain
    logic [AW:0] rd_gray_s1, rd_gray_s2;   // read  Gray pointer -> write domain

    // ------------------------------------------------------------------
    // Write pointer + memory (wr_clk domain)
    // ------------------------------------------------------------------
    assign wr_bin_nxt  = wr_bin + (wr_en & ~wr_full);
    assign wr_gray_nxt = (wr_bin_nxt >> 1) ^ wr_bin_nxt;

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= '0;
            wr_gray <= '0;
        end else begin
            wr_bin  <= wr_bin_nxt;
            wr_gray <= wr_gray_nxt;
        end
    end

    always_ff @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            mem[wr_bin[AW-1:0]] <= wr_data;
    end

    // Registered full flag (write domain). full when the *next* write Gray
    // pointer equals the synchronized read pointer with the top two bits
    // inverted (the classic wrap condition).
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_full <= 1'b0;
        else
            wr_full <= (wr_gray_nxt ==
                        {~rd_gray_s2[AW:AW-1], rd_gray_s2[AW-2:0]});
    end

    // ------------------------------------------------------------------
    // Read pointer (rd_clk domain) + FWFT read data
    // ------------------------------------------------------------------
    assign rd_bin_nxt  = rd_bin + (rd_en & ~rd_empty);
    assign rd_gray_nxt = (rd_bin_nxt >> 1) ^ rd_bin_nxt;

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= '0;
            rd_gray <= '0;
        end else begin
            rd_bin  <= rd_bin_nxt;
            rd_gray <= rd_gray_nxt;
        end
    end

    // First-word-fall-through: expose the current head combinationally.
    assign rd_data = mem[rd_bin[AW-1:0]];

    // Registered empty flag (read domain).
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_empty <= 1'b1;
        else
            rd_empty <= (rd_gray_nxt == wr_gray_s2);
    end

    // ------------------------------------------------------------------
    // Cross-domain synchronizers
    // ------------------------------------------------------------------
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_s1 <= '0;
            wr_gray_s2 <= '0;
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end
    end

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_s1 <= '0;
            rd_gray_s2 <= '0;
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
        end
    end

    // ------------------------------------------------------------------
    // Assertions (bind-friendly; guarded so simulators without SVA are happy)
    // ------------------------------------------------------------------
`ifdef ASYNC_FIFO_SVA
    // No overflow: the design deliberately TOLERATES wr_en being held during
    // wr_full (the datapath gates with wr_en & ~wr_full), so we do not forbid
    // the enable - we assert the guard actually works: a write attempt while
    // full must NOT advance the write pointer (no data is admitted/corrupted).
    property p_no_overflow;
        @(posedge wr_clk) disable iff (!wr_rst_n)
            (wr_full && wr_en) |=> (wr_bin == $past(wr_bin));
    endproperty
    a_no_overflow: assert property (p_no_overflow)
        else $error("async_fifo: write pointer advanced while full (overflow)");

    // No underflow: symmetric guard on the read side.
    property p_no_underflow;
        @(posedge rd_clk) disable iff (!rd_rst_n)
            (rd_empty && rd_en) |=> (rd_bin == $past(rd_bin));
    endproperty
    a_no_underflow: assert property (p_no_underflow)
        else $error("async_fifo: read pointer advanced while empty (underflow)");

    // Gray pointers change by at most one bit per clock (single-bit CDC).
    function automatic int unsigned popcount(input logic [AW:0] v);
        popcount = 0;
        for (int i = 0; i <= AW; i++) popcount += v[i];
    endfunction
    property p_wr_gray_onebit;
        logic [AW:0] prev;
        @(posedge wr_clk) disable iff (!wr_rst_n)
            (1, prev = wr_gray) |=> (popcount(wr_gray ^ prev) <= 1);
    endproperty
    a_wr_gray_onebit: assert property (p_wr_gray_onebit)
        else $error("async_fifo: write Gray pointer changed >1 bit");
    property p_rd_gray_onebit;
        logic [AW:0] prev;
        @(posedge rd_clk) disable iff (!rd_rst_n)
            (1, prev = rd_gray) |=> (popcount(rd_gray ^ prev) <= 1);
    endproperty
    a_rd_gray_onebit: assert property (p_rd_gray_onebit)
        else $error("async_fifo: read Gray pointer changed >1 bit");
`endif

endmodule
