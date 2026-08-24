// Author: Asresh Kuricheti
//
// directed + random delay/fault stimulus
//                  |
//                  v
// DUT signals -> independent cycle model -> compare every output -> PASS/FAIL
`timescale 1ns/1ps

module tb_power_domain_portable;
  localparam int TIMEOUT_CYCLES = 8;
  typedef enum logic [2:0] {ON, SAVE, ISO, OFF, PWR_WAIT, RESTORE, DEISO, FAULT} ref_state_t;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic sleep_req, wake_req, save_done, restore_done, pwr_good;
  logic isolate_en, retention_save, retention_restore;
  logic power_switch_en, domain_clk_en, busy, asleep, fault;
  logic [2:0] state_dbg;
  ref_state_t ref_state;
  integer ref_wait, checks, errors, cycles, i;
  integer state_seen[0:7], good_cycles, timeout_cycles, random_cycles;

  power_domain_controller #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (.*);

  task automatic compare_outputs;
    logic exp_iso, exp_save, exp_restore, exp_power, exp_clk;
    logic exp_busy, exp_asleep, exp_fault;
    begin
      exp_iso=1; exp_save=0; exp_restore=0; exp_power=1;
      exp_clk=0; exp_busy=1; exp_asleep=0; exp_fault=0;
      case (ref_state)
        ON:      begin exp_iso=0; exp_clk=1; exp_busy=0; end
        SAVE:    begin exp_iso=0; exp_save=1; exp_clk=1; end
        ISO:     begin exp_iso=1; exp_clk=0; end
        OFF:     begin exp_power=0; exp_clk=0; exp_busy=0; exp_asleep=1; end
        PWR_WAIT:begin exp_iso=1; exp_power=1; end
        RESTORE: begin exp_iso=1; exp_restore=1; end
        DEISO:   begin exp_iso=0; exp_clk=1; end
        default: begin exp_iso=1; exp_power=1; exp_clk=0; exp_fault=1; end
      endcase
      checks=checks+9;
      if ({isolate_en,retention_save,retention_restore,power_switch_en,
           domain_clk_en,busy,asleep,fault,state_dbg} !==
          {exp_iso,exp_save,exp_restore,exp_power,exp_clk,exp_busy,
           exp_asleep,exp_fault,ref_state}) begin
        $error("cycle %0d state=%0d output mismatch got=%b%b%b%b%b%b%b%b/%0d",
          cycles,ref_state,isolate_en,retention_save,retention_restore,
          power_switch_en,domain_clk_en,busy,asleep,fault,state_dbg);
        errors=errors+1;
      end
      if (!power_switch_en && (!isolate_en || domain_clk_en)) begin
        $error("unsafe powered-off outputs"); errors=errors+1;
      end
      state_seen[ref_state]=1;
    end
  endtask

  task automatic step_model;
    ref_state_t next_ref;
    begin
      next_ref=ref_state;
      case(ref_state)
        ON:       if(sleep_req) next_ref=SAVE;
        SAVE:     if(save_done) next_ref=ISO; else if(ref_wait>=TIMEOUT_CYCLES-1) next_ref=FAULT;
        ISO:      next_ref=OFF;
        OFF:      if(wake_req) next_ref=PWR_WAIT;
        PWR_WAIT: if(pwr_good) next_ref=RESTORE; else if(ref_wait>=TIMEOUT_CYCLES-1) next_ref=FAULT;
        RESTORE:  if(restore_done) next_ref=DEISO; else if(ref_wait>=TIMEOUT_CYCLES-1) next_ref=FAULT;
        DEISO:    next_ref=ON;
        default:  next_ref=FAULT;
      endcase
      if((next_ref!=ref_state) ||
         !((ref_state==SAVE)||(ref_state==PWR_WAIT)||(ref_state==RESTORE))) ref_wait=0;
      else if(ref_wait<TIMEOUT_CYCLES-1) ref_wait=ref_wait+1;
      ref_state=next_ref;
    end
  endtask

  task automatic cycle;
    begin
      @(posedge clk); #1; cycles=cycles+1; step_model(); compare_outputs();
    end
  endtask

  task automatic pulse_sleep; begin @(negedge clk);sleep_req=1;cycle();@(negedge clk);sleep_req=0;end endtask
  task automatic pulse_wake;  begin @(negedge clk);wake_req=1; cycle();@(negedge clk);wake_req=0; end endtask
  task automatic ack_save(input integer delay_cycles);
    integer d;
    begin
      while(!retention_save) cycle();
      for(d=0;d<delay_cycles;d=d+1) cycle();
      @(negedge clk);save_done=1;cycle();@(negedge clk);save_done=0;
    end
  endtask
  task automatic ack_restore(input integer delay_cycles);
    integer d;
    begin
      while(!retention_restore) cycle();
      for(d=0;d<delay_cycles;d=d+1) cycle();
      @(negedge clk);restore_done=1;cycle();@(negedge clk);restore_done=0;
    end
  endtask
  task automatic normal_roundtrip(input integer sd, input integer pd, input integer rd);
    begin
      pwr_good=0; pulse_sleep(); ack_save(sd);
      while(!asleep) cycle(); repeat(2) cycle(); pulse_wake();
      repeat(pd) cycle(); @(negedge clk);pwr_good=1; cycle();
      ack_restore(rd);
      while(busy) cycle(); good_cycles=good_cycles+1;
    end
  endtask

  initial begin
    $dumpfile("power_domain_controller.vcd");
    $dumpvars(0,tb_power_domain_portable);
    sleep_req=0;wake_req=0;save_done=0;restore_done=0;pwr_good=1;
    ref_state=ON;ref_wait=0;checks=0;errors=0;cycles=0;
    good_cycles=0;timeout_cycles=0;random_cycles=0;
    for(i=0;i<8;i=i+1)state_seen[i]=0;
    repeat(3)@(posedge clk); #1; rst_n=1; compare_outputs();

    // Directed nominal path: delayed retention and power acknowledgments.
    normal_roundtrip(2,3,2);

    // Directed immediate-ack corner.
    normal_roundtrip(0,0,0);

    // Constrained-random legal handshakes, bounded below the timeout.
    for(i=0;i<24;i=i+1) begin
      normal_roundtrip($urandom_range(0,4),$urandom_range(0,4),$urandom_range(0,4));
      random_cycles=random_cycles+1;
    end

    // Timeout corner: omit save_done and require a latched safe fault.
    pulse_sleep();
    while(!fault && cycles<2000) cycle();
    timeout_cycles=timeout_cycles+1;
    repeat(3) cycle();
    if(!fault || !isolate_en || !power_switch_en || domain_clk_en) begin
      $error("fault state is not fail-safe"); errors=errors+1;
    end
    for(i=0;i<8;i=i+1) if(!state_seen[i]) begin
      $error("functional coverage hole: state %0d unseen",i); errors=errors+1;
    end
    if(good_cycles==0 || timeout_cycles==0 || random_cycles==0) begin
      $error("functional coverage categories incomplete"); errors=errors+1;
    end
    if(errors==0)
      $display("RESULT: *** PASS *** checks=%0d cycles=%0d roundtrips=%0d timeout_faults=%0d",checks,cycles,good_cycles,timeout_cycles);
    else $display("RESULT: *** FAIL *** errors=%0d",errors);
    $finish;
  end
  initial begin #2ms; $fatal(1,"portable testbench timeout"); end
endmodule
