// Author: Asresh Kuricheti
// Complete UVM environment: two active agents, virtual sequences, scoreboard, and coverage.
package axi_read_reorder_pkg;
  import uvm_pkg::*;
  import axi_read_reorder_ref_pkg::*;
  `include "uvm_macros.svh"

  class axi_read_item extends uvm_sequence_item;
    rand bit [1:0] id;
    rand bit [15:0] addr;
    rand int unsigned idle_cycles;
    constraint aligned_c { addr[1:0] == 0; idle_cycles inside {[0:3]}; }
    constraint useful_c {
      addr[15:12] dist {0:=5, [1:14]:=12, 15:=3};
      addr[5:2] dist {4'hf:=2, [0:14]:=14};
    }
    `uvm_object_utils_begin(axi_read_item)
      `uvm_field_int(id,UVM_DEC) `uvm_field_int(addr,UVM_HEX)
      `uvm_field_int(idle_cycles,UVM_DEC)
    `uvm_object_utils_end
    function new(string name="axi_read_item"); super.new(name); endfunction
  endclass

  typedef enum {COMPLETE_OLDEST, COMPLETE_NEWEST, COMPLETE_RANDOM} complete_mode_e;
  class mem_control_item extends uvm_sequence_item;
    rand bit req_ready;
    rand bit r_ready;
    rand bit complete;
    rand complete_mode_e mode;
    constraint flow_c {
      req_ready dist {1:=9,0:=1}; r_ready dist {1:=7,0:=3};
      complete dist {1:=7,0:=3};
      mode dist {COMPLETE_OLDEST:=2,COMPLETE_NEWEST:=5,COMPLETE_RANDOM:=3};
    }
    `uvm_object_utils_begin(mem_control_item)
      `uvm_field_int(req_ready,UVM_BIN) `uvm_field_int(r_ready,UVM_BIN)
      `uvm_field_int(complete,UVM_BIN) `uvm_field_enum(complete_mode_e,mode,UVM_DEFAULT)
    `uvm_object_utils_end
    function new(string name="mem_control_item"); super.new(name); endfunction
  endclass

  class bus_sample extends uvm_sequence_item;
    bit rst_n, ar_valid, ar_ready, mem_req_valid, mem_req_ready, mem_rsp_valid;
    bit r_valid, r_ready, mem_rsp_error, r_error;
    bit [1:0] ar_id, mem_req_id, r_id;
    bit [2:0] mem_req_tag, mem_rsp_tag;
    bit [15:0] ar_addr, mem_req_addr;
    bit [31:0] mem_rsp_data, r_data;
    int unsigned occupancy;
    `uvm_object_utils(bus_sample)
    function new(string name="bus_sample"); super.new(name); endfunction
  endclass

  class axi_read_sequencer extends uvm_sequencer #(axi_read_item);
    `uvm_component_utils(axi_read_sequencer)
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
  endclass
  class mem_sequencer extends uvm_sequencer #(mem_control_item);
    `uvm_component_utils(mem_sequencer)
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
  endclass

  class axi_read_driver extends uvm_driver #(axi_read_item);
    `uvm_component_utils(axi_read_driver)
    virtual axi_read_reorder_if vif;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual axi_read_reorder_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","request driver has no vif")
    endfunction
    task run_phase(uvm_phase phase);
      vif.req_cb.ar_valid <= 0; vif.req_cb.ar_id <= 0; vif.req_cb.ar_addr <= 0;
      forever begin
        seq_item_port.get_next_item(req);
        repeat(req.idle_cycles) @(vif.req_cb);
        vif.req_cb.ar_valid <= 1; vif.req_cb.ar_id <= req.id; vif.req_cb.ar_addr <= req.addr;
        do @(vif.req_cb); while(!vif.req_cb.ar_ready);
        vif.req_cb.ar_valid <= 0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class mem_driver extends uvm_driver #(mem_control_item);
    `uvm_component_utils(mem_driver)
    typedef struct packed {bit [2:0] tag; bit [1:0] id; bit [15:0] addr;} pending_t;
    pending_t pending[$];
    virtual axi_read_reorder_if vif;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual axi_read_reorder_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","memory driver has no vif")
    endfunction
    task run_phase(uvm_phase phase);
      pending_t p; bit [32:0] refv; int idx;
      vif.mem_cb.mem_req_ready<=0; vif.mem_cb.mem_rsp_valid<=0; vif.mem_cb.r_ready<=0;
      forever begin
        seq_item_port.get_next_item(req);
        vif.mem_cb.mem_req_ready<=req.req_ready; vif.mem_cb.r_ready<=req.r_ready;
        vif.mem_cb.mem_rsp_valid<=0;
        @(vif.mem_cb);
        if(vif.mem_cb.mem_req_valid && vif.mem_cb.mem_req_ready) begin
          p='{vif.mem_cb.mem_req_tag,vif.mem_cb.mem_req_id,vif.mem_cb.mem_req_addr};
          pending.push_back(p);
        end
        if(req.complete && pending.size()) begin
          case(req.mode)
            COMPLETE_OLDEST: idx=0;
            COMPLETE_NEWEST: idx=pending.size()-1;
            default: idx=$urandom_range(pending.size()-1,0);
          endcase
          p=pending[idx]; pending.delete(idx); refv=ref_read(p.addr);
          vif.mem_cb.mem_rsp_valid<=1; vif.mem_cb.mem_rsp_tag<=p.tag;
          vif.mem_cb.mem_rsp_error<=refv[32]; vif.mem_cb.mem_rsp_data<=refv[31:0];
        end
        seq_item_port.item_done();
      end
    endtask
  endclass

  class reorder_monitor extends uvm_monitor;
    `uvm_component_utils(reorder_monitor)
    virtual axi_read_reorder_if vif;
    uvm_analysis_port #(bus_sample) ap;
    function new(string name,uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual axi_read_reorder_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","monitor has no vif")
    endfunction
    task run_phase(uvm_phase phase); bus_sample s;
      forever begin @(vif.mon_cb); s=bus_sample::type_id::create("s");
        s.rst_n=vif.mon_cb.rst_n; s.ar_valid=vif.mon_cb.ar_valid; s.ar_ready=vif.mon_cb.ar_ready;
        s.ar_id=vif.mon_cb.ar_id; s.ar_addr=vif.mon_cb.ar_addr;
        s.mem_req_valid=vif.mon_cb.mem_req_valid; s.mem_req_ready=vif.mon_cb.mem_req_ready;
        s.mem_req_tag=vif.mon_cb.mem_req_tag; s.mem_req_id=vif.mon_cb.mem_req_id;
        s.mem_req_addr=vif.mon_cb.mem_req_addr; s.mem_rsp_valid=vif.mon_cb.mem_rsp_valid;
        s.mem_rsp_tag=vif.mon_cb.mem_rsp_tag; s.mem_rsp_data=vif.mon_cb.mem_rsp_data;
        s.mem_rsp_error=vif.mon_cb.mem_rsp_error; s.r_valid=vif.mon_cb.r_valid;
        s.r_ready=vif.mon_cb.r_ready; s.r_id=vif.mon_cb.r_id; s.r_data=vif.mon_cb.r_data;
        s.r_error=vif.mon_cb.r_error; s.occupancy=vif.mon_cb.occupancy; ap.write(s);
      end
    endtask
  endclass

  class axi_read_agent extends uvm_agent;
    `uvm_component_utils(axi_read_agent)
    axi_read_sequencer sqr; axi_read_driver drv;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      sqr=axi_read_sequencer::type_id::create("sqr",this);
      drv=axi_read_driver::type_id::create("drv",this);
    endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
  endclass
  class memory_agent extends uvm_agent;
    `uvm_component_utils(memory_agent)
    mem_sequencer sqr; mem_driver drv;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      sqr=mem_sequencer::type_id::create("sqr",this); drv=mem_driver::type_id::create("drv",this);
    endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
  endclass

  class reorder_scoreboard extends uvm_subscriber #(bus_sample);
    `uvm_component_utils(reorder_scoreboard)
    bit [32:0] expected[4][$]; bit [15:0] tag_addr[8]; bit tag_live[8];
    int checks, errors, reordered_completions; int last_rsp_tag=-1;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void write(bus_sample s); bit [32:0] exp;
      if(!s.rst_n) begin foreach(expected[i]) expected[i].delete(); foreach(tag_live[i]) tag_live[i]=0; return; end
      if(s.ar_valid && s.ar_ready) expected[s.ar_id].push_back(ref_read(s.ar_addr));
      if(s.mem_req_valid && s.mem_req_ready) begin
        if(tag_live[s.mem_req_tag]) begin `uvm_error("TAG","tag reused while live") errors++; end
        tag_live[s.mem_req_tag]=1; tag_addr[s.mem_req_tag]=s.mem_req_addr;
        if(!(s.ar_valid&&s.ar_ready) || s.mem_req_id!=s.ar_id || s.mem_req_addr!=s.ar_addr) begin
          `uvm_error("REQ","downstream request differs from accepted AXI request") errors++;
        end
      end
      if(s.mem_rsp_valid) begin
        if(!tag_live[s.mem_rsp_tag]) begin `uvm_error("RSPTAG","completion for inactive tag") errors++; end
        exp=ref_read(tag_addr[s.mem_rsp_tag]);
        if({s.mem_rsp_error,s.mem_rsp_data}!==exp) begin `uvm_error("MEMDATA","memory model returned bad data") errors++; end
        if(last_rsp_tag>=0 && s.mem_rsp_tag<last_rsp_tag) reordered_completions++;
        last_rsp_tag=s.mem_rsp_tag;
        tag_live[s.mem_rsp_tag]=0;
      end
      if(s.r_valid && s.r_ready) begin
        checks++;
        if(!expected[s.r_id].size()) begin `uvm_error("EXTRA","unexpected upstream response") errors++; end
        else begin exp=expected[s.r_id].pop_front();
          if({s.r_error,s.r_data}!==exp) begin
            `uvm_error("MISMATCH",$sformatf("id=%0d expected=%09x got=%09x",s.r_id,exp,{s.r_error,s.r_data})) errors++;
          end
        end
      end
    endfunction
    function void report_phase(uvm_phase phase); int pending=0;
      foreach(expected[i]) pending+=expected[i].size();
      if(errors==0 && checks>0 && pending==0 && reordered_completions>0)
        `uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d reads, %0d reordered completions)",checks,reordered_completions),UVM_NONE)
      else `uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** errors=%0d checks=%0d pending=%0d reordered=%0d",errors,checks,pending,reordered_completions))
    endfunction
  endclass

  class reorder_coverage extends uvm_subscriber #(bus_sample);
    `uvm_component_utils(reorder_coverage)
    bus_sample cur;
    covergroup cg;
      option.per_instance=1;
      cp_id: coverpoint cur.r_id iff(cur.r_valid&&cur.r_ready) { bins ids[]={0,1,2,3}; }
      cp_error: coverpoint cur.r_error iff(cur.r_valid&&cur.r_ready);
      cp_occ: coverpoint cur.occupancy { bins empty={0}; bins low={[1:3]}; bins high={[4:7]}; bins full={8}; }
      cp_stall: coverpoint {cur.r_valid,cur.r_ready} { bins transfer={2'b11}; bins stalled={2'b10}; }
      id_x_error: cross cp_id,cp_error;
    endgroup
    function new(string name,uvm_component parent); super.new(name,parent); cg=new; endfunction
    function void write(bus_sample t); cur=t; if(t.rst_n) cg.sample(); endfunction
  endclass

  class directed_read_seq extends uvm_sequence #(axi_read_item);
    `uvm_object_utils(directed_read_seq)
    function new(string name="directed_read_seq"); super.new(name); endfunction
    task emit(bit[1:0] id,bit[15:0] addr,int idle=0); axi_read_item it=axi_read_item::type_id::create("it");
      start_item(it); it.id=id; it.addr=addr; it.idle_cycles=idle; finish_item(it); endtask
    task body();
      emit(0,16'h0100); emit(0,16'h0104); emit(1,16'h0200); emit(0,16'h013c);
      emit(2,16'h103c); emit(3,16'h2040); emit(1,16'h0204); emit(2,16'h1040);
    endtask
  endclass
  class random_read_seq extends uvm_sequence #(axi_read_item);
    `uvm_object_utils(random_read_seq)
    int count=300;
    function new(string name="random_read_seq"); super.new(name); endfunction
    task body(); repeat(count) begin axi_read_item it=axi_read_item::type_id::create("it"); start_item(it);
      if(!it.randomize()) `uvm_fatal("RAND","read randomization failed") finish_item(it); end endtask
  endclass
  class memory_flow_seq extends uvm_sequence #(mem_control_item);
    `uvm_object_utils(memory_flow_seq)
    int count=1200;
    function new(string name="memory_flow_seq"); super.new(name); endfunction
    task body(); repeat(count) begin mem_control_item it=mem_control_item::type_id::create("it"); start_item(it);
      if(!it.randomize()) `uvm_fatal("RAND","memory control randomization failed") finish_item(it); end endtask
  endclass
  class drain_memory_seq extends uvm_sequence #(mem_control_item);
    `uvm_object_utils(drain_memory_seq)
    function new(string name="drain_memory_seq"); super.new(name); endfunction
    task body(); repeat(128) begin mem_control_item it=mem_control_item::type_id::create("it"); start_item(it);
      it.req_ready=1; it.r_ready=1; it.complete=1; it.mode=COMPLETE_NEWEST; finish_item(it); end endtask
  endclass

  class reorder_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(reorder_virtual_sequencer)
    axi_read_sequencer read_sqr; mem_sequencer mem_sqr;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
  endclass
  class reorder_regress_vseq extends uvm_sequence;
    `uvm_object_utils(reorder_regress_vseq)
    `uvm_declare_p_sequencer(reorder_virtual_sequencer)
    function new(string name="reorder_regress_vseq"); super.new(name); endfunction
    task body(); directed_read_seq d; random_read_seq r; memory_flow_seq m; drain_memory_seq drain;
      d=directed_read_seq::type_id::create("d"); r=random_read_seq::type_id::create("r");
      m=memory_flow_seq::type_id::create("m"); drain=drain_memory_seq::type_id::create("drain");
      fork begin d.start(p_sequencer.read_sqr); r.start(p_sequencer.read_sqr); end
           m.start(p_sequencer.mem_sqr); join
      drain.start(p_sequencer.mem_sqr);
    endtask
  endclass

  class reorder_env extends uvm_env;
    `uvm_component_utils(reorder_env)
    axi_read_agent read_agent; memory_agent mem_agent; reorder_monitor mon;
    reorder_scoreboard sb; reorder_coverage cov; reorder_virtual_sequencer vsqr;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      read_agent=axi_read_agent::type_id::create("read_agent",this); mem_agent=memory_agent::type_id::create("mem_agent",this);
      mon=reorder_monitor::type_id::create("mon",this); sb=reorder_scoreboard::type_id::create("sb",this);
      cov=reorder_coverage::type_id::create("cov",this); vsqr=reorder_virtual_sequencer::type_id::create("vsqr",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      mon.ap.connect(sb.analysis_export); mon.ap.connect(cov.analysis_export);
      vsqr.read_sqr=read_agent.sqr; vsqr.mem_sqr=mem_agent.sqr;
    endfunction
  endclass
  class axi_reorder_regress_test extends uvm_test;
    `uvm_component_utils(axi_reorder_regress_test)
    reorder_env env;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase); env=reorder_env::type_id::create("env",this); endfunction
    task run_phase(uvm_phase phase); reorder_regress_vseq v=reorder_regress_vseq::type_id::create("v");
      phase.raise_objection(this); v.start(env.vsqr); repeat(40) @(posedge env.mon.vif.clk); phase.drop_objection(this); endtask
  endclass
endpackage
