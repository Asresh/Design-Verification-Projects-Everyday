// Author: Asresh Kuricheti
interface pcie_replay_if #(parameter DATA_W=32, SEQ_W=8, DEPTH=8) (input logic clk);
  logic rst_n, tx_valid, tx_ready, link_valid, link_ready;
  logic ack_valid, nak_valid, replay_active, full, empty;
  logic [DATA_W-1:0] tx_data, link_data;
  logic [SEQ_W-1:0] link_seq, ack_seq, nak_seq;
  logic [$clog2(DEPTH+1)-1:0] occupancy;

  clocking drv_cb @(posedge clk);
    default input #1step output #1step;
    output tx_valid, tx_data, link_ready, ack_valid, ack_seq, nak_valid, nak_seq;
    input tx_ready, link_valid, link_data, link_seq, replay_active, full, empty, occupancy;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, tx_valid, tx_ready, tx_data, link_valid, link_ready, link_data,
          link_seq, ack_valid, ack_seq, nak_valid, nak_seq, replay_active, full,
          empty, occupancy;
  endclocking
endinterface
