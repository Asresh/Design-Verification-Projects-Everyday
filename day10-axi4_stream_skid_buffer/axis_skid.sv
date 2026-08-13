// ============================================================================
// axis_skid.sv - AXI4-Stream skid buffer / register slice (DUT)
//
// A skid buffer registers the AXI-Stream handshake so that BOTH the payload
// (TDATA/TKEEP/TLAST) and the flow-control signals (TVALID/TREADY) are driven
// from flip-flops. This breaks the long combinational TVALID<->TREADY path
// that a naive register slice would create, yet still sustains FULL throughput
// (one beat per clock) when the downstream side is ready.
//
// HOW IT STAYS LOSSLESS UNDER BACK-PRESSURE
//   The output slot is a registered beat (m_*). When the downstream side
//   stalls (m_tready == 0) the output slot holds its beat. If a fresh beat is
//   accepted from upstream in that same cycle it cannot go to the (occupied,
//   stalled) output slot, so it is parked in a one-entry SKID register. While
//   the skid register is occupied the module de-asserts s_tready, propagating
//   back-pressure upstream. The buffer therefore holds at most two beats
//   (output slot + skid) and never drops or duplicates a beat.
//
// PROTOCOL GUARANTEES (checked by the testbench + SVA)
//   * Every accepted input beat (s_tvalid && s_tready) appears exactly once on
//     the master side, IN ORDER, with identical {TDATA, TKEEP, TLAST}.
//   * TVALID, once asserted, stays asserted with stable payload until the
//     handshake completes (never retracted) - a direct consequence of the
//     registered output slot only reloading when it is free.
//
// This is a classic, self-contained design-verification target: the checking
// is pure order+data integrity across a randomized two-sided back-pressure
// environment, exactly what a streaming-interconnect stage must guarantee.
// ============================================================================
`timescale 1ns/1ps
module axis_skid #(
    parameter int DATA_WIDTH = 8,
    parameter int KEEP_WIDTH = (DATA_WIDTH + 7) / 8
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- Slave (upstream) side : the module CONSUMES beats here ----
    input  logic                    s_tvalid,
    output logic                    s_tready,
    input  logic [DATA_WIDTH-1:0]   s_tdata,
    input  logic [KEEP_WIDTH-1:0]   s_tkeep,
    input  logic                    s_tlast,

    // ---- Master (downstream) side : the module PRODUCES beats here ----
    output logic                    m_tvalid,
    input  logic                    m_tready,
    output logic [DATA_WIDTH-1:0]   m_tdata,
    output logic [KEEP_WIDTH-1:0]   m_tkeep,
    output logic                    m_tlast
);

    // The payload that travels through the buffer as one atomic word.
    localparam int PW = DATA_WIDTH + KEEP_WIDTH + 1;   // {tlast, tkeep, tdata}
    logic [PW-1:0] s_payload;
    assign s_payload = {s_tlast, s_tkeep, s_tdata};

    // ---- Skid (overflow) register -------------------------------------------
    // Holds the single beat that was accepted from upstream in the cycle the
    // registered output slot was occupied AND stalled.
    logic            skid_valid;
    logic [PW-1:0]   skid_payload;

    // ---- Registered master-side output slot ---------------------------------
    logic            m_tvalid_q;
    logic [PW-1:0]   m_payload_q;

    // We can accept from upstream whenever the skid register is empty.
    assign s_tready = !skid_valid;

    // Handy handshake terms.
    logic s_hs;      // an upstream beat is accepted this cycle
    logic out_free;  // the output slot is free to (re)load this cycle
    assign s_hs     = s_tvalid & s_tready;
    assign out_free = ~m_tvalid_q | m_tready;

    // Skid register control: fill when we accept a beat that the (occupied,
    // stalled) output slot cannot take; drain when the output slot moves.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            skid_valid <= 1'b0;
        else if (s_hs && !out_free)   // output busy+stalled -> park the beat
            skid_valid <= 1'b1;
        else if (m_tready)            // output advanced -> skid can drain
            skid_valid <= 1'b0;
    end

    always_ff @(posedge clk) begin
        if (s_tready)                 // only latch while we are accepting
            skid_payload <= s_payload;
    end

    // Output slot: reload whenever it is free. Prefer the parked (skid) beat
    // so ordering is preserved; otherwise take the beat straight from upstream.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            m_tvalid_q <= 1'b0;
        else if (out_free)
            m_tvalid_q <= skid_valid | s_tvalid;
    end

    always_ff @(posedge clk) begin
        if (out_free)
            m_payload_q <= skid_valid ? skid_payload : s_payload;
    end

    assign m_tvalid = m_tvalid_q;
    assign m_tdata  = m_payload_q[DATA_WIDTH-1:0];
    assign m_tkeep  = m_payload_q[DATA_WIDTH +: KEEP_WIDTH];
    assign m_tlast  = m_payload_q[DATA_WIDTH + KEEP_WIDTH];

endmodule
