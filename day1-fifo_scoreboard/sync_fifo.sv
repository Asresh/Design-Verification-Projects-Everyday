// -----------------------------------------------------------------------------
// sync_fifo.sv
// Parameterized synchronous (single-clock) FIFO.
//
// Classic, synthesizable, reset-safe FIFO with full/empty status flags and an
// occupancy count. Simultaneous read+write when neither full nor empty keeps
// the occupancy unchanged (a "pass-through" cycle at the pointer level).
//
// Behavior contract (what the testbench verifies):
//   * A write is accepted only when wr_en=1 && !full.
//   * A read is accepted only when rd_en=1 && !empty.
//   * Data comes out in the exact order it went in (first-in first-out).
//   * empty asserts when count==0, full asserts when count==DEPTH.
//   * count never exceeds DEPTH and never underflows below 0.
// -----------------------------------------------------------------------------
module sync_fifo #(
    parameter int WIDTH = 8,       // data width in bits
    parameter int DEPTH = 8        // number of entries (power of two recommended)
) (
    input  logic                     clk,
    input  logic                     rst_n,     // active-low synchronous reset
    input  logic                     wr_en,
    input  logic [WIDTH-1:0]         wr_data,
    input  logic                     rd_en,
    output logic [WIDTH-1:0]         rd_data,
    output logic                     full,
    output logic                     empty,
    output logic [$clog2(DEPTH):0]   count      // 0 .. DEPTH (needs +1 bit)
);

    // Address width for the storage array.
    localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    logic [WIDTH-1:0] mem [DEPTH];
    logic [AW-1:0]    wr_ptr;
    logic [AW-1:0]    rd_ptr;

    // Qualified (accepted) operations.
    wire do_wr = wr_en & ~full;
    wire do_rd = rd_en & ~empty;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= (wr_ptr == AW'(DEPTH-1)) ? '0 : wr_ptr + AW'(1);
            end
            if (do_rd) begin
                rd_ptr <= (rd_ptr == AW'(DEPTH-1)) ? '0 : rd_ptr + AW'(1);
            end
            // Occupancy update: changes only when exactly one of read/write fires.
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;    // 2'b00 or 2'b11 -> unchanged
            endcase
        end
    end

    // Combinational data output: shows the entry at the current read pointer.
    assign rd_data = mem[rd_ptr];
    assign empty   = (count == '0);
    assign full    = (count == DEPTH[$clog2(DEPTH):0]);

endmodule
