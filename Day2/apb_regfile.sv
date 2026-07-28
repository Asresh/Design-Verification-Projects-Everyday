// -----------------------------------------------------------------------------
// apb_regfile.sv  -  Synthesizable APB4 slave register file (DUT)
//
// A zero-wait-state AMBA-APB (APB4) slave that exposes NUM_REGS 32-bit
// registers. Implements the classic IDLE -> SETUP -> ACCESS phase protocol:
//
//   SETUP  : PSEL=1, PENABLE=0   (address/control presented for one cycle)
//   ACCESS : PSEL=1, PENABLE=1    (transfer completes when PREADY=1)
//
// Features:
//   - Byte-granular writes via PSTRB (one strobe bit per byte lane).
//   - Combinational read data mux (PRDATA valid during ACCESS).
//   - PSLVERR on an out-of-range word address.
//   - Active-low asynchronous-assert / synchronous-release reset.
//
// The design is intentionally lint-friendly and reset-safe: every register
// clears to 0 on reset and no write occurs unless a valid ACCESS transfer
// completes to an in-range address.
// -----------------------------------------------------------------------------
module apb_regfile #(
    parameter int ADDR_WIDTH = 8,          // PADDR width (byte address)
    parameter int DATA_WIDTH = 32,         // register / data-bus width
    parameter int NUM_REGS   = 16          // number of 32-bit registers
) (
    input  logic                    PCLK,
    input  logic                    PRESETn,   // active-low reset
    // APB request channel
    input  logic                    PSEL,
    input  logic                    PENABLE,
    input  logic                    PWRITE,
    input  logic [ADDR_WIDTH-1:0]   PADDR,     // byte address
    input  logic [DATA_WIDTH-1:0]   PWDATA,
    input  logic [DATA_WIDTH/8-1:0] PSTRB,
    // APB response channel
    output logic [DATA_WIDTH-1:0]   PRDATA,
    output logic                    PREADY,
    output logic                    PSLVERR
);

    localparam int NBYTES   = DATA_WIDTH/8;
    localparam int IDX_LSB  = $clog2(NBYTES);            // word-address shift
    localparam int IDX_BITS = (NUM_REGS > 1) ? $clog2(NUM_REGS) : 1;

    // Word (register) index derived from the byte address.
    logic [ADDR_WIDTH-IDX_LSB-1:0] word_addr;
    assign word_addr = PADDR[ADDR_WIDTH-1:IDX_LSB];

    logic addr_ok;
    assign addr_ok = (word_addr < NUM_REGS[ADDR_WIDTH-IDX_LSB-1:0]);

    // ACCESS phase = the second (enable) beat of a transfer.
    logic access_phase;
    assign access_phase = PSEL & PENABLE;

    // Zero-wait-state slave: ready as soon as we are in the ACCESS phase.
    assign PREADY  = access_phase;
    // Error is only meaningful during the completing ACCESS beat.
    assign PSLVERR = access_phase & ~addr_ok;

    // Register storage.
    logic [DATA_WIDTH-1:0] regs [NUM_REGS];

    // Safe index for array access (avoids out-of-range indexing on bad addr).
    logic [IDX_BITS-1:0] idx;
    assign idx = word_addr[IDX_BITS-1:0];

    // ---- Write path (byte-strobed) ----
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            for (int r = 0; r < NUM_REGS; r++)
                regs[r] <= '0;
        end else if (access_phase && PWRITE && PREADY && addr_ok) begin
            for (int b = 0; b < NBYTES; b++)
                if (PSTRB[b])
                    regs[idx][8*b +: 8] <= PWDATA[8*b +: 8];
        end
    end

    // ---- Read path (combinational mux; 0 on error/idle) ----
    always_comb begin
        if (access_phase && !PWRITE && addr_ok)
            PRDATA = regs[idx];
        else
            PRDATA = '0;
    end

endmodule
