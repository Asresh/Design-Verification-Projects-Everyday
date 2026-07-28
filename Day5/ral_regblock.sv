// -----------------------------------------------------------------------------
// ral_regblock.sv  -  Synthesizable APB4 slave register block with field
//                     access policies (DUT for the UVM RAL demo)
//
// A zero-wait-state APB4 slave exposing four 32-bit registers that exercise the
// common register-field access policies:
//
//   0x00  CTRL      RW    reset 0x00000000  - plain read/write
//   0x04  STATUS    RO    reset 0xDEADBEEF  - read-only; bus writes ignored
//   0x08  INTFLAGS  W1C   reset 0x00000000  - hardware sets bits (hw_event),
//                                             a bus write of 1 clears a bit
//   0x0C  SCRATCH   RW    reset 0x00000000  - plain read/write
//
// Byte-granular writes via PSTRB. PSLVERR on an out-of-range word address.
// Active-low async-assert / sync-release reset. The register storage nodes are
// named ctrl_q / status_q / intf_q / scratch_q so the UVM RAL model can attach
// back-door HDL paths to them.
// -----------------------------------------------------------------------------
module ral_regblock #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input  logic                    PCLK,
    input  logic                    PRESETn,
    // APB request channel
    input  logic                    PSEL,
    input  logic                    PENABLE,
    input  logic                    PWRITE,
    input  logic [ADDR_WIDTH-1:0]   PADDR,
    input  logic [DATA_WIDTH-1:0]   PWDATA,
    input  logic [DATA_WIDTH/8-1:0] PSTRB,
    // APB response channel
    output logic [DATA_WIDTH-1:0]   PRDATA,
    output logic                    PREADY,
    output logic                    PSLVERR,
    // Hardware event input that sets INTFLAGS bits (sticky until W1C).
    input  logic [DATA_WIDTH-1:0]   hw_event
);
    localparam int NBYTES  = DATA_WIDTH/8;
    localparam int IDX_LSB = $clog2(NBYTES);

    localparam logic [1:0] A_CTRL = 2'd0, A_STATUS = 2'd1,
                           A_INTF = 2'd2, A_SCRATCH = 2'd3;

    // Word (register) index derived from the byte address.
    logic [ADDR_WIDTH-IDX_LSB-1:0] word_addr;
    assign word_addr = PADDR[ADDR_WIDTH-1:IDX_LSB];

    logic addr_ok;
    assign addr_ok = (word_addr < 4);

    logic [1:0] idx;
    assign idx = word_addr[1:0];

    logic access_phase;
    assign access_phase = PSEL & PENABLE;

    assign PREADY  = access_phase;
    assign PSLVERR = access_phase & ~addr_ok;

    // A completing, in-range write to a given register.
    logic do_wr;
    assign do_wr = access_phase && PWRITE && PREADY && addr_ok;

    // Register storage (back-door HDL path targets).
    logic [DATA_WIDTH-1:0] ctrl_q;
    logic [DATA_WIDTH-1:0] status_q;
    logic [DATA_WIDTH-1:0] intf_q;
    logic [DATA_WIDTH-1:0] scratch_q;

    // Byte-strobed write value for the addressed register.
    function automatic logic [DATA_WIDTH-1:0] strobed(
            input logic [DATA_WIDTH-1:0] cur,
            input logic [DATA_WIDTH-1:0] wr,
            input logic [NBYTES-1:0]     strb);
        logic [DATA_WIDTH-1:0] r = cur;
        for (int b = 0; b < NBYTES; b++)
            if (strb[b]) r[8*b +: 8] = wr[8*b +: 8];
        return r;
    endfunction

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            ctrl_q    <= 32'h0000_0000;
            status_q  <= 32'hDEAD_BEEF;   // RO hardware value
            intf_q    <= 32'h0000_0000;
            scratch_q <= 32'h0000_0000;
        end else begin
            // ---- CTRL : RW ----
            if (do_wr && idx == A_CTRL)
                ctrl_q <= strobed(ctrl_q, PWDATA, PSTRB);

            // ---- STATUS : RO ---- bus writes ignored; constant hardware value.
            status_q <= 32'hDEAD_BEEF;

            // ---- INTFLAGS : W1C ----
            // A bus write of 1 (byte-strobed) clears a bit; hw_event sets bits.
            // Set wins over clear on a simultaneous cycle (no event is lost).
            begin
                logic [DATA_WIDTH-1:0] clr;
                clr = '0;
                if (do_wr && idx == A_INTF) begin
                    for (int b = 0; b < NBYTES; b++)
                        if (PSTRB[b]) clr[8*b +: 8] = PWDATA[8*b +: 8];
                end
                intf_q <= (intf_q & ~clr) | hw_event;
            end

            // ---- SCRATCH : RW ----
            if (do_wr && idx == A_SCRATCH)
                scratch_q <= strobed(scratch_q, PWDATA, PSTRB);
        end
    end

    // ---- Read mux (combinational; 0 on error/idle) ----
    always_comb begin
        PRDATA = '0;
        if (access_phase && !PWRITE && addr_ok) begin
            case (idx)
                A_CTRL    : PRDATA = ctrl_q;
                A_STATUS  : PRDATA = status_q;
                A_INTF    : PRDATA = intf_q;
                A_SCRATCH : PRDATA = scratch_q;
                default   : PRDATA = '0;
            endcase
        end
    end

endmodule
