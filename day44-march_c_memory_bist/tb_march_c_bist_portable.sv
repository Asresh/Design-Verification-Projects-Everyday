// Author: Asresh Kuricheti
// Portable self-checking regression with a golden March C- command model.
`timescale 1ns/1ps
module tb_march_c_bist_portable;
  localparam int ADDR_W=4, DATA_W=8, DEPTH=(1<<ADDR_W);
  logic clk=0, rst_n=0, start=0;
  logic busy, done, pass, fail;
  logic [ADDR_W-1:0] fail_addr;
  logic [DATA_W-1:0] fail_expected, fail_actual;
  logic mem_valid, mem_ready, mem_write, mem_rsp_valid;
  logic [ADDR_W-1:0] mem_addr;
  logic [DATA_W-1:0] mem_wdata, mem_rdata;
  logic [DATA_W-1:0] memory [0:DEPTH-1];
  logic inject_en, inject_stuck_value;
  logic [ADDR_W-1:0] inject_addr;
  integer errors=0, checks=0, commands=0, reads=0, writes=0, stalls=0;
  integer clean_runs=0, detected_faults=0;
  integer exp_phase, exp_addr, exp_subop, rsp_delay;
  logic pending_rsp;
  logic [DATA_W-1:0] pending_data;
  logic accepted_write;
  integer i;

  always #5 clk=~clk;
  march_c_bist #(.ADDR_W(ADDR_W),.DATA_W(DATA_W)) dut (.*);

  function automatic logic [DATA_W-1:0] physical_read(input logic [ADDR_W-1:0] a);
    logic [DATA_W-1:0] value;
    begin
      value = memory[a];
      if (inject_en && a==inject_addr)
        value[0] = inject_stuck_value;
      physical_read = value;
    end
  endfunction

  task automatic expect_command(
    input logic wr, input integer addr, input logic [DATA_W-1:0] data
  );
    begin
      checks=checks+1;
      if (mem_write!==wr || mem_addr!==addr[ADDR_W-1:0] || (wr && mem_wdata!==data)) begin
        $display("ERROR command phase=%0d got wr=%b addr=%0d data=%02h expected wr=%b addr=%0d data=%02h",
                 exp_phase,mem_write,mem_addr,mem_wdata,wr,addr,data);
        errors=errors+1;
      end
    end
  endtask

  task automatic advance_golden;
    begin
      case (exp_phase)
        0: if (exp_addr==DEPTH-1) begin exp_phase=1; exp_addr=0; end else exp_addr=exp_addr+1;
        1,2: begin
          if (exp_subop==0) exp_subop=1;
          else begin
            exp_subop=0;
            if (exp_addr==DEPTH-1) begin exp_phase=exp_phase+1; exp_addr=(exp_phase==3)?DEPTH-1:0; end
            else exp_addr=exp_addr+1;
          end
        end
        3,4: begin
          if (exp_subop==0) exp_subop=1;
          else begin
            exp_subop=0;
            if (exp_addr==0) begin exp_phase=exp_phase+1; exp_addr=DEPTH-1; end
            else exp_addr=exp_addr-1;
          end
        end
        5: if (exp_addr>0) exp_addr=exp_addr-1;
        default: ;
      endcase
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      mem_ready<=0; mem_rsp_valid<=0; mem_rdata<='0;
      pending_rsp<=0; rsp_delay<=0;
    end else begin
      mem_ready <= ($urandom_range(0,3)!=0);
      mem_rsp_valid <= 0;
      if (mem_valid && !mem_ready) stalls=stalls+1;
      if (pending_rsp) begin
        if (rsp_delay==0) begin
          mem_rsp_valid <= 1;
          mem_rdata <= pending_data;
          pending_rsp <= 0;
        end else rsp_delay <= rsp_delay-1;
      end
      if (mem_valid && mem_ready) begin
        commands=commands+1;
        if (exp_phase==0) expect_command(1,exp_addr,'0);
        else if (exp_phase==1 || exp_phase==3)
          expect_command(exp_subop==1,exp_addr,exp_subop==1 ? {DATA_W{1'b1}} : '0);
        else if (exp_phase==2 || exp_phase==4)
          expect_command(exp_subop==1,exp_addr,'0);
        else expect_command(0,exp_addr,'0);

        if (mem_write) begin
          writes=writes+1;
          memory[mem_addr] <= mem_wdata;
          if (inject_en && mem_addr==inject_addr)
            memory[mem_addr][0] <= inject_stuck_value;
        end else begin
          reads=reads+1;
          pending_data <= physical_read(mem_addr);
          pending_rsp <= 1;
          rsp_delay <= $urandom_range(0,2);
        end
        advance_golden();
      end
    end
  end

  task automatic run_case(input logic do_inject, input integer bad_addr);
    integer timeout;
    begin
      inject_en=do_inject; inject_addr=bad_addr[ADDR_W-1:0]; inject_stuck_value=1'b1;
      exp_phase=0; exp_addr=0; exp_subop=0; commands=0;
      @(negedge clk); start=1;
      @(negedge clk); start=0;
      timeout=0;
      while (!done && timeout<4000) begin @(negedge clk); timeout=timeout+1; end
      if (timeout>=4000) begin $display("ERROR timeout"); errors=errors+1; end
      checks=checks+1;
      if (!do_inject && (!pass || fail)) begin
        $display("ERROR clean run did not pass"); errors=errors+1;
      end else if (!do_inject) clean_runs=clean_runs+1;
      if (do_inject && (!fail || pass || fail_addr!=bad_addr[ADDR_W-1:0] || fail_expected!='0 || fail_actual[0]!=1'b1)) begin
        $display("ERROR injected fault not localized: fail=%b addr=%0d exp=%02h actual=%02h",
                 fail,fail_addr,fail_expected,fail_actual); errors=errors+1;
      end else if (do_inject) detected_faults=detected_faults+1;
      @(negedge clk); repeat(2) @(negedge clk);
    end
  endtask

  initial begin
    $dumpfile("march_c_bist.vcd"); $dumpvars(0,tb_march_c_bist_portable);
    mem_ready=0; mem_rsp_valid=0; mem_rdata='0; pending_rsp=0;
    inject_en=0; inject_addr='0; inject_stuck_value=0;
    for (i=0;i<DEPTH;i=i+1) memory[i]=$urandom;
    repeat(4) @(negedge clk); rst_n=1;
    run_case(0,0);
    run_case(1,5);
    run_case(1,DEPTH-2);
    if (reads==0 || writes==0 || stalls==0 || clean_runs!=1 || detected_faults!=2) begin
      $display("ERROR coverage hole reads=%0d writes=%0d stalls=%0d clean=%0d faults=%0d",
               reads,writes,stalls,clean_runs,detected_faults); errors=errors+1;
    end
    if (errors==0)
      $display("RESULT: *** PASS *** checks=%0d reads=%0d writes=%0d stalls=%0d detected_faults=%0d",
               checks,reads,writes,stalls,detected_faults);
    else $fatal(1,"RESULT: *** FAIL *** errors=%0d",errors);
    #20 $finish;
  end

  initial begin #200000; $fatal(1,"TIMEOUT: March C- BIST regression exceeded 200 us"); end
endmodule
