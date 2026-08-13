// -----------------------------------------------------------------------------
// warp_scan.sv - GPU warp-level parallel prefix-sum (scan) engine
//
// A PREFIX SUM (SCAN) over a warp is one of the most heavily used GPU
// primitives: it is the workhorse behind stream compaction, radix-sort digit
// counting, sparse-matrix row pointers, histogram/CDF construction, and warp
// aggregation. CUDA exposes it directly as `__shfl`-based warp scans,
// cub::WarpScan, and thrust::inclusive_scan. The same block is exactly what a
// low-latency (HFT) pipeline drops in to keep a RUNNING CUMULATIVE VOLUME /
// order-book depth ladder or a running P&L at line rate - one distinct partial
// sum per price level, every cycle.
//
// This DUT is a fully-pipelined KOGGE-STONE scan network over an N-lane vector.
// Kogge-Stone is the data-INDEPENDENT parallel-prefix schedule (no branching,
// no divergence) that a SIMT lane-array and a pipelined ASIC/FPGA datapath both
// want: for a vector of N = 2**L lanes it runs exactly L = log2(N) add layers,
// where layer s (offset = 2**(s-1)) does  lane[i] += lane[i-offset]  for every
// i >= offset. Each layer is registered, so the pipeline has a fixed latency
// LAT = L+2 and accepts a new vector every cycle (zero-bubble).
//
// Both INCLUSIVE and EXCLUSIVE scans are supported at runtime via in_excl:
//   inclusive out[i] = sum(in[0..i])            (out[i] includes lane i)
//   exclusive out[i] = sum(in[0..i-1]), out[0]=0 (identity of + shifted right)
// Lanes are DW-bit two's-complement values summed MODULO 2**DW (well-defined
// wraparound), so signed running sums that overflow the lane width wrap
// deterministically - matching a golden modular reference exactly.
//
// Interface (streaming, one vector per cycle, zero-bubble):
//   in_valid  : a new N-lane vector is present on in_data this cycle
//   in_excl   : 0 = inclusive scan, 1 = exclusive scan
//   in_data   : N lanes packed low-lane-first, each DW bits
//   out_valid : LAT cycles later, out_data holds the scanned vector
//   out_excl  : the scan mode that produced out_data (pipeline-aligned)
//   out_data  : the scanned N-lane vector
//
// The design is parameterized (N a power of two), reset-safe, and all outputs
// are registered.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module warp_scan #(
    parameter int N  = 8,        // warp width / vector length (power of two)
    parameter int DW = 16        // per-lane data width (bits)
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              in_valid,
    input  logic              in_excl,       // 0 = inclusive, 1 = exclusive
    input  logic [N*DW-1:0]   in_data,

    output logic              out_valid,
    output logic              out_excl,
    output logic [N*DW-1:0]   out_data
);

    localparam int L   = $clog2(N);          // number of Kogge-Stone layers
    localparam int LAT = L + 2;              // input-reg + L layers + output-reg

    // -------------------------------------------------------------------------
    // Pipeline registers. pipe[0] is the registered input vector; pipe[s] is the
    // vector after Kogge-Stone add layer s (offset = 2**(s-1)). vpipe/epipe carry
    // valid + scan-mode in lock-step so out_valid/out_excl stay aligned.
    // -------------------------------------------------------------------------
    logic [DW-1:0] pipe  [0:L][0:N-1];
    logic          vpipe [0:L];
    logic          epipe [0:L];

    // ---- stage 0 : register the input vector ----
    integer s0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe[0] <= 1'b0;
            epipe[0] <= 1'b0;
            for (s0 = 0; s0 < N; s0 = s0 + 1) pipe[0][s0] <= '0;
        end else begin
            vpipe[0] <= in_valid;
            epipe[0] <= in_excl;
            for (s0 = 0; s0 < N; s0 = s0 + 1)
                pipe[0][s0] <= in_data[s0*DW +: DW];
        end
    end

    // ---- stages 1..L : one Kogge-Stone add layer each ----
    // Layer s uses offset = 2**(s-1): lane[i] <= lane[i] + lane[i-offset] for
    // i >= offset, else lane[i] passes through. Modular DW-bit add (wraparound).
    genvar gs, gi;
    generate
        for (gs = 1; gs <= L; gs = gs + 1) begin : g_stage
            localparam int OFFS = 1 << (gs - 1);
            // valid / mode shift for this layer
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vpipe[gs] <= 1'b0;
                    epipe[gs] <= 1'b0;
                end else begin
                    vpipe[gs] <= vpipe[gs-1];
                    epipe[gs] <= epipe[gs-1];
                end
            end
            for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n)
                        pipe[gs][gi] <= '0;
                    else if (gi >= OFFS)
                        pipe[gs][gi] <= pipe[gs-1][gi] + pipe[gs-1][gi-OFFS];
                    else
                        pipe[gs][gi] <= pipe[gs-1][gi];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output register: pipe[L] holds the INCLUSIVE scan. The exclusive scan is
    // that vector shifted one lane to the right with a 0 (additive identity) in
    // lane 0: out_excl -> out[i] = inclusive[i-1], out[0] = 0.
    // -------------------------------------------------------------------------
    integer so;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_excl  <= 1'b0;
            out_data  <= '0;
        end else begin
            out_valid <= vpipe[L];
            out_excl  <= epipe[L];
            for (so = 0; so < N; so = so + 1)
                out_data[so*DW +: DW] <=
                    epipe[L] ? ((so == 0) ? {DW{1'b0}} : pipe[L][so-1])
                             : pipe[L][so];
        end
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+WSCAN_SVA)
    // ------------------------------------------------------------------------
`ifdef WSCAN_SVA
    // Fixed pipeline latency: a valid input produces a valid output exactly LAT
    // cycles later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // Exclusive scan always emits the additive identity (0) in lane 0.
    a_excl_lane0_zero: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && out_excl) |-> (out_data[0 +: DW] == {DW{1'b0}}));

    // Outputs are always known while a scanned vector is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_excl, out_data}));
`endif

endmodule

`default_nettype wire
