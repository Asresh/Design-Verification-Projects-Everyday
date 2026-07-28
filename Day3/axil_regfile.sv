// -----------------------------------------------------------------------------
// axil_regfile.sv  -  Synthesizable AXI4-Lite slave register file (DUT)
//
// A single-outstanding AXI4-Lite slave exposing NUM_REGS 32-bit registers.
// It implements all five AXI4-Lite channels with standard VALID/READY
// handshakes:
//
//   AW : write address   (AWADDR, AWVALID, AWREADY)
//   W  : write data       (WDATA, WSTRB, WVALID, WREADY)
//   B  : write response   (BRESP, BVALID, BREADY)
//   AR : read address     (ARADDR, ARVALID, ARREADY)
//   R  : read data         (RDATA, RRESP, RVALID, RREADY)
//
// Features:
//   - Byte-granular writes via WSTRB (one strobe per byte lane).
//   - RRESP / BRESP = OKAY (2'b00) for in-range, SLVERR (2'b10) for an
//     out-of-range word address.
//   - Out-of-range reads return 0 and never disturb stored state.
//   - Active-low asynchronous-assert / synchronous-release reset; every
//     register clears to 0 on reset.
//
// The slave processes one write and one read transaction at a time (a typical
// register-block simplification). The address and data of the write channel
// are captured independently, so AW and W may arrive in either order or the
// same cycle. AWREADY/WREADY/ARREADY are combinational (asserted while idle),
// making the handshake latency deterministic.
// -----------------------------------------------------------------------------
module axil_regfile #(
    parameter int ADDR_WIDTH = 8,          // byte-address width
    parameter int DATA_WIDTH = 32,         // register / data-bus width
    parameter int NUM_REGS   = 16          // number of 32-bit registers
) (
    input  logic                    ACLK,
    input  logic                    ARESETn,   // active-low reset
    // ---- Write address channel ----
    input  logic [ADDR_WIDTH-1:0]   AWADDR,
    input  logic                    AWVALID,
    output logic                    AWREADY,
    // ---- Write data channel ----
    input  logic [DATA_WIDTH-1:0]   WDATA,
    input  logic [DATA_WIDTH/8-1:0] WSTRB,
    input  logic                    WVALID,
    output logic                    WREADY,
    // ---- Write response channel ----
    output logic [1:0]              BRESP,
    output logic                    BVALID,
    input  logic                    BREADY,
    // ---- Read address channel ----
    input  logic [ADDR_WIDTH-1:0]   ARADDR,
    input  logic                    ARVALID,
    output logic                    ARREADY,
    // ---- Read data channel ----
    output logic [DATA_WIDTH-1:0]   RDATA,
    output logic [1:0]              RRESP,
    output logic                    RVALID,
    input  logic                    RREADY
);

    localparam int NBYTES  = DATA_WIDTH/8;
    localparam int IDX_LSB = $clog2(NBYTES);            // word-address shift
    localparam int IDX_BITS = (NUM_REGS > 1) ? $clog2(NUM_REGS) : 1;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // Register storage.
    logic [DATA_WIDTH-1:0] regs [NUM_REGS];

    // =========================================================================
    // Write channels
    // =========================================================================
    logic                  aw_hs;      // AW captured, awaiting write
    logic                  w_hs;       // W  captured, awaiting write
    logic [ADDR_WIDTH-1:0] awaddr_q;
    logic [DATA_WIDTH-1:0] wdata_q;
    logic [NBYTES-1:0]     wstrb_q;

    // Accept AW / W while idle (not yet captured and no response outstanding).
    assign AWREADY = ~aw_hs & ~BVALID;
    assign WREADY  = ~w_hs  & ~BVALID;

    // Write word index / range check from the captured address.
    logic [ADDR_WIDTH-IDX_LSB-1:0] w_word;
    logic                          w_ok;
    logic [IDX_BITS-1:0]           w_idx;
    assign w_word = awaddr_q[ADDR_WIDTH-1:IDX_LSB];
    assign w_ok   = (w_word < NUM_REGS[ADDR_WIDTH-IDX_LSB-1:0]);
    assign w_idx  = w_word[IDX_BITS-1:0];

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            aw_hs    <= 1'b0;
            w_hs     <= 1'b0;
            awaddr_q <= '0;
            wdata_q  <= '0;
            wstrb_q  <= '0;
            BVALID   <= 1'b0;
            BRESP    <= RESP_OKAY;
            for (int r = 0; r < NUM_REGS; r++)
                regs[r] <= '0;
        end else begin
            // Capture write address.
            if (AWREADY && AWVALID) begin
                aw_hs    <= 1'b1;
                awaddr_q <= AWADDR;
            end
            // Capture write data.
            if (WREADY && WVALID) begin
                w_hs    <= 1'b1;
                wdata_q <= WDATA;
                wstrb_q <= WSTRB;
            end
            // Perform the write once both halves are captured.
            if (aw_hs && w_hs && !BVALID) begin
                if (w_ok) begin
                    for (int b = 0; b < NBYTES; b++)
                        if (wstrb_q[b])
                            regs[w_idx][8*b +: 8] <= wdata_q[8*b +: 8];
                end
                BRESP  <= w_ok ? RESP_OKAY : RESP_SLVERR;
                BVALID <= 1'b1;
                aw_hs  <= 1'b0;
                w_hs   <= 1'b0;
            end
            // Write-response handshake.
            if (BVALID && BREADY)
                BVALID <= 1'b0;
        end
    end

    // =========================================================================
    // Read channels
    // =========================================================================
    logic                  ar_hs;
    logic [ADDR_WIDTH-1:0] araddr_q;

    assign ARREADY = ~ar_hs & ~RVALID;

    logic [ADDR_WIDTH-IDX_LSB-1:0] r_word;
    logic                          r_ok;
    logic [IDX_BITS-1:0]           r_idx;
    assign r_word = araddr_q[ADDR_WIDTH-1:IDX_LSB];
    assign r_ok   = (r_word < NUM_REGS[ADDR_WIDTH-IDX_LSB-1:0]);
    assign r_idx  = r_word[IDX_BITS-1:0];

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            ar_hs    <= 1'b0;
            araddr_q <= '0;
            RVALID   <= 1'b0;
            RDATA    <= '0;
            RRESP    <= RESP_OKAY;
        end else begin
            // Capture read address.
            if (ARREADY && ARVALID) begin
                ar_hs    <= 1'b1;
                araddr_q <= ARADDR;
            end
            // Produce read data one cycle after capture.
            if (ar_hs && !RVALID) begin
                RDATA  <= r_ok ? regs[r_idx] : '0;
                RRESP  <= r_ok ? RESP_OKAY : RESP_SLVERR;
                RVALID <= 1'b1;
                ar_hs  <= 1'b0;
            end
            // Read-data handshake.
            if (RVALID && RREADY)
                RVALID <= 1'b0;
        end
    end

endmodule
