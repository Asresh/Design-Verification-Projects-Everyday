// ============================================================================
// cache_ref_pkg.sv - the golden reference model for the write-back cache.
// ----------------------------------------------------------------------------
// The model is written from the *contract* the cache offers, not from the RTL.
// It has no FSM, no burst counters, no handshakes and no notion of a clock.
// It keeps three things:
//
//   ref_arch[w]  the ARCHITECTURAL value of word w - what a read of w must
//                return.  This is the value the programmer believes is there.
//
//   ref_back[w]  what BACKING MEMORY should physically contain.  It lags
//                ref_arch for any word inside a resident dirty line, and
//                catches up when that line is evicted or flushed.
//
//   valid/dirty/tag per set - the minimum needed to predict hit vs miss and
//                to know when ref_back must catch up.
//
// Splitting "true value" from "value in DRAM" is the whole trick.  A cache
// bug is almost never "the read returned garbage"; it is "the read was right
// but memory quietly kept a stale copy", or "the line was written back to the
// wrong address".  A model that only tracks one memory image cannot tell the
// difference.  Tracking both means the testbench can assert two independent
// things: every read matches ref_arch as it happens, and after a flush the
// memory the DUT actually wrote matches ref_back word for word.
//
// Reset is modelled honestly.  The DUT's reset clears valid/dirty, which
// throws away every store that has not been written back yet.  ref_hw_reset()
// therefore rolls ref_arch back to ref_back for the dirty lines: after a
// reset, reads legitimately return the OLD data.  Pretending otherwise would
// make the model disagree with a correct DUT, and the natural "fix" - relaxing
// the check - would blind the testbench to real data-loss bugs.
//
// Everything is a plain function over package-scope state so the same model
// compiles under Icarus (which has no classes worth relying on and no UVM) and
// under a UVM simulator, where the scoreboard calls exactly these functions.
// ============================================================================
`timescale 1ns/1ps

package cache_ref_pkg;

    // ---- geometry, fixed to match tb_top / the dump TB ---------------------
    localparam int REF_ADDR_W     = 32;
    localparam int REF_DATA_W     = 32;
    localparam int REF_BYTES      = REF_DATA_W/8;      // 4
    localparam int REF_LINE_WORDS = 4;
    localparam int REF_SETS       = 8;

    localparam int REF_BYTE_W = 2;
    localparam int REF_OFF_W  = 2;
    localparam int REF_IDX_W  = 3;
    localparam int REF_TAG_W  = REF_ADDR_W - REF_IDX_W - REF_OFF_W - REF_BYTE_W;

    // The testbench works inside a 1 KB window, which is 8 distinct tags per
    // set - enough for deep conflict thrash while keeping the model a plain
    // array instead of an associative one (Icarus will not index an
    // associative array by a type name).
    localparam int REF_TAGS    = 8;
    localparam int REF_NLINES  = REF_TAGS * REF_SETS;              // 64
    localparam int REF_NWORDS  = REF_NLINES * REF_LINE_WORDS;      // 256
    localparam int REF_WINDOW  = REF_NWORDS * REF_BYTES;           // 0x400

    // ---- model state -------------------------------------------------------
    logic [REF_DATA_W-1:0] ref_arch [0:REF_NWORDS-1];
    logic [REF_DATA_W-1:0] ref_back [0:REF_NWORDS-1];

    logic                 ref_valid [0:REF_SETS-1];
    logic                 ref_dirty [0:REF_SETS-1];
    logic [REF_TAG_W-1:0] ref_tag   [0:REF_SETS-1];

    int ref_hits;
    int ref_misses;
    int ref_evicts;
    int ref_fills;
    int ref_flush_wbs;

    // ---- the outcome of one access ----------------------------------------
    // Packed so it can be pushed into a `bit [34:0] q[$]` when a queue is
    // wanted; Icarus will not hold a queue of named structs.
    typedef struct packed {
        logic [REF_DATA_W-1:0] rdata;   // meaningful for reads; 0 for writes
        logic                  hit;
        logic                  evict;   // a dirty line had to be written back
        logic                  fill;    // a line was pulled in from memory
    } ref_rsp_t;
    localparam int REF_RSP_W = REF_DATA_W + 3;

    // ========================================================================
    // Address decomposition
    // ========================================================================
    function automatic int ref_word_index(input logic [REF_ADDR_W-1:0] a);
        return int'(a >> REF_BYTE_W) % REF_NWORDS;
    endfunction

    function automatic logic [REF_OFF_W-1:0] ref_off(input logic [REF_ADDR_W-1:0] a);
        return a[REF_BYTE_W +: REF_OFF_W];
    endfunction

    function automatic logic [REF_IDX_W-1:0] ref_idx(input logic [REF_ADDR_W-1:0] a);
        return a[REF_BYTE_W+REF_OFF_W +: REF_IDX_W];
    endfunction

    function automatic logic [REF_TAG_W-1:0] ref_tag_of(input logic [REF_ADDR_W-1:0] a);
        return a[REF_ADDR_W-1 -: REF_TAG_W];
    endfunction

    // First word of the line that (tag, set) names, as a word index.
    function automatic int ref_line_base(input logic [REF_TAG_W-1:0] t,
                                         input logic [REF_IDX_W-1:0] s);
        return ((int'(t) * REF_SETS) + int'(s)) * REF_LINE_WORDS;
    endfunction

    // Byte address of a word index - the address the DUT should present on the
    // memory port when it moves that word.
    function automatic logic [REF_ADDR_W-1:0] ref_byte_addr(input int wi);
        logic [REF_ADDR_W-1:0] a;
        a = wi << REF_BYTE_W;
        return a;
    endfunction

    // ========================================================================
    // Memory contents at power-up.  Deterministic, so the DUT's backing-memory
    // model and the reference model can be seeded identically without either
    // one telling the other what it chose.
    // ========================================================================
    function automatic logic [REF_DATA_W-1:0] ref_init_word(input int wi);
        logic [31:0] w;
        w = 32'h1000_0000 + (wi * 32'h0001_0193);
        w = w ^ {w[15:0], w[31:16]};
        w = w + 32'hA5A5_0000 + wi[7:0];
        return w;
    endfunction

    // ========================================================================
    // Lifecycle
    // ========================================================================
    function automatic void ref_model_init();
        for (int i = 0; i < REF_NWORDS; i++) begin
            ref_arch[i] = ref_init_word(i);
            ref_back[i] = ref_arch[i];
        end
        for (int s = 0; s < REF_SETS; s++) begin
            ref_valid[s] = 1'b0;
            ref_dirty[s] = 1'b0;
            ref_tag[s]   = '0;
        end
        ref_hits      = 0;
        ref_misses    = 0;
        ref_evicts    = 0;
        ref_fills     = 0;
        ref_flush_wbs = 0;
    endfunction

    // Model the DUT's asynchronous reset.  Valid and dirty are cleared, which
    // means every store still sitting in a dirty line is DISCARDED - so the
    // architectural view rolls back to whatever memory holds.
    function automatic void ref_hw_reset();
        int base;
        for (int s = 0; s < REF_SETS; s++) begin
            if (ref_valid[s] && ref_dirty[s]) begin
                base = ref_line_base(ref_tag[s], s[REF_IDX_W-1:0]);
                for (int w = 0; w < REF_LINE_WORDS; w++)
                    ref_arch[base + w] = ref_back[base + w];
            end
            ref_valid[s] = 1'b0;
            ref_dirty[s] = 1'b0;
            ref_tag[s]   = '0;
        end
    endfunction

    // ========================================================================
    // The line-level primitive both eviction and flush are made of: memory
    // catches up with the architectural value of the line, and it stops being
    // dirty.
    // ========================================================================
    function automatic void ref_writeback(input logic [REF_IDX_W-1:0] s);
        int base;
        base = ref_line_base(ref_tag[s], s);
        for (int w = 0; w < REF_LINE_WORDS; w++)
            ref_back[base + w] = ref_arch[base + w];
        ref_dirty[s] = 1'b0;
    endfunction

    // ========================================================================
    // One CPU access.  Returns the data a read must produce and whether the
    // access should have hit - both of which the scoreboard compares against
    // what the DUT actually did.
    // ========================================================================
    function automatic ref_rsp_t ref_access(input logic [REF_ADDR_W-1:0] addr,
                                            input logic                 we,
                                            input logic [REF_DATA_W-1:0] wdata,
                                            input logic [REF_BYTES-1:0]  wstrb);
        ref_rsp_t r;
        logic [REF_IDX_W-1:0] s;
        logic [REF_TAG_W-1:0] t;
        int                   wi;
        logic [REF_DATA_W-1:0] cur;

        s  = ref_idx(addr);
        t  = ref_tag_of(addr);
        wi = ref_word_index(addr);

        r.rdata = '0;
        r.evict = 1'b0;
        r.fill  = 1'b0;

        if (ref_valid[s] && (ref_tag[s] == t)) begin
            r.hit = 1'b1;
            ref_hits++;
        end else begin
            r.hit = 1'b0;
            ref_misses++;
            // Write-allocate with write-back: evict first if the resident line
            // is dirty, then pull the new line in.
            if (ref_valid[s] && ref_dirty[s]) begin
                ref_writeback(s);
                r.evict = 1'b1;
                ref_evicts++;
            end
            ref_valid[s] = 1'b1;
            ref_tag[s]   = t;
            ref_dirty[s] = 1'b0;
            r.fill       = 1'b1;
            ref_fills++;
        end

        if (we) begin
            cur = ref_arch[wi];
            for (int b = 0; b < REF_BYTES; b++)
                if (wstrb[b]) cur[8*b +: 8] = wdata[8*b +: 8];
            ref_arch[wi] = cur;
            ref_dirty[s] = 1'b1;      // the store makes the line dirty
            r.rdata      = '0;        // the DUT drives 0 on the write path
        end else begin
            r.rdata = ref_arch[wi];
        end

        return r;
    endfunction

    // ========================================================================
    // A maintenance flush: every dirty line is written back.  Lines stay
    // resident and become clean - the DUT does not invalidate on flush, and
    // the model must not either, or the next access would be mispredicted as
    // a miss.
    // ========================================================================
    function automatic int ref_flush();
        int n;
        n = 0;
        for (int s = 0; s < REF_SETS; s++) begin
            if (ref_valid[s] && ref_dirty[s]) begin
                ref_writeback(s[REF_IDX_W-1:0]);
                n++;
                ref_flush_wbs++;
            end
        end
        return n;
    endfunction

    // ========================================================================
    // Convenience for the scoreboard's end-of-test memory comparison.
    // ========================================================================
    function automatic logic [REF_DATA_W-1:0] ref_back_word(input int wi);
        return ref_back[wi];
    endfunction

    function automatic logic [REF_DATA_W-1:0] ref_arch_word(input int wi);
        return ref_arch[wi];
    endfunction

    function automatic logic ref_addr_in_window(input logic [REF_ADDR_W-1:0] a);
        return (a < REF_WINDOW);
    endfunction

    function automatic string ref_state_name(input logic [3:0] s);
        case (s)
            4'd0: return "IDLE";
            4'd1: return "LOOKUP";
            4'd2: return "EVICT";
            4'd3: return "FILL";
            4'd4: return "ALLOC";
            4'd5: return "RESP";
            4'd6: return "FSCAN";
            4'd7: return "FWB";
            default: return "?";
        endcase
    endfunction

    // ========================================================================
    // ref_selfcheck - make the model prove its own invariants inside the
    // simulator before it is trusted to judge the DUT.
    //
    // A reference model is only worth having if it is independently right, so
    // this re-derives, from the model alone, the handful of statements the
    // whole testbench leans on.  If any of them fail, the run stops here
    // rather than reporting a DUT bug that is really a model bug.
    // ========================================================================
    function automatic int ref_selfcheck(input logic verbose);
        int bad;
        ref_rsp_t r;
        logic [REF_DATA_W-1:0] seen, expect_w;
        logic [REF_ADDR_W-1:0] a0, a1, a2;
        int n;

        bad = 0;
        ref_model_init();

        // ---- 1. cold read misses, and returns memory ----------------------
        a0 = 32'h0000_0000;
        r = ref_access(a0, 1'b0, 32'h0, 4'h0);
        if (r.hit !== 1'b0)            begin bad++; $display("  ref: cold read should miss"); end
        if (r.rdata !== ref_init_word(0)) begin bad++; $display("  ref: cold read data wrong"); end

        // ---- 2. the rest of the line is now resident: hits ----------------
        r = ref_access(32'h0000_0004, 1'b0, 32'h0, 4'h0);
        if (r.hit !== 1'b1) begin bad++; $display("  ref: same-line access should hit"); end

        // ---- 3. a store hits memory only on eviction ----------------------
        r = ref_access(32'h0000_0004, 1'b1, 32'hDEAD_BEEF, 4'hF);
        if (ref_arch[1] !== 32'hDEAD_BEEF)
            begin bad++; $display("  ref: store did not update the arch view"); end
        if (ref_back[1] !== ref_init_word(1))
            begin bad++; $display("  ref: write-back model leaked a store to memory early"); end

        // ---- 4. reading it back returns the stored value -------------------
        r = ref_access(32'h0000_0004, 1'b0, 32'h0, 4'h0);
        if (r.rdata !== 32'hDEAD_BEEF)
            begin bad++; $display("  ref: store not visible to a later load"); end

        // ---- 5. byte strobes merge, they do not overwrite -----------------
        r = ref_access(32'h0000_0004, 1'b1, 32'h1122_3344, 4'b0010);
        if (r.rdata !== 32'h0) begin bad++; $display("  ref: write path must return 0"); end
        r = ref_access(32'h0000_0004, 1'b0, 32'h0, 4'h0);
        if (r.rdata !== 32'hDEAD_33EF)
            begin bad++; $display("  ref: byte-strobe merge wrong: %08h", r.rdata); end

        // ---- 6. a conflicting line evicts, and the eviction lands ---------
        //  same index (bits 6:4), different tag (bit 7 up)
        a1 = 32'h0000_0084;   // idx 0, tag differs from a0's
        r = ref_access(a1, 1'b0, 32'h0, 4'h0);
        if (r.hit !== 1'b0)   begin bad++; $display("  ref: conflicting tag should miss"); end
        if (r.evict !== 1'b1) begin bad++; $display("  ref: dirty conflict should evict"); end
        if (ref_back[1] !== 32'hDEAD_33EF)
            begin bad++; $display("  ref: eviction did not update memory: %08h", ref_back[1]); end

        // ---- 7. flush cleans without invalidating -------------------------
        r = ref_access(a1, 1'b1, 32'hCAFE_0001, 4'hF);
        n = ref_flush();
        if (n != 1) begin bad++; $display("  ref: flush should have written back exactly one line"); end
        if (ref_back[ref_word_index(a1)] !== 32'hCAFE_0001)
            begin bad++; $display("  ref: flush did not reach memory"); end
        r = ref_access(a1, 1'b0, 32'h0, 4'h0);
        if (r.hit !== 1'b1) begin bad++; $display("  ref: flush must not invalidate"); end

        // ---- 8. after a flush, memory and the arch view agree everywhere --
        for (int i = 0; i < REF_NWORDS; i++)
            if (ref_arch[i] !== ref_back[i]) begin
                bad++;
                $display("  ref: post-flush mismatch at word %0d", i);
                break;
            end

        // ---- 9. reset discards dirty data ---------------------------------
        a2 = 32'h0000_0100;
        r  = ref_access(a2, 1'b0, 32'h0, 4'h0);
        expect_w = r.rdata;
        r  = ref_access(a2, 1'b1, 32'h0BAD_0BAD, 4'hF);
        r  = ref_access(a2, 1'b0, 32'h0, 4'h0);
        if (r.rdata !== 32'h0BAD_0BAD)
            begin bad++; $display("  ref: pre-reset store not visible"); end
        ref_hw_reset();
        r = ref_access(a2, 1'b0, 32'h0, 4'h0);
        if (r.hit !== 1'b0)
            begin bad++; $display("  ref: reset must invalidate"); end
        if (r.rdata !== expect_w)
            begin bad++; $display("  ref: reset should have discarded the dirty store"); end

        // ---- 10. every window address decodes into the window -------------
        for (int i = 0; i < REF_NWORDS; i++) begin
            logic [REF_ADDR_W-1:0] ba;
            ba = ref_byte_addr(i);
            if (ref_word_index(ba) != i) begin
                bad++; $display("  ref: address round-trip failed at word %0d", i); break;
            end
            if (ref_line_base(ref_tag_of(ba), ref_idx(ba)) + int'(ref_off(ba)) != i) begin
                bad++; $display("  ref: tag/index/offset split failed at word %0d", i); break;
            end
        end

        ref_model_init();
        if (verbose)
            $display("  reference-model self-check: %0d problem(s)", bad);
        return bad;
    endfunction

endpackage : cache_ref_pkg
