`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import noc_router_pkg::*;
    logic clk=0;
    always #5 clk=~clk;
    noc_router_if vif(clk);
    noc_router dut(.clk(clk),.rst_n(vif.rst_n),
        .in_valid(vif.in_valid),.in_ready(vif.in_ready),.in_flit(vif.in_flit),
        .in_dest(vif.in_dest),.in_last(vif.in_last),.out_valid(vif.out_valid),
        .out_ready(vif.out_ready),.out_flit(vif.out_flit),.out_dest(vif.out_dest),
        .out_last(vif.out_last));
    initial begin
        vif.rst_n=0; vif.in_valid='0; vif.in_flit='0; vif.in_dest='0;
        vif.in_last='0; vif.out_ready='0;
        repeat(4) @(posedge clk); vif.rst_n=1;
    end
    initial begin
        uvm_config_db#(virtual noc_router_if)::set(null,"uvm_test_top.env*","vif",vif);
        run_test();
    end
    initial begin #200000; `uvm_fatal("TIMEOUT","test exceeded 200 us") end
endmodule
