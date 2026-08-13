`timescale 1ns/1ps

module noc_router #(
    parameter int NPORT   = 3,
    parameter int FLIT_W  = 32,
    parameter int DEST_W  = $clog2(NPORT)
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic [NPORT-1:0]          in_valid,
    output logic [NPORT-1:0]          in_ready,
    input  logic [NPORT*FLIT_W-1:0]   in_flit,
    input  logic [NPORT*DEST_W-1:0]   in_dest,
    input  logic [NPORT-1:0]          in_last,
    output logic [NPORT-1:0]          out_valid,
    input  logic [NPORT-1:0]          out_ready,
    output logic [NPORT*FLIT_W-1:0]   out_flit,
    output logic [NPORT*DEST_W-1:0]   out_dest,
    output logic [NPORT-1:0]          out_last
);
    localparam int PTR_W = $clog2(NPORT);

    logic [NPORT-1:0]        buf_valid_q;
    logic [FLIT_W-1:0]       buf_flit_q [0:NPORT-1];
    logic [DEST_W-1:0]       buf_dest_q [0:NPORT-1];
    logic                    buf_last_q [0:NPORT-1];
    logic [PTR_W-1:0]        rr_q       [0:NPORT-1];
    integer                  winner     [0:NPORT-1];

    always_comb begin
        in_ready = ~buf_valid_q;
        out_valid = '0;
        out_flit = '0;
        out_dest = '0;
        out_last = '0;
        for (int o = 0; o < NPORT; o++) begin
            winner[o] = -1;
            for (int k = 0; k < NPORT; k++) begin
                int i;
                i = (int'(rr_q[o]) + k) % NPORT;
                if ((winner[o] < 0) && buf_valid_q[i] &&
                    (buf_dest_q[i] == DEST_W'(o)))
                    winner[o] = i;
            end
            if (winner[o] >= 0) begin
                out_valid[o] = 1'b1;
                out_flit[o*FLIT_W +: FLIT_W] = buf_flit_q[winner[o]];
                out_dest[o*DEST_W +: DEST_W] = buf_dest_q[winner[o]];
                out_last[o] = buf_last_q[winner[o]];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid_q <= '0;
            for (int o = 0; o < NPORT; o++) rr_q[o] <= '0;
            for (int i = 0; i < NPORT; i++) begin
                buf_flit_q[i] <= '0;
                buf_dest_q[i] <= '0;
                buf_last_q[i] <= 1'b0;
            end
        end else begin
            for (int o = 0; o < NPORT; o++) begin
                if (out_valid[o] && out_ready[o]) begin
                    buf_valid_q[winner[o]] <= 1'b0;
                    rr_q[o] <= (winner[o] == NPORT-1) ? '0 : PTR_W'(winner[o] + 1);
                end
            end
            for (int i = 0; i < NPORT; i++) begin
                if (in_valid[i] && in_ready[i]) begin
                    buf_valid_q[i] <= 1'b1;
                    buf_flit_q[i] <= in_flit[i*FLIT_W +: FLIT_W];
                    buf_dest_q[i] <= in_dest[i*DEST_W +: DEST_W];
                    buf_last_q[i] <= in_last[i];
                end
            end
        end
    end

`ifdef NOC_SVA
    generate
        for (genvar p = 0; p < NPORT; p++) begin : g_protocol_sva
            p_output_stable: assert property (@(posedge clk) disable iff (!rst_n)
                out_valid[p] && !out_ready[p] |=>
                out_valid[p] && $stable(out_flit[p*FLIT_W +: FLIT_W]) &&
                $stable(out_dest[p*DEST_W +: DEST_W]) && $stable(out_last[p]));
            p_legal_destination: assert property (@(posedge clk) disable iff (!rst_n)
                in_valid[p] && in_ready[p] |-> in_dest[p*DEST_W +: DEST_W] < NPORT);
            p_no_unknown_output: assert property (@(posedge clk) disable iff (!rst_n)
                out_valid[p] |-> !$isunknown({out_flit[p*FLIT_W +: FLIT_W],
                                              out_dest[p*DEST_W +: DEST_W], out_last[p]}));
        end
    endgenerate
`endif
endmodule
