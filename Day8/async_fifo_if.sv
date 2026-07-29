// ============================================================================
// async_fifo_if.sv - dual-clock interface for the async_fifo UVM environment
// ----------------------------------------------------------------------------
// Carries both clock domains. The write agent (driver/monitor) uses the
// wr_clk clocking blocks; the read agent uses the rd_clk clocking blocks.
// Separate driver vs monitor clocking blocks keep drive/sample skew explicit.
// ============================================================================
interface async_fifo_if #(parameter int DW = 8) (
    input logic wr_clk,
    input logic wr_rst_n,
    input logic rd_clk,
    input logic rd_rst_n
);
    // Write-domain signals
    logic          wr_en;
    logic [DW-1:0] wr_data;
    logic          wr_full;

    // Read-domain signals
    logic          rd_en;
    logic [DW-1:0] rd_data;
    logic          rd_empty;

    // ---- write-domain clocking blocks ----
    clocking wr_drv_cb @(posedge wr_clk);
        default input #1step output #1ns;
        output wr_en, wr_data;
        input  wr_full;
    endclocking

    clocking wr_mon_cb @(posedge wr_clk);
        default input #1step;
        input wr_en, wr_data, wr_full;
    endclocking

    // ---- read-domain clocking blocks ----
    clocking rd_drv_cb @(posedge rd_clk);
        default input #1step output #1ns;
        output rd_en;
        input  rd_empty, rd_data;
    endclocking

    clocking rd_mon_cb @(posedge rd_clk);
        default input #1step;
        input rd_en, rd_empty, rd_data;
    endclocking

    modport WR_DRV (clocking wr_drv_cb, input wr_rst_n);
    modport WR_MON (clocking wr_mon_cb, input wr_rst_n);
    modport RD_DRV (clocking rd_drv_cb, input rd_rst_n);
    modport RD_MON (clocking rd_mon_cb, input rd_rst_n);
endinterface
