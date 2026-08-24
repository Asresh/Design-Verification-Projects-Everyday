// Author: Asresh Kuricheti
//
// ctrl_sequence -> ctrl_agent ----+
//                                  v
// virtual_sequence             DUT/interface -> cycle scoreboard -> result
//                                  ^                    |
// ack_sequence  -> ack_agent -----+                    +-> coverage
package power_domain_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int TIMEOUT_CYCLES = 8;
  typedef enum int {FAIL_NONE, FAIL_SAVE, FAIL_POWER, FAIL_RESTORE} fail_stage_e;

  class power_cmd_item extends uvm_sequence_item;
    rand int unsigned off_hold_cycles;
    bit reset_first;
    constraint c_hold { off_hold_cycles inside {[0:5]}; }
    `uvm_object_utils_begin(power_cmd_item)
      `uvm_field_int(off_hold_cycles,UVM_ALL_ON)
      `uvm_field_int(reset_first,UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="power_cmd_item"); super.new(name); endfunction
  endclass

  class power_ack_item extends uvm_sequence_item;
    rand int unsigned save_delay, power_delay, restore_delay;
    fail_stage_e fail_stage;
    constraint c_delays {
      save_delay inside {[0:TIMEOUT_CYCLES-3]};
      power_delay inside {[0:TIMEOUT_CYCLES-3]};
      restore_delay inside {[0:TIMEOUT_CYCLES-3]};
    }
    `uvm_object_utils_begin(power_ack_item)
      `uvm_field_int(save_delay,UVM_ALL_ON)
      `uvm_field_int(power_delay,UVM_ALL_ON)
      `uvm_field_int(restore_delay,UVM_ALL_ON)
      `uvm_field_enum(fail_stage_e,fail_stage,UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="power_ack_item"); super.new(name); endfunction
  endclass

  class power_cycle_item extends uvm_sequence_item;
    bit rst_n, sleep_req, wake_req, save_done, restore_done, pwr_good;
    bit isolate_en, retention_save, retention_restore, power_switch_en;
    bit domain_clk_en, busy, asleep, fault;
    bit [2:0] state_dbg;
    `uvm_object_utils_begin(power_cycle_item)
      `uvm_field_int(rst_n,UVM_ALL_ON) `uvm_field_int(sleep_req,UVM_ALL_ON)
      `uvm_field_int(wake_req,UVM_ALL_ON) `uvm_field_int(save_done,UVM_ALL_ON)
      `uvm_field_int(restore_done,UVM_ALL_ON) `uvm_field_int(pwr_good,UVM_ALL_ON)
      `uvm_field_int(isolate_en,UVM_ALL_ON) `uvm_field_int(retention_save,UVM_ALL_ON)
      `uvm_field_int(retention_restore,UVM_ALL_ON) `uvm_field_int(power_switch_en,UVM_ALL_ON)
      `uvm_field_int(domain_clk_en,UVM_ALL_ON) `uvm_field_int(busy,UVM_ALL_ON)
      `uvm_field_int(asleep,UVM_ALL_ON) `uvm_field_int(fault,UVM_ALL_ON)
      `uvm_field_int(state_dbg,UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="power_cycle_item"); super.new(name); endfunction
  endclass

  class power_cmd_sequencer extends uvm_sequencer #(power_cmd_item);
    `uvm_component_utils(power_cmd_sequencer)
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass
  class power_ack_sequencer extends uvm_sequencer #(power_ack_item);
    `uvm_component_utils(power_ack_sequencer)
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass

  class power_cmd_driver extends uvm_driver #(power_cmd_item);
    `uvm_component_utils(power_cmd_driver)
    virtual power_domain_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual power_domain_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","command driver needs power_domain_if")
    endfunction
    task run_phase(uvm_phase phase);
      vif.sleep_req<=0;vif.wake_req<=0;
      forever begin
        seq_item_port.get_next_item(req);
        if(req.reset_first) begin
          @(negedge vif.clk);vif.rst_n<=0;repeat(3)@(posedge vif.clk);
          @(negedge vif.clk);vif.rst_n<=1;
        end
        @(negedge vif.clk);vif.sleep_req<=1;
        @(posedge vif.clk);@(negedge vif.clk);vif.sleep_req<=0;
        wait(vif.asleep || vif.fault);
        if(!vif.fault) begin
          repeat(req.off_hold_cycles)@(posedge vif.clk);
          @(negedge vif.clk);vif.wake_req<=1;
          @(posedge vif.clk);@(negedge vif.clk);vif.wake_req<=0;
          wait((!vif.busy && !vif.asleep) || vif.fault);
        end
        seq_item_port.item_done();
      end
    endtask
  endclass

  class power_ack_driver extends uvm_driver #(power_ack_item);
    `uvm_component_utils(power_ack_driver)
    virtual power_domain_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual power_domain_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","ack driver needs power_domain_if")
    endfunction
    task pulse(ref logic sig);@(negedge vif.clk);sig<=1;@(posedge vif.clk);@(negedge vif.clk);sig<=0;endtask
    task run_phase(uvm_phase phase);
      vif.save_done<=0;vif.restore_done<=0;vif.pwr_good<=1;
      forever begin
        seq_item_port.get_next_item(req);
        @(negedge vif.clk);vif.pwr_good<=0;
        wait(vif.retention_save || vif.fault);
        if(req.fail_stage==FAIL_SAVE) wait(vif.fault);
        else begin
          repeat(req.save_delay)@(posedge vif.clk);pulse(vif.save_done);
          wait(vif.asleep || vif.fault);
          if(!vif.fault) begin
            wait(vif.state_dbg==3'd4 || vif.fault);
            if(req.fail_stage==FAIL_POWER) wait(vif.fault);
            else begin
              repeat(req.power_delay)@(posedge vif.clk);
              @(negedge vif.clk);vif.pwr_good<=1;
              wait(vif.retention_restore || vif.fault);
              if(req.fail_stage==FAIL_RESTORE) wait(vif.fault);
              else begin repeat(req.restore_delay)@(posedge vif.clk);pulse(vif.restore_done); end
            end
          end
        end
        seq_item_port.item_done();
      end
    endtask
  endclass

  class power_cycle_monitor extends uvm_component;
    `uvm_component_utils(power_cycle_monitor)
    virtual power_domain_if vif;
    uvm_analysis_port #(power_cycle_item) ap;
    function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual power_domain_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","cycle monitor needs power_domain_if")
    endfunction
    task run_phase(uvm_phase phase);power_cycle_item t;
      forever begin
        @(posedge vif.clk);#1ps;t=power_cycle_item::type_id::create("cycle");
        t.rst_n=vif.rst_n;t.sleep_req=vif.sleep_req;t.wake_req=vif.wake_req;
        t.save_done=vif.save_done;t.restore_done=vif.restore_done;t.pwr_good=vif.pwr_good;
        t.isolate_en=vif.isolate_en;t.retention_save=vif.retention_save;
        t.retention_restore=vif.retention_restore;t.power_switch_en=vif.power_switch_en;
        t.domain_clk_en=vif.domain_clk_en;t.busy=vif.busy;t.asleep=vif.asleep;
        t.fault=vif.fault;t.state_dbg=vif.state_dbg;ap.write(t);
      end
    endtask
  endclass

  class power_cmd_agent extends uvm_agent;
    `uvm_component_utils(power_cmd_agent)
    power_cmd_sequencer sqr;power_cmd_driver drv;power_cycle_monitor mon;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      sqr=power_cmd_sequencer::type_id::create("sqr",this);
      drv=power_cmd_driver::type_id::create("drv",this);
      mon=power_cycle_monitor::type_id::create("mon",this);
    endfunction
    function void connect_phase(uvm_phase phase);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
  endclass

  class power_ack_agent extends uvm_agent;
    `uvm_component_utils(power_ack_agent)
    power_ack_sequencer sqr;power_ack_driver drv;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      sqr=power_ack_sequencer::type_id::create("sqr",this);
      drv=power_ack_driver::type_id::create("drv",this);
    endfunction
    function void connect_phase(uvm_phase phase);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
  endclass

  class power_domain_scoreboard extends uvm_subscriber #(power_cycle_item);
    `uvm_component_utils(power_domain_scoreboard)
    typedef enum bit[2:0]{ON,SAVE,ISO,OFF,PWR_WAIT,RESTORE,DEISO,FAULT} model_state_e;
    model_state_e state,next_state;int wait_count,checks,errors,roundtrips,faults;
    function new(string n,uvm_component p);super.new(n,p);state=ON;endfunction
    function void write(power_cycle_item t);
      bit exp_iso=1,exp_save=0,exp_restore=0,exp_power=1,exp_clk=0;
      bit exp_busy=1,exp_asleep=0,exp_fault=0;
      if(!t.rst_n)begin state=ON;wait_count=0;return;end
      next_state=state;
      case(state)
        ON:if(t.sleep_req)next_state=SAVE;
        SAVE:if(t.save_done)next_state=ISO;else if(wait_count>=TIMEOUT_CYCLES-1)next_state=FAULT;
        ISO:next_state=OFF;
        OFF:if(t.wake_req)next_state=PWR_WAIT;
        PWR_WAIT:if(t.pwr_good)next_state=RESTORE;else if(wait_count>=TIMEOUT_CYCLES-1)next_state=FAULT;
        RESTORE:if(t.restore_done)next_state=DEISO;else if(wait_count>=TIMEOUT_CYCLES-1)next_state=FAULT;
        DEISO:next_state=ON;
        default:next_state=FAULT;
      endcase
      if(next_state!=state || !(state inside {SAVE,PWR_WAIT,RESTORE}))wait_count=0;
      else if(wait_count<TIMEOUT_CYCLES-1)wait_count++;
      if(state==DEISO&&next_state==ON)roundtrips++;
      if(state!=FAULT&&next_state==FAULT)faults++;
      state=next_state;
      case(state)
        ON:begin exp_iso=0;exp_clk=1;exp_busy=0;end
        SAVE:begin exp_iso=0;exp_save=1;exp_clk=1;end
        ISO:begin exp_iso=1;exp_clk=0;end
        OFF:begin exp_power=0;exp_busy=0;exp_asleep=1;end
        PWR_WAIT:begin end
        RESTORE:begin exp_restore=1;end
        DEISO:begin exp_iso=0;exp_clk=1;end
        default:begin exp_fault=1;end
      endcase
      checks+=9;
      if({t.isolate_en,t.retention_save,t.retention_restore,t.power_switch_en,
          t.domain_clk_en,t.busy,t.asleep,t.fault,t.state_dbg}!==
         {exp_iso,exp_save,exp_restore,exp_power,exp_clk,exp_busy,exp_asleep,
          exp_fault,state})begin errors++;`uvm_error("MODEL",$sformatf("state=%0d outputs mismatch",state))end
    endfunction
    function void report_phase(uvm_phase phase);
      if(errors==0)`uvm_info("RESULT",$sformatf("RESULT: *** PASS *** checks=%0d roundtrips=%0d faults=%0d",checks,roundtrips,faults),UVM_NONE)
      else `uvm_fatal("RESULT",$sformatf("RESULT: *** FAIL *** errors=%0d",errors))
    endfunction
  endclass

  class power_domain_coverage extends uvm_subscriber #(power_cycle_item);
    `uvm_component_utils(power_domain_coverage)
    power_cycle_item sample;
    covergroup cg;
      cp_state:coverpoint sample.state_dbg{bins states[]={[0:7]};}
      cp_busy:coverpoint sample.busy;
      cp_power:coverpoint sample.power_switch_en;
      cp_fault:coverpoint sample.fault;
      cx_state_power:cross cp_state,cp_power;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
    function void write(power_cycle_item t);sample=t;cg.sample();endfunction
  endclass

  class power_domain_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(power_domain_virtual_sequencer)
    power_cmd_sequencer cmd_sqr;power_ack_sequencer ack_sqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass

  class one_cmd_sequence extends uvm_sequence #(power_cmd_item);
    `uvm_object_utils(one_cmd_sequence)
    int hold_cycles;bit reset_first;
    function new(string n="one_cmd_sequence");super.new(n);endfunction
    task body();req=power_cmd_item::type_id::create("req");start_item(req);
      req.off_hold_cycles=hold_cycles;req.reset_first=reset_first;finish_item(req);endtask
  endclass
  class one_ack_sequence extends uvm_sequence #(power_ack_item);
    `uvm_object_utils(one_ack_sequence)
    int sd,pd,rd;fail_stage_e fs;
    function new(string n="one_ack_sequence");super.new(n);endfunction
    task body();req=power_ack_item::type_id::create("req");start_item(req);
      req.save_delay=sd;req.power_delay=pd;req.restore_delay=rd;req.fail_stage=fs;finish_item(req);endtask
  endclass

  class power_domain_regress_vseq extends uvm_sequence;
    `uvm_object_utils(power_domain_regress_vseq)
    `uvm_declare_p_sequencer(power_domain_virtual_sequencer)
    function new(string n="power_domain_regress_vseq");super.new(n);endfunction
    task run_case(int sd,int pd,int rd,int hold,fail_stage_e fs,bit reset_first);
      one_cmd_sequence cs=one_cmd_sequence::type_id::create("cs");
      one_ack_sequence as=one_ack_sequence::type_id::create("as");
      cs.hold_cycles=hold;cs.reset_first=reset_first;
      as.sd=sd;as.pd=pd;as.rd=rd;as.fs=fs;
      fork cs.start(p_sequencer.cmd_sqr);as.start(p_sequencer.ack_sqr);join
    endtask
    task body();power_ack_item random_delays;int i;
      run_case(2,3,2,2,FAIL_NONE,0);run_case(0,0,0,0,FAIL_NONE,0);
      for(i=0;i<40;i++)begin
        random_delays=power_ack_item::type_id::create("random_delays");
        if(!random_delays.randomize())`uvm_fatal("RAND","delay randomization failed")
        run_case(random_delays.save_delay,random_delays.power_delay,
          random_delays.restore_delay,$urandom_range(0,5),FAIL_NONE,0);
      end
      run_case(0,0,0,0,FAIL_SAVE,0);
      run_case(0,0,0,0,FAIL_POWER,1);
      run_case(0,0,0,0,FAIL_RESTORE,1);
    endtask
  endclass

  class power_domain_env extends uvm_env;
    `uvm_component_utils(power_domain_env)
    power_cmd_agent cmd;power_ack_agent ack;power_domain_scoreboard sb;
    power_domain_coverage cov;power_domain_virtual_sequencer vsqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      cmd=power_cmd_agent::type_id::create("cmd",this);ack=power_ack_agent::type_id::create("ack",this);
      sb=power_domain_scoreboard::type_id::create("sb",this);cov=power_domain_coverage::type_id::create("cov",this);
      vsqr=power_domain_virtual_sequencer::type_id::create("vsqr",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      cmd.mon.ap.connect(sb.analysis_export);cmd.mon.ap.connect(cov.analysis_export);
      vsqr.cmd_sqr=cmd.sqr;vsqr.ack_sqr=ack.sqr;
    endfunction
  endclass

  class power_domain_regress_test extends uvm_test;
    `uvm_component_utils(power_domain_regress_test)
    power_domain_env env;virtual power_domain_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      env=power_domain_env::type_id::create("env",this);
      if(!uvm_config_db#(virtual power_domain_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","test needs vif")
    endfunction
    task run_phase(uvm_phase phase);power_domain_regress_vseq vseq;
      phase.raise_objection(this);repeat(3)@(posedge vif.clk);
      vseq=power_domain_regress_vseq::type_id::create("vseq");vseq.start(env.vsqr);
      repeat(4)@(posedge vif.clk);phase.drop_objection(this);
    endtask
  endclass
endpackage
