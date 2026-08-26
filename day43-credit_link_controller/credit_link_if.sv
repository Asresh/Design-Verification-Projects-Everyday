// Author: Asresh Kuricheti
interface credit_link_if #(parameter int DATA_W=16, MAX_CREDITS=8,
                           CREDIT_W=$clog2(MAX_CREDITS+1)) (input logic clk);
  logic rst_n;
  logic cfg_valid;
  logic [CREDIT_W-1:0] cfg_credits;
  logic req_valid, req_ready;
  logic [DATA_W-1:0] req_data;
  logic req_last;
  logic [CREDIT_W-1:0] credit_return;
  logic link_valid;
  logic [DATA_W-1:0] link_data;
  logic link_last;
  logic [CREDIT_W-1:0] credit_count;
  logic credit_overflow;

  clocking drv_cb @(posedge clk);
    default input #1step output #1step;
    input req_ready, link_valid, link_data, link_last, credit_count, credit_overflow;
    output rst_n, cfg_valid, cfg_credits, req_valid, req_data, req_last, credit_return;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, cfg_valid, cfg_credits, req_valid, req_ready, req_data, req_last;
    input credit_return, link_valid, link_data, link_last, credit_count, credit_overflow;
  endclocking

  property p_request_stable_while_blocked;
    @(posedge clk) disable iff (!rst_n) req_valid && !req_ready |=>
      req_valid && $stable({req_data, req_last});
  endproperty
  property p_no_unknown_link;
    @(posedge clk) disable iff (!rst_n) link_valid |-> !$isunknown({link_data, link_last});
  endproperty
  assert property (p_request_stable_while_blocked);
  assert property (p_no_unknown_link);
endinterface
