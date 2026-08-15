// Author: Asresh Kuricheti
// PCIe-style replay buffer: retains transmitted packets until cumulative ACK.
`timescale 1ns/1ps
module pcie_replay_buffer #(
  parameter int DATA_W = 32,
  parameter int SEQ_W  = 8,
  parameter int DEPTH  = 8,
  parameter int PTR_W  = $clog2(DEPTH)
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              tx_valid,
  output logic              tx_ready,
  input  logic [DATA_W-1:0] tx_data,
  output logic              link_valid,
  input  logic              link_ready,
  output logic [DATA_W-1:0] link_data,
  output logic [SEQ_W-1:0]  link_seq,
  input  logic              ack_valid,
  input  logic [SEQ_W-1:0]  ack_seq,
  input  logic              nak_valid,
  input  logic [SEQ_W-1:0]  nak_seq,
  output logic              replay_active,
  output logic              full,
  output logic              empty,
  output logic [$clog2(DEPTH+1)-1:0] occupancy
);
  logic [DATA_W-1:0] data_mem [0:DEPTH-1];
  logic [SEQ_W-1:0]  seq_mem  [0:DEPTH-1];
  logic [PTR_W-1:0] head, tail, send_ptr;
  logic [$clog2(DEPTH+1)-1:0] count, pending;
  logic [SEQ_W-1:0] next_seq;
  integer i;
  integer ack_n;
  integer nak_off;

  function automatic logic [PTR_W-1:0] ptr_add(
    input logic [PTR_W-1:0] p, input integer amount);
    integer tmp;
    begin
      tmp = p + amount;
      while (tmp >= DEPTH) tmp = tmp - DEPTH;
      ptr_add = tmp[PTR_W-1:0];
    end
  endfunction

  always_comb begin
    tx_ready = (count < DEPTH) && !ack_valid && !nak_valid;
    full = (count == DEPTH);
    empty = (count == 0);
    occupancy = count;
    link_valid = (pending != 0) && !ack_valid && !nak_valid;
    link_data = data_mem[send_ptr];
    link_seq = seq_mem[send_ptr];
    ack_n = 0;
    for (i = 0; i < DEPTH; i = i + 1)
      if ((i < count) && (seq_mem[ptr_add(head, i)] == ack_seq)) ack_n = i + 1;
    nak_off = -1;
    for (i = 0; i < DEPTH; i = i + 1)
      if ((i < count) && (seq_mem[ptr_add(head, i)] == nak_seq)) nak_off = i;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head <= '0; tail <= '0; send_ptr <= '0;
      count <= '0; pending <= '0; next_seq <= '0;
      replay_active <= 1'b0;
      for (i = 0; i < DEPTH; i = i + 1) begin
        data_mem[i] <= '0; seq_mem[i] <= '0;
      end
    end else begin
      if (ack_valid && (ack_n != 0)) begin
        head <= ptr_add(head, ack_n);
        count <= count - ack_n;
        if (count == ack_n) begin
          send_ptr <= ptr_add(head, ack_n);
          pending <= '0;
        end
        replay_active <= 1'b0;
      end else if (nak_valid && (nak_off >= 0)) begin
        send_ptr <= ptr_add(head, nak_off);
        pending <= count - nak_off;
        replay_active <= 1'b1;
      end else begin
        if (tx_valid && tx_ready) begin
          data_mem[tail] <= tx_data;
          seq_mem[tail] <= next_seq;
          tail <= ptr_add(tail, 1);
          next_seq <= next_seq + 1'b1;
          count <= count + 1'b1;
          pending <= pending + 1'b1;
        end
        if (link_valid && link_ready) begin
          send_ptr <= ptr_add(send_ptr, 1);
          pending <= pending - 1'b1;
          if (pending == 1) replay_active <= 1'b0;
        end
        if ((tx_valid && tx_ready) && (link_valid && link_ready))
          pending <= pending;
      end
    end
  end

`ifdef PCIE_REPLAY_SVA
  property p_stable_when_stalled;
    @(posedge clk) disable iff (!rst_n) link_valid && !link_ready |=>
      link_valid && $stable(link_data) && $stable(link_seq);
  endproperty
  assert property (p_stable_when_stalled);
  assert property (@(posedge clk) disable iff (!rst_n) occupancy <= DEPTH);
  assert property (@(posedge clk) disable iff (!rst_n) !(ack_valid && nak_valid));
  assert property (@(posedge clk) disable iff (!rst_n) empty |-> !link_valid);
  assert property (@(posedge clk) disable iff (!rst_n) full |-> !tx_ready);
`endif
endmodule
