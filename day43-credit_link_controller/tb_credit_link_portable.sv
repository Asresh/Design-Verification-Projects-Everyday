// Author: Asresh Kuricheti
// Portable cycle-exact regression for simulators without a UVM library.
`timescale 1ns/1ps
module tb_credit_link_portable;
  localparam int DATA_W=16, MAX_CREDITS=8, CREDIT_W=$clog2(MAX_CREDITS+1);
  logic clk=0, rst_n=0, cfg_valid=0, req_valid=0, req_ready, req_last=0;
  logic [CREDIT_W-1:0] cfg_credits=0, credit_return=0, credit_count;
  logic [DATA_W-1:0] req_data=0, link_data;
  logic link_valid, link_last, credit_overflow;
  int model_credits=0, checks=0, errors=0, accepted=0, stalls=0, returns=0;
  int empty_hits=0, full_hits=0, simultaneous_hits=0, last_hits=0, overflow_hits=0;
  bit model_overflow=0;

  always #5 clk=~clk;
  credit_link_tx #(.DATA_W(DATA_W),.MAX_CREDITS(MAX_CREDITS)) dut(.*);

  task automatic cycle(input bit v, input logic [DATA_W-1:0] data, input bit last,
                       input int ret, input bit cfg, input int cfg_amt);
    bit launch; int next_model;
    @(negedge clk);
    req_valid=v; req_data=data; req_last=last; credit_return=ret;
    cfg_valid=cfg; cfg_credits=cfg_amt;
    launch = rst_n && !cfg && v && (model_credits!=0);
    if(cfg) begin next_model=(cfg_amt>MAX_CREDITS)?MAX_CREDITS:cfg_amt; model_overflow=(cfg_amt>MAX_CREDITS); end
    else begin next_model=model_credits+ret-(launch?1:0); if(next_model>MAX_CREDITS) begin next_model=MAX_CREDITS; model_overflow=1; end end
    @(posedge clk); #1;
    checks++;
    if(link_valid!==launch) begin $error("link_valid=%0b expected=%0b",link_valid,launch); errors++; end
    if(launch && (link_data!==data || link_last!==last)) begin $error("payload mismatch"); errors++; end
    if(credit_count!==next_model[CREDIT_W-1:0]) begin $error("credits=%0d expected=%0d",credit_count,next_model); errors++; end
    if(credit_overflow!==model_overflow) begin $error("overflow=%0b expected=%0b",credit_overflow,model_overflow); errors++; end
    if(launch) begin accepted++; if(last) last_hits++; end
    if(v&&!launch&&!cfg) stalls++;
    if(ret!=0) returns++;
    if(launch&&ret!=0) simultaneous_hits++;
    model_credits=next_model;
    if(model_credits==0) empty_hits++;
    if(model_credits==MAX_CREDITS) full_hits++;
    if(credit_overflow) overflow_hits++;
  endtask

  initial begin : regression
    int i; bit pending; logic [DATA_W-1:0] held_data; bit held_last; int ret;
    $dumpfile("credit_link.vcd"); $dumpvars(0,tb_credit_link_portable);
    repeat(3) cycle(0,'0,0,0,0,0);
    @(negedge clk); rst_n=1;

    // Directed: configure three credits, drain to empty, prove blocking, recover.
    cycle(0,'0,0,0,1,3);
    cycle(1,16'h1001,0,0,0,0);
    cycle(1,16'h1002,0,0,0,0);
    cycle(1,16'h1003,1,0,0,0);
    cycle(1,16'hbeef,1,0,0,0);
    cycle(1,16'hbeef,1,2,0,0);
    cycle(1,16'hbeef,1,0,0,0);
    cycle(1,16'h2001,0,1,0,0); // simultaneous return and launch
    cycle(1,16'h2002,1,0,0,0);
    cycle(0,'0,0,MAX_CREDITS,0,0);
    cycle(0,'0,0,1,0,0); // excess return saturates and raises sticky overflow

    // Constrained-random: a pending request remains stable until accepted.
    pending=0; held_data='0; held_last=0;
    for(i=0;i<220;i++) begin
      if(!pending && $urandom_range(0,99)<72) begin
        pending=1; held_data=$urandom; held_last=($urandom_range(0,4)==0);
      end
      ret=($urandom_range(0,99)<45) ? $urandom_range(1,2) : 0;
      cycle(pending,held_data,held_last,ret,0,0);
      if(pending && link_valid) pending=0;
    end
    repeat(3) cycle(0,'0,0,0,0,0);

    if(accepted<80) begin $error("coverage: too few accepted flits"); errors++; end
    if(empty_hits==0||full_hits==0||simultaneous_hits==0||last_hits==0||stalls==0||overflow_hits==0) begin
      $error("coverage hole empty=%0d full=%0d simultaneous=%0d last=%0d stalls=%0d overflow=%0d",empty_hits,full_hits,simultaneous_hits,last_hits,stalls,overflow_hits); errors++;
    end
    if(errors==0)
      $display("RESULT: *** PASS *** checks=%0d accepted=%0d stalls=%0d returns=%0d",checks,accepted,stalls,returns);
    else $fatal(1,"RESULT: *** FAIL *** errors=%0d",errors);
    $finish;
  end

  initial begin #100000; $fatal(1,"TIMEOUT"); end
endmodule
