// ============================================================================
// cache_ctrl.sv - direct-mapped, write-back, write-allocate cache controller.
// ----------------------------------------------------------------------------
// A small blocking cache sitting between a CPU-style request/response port and
// a word-wide backing-memory port.  It is deliberately the simplest cache that
// still has every interesting verification problem in it:
//
//   * write-back    - a store lands in the cache only; memory is updated later,
//                     when the line is evicted or flushed.  The cache and
//                     memory therefore DISAGREE for long stretches of time,
//                     and the whole point of the testbench is to prove the
//                     disagreement is always the intended one.
//   * write-allocate- a store that misses refills the line first, then writes
//                     into it.  So a store can generate a read burst.
//   * direct-mapped - address bits pick exactly one line, so two addresses
//                     that share an index but not a tag evict each other on
//                     every access.  Conflict thrash is one line of stimulus.
//   * blocking      - one access in flight.  That is what makes a golden
//                     reference model a *function*, and lets the scoreboard
//                     predict the exact hit/miss outcome rather than a range.
//
// Address decomposition (ADDR_W = 32, DATA_W = 32, LINE_WORDS = 4, SETS = 8):
//
//     31                     7 6     4 3   2 1  0
//    +-------------------------+-------+-----+----+
//    |          tag            | index | off |byte|
//    +-------------------------+-------+-----+----+
//              25 b               3 b    2 b   2 b
//
// Controller FSM:
//
//    IDLE --accept--> LOOKUP --hit-------------------------------> RESP
//                        |                                          ^
//                        +--miss, line dirty--> EVICT --+           |
//                        |                              v           |
//                        +--miss, line clean----------> FILL --> ALLOC
//
//    IDLE --flush_req--> FSCAN <--> FWB          (maintenance walk)
//
// EVICT writes the whole dirty line back word by word; FILL reads the whole
// new line in, one outstanding read at a time; ALLOC re-tags the line and then
// performs the access that missed.
//
// A FLUSH walks every set and writes back the dirty ones.  It deliberately
// does NOT invalidate: after a flush the lines are still resident, just clean.
// That is a real design choice and the reference model has to match it.
//
// Reset behaviour worth naming, because it is a genuine hazard and the
// testbench exercises it on purpose: reset clears valid/dirty, so any store
// that has not yet been written back is LOST.  This is correct for a cache
// with no battery-backed state, and the reference model models the data loss
// rather than pretending it does not happen.
// ============================================================================
`timescale 1ns/1ps
// verilator lint_off DECLFILENAME

module cache_ctrl #(
    parameter int ADDR_W     = 32,
    parameter int DATA_W     = 32,
    parameter int LINE_WORDS = 4,
    parameter int SETS       = 8
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- CPU request channel (valid/ready) --------------------------------
    input  logic                    cpu_req_valid,
    output logic                    cpu_req_ready,
    input  logic [ADDR_W-1:0]       cpu_req_addr,
    input  logic                    cpu_req_we,
    input  logic [DATA_W-1:0]       cpu_req_wdata,
    input  logic [DATA_W/8-1:0]     cpu_req_wstrb,

    // ---- CPU response channel (valid only; one access in flight) ----------
    output logic                    cpu_rsp_valid,
    output logic [DATA_W-1:0]       cpu_rsp_rdata,
    output logic                    cpu_rsp_hit,

    // ---- maintenance ------------------------------------------------------
    input  logic                    flush_req,
    output logic                    flush_busy,
    output logic                    flush_done,

    // ---- backing-memory port ----------------------------------------------
    // Writes are posted: accepted on valid && ready, no response.
    // Reads are single-outstanding: accepted on valid && ready, data returns
    // later on mem_rsp_valid.
    output logic                    mem_req_valid,
    input  logic                    mem_req_ready,
    output logic                    mem_req_we,
    output logic [ADDR_W-1:0]       mem_req_addr,
    output logic [DATA_W-1:0]       mem_req_wdata,
    input  logic                    mem_rsp_valid,
    input  logic [DATA_W-1:0]       mem_rsp_rdata,

    // ---- observability (free to leave unconnected in a real SoC) ----------
    output logic [3:0]              state_o,
    output logic                    stat_hit,
    output logic                    stat_miss,
    output logic                    stat_wb
);

    // ---- derived geometry --------------------------------------------------
    localparam int BYTES  = DATA_W/8;
    localparam int BYTE_W = $clog2(BYTES);         // 2
    localparam int OFF_W  = $clog2(LINE_WORDS);    // 2
    localparam int IDX_W  = $clog2(SETS);          // 3
    localparam int TAG_W  = ADDR_W - IDX_W - OFF_W - BYTE_W;
    localparam int ENTRIES = SETS * LINE_WORDS;

    // ---- FSM ---------------------------------------------------------------
    localparam logic [3:0] S_IDLE   = 4'd0;
    localparam logic [3:0] S_LOOKUP = 4'd1;
    localparam logic [3:0] S_EVICT  = 4'd2;
    localparam logic [3:0] S_FILL   = 4'd3;
    localparam logic [3:0] S_ALLOC  = 4'd4;
    localparam logic [3:0] S_RESP   = 4'd5;
    localparam logic [3:0] S_FSCAN  = 4'd6;
    localparam logic [3:0] S_FWB    = 4'd7;

    logic [3:0] state_q;

    // ---- tag / data arrays -------------------------------------------------
    logic [TAG_W-1:0]  tag_arr   [0:SETS-1];
    logic              valid_arr [0:SETS-1];
    logic              dirty_arr [0:SETS-1];
    logic [DATA_W-1:0] data_arr  [0:ENTRIES-1];

    // ---- latched request ---------------------------------------------------
    logic [ADDR_W-1:0]   req_addr_q;
    logic                req_we_q;
    logic [DATA_W-1:0]   req_wdata_q;
    logic [BYTES-1:0]    req_wstrb_q;
    logic [DATA_W-1:0]   rsp_data_q;
    logic                hit_q;

    // ---- burst / flush bookkeeping ----------------------------------------
    logic [OFF_W-1:0] cnt_q;         // word within the line
    logic             rd_pending_q;  // a fill read has been accepted, awaiting data
    logic [IDX_W:0]   fidx_q;        // flush set walker, one bit wider so it can hit SETS
    logic             flush_pend_q;

    // ---- request decode ----------------------------------------------------
    wire [OFF_W-1:0] req_off = req_addr_q[BYTE_W +: OFF_W];
    wire [IDX_W-1:0] req_idx = req_addr_q[BYTE_W+OFF_W +: IDX_W];
    wire [TAG_W-1:0] req_tag = req_addr_q[ADDR_W-1 -: TAG_W];

    wire tag_match = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);
    wire line_dirty = valid_arr[req_idx] && dirty_arr[req_idx];

    // Flat index into the data array.  Kept as a function so every use site
    // reads the same and there is one place to get the packing wrong.
    function automatic int unsigned entry_of(input logic [IDX_W-1:0] s,
                                             input logic [OFF_W-1:0] w);
        return (int'(s) * LINE_WORDS) + int'(w);
    endfunction

    // Byte-strobe merge, shared by the hit path and the allocate path.
    function automatic logic [DATA_W-1:0] merge(input logic [DATA_W-1:0] old_w,
                                                input logic [DATA_W-1:0] new_w,
                                                input logic [BYTES-1:0]  strb);
        logic [DATA_W-1:0] r;
        r = old_w;
        for (int b = 0; b < BYTES; b++)
            if (strb[b]) r[8*b +: 8] = new_w[8*b +: 8];
        return r;
    endfunction

    // ---- outputs -----------------------------------------------------------
    assign state_o       = state_q;
    // A new request is taken only from IDLE, and never ahead of a pending
    // flush: giving the flush priority is what stops a hot request stream
    // from starving maintenance forever.
    assign cpu_req_ready = (state_q == S_IDLE) && !flush_pend_q && rst_n;
    assign flush_busy    = (state_q == S_FSCAN) || (state_q == S_FWB);

    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_we    = 1'b0;
        mem_req_addr  = '0;
        mem_req_wdata = '0;
        case (state_q)
            S_EVICT: begin
                mem_req_valid = 1'b1;
                mem_req_we    = 1'b1;
                mem_req_addr  = {tag_arr[req_idx], req_idx, cnt_q, {BYTE_W{1'b0}}};
                mem_req_wdata = data_arr[entry_of(req_idx, cnt_q)];
            end
            S_FILL: begin
                mem_req_valid = !rd_pending_q;
                mem_req_we    = 1'b0;
                mem_req_addr  = {req_tag, req_idx, cnt_q, {BYTE_W{1'b0}}};
            end
            S_FWB: begin
                mem_req_valid = 1'b1;
                mem_req_we    = 1'b1;
                mem_req_addr  = {tag_arr[fidx_q[IDX_W-1:0]], fidx_q[IDX_W-1:0],
                                 cnt_q, {BYTE_W{1'b0}}};
                mem_req_wdata = data_arr[entry_of(fidx_q[IDX_W-1:0], cnt_q)];
            end
            default: ;
        endcase
    end

    // ---- sequential core ---------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= S_IDLE;
            cpu_rsp_valid<= 1'b0;
            cpu_rsp_rdata<= '0;
            cpu_rsp_hit  <= 1'b0;
            flush_done   <= 1'b0;
            stat_hit     <= 1'b0;
            stat_miss    <= 1'b0;
            stat_wb      <= 1'b0;
            req_addr_q   <= '0;
            req_we_q     <= 1'b0;
            req_wdata_q  <= '0;
            req_wstrb_q  <= '0;
            rsp_data_q   <= '0;
            hit_q        <= 1'b0;
            cnt_q        <= '0;
            rd_pending_q <= 1'b0;
            fidx_q       <= '0;
            flush_pend_q <= 1'b0;
            for (int s = 0; s < SETS; s++) begin
                valid_arr[s] <= 1'b0;
                dirty_arr[s] <= 1'b0;
                tag_arr[s]   <= '0;
            end
            // Not architecturally required - a real cache leaves the data RAM
            // alone - but it keeps the array out of X, which keeps the VCD and
            // any X-propagation check honest.
            for (int e = 0; e < ENTRIES; e++)
                data_arr[e] <= '0;
        end else begin
            // one-cycle pulses
            cpu_rsp_valid <= 1'b0;
            flush_done    <= 1'b0;
            stat_hit      <= 1'b0;
            stat_miss     <= 1'b0;
            stat_wb       <= 1'b0;

            // A flush request is remembered the cycle it is seen, whatever the
            // controller happens to be doing, and serviced from IDLE.
            if (flush_req && !flush_busy && !flush_pend_q)
                flush_pend_q <= 1'b1;

            case (state_q)

                // ---------------------------------------------------------
                S_IDLE: begin
                    if (cpu_req_valid && cpu_req_ready) begin
                        req_addr_q  <= cpu_req_addr;
                        req_we_q    <= cpu_req_we;
                        req_wdata_q <= cpu_req_wdata;
                        req_wstrb_q <= cpu_req_wstrb;
                        state_q     <= S_LOOKUP;
                    end else if (flush_pend_q || (flush_req && !flush_busy)) begin
                        fidx_q  <= '0;
                        cnt_q   <= '0;
                        state_q <= S_FSCAN;
                    end
                end

                // ---------------------------------------------------------
                S_LOOKUP: begin
                    if (tag_match) begin
                        stat_hit <= 1'b1;
                        hit_q    <= 1'b1;
                        if (req_we_q) begin
                            data_arr[entry_of(req_idx, req_off)] <=
                                merge(data_arr[entry_of(req_idx, req_off)],
                                      req_wdata_q, req_wstrb_q);
                            dirty_arr[req_idx] <= 1'b1;
                            rsp_data_q         <= '0;
                        end else begin
                            rsp_data_q <= data_arr[entry_of(req_idx, req_off)];
                        end
                        state_q <= S_RESP;
                    end else begin
                        stat_miss <= 1'b1;
                        hit_q     <= 1'b0;
                        cnt_q     <= '0;
                        if (line_dirty) begin
                            stat_wb <= 1'b1;
                            state_q <= S_EVICT;
                        end else begin
                            rd_pending_q <= 1'b0;
                            state_q      <= S_FILL;
                        end
                    end
                end

                // ---- write the resident dirty line back, word by word ----
                S_EVICT: begin
                    if (mem_req_ready) begin
                        if (cnt_q == LINE_WORDS-1) begin
                            dirty_arr[req_idx] <= 1'b0;
                            cnt_q              <= '0;
                            rd_pending_q       <= 1'b0;
                            state_q            <= S_FILL;
                        end else begin
                            cnt_q <= cnt_q + 1'b1;
                        end
                    end
                end

                // ---- pull the new line in, one outstanding read at a time --
                S_FILL: begin
                    if (!rd_pending_q && mem_req_ready) begin
                        rd_pending_q <= 1'b1;
                    end else if (rd_pending_q && mem_rsp_valid) begin
                        data_arr[entry_of(req_idx, cnt_q)] <= mem_rsp_rdata;
                        rd_pending_q                       <= 1'b0;
                        if (cnt_q == LINE_WORDS-1) begin
                            cnt_q   <= '0;
                            state_q <= S_ALLOC;
                        end else begin
                            cnt_q <= cnt_q + 1'b1;
                        end
                    end
                end

                // ---- re-tag, then perform the access that missed ----------
                S_ALLOC: begin
                    tag_arr[req_idx]   <= req_tag;
                    valid_arr[req_idx] <= 1'b1;
                    if (req_we_q) begin
                        data_arr[entry_of(req_idx, req_off)] <=
                            merge(data_arr[entry_of(req_idx, req_off)],
                                  req_wdata_q, req_wstrb_q);
                        dirty_arr[req_idx] <= 1'b1;
                        rsp_data_q         <= '0;
                    end else begin
                        dirty_arr[req_idx] <= 1'b0;
                        rsp_data_q         <= data_arr[entry_of(req_idx, req_off)];
                    end
                    state_q <= S_RESP;
                end

                // ---------------------------------------------------------
                S_RESP: begin
                    cpu_rsp_valid <= 1'b1;
                    cpu_rsp_rdata <= rsp_data_q;
                    cpu_rsp_hit   <= hit_q;
                    state_q       <= S_IDLE;
                end

                // ---- maintenance walk over every set ---------------------
                S_FSCAN: begin
                    if (fidx_q == SETS[IDX_W:0]) begin
                        flush_done   <= 1'b1;
                        flush_pend_q <= 1'b0;
                        state_q      <= S_IDLE;
                    end else if (valid_arr[fidx_q[IDX_W-1:0]] &&
                                 dirty_arr[fidx_q[IDX_W-1:0]]) begin
                        cnt_q   <= '0;
                        state_q <= S_FWB;
                    end else begin
                        fidx_q <= fidx_q + 1'b1;
                    end
                end

                S_FWB: begin
                    if (mem_req_ready) begin
                        if (cnt_q == LINE_WORDS-1) begin
                            // Flush cleans the line, it does not evict it.
                            dirty_arr[fidx_q[IDX_W-1:0]] <= 1'b0;
                            fidx_q                       <= fidx_q + 1'b1;
                            cnt_q                        <= '0;
                            state_q                      <= S_FSCAN;
                        end else begin
                            cnt_q <= cnt_q + 1'b1;
                        end
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifdef CACHE_SVA
    // ------------------------------------------------------------------
    // Protocol and internal-consistency properties.  Compiled only for the
    // simulators that implement concurrent assertions (Icarus does not), via
    // +define+CACHE_SVA in the Makefile's vcs / questa / verilator targets.
    // ------------------------------------------------------------------
    default disable iff (!rst_n);

    // A memory request, once offered, stays offered and stable until taken.
    // This is the property a bus bridge downstream would rely on.
    a_mem_req_stable: assert property (@(posedge clk)
        (mem_req_valid && !mem_req_ready) |=>
            (mem_req_valid && $stable(mem_req_addr) && $stable(mem_req_we)
             && $stable(mem_req_wdata)));

    // Read data may only arrive while a read is actually outstanding.
    a_no_stray_rsp: assert property (@(posedge clk)
        mem_rsp_valid |-> (state_q == S_FILL && rd_pending_q));

    // The CPU port only ever accepts from IDLE, and never with a flush queued.
    a_ready_only_idle: assert property (@(posedge clk)
        cpu_req_ready |-> (state_q == S_IDLE && !flush_pend_q));

    // Exactly one response per accepted request: no response can be produced
    // unless the controller is leaving S_RESP.
    a_rsp_from_resp: assert property (@(posedge clk)
        cpu_rsp_valid |-> $past(state_q == S_RESP));

    // A hit costs no memory traffic: the cycle after a hit is the response
    // cycle, and nothing is asked of memory in between.
    a_hit_is_silent: assert property (@(posedge clk)
        stat_hit |-> !mem_req_valid ##1 !mem_req_valid);

    // hit and miss are mutually exclusive outcomes of one lookup.
    a_hit_xor_miss: assert property (@(posedge clk)
        !(stat_hit && stat_miss));

    // A writeback is only ever announced for a line that really was dirty.
    a_wb_implies_dirty: assert property (@(posedge clk)
        stat_wb |-> (valid_arr[req_idx] && dirty_arr[req_idx]));

    // Progress: a fill always ends.  Once the last word of a line has been
    // requested, ALLOC is reached within a bounded number of cycles for any
    // memory that eventually answers.
    a_fill_terminates: assert property (@(posedge clk)
        (state_q == S_FILL && cnt_q == LINE_WORDS-1 && rd_pending_q
         && mem_rsp_valid) |=> (state_q == S_ALLOC));

    // flush_done is a single cycle and only ever ends a flush.
    a_flush_done_once: assert property (@(posedge clk)
        flush_done |-> ($past(state_q) == S_FSCAN && !flush_busy));

    // After ALLOC the line is resident with the requested tag.
    a_alloc_tags: assert property (@(posedge clk)
        (state_q == S_ALLOC) |=> (valid_arr[$past(req_idx)]
                                  && tag_arr[$past(req_idx)] == $past(req_tag)));

    // A response never carries X.
    a_rsp_known: assert property (@(posedge clk)
        cpu_rsp_valid |-> !$isunknown(cpu_rsp_rdata));
`endif

endmodule
// verilator lint_on DECLFILENAME
