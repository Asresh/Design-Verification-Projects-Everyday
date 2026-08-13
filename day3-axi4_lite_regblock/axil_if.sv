// -----------------------------------------------------------------------------
// axil_if.sv  -  AXI4-Lite interface + clocking blocks + protocol assertions
//
// Shared between the UVM driver (drives the master side of all five channels)
// and the UVM monitor (samples the whole bus). Parameters mirror the DUT.
// -----------------------------------------------------------------------------
interface axil_if #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input logic ACLK,
    input logic ARESETn
);
    localparam int NBYTES = DATA_WIDTH/8;

    // AW
    logic [ADDR_WIDTH-1:0] AWADDR;
    logic                  AWVALID, AWREADY;
    // W
    logic [DATA_WIDTH-1:0] WDATA;
    logic [NBYTES-1:0]     WSTRB;
    logic                  WVALID, WREADY;
    // B
    logic [1:0]            BRESP;
    logic                  BVALID, BREADY;
    // AR
    logic [ADDR_WIDTH-1:0] ARADDR;
    logic                  ARVALID, ARREADY;
    // R
    logic [DATA_WIDTH-1:0] RDATA;
    logic [1:0]            RRESP;
    logic                  RVALID, RREADY;

    // Master driver drives all request channels + response readies.
    clocking drv_cb @(posedge ACLK);
        default input #1step output #1;
        output AWADDR, AWVALID, WDATA, WSTRB, WVALID, BREADY,
               ARADDR, ARVALID, RREADY;
        input  AWREADY, WREADY, BRESP, BVALID, ARREADY, RDATA, RRESP, RVALID;
    endclocking

    // Passive monitor: sample everything.
    clocking mon_cb @(posedge ACLK);
        default input #1step;
        input AWADDR, AWVALID, AWREADY, WDATA, WSTRB, WVALID,
              BRESP, BVALID, BREADY, ARADDR, ARVALID, ARREADY,
              RDATA, RRESP, RVALID, RREADY;
    endclocking

    modport drv (clocking drv_cb, input ACLK, ARESETn);
    modport mon (clocking mon_cb, input ACLK, ARESETn);

    // ------------------------------------------------------------------
    // AXI4-Lite protocol assertions (only meaningful under an SVA sim).
    // ------------------------------------------------------------------
`ifndef AXI_NO_SVA
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // Helper: VALID must stay asserted until its READY completes the beat,
    // and the payload must be stable across the stall.
    property p_valid_stable(valid, ready);
        @(posedge ACLK) disable iff (!ARESETn)
            (valid && !ready) |=> valid;
    endproperty
    a_aw_valid_stable: assert property (p_valid_stable(AWVALID, AWREADY))
        else $error("AXI: AWVALID dropped before AWREADY");
    a_w_valid_stable : assert property (p_valid_stable(WVALID, WREADY))
        else $error("AXI: WVALID dropped before WREADY");
    a_b_valid_stable : assert property (p_valid_stable(BVALID, BREADY))
        else $error("AXI: BVALID dropped before BREADY");
    a_ar_valid_stable: assert property (p_valid_stable(ARVALID, ARREADY))
        else $error("AXI: ARVALID dropped before ARREADY");
    a_r_valid_stable : assert property (p_valid_stable(RVALID, RREADY))
        else $error("AXI: RVALID dropped before RREADY");

    // Write-address payload stable while AWVALID stalled.
    property p_aw_payload_stable;
        @(posedge ACLK) disable iff (!ARESETn)
            (AWVALID && !AWREADY) |=> $stable(AWADDR);
    endproperty
    a_aw_payload_stable: assert property (p_aw_payload_stable)
        else $error("AXI: AWADDR changed while AWVALID stalled");

    // Write-data payload stable while WVALID stalled.
    property p_w_payload_stable;
        @(posedge ACLK) disable iff (!ARESETn)
            (WVALID && !WREADY) |=> $stable(WDATA) && $stable(WSTRB);
    endproperty
    a_w_payload_stable: assert property (p_w_payload_stable)
        else $error("AXI: WDATA/WSTRB changed while WVALID stalled");

    // Read-data payload stable while RVALID stalled.
    property p_r_payload_stable;
        @(posedge ACLK) disable iff (!ARESETn)
            (RVALID && !RREADY) |=> $stable(RDATA) && $stable(RRESP);
    endproperty
    a_r_payload_stable: assert property (p_r_payload_stable)
        else $error("AXI: RDATA/RRESP changed while RVALID stalled");

    // Responses are restricted to OKAY / SLVERR for this slave (no AXI4-Lite
    // EXOKAY; DECERR is not produced - out-of-range maps to SLVERR).
    a_bresp_legal: assert property (
        @(posedge ACLK) disable iff (!ARESETn)
            BVALID |-> (BRESP == RESP_OKAY || BRESP == RESP_SLVERR))
        else $error("AXI: illegal BRESP");
    a_rresp_legal: assert property (
        @(posedge ACLK) disable iff (!ARESETn)
            RVALID |-> (RRESP == RESP_OKAY || RRESP == RESP_SLVERR))
        else $error("AXI: illegal RRESP");

    // No response VALID may be asserted during reset.
    a_no_bvalid_in_reset: assert property (
        @(posedge ACLK) (!ARESETn) |-> !BVALID)
        else $error("AXI: BVALID asserted during reset");
    a_no_rvalid_in_reset: assert property (
        @(posedge ACLK) (!ARESETn) |-> !RVALID)
        else $error("AXI: RVALID asserted during reset");
`endif
endinterface
