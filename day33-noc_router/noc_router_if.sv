`timescale 1ns/1ps

interface noc_router_if #(parameter int NPORT=3, FLIT_W=32,
                          DEST_W=$clog2(NPORT)) (input logic clk);
    logic rst_n;
    logic [NPORT-1:0] in_valid, in_ready, in_last;
    logic [NPORT*FLIT_W-1:0] in_flit;
    logic [NPORT*DEST_W-1:0] in_dest;
    logic [NPORT-1:0] out_valid, out_ready, out_last;
    logic [NPORT*FLIT_W-1:0] out_flit;
    logic [NPORT*DEST_W-1:0] out_dest;

    clocking drv_cb @(posedge clk);
        default input #1step output #1ns;
        output in_valid, in_flit, in_dest, in_last, out_ready;
        input in_ready, out_valid, out_flit, out_dest, out_last;
    endclocking
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_ready, in_flit, in_dest, in_last,
              out_valid, out_ready, out_flit, out_dest, out_last;
    endclocking

`ifdef NOC_SVA
    generate for (genvar p=0; p<NPORT; p++) begin : g_if_sva
        p_input_stable: assert property (@(posedge clk) disable iff (!rst_n)
            in_valid[p] && !in_ready[p] |=> in_valid[p] &&
            $stable(in_flit[p*FLIT_W +: FLIT_W]) &&
            $stable(in_dest[p*DEST_W +: DEST_W]) && $stable(in_last[p]));
    end endgenerate
`endif
endinterface
