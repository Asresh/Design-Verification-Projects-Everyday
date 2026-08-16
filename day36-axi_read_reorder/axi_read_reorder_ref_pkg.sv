// Author: Asresh Kuricheti
// Independent reference-model helpers shared by the UVM scoreboard.
package axi_read_reorder_ref_pkg;
  function automatic bit [32:0] ref_read(input bit [15:0] addr);
    bit [31:0] data;
    begin
      data = {addr, (addr ^ 16'h5a3c)};
      ref_read = {(addr[5:2] == 4'hf), data};
    end
  endfunction
endpackage
