// Author: Asresh Kuricheti
// Credit-based link transmitter: one credit is consumed by every launched flit.
`timescale 1ns/1ps
module credit_link_tx #(
  parameter int DATA_W = 16,
  parameter int MAX_CREDITS = 8,
  parameter int CREDIT_W = $clog2(MAX_CREDITS + 1)
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                cfg_valid,
  input  logic [CREDIT_W-1:0] cfg_credits,
  input  logic                req_valid,
  output logic                req_ready,
  input  logic [DATA_W-1:0]   req_data,
  input  logic                req_last,
  input  logic [CREDIT_W-1:0] credit_return,
  output logic                link_valid,
  output logic [DATA_W-1:0]   link_data,
  output logic                link_last,
  output logic [CREDIT_W-1:0] credit_count,
  output logic                credit_overflow
);
  logic [CREDIT_W:0] next_credits;
  logic launch;

  assign req_ready = rst_n && !cfg_valid && (credit_count != 0);
  assign launch = req_valid && req_ready;

  always_comb begin
    next_credits = {1'b0, credit_count} + credit_return;
    if (launch)
      next_credits = next_credits - 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      link_valid      <= 1'b0;
      link_data       <= '0;
      link_last       <= 1'b0;
      credit_count    <= '0;
      credit_overflow <= 1'b0;
    end else begin
      link_valid <= launch;
      if (launch) begin
        link_data <= req_data;
        link_last <= req_last;
      end

      if (cfg_valid) begin
        credit_count    <= (cfg_credits > MAX_CREDITS) ? MAX_CREDITS : cfg_credits;
        credit_overflow <= (cfg_credits > MAX_CREDITS);
      end else if (next_credits > MAX_CREDITS) begin
        credit_count    <= MAX_CREDITS;
        credit_overflow <= 1'b1;
      end else begin
        credit_count <= next_credits[CREDIT_W-1:0];
      end
    end
  end

`ifndef SYNTHESIS
  property p_no_launch_without_credit;
    @(posedge clk) disable iff (!rst_n) link_valid |-> $past(credit_count != 0);
  endproperty
  property p_link_matches_accept;
    @(posedge clk) disable iff (!rst_n) link_valid == $past(req_valid && req_ready);
  endproperty
  property p_credit_bound;
    @(posedge clk) disable iff (!rst_n) credit_count <= MAX_CREDITS;
  endproperty
  assert property (p_no_launch_without_credit);
  assert property (p_link_matches_accept);
  assert property (p_credit_bound);
`endif
endmodule
