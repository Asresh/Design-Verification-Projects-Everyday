// Author: Asresh Kuricheti
package pcie_replay_ref_pkg;
  parameter int REF_DATA_W = 32;
  parameter int REF_SEQ_W = 8;
  typedef struct packed {
    logic [REF_SEQ_W-1:0] seq;
    logic [REF_DATA_W-1:0] data;
  } replay_entry_t;
  function automatic bit seq_in_window(
    input logic [REF_SEQ_W-1:0] first,
    input logic [REF_SEQ_W-1:0] candidate,
    input int unsigned count);
    logic [REF_SEQ_W-1:0] delta;
    begin
      delta = candidate - first;
      return int'(delta) < count;
    end
  endfunction
endpackage
