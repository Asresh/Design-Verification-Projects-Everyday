// -----------------------------------------------------------------------------
// apb_if.sv  -  APB4 interface + clocking blocks + protocol assertions (SVA)
//
// Shared between the UVM driver (drives the request channel) and the UVM
// monitor (samples the whole bus). Parameters mirror the DUT defaults.
// -----------------------------------------------------------------------------
interface apb_if #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input logic PCLK,
    input logic PRESETn
);
    localparam int NBYTES = DATA_WIDTH/8;

    logic                    PSEL;
    logic                    PENABLE;
    logic                    PWRITE;
    logic [ADDR_WIDTH-1:0]   PADDR;
    logic [DATA_WIDTH-1:0]   PWDATA;
    logic [NBYTES-1:0]       PSTRB;
    logic [DATA_WIDTH-1:0]   PRDATA;
    logic                    PREADY;
    logic                    PSLVERR;

    // Driver drives the request channel synchronous to PCLK.
    clocking drv_cb @(posedge PCLK);
        default input #1step output #1;
        output PSEL, PENABLE, PWRITE, PADDR, PWDATA, PSTRB;
        input  PRDATA, PREADY, PSLVERR;
    endclocking

    // Monitor is passive: sample everything.
    clocking mon_cb @(posedge PCLK);
        default input #1step;
        input PSEL, PENABLE, PWRITE, PADDR, PWDATA, PSTRB,
              PRDATA, PREADY, PSLVERR;
    endclocking

    modport drv (clocking drv_cb, input PCLK, PRESETn);
    modport mon (clocking mon_cb, input PCLK, PRESETn);

    // ------------------------------------------------------------------
    // APB protocol assertions (only meaningful under an SVA-capable sim).
    // ------------------------------------------------------------------
`ifndef APB_NO_SVA
    // After a SETUP beat (PSEL & !PENABLE) the next cycle must be ACCESS
    // (PSEL & PENABLE) while reset is de-asserted.
    property p_setup_to_access;
        @(posedge PCLK) disable iff (!PRESETn)
            (PSEL && !PENABLE) |=> (PSEL && PENABLE);
    endproperty
    a_setup_to_access: assert property (p_setup_to_access)
        else $error("APB: SETUP beat not followed by ACCESS beat");

    // Address/control must be stable from SETUP into ACCESS.
    property p_addr_stable;
        @(posedge PCLK) disable iff (!PRESETn)
            (PSEL && !PENABLE) |=> $stable(PADDR) && $stable(PWRITE);
    endproperty
    a_addr_stable: assert property (p_addr_stable)
        else $error("APB: PADDR/PWRITE changed between SETUP and ACCESS");

    // Enable is never asserted without select.
    a_enable_needs_sel: assert property (
        @(posedge PCLK) disable iff (!PRESETn) PENABLE |-> PSEL)
        else $error("APB: PENABLE asserted while PSEL low");
`endif
endinterface
