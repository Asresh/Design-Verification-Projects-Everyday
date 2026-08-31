// Author: Asresh Kuricheti
// Reusable dual-agent UVM environment, virtual sequence, coverage, and scoreboard.
package march_c_bist_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  parameter int ADDR_W=4, DATA_W=8, DEPTH=(1<<ADDR_W);
  typedef virtual march_c_bist_if #(ADDR_W,DATA_W) vif_t;

  class bist_ctrl_item extends uvm_sequence_item;
    rand bit inject_en;
    rand bit [ADDR_W-1:0] inject_addr;
    rand bit inject_stuck_value;
    `uvm_object_utils_begin(bist_ctrl_item)
      `uvm_field_int(inject_en,UVM_DEFAULT)
      `uvm_field_int(inject_addr,UVM_DEFAULT)
      `uvm_field_int(inject_stuck_value,UVM_DEFAULT)
    `uvm_object_utils_end
    function new(string name="bist_ctrl_item"); super.new(name); endfunction
  endclass

  class mem_cfg_item extends uvm_sequence_item;
    rand int unsigned ready_pct;
    rand int unsigned max_latency;
    constraint legal_c { ready_pct inside {[55:100]}; max_latency inside {[0:4]}; }
    `uvm_object_utils_begin(mem_cfg_item)
      `uvm_field_int(ready_pct,UVM_DEFAULT)
      `uvm_field_int(max_latency,UVM_DEFAULT)
    `uvm_object_utils_end
    function new(string name="mem_cfg_item"); super.new(name); endfunction
  endclass

  class bist_cycle_item extends uvm_sequence_item;
    bit start,busy,done,pass,fail;
    bit [ADDR_W-1:0] fail_addr,mem_addr;
    bit [DATA_W-1:0] fail_expected,fail_actual,mem_wdata,mem_rdata;
    bit mem_valid,mem_ready,mem_write,mem_rsp_valid;
    `uvm_object_utils(bist_cycle_item)
    function new(string name="bist_cycle_item"); super.new(name); endfunction
  endclass

  class bist_ctrl_sequence extends uvm_sequence #(bist_ctrl_item);
    bit inject; bit [ADDR_W-1:0] address; bit stuck;
    `uvm_object_utils(bist_ctrl_sequence)
    function new(string name="bist_ctrl_sequence"); super.new(name); endfunction
    task body();
      req=bist_ctrl_item::type_id::create("req"); start_item(req);
      req.inject_en=inject; req.inject_addr=address; req.inject_stuck_value=stuck;
      finish_item(req);
    endtask
  endclass

  class mem_cfg_sequence extends uvm_sequence #(mem_cfg_item);
    `uvm_object_utils(mem_cfg_sequence)
    function new(string name="mem_cfg_sequence"); super.new(name); endfunction
    task body();
      req=mem_cfg_item::type_id::create("req"); start_item(req);
      assert(req.randomize()); finish_item(req);
    endtask
  endclass

  class bist_ctrl_driver extends uvm_driver #(bist_ctrl_item);
    `uvm_component_utils(bist_ctrl_driver) vif_t vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","ctrl driver")
    endfunction
    task run_phase(uvm_phase phase);
      vif.start<=0; vif.inject_en<=0; vif.inject_addr<='0; vif.inject_stuck_value<=0;
      forever begin
        seq_item_port.get_next_item(req);
        while(vif.busy||vif.done) @(vif.ctrl_cb);
        vif.ctrl_cb.inject_en<=req.inject_en; vif.ctrl_cb.inject_addr<=req.inject_addr;
        vif.ctrl_cb.inject_stuck_value<=req.inject_stuck_value; vif.ctrl_cb.start<=1;
        @(vif.ctrl_cb); vif.ctrl_cb.start<=0;
        while(!vif.done) @(vif.ctrl_cb);
        seq_item_port.item_done();
      end
    endtask
  endclass

  class bist_mem_driver extends uvm_driver #(mem_cfg_item);
    `uvm_component_utils(bist_mem_driver) vif_t vif;
    bit [DATA_W-1:0] mem[DEPTH]; int ready_pct=75,max_latency=3,delay;
    bit pending; bit [DATA_W-1:0] pending_data;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","mem driver")
    endfunction
    task run_phase(uvm_phase phase);
      mem_cfg_item cfg; vif.mem_ready<=0; vif.mem_rsp_valid<=0; pending=0;
      foreach(mem[i]) mem[i]=$urandom;
      forever begin
        @(vif.mem_cb); cfg=null; seq_item_port.try_next_item(cfg);
        if(cfg!=null) begin ready_pct=cfg.ready_pct; max_latency=cfg.max_latency; seq_item_port.item_done(); end
        vif.mem_cb.mem_ready<=($urandom_range(1,100)<=ready_pct); vif.mem_cb.mem_rsp_valid<=0;
        if(pending) begin
          if(delay==0) begin vif.mem_cb.mem_rsp_valid<=1; vif.mem_cb.mem_rdata<=pending_data; pending=0; end
          else delay--;
        end
        if(vif.mem_valid&&vif.mem_ready) begin
          if(vif.mem_write) begin
            mem[vif.mem_addr]=vif.mem_wdata;
            if(vif.inject_en&&vif.mem_addr==vif.inject_addr) mem[vif.mem_addr][0]=vif.inject_stuck_value;
          end else begin
            pending_data=mem[vif.mem_addr];
            if(vif.inject_en&&vif.mem_addr==vif.inject_addr) pending_data[0]=vif.inject_stuck_value;
            pending=1; delay=$urandom_range(0,max_latency);
          end
        end
      end
    endtask
  endclass

  class bist_cycle_monitor extends uvm_monitor;
    `uvm_component_utils(bist_cycle_monitor) vif_t vif; uvm_analysis_port #(bist_cycle_item) ap;
    function new(string n,uvm_component p); super.new(n,p); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","monitor")
    endfunction
    task run_phase(uvm_phase phase); bist_cycle_item t;
      forever begin @(posedge vif.clk); #1step; t=bist_cycle_item::type_id::create("t");
        t.start=vif.start; t.busy=vif.busy; t.done=vif.done; t.pass=vif.pass; t.fail=vif.fail;
        t.fail_addr=vif.fail_addr; t.fail_expected=vif.fail_expected; t.fail_actual=vif.fail_actual;
        t.mem_valid=vif.mem_valid; t.mem_ready=vif.mem_ready; t.mem_write=vif.mem_write;
        t.mem_addr=vif.mem_addr; t.mem_wdata=vif.mem_wdata; t.mem_rsp_valid=vif.mem_rsp_valid; t.mem_rdata=vif.mem_rdata; ap.write(t);
      end
    endtask
  endclass

  class bist_ctrl_agent extends uvm_agent;
    `uvm_component_utils(bist_ctrl_agent) uvm_sequencer#(bist_ctrl_item) seqr; bist_ctrl_driver drv;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase ph);super.build_phase(ph);seqr=new("seqr",this);drv=bist_ctrl_driver::type_id::create("drv",this);endfunction
    function void connect_phase(uvm_phase ph);drv.seq_item_port.connect(seqr.seq_item_export);endfunction
  endclass
  class bist_mem_agent extends uvm_agent;
    `uvm_component_utils(bist_mem_agent) uvm_sequencer#(mem_cfg_item) seqr; bist_mem_driver drv;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase ph);super.build_phase(ph);seqr=new("seqr",this);drv=bist_mem_driver::type_id::create("drv",this);endfunction
    function void connect_phase(uvm_phase ph);drv.seq_item_port.connect(seqr.seq_item_export);endfunction
  endclass

  class bist_scoreboard extends uvm_subscriber #(bist_cycle_item);
    `uvm_component_utils(bist_scoreboard)
    int phase_idx,addr,subop,errors,commands,clean_done,fault_done; bit active,expect_fault;
    covergroup cg with function sample(int p,int a,bit wr,bit stalled);
      cp_phase: coverpoint p { bins phases[]={[0:5]}; }
      cp_edge: coverpoint a { bins first={0}; bins middle={[1:DEPTH-2]}; bins last={DEPTH-1}; }
      cp_kind: coverpoint wr; cp_stall: coverpoint stalled;
      phase_x_kind: cross cp_phase,cp_kind;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
    function void bad(string s);`uvm_error("SCOREBOARD",s) errors++;endfunction
    function void write(bist_cycle_item t);
      bit exp_wr,exp_bit;
      if(t.start) begin active=1;phase_idx=0;addr=0;subop=0;expect_fault=0;end
      if(t.mem_valid) cg.sample(phase_idx,addr,t.mem_write,!t.mem_ready);
      if(active&&t.mem_valid&&t.mem_ready) begin
        exp_wr=(phase_idx==0)||((phase_idx>=1&&phase_idx<=4)&&subop==1);
        exp_bit=(phase_idx==1||phase_idx==3);
        if(t.mem_write!=exp_wr||t.mem_addr!=addr) bad($sformatf("unexpected command phase=%0d addr=%0d",phase_idx,addr));
        if(exp_wr&&t.mem_wdata!={DATA_W{exp_bit}}) bad("wrong March write data");
        commands++;
        if(phase_idx==0||subop==1||phase_idx==5) begin
          subop=0;
          if(phase_idx<3) begin if(addr==DEPTH-1) begin phase_idx++;addr=(phase_idx==3)?DEPTH-1:0;end else addr++;end
          else begin if(addr==0) begin phase_idx++;addr=DEPTH-1;end else addr--;end
        end else subop=1;
      end
      if(t.done&&active) begin
        active=0; if(t.fail) fault_done++; else clean_done++;
        if(t.pass==t.fail) bad("pass/fail completion flags inconsistent");
      end
    endfunction
    function void report_phase(uvm_phase phase);
      if(errors==0&&clean_done>0&&fault_done>0&&cg.get_coverage()>80.0)
        `uvm_info("RESULT",$sformatf("RESULT: *** PASS *** commands=%0d coverage=%0.1f",commands,cg.get_coverage()),UVM_NONE)
      else `uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** errors=%0d clean=%0d faults=%0d coverage=%0.1f",errors,clean_done,fault_done,cg.get_coverage()))
    endfunction
  endclass

  class bist_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(bist_virtual_sequencer)
    uvm_sequencer#(bist_ctrl_item) ctrl_seqr; uvm_sequencer#(mem_cfg_item) mem_seqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass
  class bist_regress_vseq extends uvm_sequence;
    `uvm_object_utils(bist_regress_vseq) `uvm_declare_p_sequencer(bist_virtual_sequencer)
    function new(string n="bist_regress_vseq");super.new(n);endfunction
    task one(bit inj,bit[ADDR_W-1:0] a,bit stuck);
      bist_ctrl_sequence c=bist_ctrl_sequence::type_id::create("c"); mem_cfg_sequence m=mem_cfg_sequence::type_id::create("m");
      c.inject=inj;c.address=a;c.stuck=stuck; fork m.start(p_sequencer.mem_seqr); c.start(p_sequencer.ctrl_seqr); join
    endtask
    task body(); one(0,'0,0); one(1,5,1); one(1,DEPTH-2,1); endtask
  endclass

  class bist_env extends uvm_env;
    `uvm_component_utils(bist_env) bist_ctrl_agent ctrl; bist_mem_agent mem; bist_cycle_monitor mon; bist_scoreboard sb; bist_virtual_sequencer vseqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase ph);super.build_phase(ph);ctrl=bist_ctrl_agent::type_id::create("ctrl",this);mem=bist_mem_agent::type_id::create("mem",this);mon=bist_cycle_monitor::type_id::create("mon",this);sb=bist_scoreboard::type_id::create("sb",this);vseqr=bist_virtual_sequencer::type_id::create("vseqr",this);endfunction
    function void connect_phase(uvm_phase ph);mon.ap.connect(sb.analysis_export);vseqr.ctrl_seqr=ctrl.seqr;vseqr.mem_seqr=mem.seqr;endfunction
  endclass
  class march_c_bist_test extends uvm_test;
    `uvm_component_utils(march_c_bist_test) bist_env env;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase ph);super.build_phase(ph);env=bist_env::type_id::create("env",this);endfunction
    task run_phase(uvm_phase ph);bist_regress_vseq v=bist_regress_vseq::type_id::create("v");ph.raise_objection(this);v.start(env.vseqr);#100;ph.drop_objection(this);endtask
  endclass
endpackage
