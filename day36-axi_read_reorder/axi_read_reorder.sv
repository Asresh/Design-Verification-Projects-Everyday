// Author: Asresh Kuricheti
// Multi-ID AXI-style read reorder engine with tagged out-of-order memory completion.
`timescale 1ns/1ps
module axi_read_reorder #(
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32,
  parameter int ID_W   = 2,
  parameter int DEPTH  = 8,
  parameter int SEQ_W  = 16,
  parameter int TAG_W  = $clog2(DEPTH)
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              ar_valid,
  output logic              ar_ready,
  input  logic [ID_W-1:0]   ar_id,
  input  logic [ADDR_W-1:0] ar_addr,
  output logic              mem_req_valid,
  input  logic              mem_req_ready,
  output logic [TAG_W-1:0]  mem_req_tag,
  output logic [ID_W-1:0]   mem_req_id,
  output logic [ADDR_W-1:0] mem_req_addr,
  input  logic              mem_rsp_valid,
  input  logic [TAG_W-1:0]  mem_rsp_tag,
  input  logic [DATA_W-1:0] mem_rsp_data,
  input  logic              mem_rsp_error,
  output logic              r_valid,
  input  logic              r_ready,
  output logic [ID_W-1:0]   r_id,
  output logic [DATA_W-1:0] r_data,
  output logic              r_error,
  output logic [$clog2(DEPTH+1)-1:0] occupancy
);
  localparam int N_IDS = 1 << ID_W;
  logic slot_valid [0:DEPTH-1];
  logic slot_done  [0:DEPTH-1];
  logic [ID_W-1:0] slot_id   [0:DEPTH-1];
  logic [SEQ_W-1:0] slot_seq [0:DEPTH-1];
  logic [DATA_W-1:0] slot_data [0:DEPTH-1];
  logic slot_error [0:DEPTH-1];
  logic [SEQ_W-1:0] alloc_seq [0:N_IDS-1];
  logic [SEQ_W-1:0] retire_seq[0:N_IDS-1];
  logic hold_valid;
  logic [TAG_W-1:0] hold_slot;
  logic free_found, eligible_found;
  logic [TAG_W-1:0] free_slot, eligible_slot;
  integer i;

  always_comb begin
    free_found = 1'b0;
    free_slot = '0;
    occupancy = '0;
    for (i = 0; i < DEPTH; i = i + 1) begin
      occupancy = occupancy + slot_valid[i];
      if (!free_found && !slot_valid[i]) begin
        free_found = 1'b1;
        free_slot = i[TAG_W-1:0];
      end
    end
    ar_ready = free_found && mem_req_ready;
    // This compact bridge accepts and issues atomically, so no unreserved tag is
    // exposed while the downstream is stalled.
    mem_req_valid = ar_valid && free_found && mem_req_ready;
    mem_req_tag = free_slot;
    mem_req_id = ar_id;
    mem_req_addr = ar_addr;

    eligible_found = 1'b0;
    eligible_slot = '0;
    for (i = 0; i < DEPTH; i = i + 1)
      if (!eligible_found && slot_valid[i] && slot_done[i] &&
          (slot_seq[i] == retire_seq[slot_id[i]])) begin
        eligible_found = 1'b1;
        eligible_slot = i[TAG_W-1:0];
      end

    r_valid = hold_valid;
    r_id = slot_id[hold_slot];
    r_data = slot_data[hold_slot];
    r_error = slot_error[hold_slot];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_valid <= 1'b0;
      hold_slot <= '0;
      for (i = 0; i < DEPTH; i = i + 1) begin
        slot_valid[i] <= 1'b0;
        slot_done[i] <= 1'b0;
        slot_id[i] <= '0;
        slot_seq[i] <= '0;
        slot_data[i] <= '0;
        slot_error[i] <= 1'b0;
      end
      for (i = 0; i < N_IDS; i = i + 1) begin
        alloc_seq[i] <= '0;
        retire_seq[i] <= '0;
      end
    end else begin
      if (ar_valid && ar_ready) begin
        slot_valid[free_slot] <= 1'b1;
        slot_done[free_slot] <= 1'b0;
        slot_id[free_slot] <= ar_id;
        slot_seq[free_slot] <= alloc_seq[ar_id];
        alloc_seq[ar_id] <= alloc_seq[ar_id] + 1'b1;
      end
      if (mem_rsp_valid && slot_valid[mem_rsp_tag] && !slot_done[mem_rsp_tag]) begin
        slot_done[mem_rsp_tag] <= 1'b1;
        slot_data[mem_rsp_tag] <= mem_rsp_data;
        slot_error[mem_rsp_tag] <= mem_rsp_error;
      end
      if (!hold_valid && eligible_found) begin
        hold_valid <= 1'b1;
        hold_slot <= eligible_slot;
      end else if (hold_valid && r_ready) begin
        slot_valid[hold_slot] <= 1'b0;
        slot_done[hold_slot] <= 1'b0;
        retire_seq[slot_id[hold_slot]] <= retire_seq[slot_id[hold_slot]] + 1'b1;
        hold_valid <= 1'b0;
      end
    end
  end

`ifdef AXI_REORDER_SVA
  assert property (@(posedge clk) disable iff (!rst_n)
    r_valid && !r_ready |=> r_valid && $stable({r_id,r_data,r_error}));
  assert property (@(posedge clk) disable iff (!rst_n) occupancy <= DEPTH);
  assert property (@(posedge clk) disable iff (!rst_n)
    mem_rsp_valid |-> slot_valid[mem_rsp_tag] && !slot_done[mem_rsp_tag]);
  assert property (@(posedge clk) disable iff (!rst_n)
    r_valid |-> slot_valid[hold_slot] && slot_done[hold_slot]);
  assert property (@(posedge clk) disable iff (!rst_n)
    ar_valid && !ar_ready |=> $stable({ar_id,ar_addr}));
`endif
endmodule
