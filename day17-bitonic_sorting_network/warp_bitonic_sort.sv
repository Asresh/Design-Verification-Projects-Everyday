// -----------------------------------------------------------------------------
// warp_bitonic_sort.sv - GPU warp-level bitonic sorting network
//
// Sorting a warp of N keys in a fixed number of clock cycles is a core GPU
// primitive: CUDA/Thrust, cub::BlockRadixSort, and every GPU top-K / order-book
// selection kernel lean on a BITONIC SORTING NETWORK because its comparator
// schedule is data-INDEPENDENT (no branching, no divergence) - exactly what a
// SIMT lane-array and a pipelined ASIC/FPGA datapath both want. The same block
// is what a low-latency (HFT) pipeline drops in to keep a price ladder / top of
// book in priority order at line rate.
//
// This DUT is a fully-pipelined bitonic sorter over N records. Each record is
// {key, tag}: the KEY_W-bit sort key in the high bits and a TAG_W-bit tie-break
// tag in the low bits, so comparing the whole RW = KEY_W+TAG_W-bit record as one
// unsigned number gives a TOTAL order (key first, tag breaks ties). That makes
// the sort deterministic even with duplicate keys - the tag acts like an
// order-id / arrival stamp, i.e. price-then-tag priority.
//
// Interface (streaming, one vector per cycle, zero-bubble):
//   in_valid  : a new N-record vector is present on in_data this cycle
//   in_dir    : 0 = ascending (record[0] smallest), 1 = descending
//   in_data   : N records packed low-lane-first, each RW bits {key,tag}
//   out_valid : LAT cycles later, out_data holds the sorted vector
//   out_dir   : the direction that produced out_data (pipeline-aligned with it)
//   out_data  : the sorted N-record vector
//
// The comparator schedule is the classic Batcher bitonic network: for a vector
// of N = 2**L records it runs NSTAGE = L*(L+1)/2 compare-exchange layers, built
// here with a nested generate (k = 2,4,..,N; j = k/2,..,1). Every layer is
// registered, so the pipeline has a fixed latency LAT = NSTAGE+1 and accepts a
// new vector every cycle. The design is parameterized (N a power of two),
// reset-safe, and all outputs are registered.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module warp_bitonic_sort #(
    parameter int N     = 8,        // warp width / vector length (power of two)
    parameter int KEY_W = 6,        // sort-key width
    parameter int TAG_W = 2         // tie-break tag width (0 = keys only)
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                in_valid,
    input  logic                in_dir,        // 0 = ascending, 1 = descending
    input  logic [N*(KEY_W+TAG_W)-1:0] in_data,

    output logic                out_valid,
    output logic                out_dir,
    output logic [N*(KEY_W+TAG_W)-1:0] out_data
);

    localparam int RW     = KEY_W + TAG_W;                 // full record width
    localparam int L      = $clog2(N);                     // log2 of vector length
    localparam int NSTAGE = (L * (L + 1)) / 2;             // compare-exchange layers
    localparam int LAT    = NSTAGE + 1;                    // input-register + layers

    // -------------------------------------------------------------------------
    // Elaboration-time helper: 1-based layer index of the Batcher (k,j) sub-stage
    // in the reference double loop
    //     for (k = 2; k <= N; k <<= 1)
    //         for (j = k>>1; j > 0; j >>= 1)   // one layer per (k,j)
    // Used only to index the pipeline registers - never called at run time.
    // -------------------------------------------------------------------------
    function automatic int stage_of(input int kq, input int jq);
        int cnt;
        cnt = 0;
        for (int k = 2; k <= N; k = k << 1)
            for (int j = k >> 1; j > 0; j = j >> 1) begin
                cnt++;
                if (k == kq && j == jq) return cnt;
            end
        return 0;
    endfunction

    // -------------------------------------------------------------------------
    // Pipeline registers. pipe[0] is the registered input vector; pipe[s] is the
    // vector after compare-exchange layer s. vpipe/dpipe carry valid + direction
    // in lock-step so out_valid/out_dir stay aligned with out_data.
    // -------------------------------------------------------------------------
    logic [RW-1:0] pipe  [0:NSTAGE][0:N-1];
    logic          vpipe [0:NSTAGE];
    logic          dpipe [0:NSTAGE];

    // ---- stage 0 : register the input vector ----
    integer s0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe[0] <= 1'b0;
            dpipe[0] <= 1'b0;
            for (s0 = 0; s0 < N; s0 = s0 + 1) pipe[0][s0] <= '0;
        end else begin
            vpipe[0] <= in_valid;
            dpipe[0] <= in_dir;
            for (s0 = 0; s0 < N; s0 = s0 + 1)
                pipe[0][s0] <= in_data[s0*RW +: RW];
        end
    end

    // ---- stages 1..NSTAGE : one bitonic compare-exchange layer per (k,j) ----
    genvar gk, gj, gi;
    generate
        for (gk = 2; gk <= N; gk = gk * 2) begin : g_k
            for (gj = gk / 2; gj > 0; gj = gj / 2) begin : g_j
                localparam int S = stage_of(gk, gj);
                // valid / direction shift for this layer
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        vpipe[S] <= 1'b0;
                        dpipe[S] <= 1'b0;
                    end else begin
                        vpipe[S] <= vpipe[S-1];
                        dpipe[S] <= dpipe[S-1];
                    end
                end
                // one compare-exchange per lane pair (lower index drives both)
                for (gi = 0; gi < N; gi = gi + 1) begin : g_i
                    if ((gi ^ gj) > gi) begin : g_ce
                        localparam int PART = gi ^ gj;
                        // ascending comparator when (gi & gk)==0, flipped by dir
                        localparam logic ASC0 = ((gi & gk) == 0) ? 1'b1 : 1'b0;
                        logic          asc;
                        logic [RW-1:0] a, b, lo, hi;
                        always_comb begin
                            asc = ASC0 ^ dpipe[S-1];
                            a   = pipe[S-1][gi];
                            b   = pipe[S-1][PART];
                            lo  = (a <= b) ? a : b;
                            hi  = (a <= b) ? b : a;
                        end
                        always_ff @(posedge clk or negedge rst_n) begin
                            if (!rst_n) begin
                                pipe[S][gi]   <= '0;
                                pipe[S][PART] <= '0;
                            end else begin
                                pipe[S][gi]   <= asc ? lo : hi;  // ordered pair
                                pipe[S][PART] <= asc ? hi : lo;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Outputs = the final pipeline stage.
    // -------------------------------------------------------------------------
    integer so;
    always_comb begin
        out_valid = vpipe[NSTAGE];
        out_dir   = dpipe[NSTAGE];
        for (so = 0; so < N; so = so + 1)
            out_data[so*RW +: RW] = pipe[NSTAGE][so];
    end

    // ------------------------------------------------------------------------
    // Assertion-based verification (enable with +define+BSORT_SVA)
    // ------------------------------------------------------------------------
`ifdef BSORT_SVA
    // Fixed pipeline latency: a valid input produces a valid output exactly LAT
    // cycles later.
    a_latency: assert property (@(posedge clk) disable iff (!rst_n)
        in_valid |-> ##(LAT) out_valid);

    // The output vector is monotonic in the requested direction (ascending puts
    // the smallest record at lane 0, descending the largest), checked as an
    // adjacent-lane ordering unrolled per lane and split by direction.
    genvar ga;
    generate
        for (ga = 0; ga < N-1; ga = ga + 1) begin : g_order
            a_mono_asc: assert property (@(posedge clk) disable iff (!rst_n)
                (out_valid && !out_dir) |->
                    (out_data[ga*RW +: RW] <= out_data[(ga+1)*RW +: RW]));
            a_mono_desc: assert property (@(posedge clk) disable iff (!rst_n)
                (out_valid &&  out_dir) |->
                    (out_data[ga*RW +: RW] >= out_data[(ga+1)*RW +: RW]));
        end
    endgenerate

    // Outputs are always known while a sorted vector is presented.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> !$isunknown({out_dir, out_data}));
`endif

endmodule

`default_nettype wire
