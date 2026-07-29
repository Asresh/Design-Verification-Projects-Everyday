// ============================================================================
// axis_skid_if.sv - SystemVerilog interface for the AXI4-Stream skid buffer.
//
// Bundles BOTH AXI-Stream channels of the DUT:
//   * slave  (upstream)   : s_* - driven by the MASTER (source) agent
//   * master (downstream) : m_* - the m_tready back-pressure line is driven by
//                                  the SLAVE (sink) agent; the rest are DUT
//                                  outputs observed by that agent's monitor.
//
// A clocking-block-free interface keeps the example portable; the UVM
// driver/monitor sample and drive on the posedge of `clk`.
// ============================================================================
interface axis_skid_if #(
    parameter int DATA_WIDTH = 8,
    parameter int KEEP_WIDTH = (DATA_WIDTH + 7) / 8
) (input logic clk, input logic rst_n);

    // Slave (upstream) channel
    logic                    s_tvalid;
    logic                    s_tready;
    logic [DATA_WIDTH-1:0]   s_tdata;
    logic [KEEP_WIDTH-1:0]   s_tkeep;
    logic                    s_tlast;

    // Master (downstream) channel
    logic                    m_tvalid;
    logic                    m_tready;
    logic [DATA_WIDTH-1:0]   m_tdata;
    logic [KEEP_WIDTH-1:0]   m_tkeep;
    logic                    m_tlast;
endinterface
