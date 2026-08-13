`timescale 1ns/1ps
module tb_noc_router_dump;
    import noc_ref_pkg::*;
    localparam int N=3, FW=32, DW=2, QDEPTH=4096;
    logic clk=0, rst_n=0;
    logic [N-1:0] in_valid, in_ready, in_last;
    logic [N*FW-1:0] in_flit;
    logic [N*DW-1:0] in_dest;
    logic [N-1:0] out_valid, out_ready, out_last;
    logic [N*FW-1:0] out_flit;
    logic [N*DW-1:0] out_dest;

    logic [FW-1:0] q_data [0:N-1][0:N-1][0:QDEPTH-1];
    logic q_last [0:N-1][0:N-1][0:QDEPTH-1];
    integer q_head [0:N-1][0:N-1], q_tail [0:N-1][0:N-1];
    integer sent, received, errors, cycle, directed_phase;

    noc_router #(.NPORT(N),.FLIT_W(FW),.DEST_W(DW)) dut (.*);
    always #5 clk = ~clk;

    task automatic drive_flit(input int p, input int d, input int serial,
                               input bit last);
        in_valid[p] = 1'b1;
        in_dest[p*DW +: DW] = d[DW-1:0];
        in_flit[p*FW +: FW] = {p[1:0], serial[21:0], d[1:0], 6'h15};
        in_last[p] = last;
    endtask

    initial begin
        $dumpfile("tb_noc_router_dump.vcd");
        $dumpvars(0,tb_noc_router_dump);
        ref_selfcheck();
        in_valid='0; in_flit='0; in_dest='0; in_last='0; out_ready='0;
        sent=0; received=0; errors=0; cycle=0; directed_phase=1;
        for (int o=0;o<N;o++) for (int s=0;s<N;s++) begin
            q_head[o][s]=0; q_tail[o][s]=0;
        end
        repeat(3) @(posedge clk);
        rst_n <= 1;
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            in_valid='0; out_ready='0;
        end else begin
            cycle++;
            out_ready = (cycle < 18) ? ((cycle==8 || cycle==9) ? 3'b101 : 3'b111)
                                     : $urandom_range(1,7);
            for (int p=0;p<N;p++) begin
                if (in_valid[p] && !in_ready[p]) begin
                    // Hold payload stable until accepted.
                end else if (directed_phase && cycle <= 10) begin
                    drive_flit(p, 1, cycle*3+p, cycle==10);
                end else if (cycle < 510 && $urandom_range(0,99) < 70) begin
                    drive_flit(p, $urandom_range(0,N-1), cycle*3+p,
                               $urandom_range(0,4)==0);
                end else begin
                    in_valid[p] = 1'b0;
                end
            end
            if (cycle > 10) directed_phase=0;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            // Sample the handshake at the active edge, before the DUT's
            // nonblocking state updates change ready/valid for the next cycle.
            for (int p=0;p<N;p++) if (in_valid[p] && in_ready[p]) begin
                int d;
                d = in_dest[p*DW +: DW];
                if (d >= N) begin errors++; $error("illegal generated destination"); end
                else begin
                    q_data[d][p][q_tail[d][p]] = in_flit[p*FW +: FW];
                    q_last[d][p][q_tail[d][p]] = in_last[p];
                    q_tail[d][p]++;
                    sent++;
                end
            end
            for (int o=0;o<N;o++) if (out_valid[o] && out_ready[o]) begin
                logic [FW-1:0] got;
                int src;
                got = out_flit[o*FW +: FW];
                src = got[FW-1 -: 2];
                if (out_dest[o*DW +: DW] != o) begin
                    errors++; $error("misroute: output %0d carries destination %0d",o,out_dest[o*DW +: DW]);
                end else if (src >= N || q_head[o][src] == q_tail[o][src]) begin
                    errors++; $error("unexpected/duplicate flit on output %0d",o);
                end else begin
                    if (got !== q_data[o][src][q_head[o][src]] ||
                        out_last[o] !== q_last[o][src][q_head[o][src]]) begin
                        errors++; $error("per-source ordering/data mismatch o=%0d src=%0d",o,src);
                    end
                    q_head[o][src]++;
                    received++;
                end
            end
            if (cycle==600) begin
                for (int o=0;o<N;o++) for (int s=0;s<N;s++)
                    if (q_head[o][s] != q_tail[o][s]) begin
                        errors++; $error("lost flits o=%0d src=%0d pending=%0d",o,s,q_tail[o][s]-q_head[o][s]);
                    end
                if (sent != received) begin errors++; $error("sent=%0d received=%0d",sent,received); end
                $display("Checked %0d routed flits with directed contention and random backpressure",received);
                if (errors==0) $display("RESULT: *** PASS ***");
                else $display("RESULT: *** FAIL *** (%0d errors)",errors);
                $finish;
            end
        end
    end

    initial begin
        #100000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1);
    end
endmodule
