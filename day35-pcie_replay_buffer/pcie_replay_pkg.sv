// Author: Asresh Kuricheti
package pcie_replay_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum {OP_SEND, OP_ACK, OP_NAK, OP_IDLE} replay_op_e;

  class replay_item extends uvm_sequence_item;
    rand replay_op_e op;
    rand bit [31:0] data;
    rand bit [7:0] seq;
    rand bit link_ready;
    constraint useful_c { op dist {OP_SEND:=50, OP_ACK:=15, OP_NAK:=10, OP_IDLE:=25};
                          link_ready dist {1:=8, 0:=2}; }
    `uvm_object_utils_begin(replay_item)
      `uvm_field_enum(replay_op_e, op, UVM_ALL_ON)
      `uvm_field_int(data, UVM_HEX)
      `uvm_field_int(seq, UVM_DEC)
      `uvm_field_int(link_ready, UVM_BIN)
    `uvm_object_utils_end
    function new(string name="replay_item"); super.new(name); endfunction
  endclass

  class replay_sample extends uvm_sequence_item;
    bit rst_n, tx_valid, tx_ready, link_valid, link_ready;
    bit ack_valid, nak_valid, replay_active, full, empty;
    bit [31:0] tx_data, link_data;
    bit [7:0] link_seq, ack_seq, nak_seq;
    int unsigned occupancy;
    `uvm_object_utils(replay_sample)
    function new(string name="replay_sample"); super.new(name); endfunction
  endclass

  class replay_sequencer extends uvm_sequencer #(replay_item);
    `uvm_component_utils(replay_sequencer)
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
  endclass

  class replay_driver extends uvm_driver #(replay_item);
    `uvm_component_utils(replay_driver)
    virtual pcie_replay_if vif;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual pcie_replay_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","driver vif")
    endfunction
    task run_phase(uvm_phase phase);
      vif.drv_cb.tx_valid<=0; vif.drv_cb.ack_valid<=0; vif.drv_cb.nak_valid<=0; vif.drv_cb.link_ready<=1;
      forever begin
        seq_item_port.get_next_item(req);
        vif.drv_cb.tx_valid<=0; vif.drv_cb.ack_valid<=0; vif.drv_cb.nak_valid<=0;
        vif.drv_cb.link_ready<=req.link_ready;
        case (req.op)
          OP_SEND: begin vif.drv_cb.tx_valid<=1; vif.drv_cb.tx_data<=req.data; end
          OP_ACK:  begin vif.drv_cb.ack_valid<=1; vif.drv_cb.ack_seq<=req.seq; end
          OP_NAK:  begin vif.drv_cb.nak_valid<=1; vif.drv_cb.nak_seq<=req.seq; end
          default: ;
        endcase
        @(vif.drv_cb);
        vif.drv_cb.tx_valid<=0; vif.drv_cb.ack_valid<=0; vif.drv_cb.nak_valid<=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class replay_monitor extends uvm_monitor;
    `uvm_component_utils(replay_monitor)
    virtual pcie_replay_if vif;
    uvm_analysis_port #(replay_sample) ap;
    function new(string name, uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual pcie_replay_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","monitor vif")
    endfunction
    task run_phase(uvm_phase phase);
      replay_sample s;
      forever begin
        @(vif.mon_cb); s=replay_sample::type_id::create("s");
        s.rst_n=vif.mon_cb.rst_n; s.tx_valid=vif.mon_cb.tx_valid; s.tx_ready=vif.mon_cb.tx_ready;
        s.tx_data=vif.mon_cb.tx_data; s.link_valid=vif.mon_cb.link_valid; s.link_ready=vif.mon_cb.link_ready;
        s.link_data=vif.mon_cb.link_data; s.link_seq=vif.mon_cb.link_seq;
        s.ack_valid=vif.mon_cb.ack_valid; s.ack_seq=vif.mon_cb.ack_seq;
        s.nak_valid=vif.mon_cb.nak_valid; s.nak_seq=vif.mon_cb.nak_seq;
        s.replay_active=vif.mon_cb.replay_active; s.full=vif.mon_cb.full; s.empty=vif.mon_cb.empty;
        s.occupancy=vif.mon_cb.occupancy; ap.write(s);
      end
    endtask
  endclass

  class replay_agent extends uvm_agent;
    `uvm_component_utils(replay_agent)
    replay_sequencer sqr; replay_driver drv; replay_monitor mon;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      sqr=replay_sequencer::type_id::create("sqr",this); drv=replay_driver::type_id::create("drv",this);
      mon=replay_monitor::type_id::create("mon",this);
    endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
  endclass

  class replay_scoreboard extends uvm_subscriber #(replay_sample);
    `uvm_component_utils(replay_scoreboard)
    typedef struct packed {bit [7:0] seq; bit [31:0] data;} entry_t;
    entry_t retained[$], send_q[$]; bit [7:0] next_seq; int checks, errors;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void write(replay_sample s);
      entry_t e; int idx=-1;
      if (!s.rst_n) begin retained.delete(); send_q.delete(); next_seq=0; return; end
      if (s.tx_valid && s.tx_ready) begin e='{next_seq,s.tx_data}; retained.push_back(e); send_q.push_back(e); next_seq++; end
      if (s.nak_valid) begin
        foreach(retained[i]) if(retained[i].seq==s.nak_seq) idx=i;
        if(idx>=0) begin send_q.delete(); for(int j=idx;j<retained.size();j++) send_q.push_back(retained[j]); end
      end
      if (s.link_valid && s.link_ready) begin
        checks++;
        if(!send_q.size()) begin `uvm_error("UNEXPECTED","link packet without model entry") errors++; end
        else begin e=send_q.pop_front(); if(e.seq!==s.link_seq || e.data!==s.link_data) begin
          `uvm_error("MISMATCH",$sformatf("expected seq=%0d data=%08x got seq=%0d data=%08x",e.seq,e.data,s.link_seq,s.link_data)) errors++; end end
      end
      if (s.ack_valid) begin
        idx=-1; foreach(retained[i]) if(retained[i].seq==s.ack_seq) idx=i;
        if(idx>=0) repeat(idx+1) void'(retained.pop_front());
      end
      if(s.occupancy != retained.size()) begin `uvm_error("OCC",$sformatf("expected %0d got %0d",retained.size(),s.occupancy)) errors++; end
    endfunction
    function void report_phase(uvm_phase phase);
      if(errors==0 && checks>0) `uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d link packets checked)",checks),UVM_NONE)
      else `uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** errors=%0d checks=%0d",errors,checks))
    endfunction
  endclass

  class replay_coverage extends uvm_subscriber #(replay_sample);
    `uvm_component_utils(replay_coverage)
    replay_sample cur;
    covergroup cg;
      option.per_instance=1;
      cp_occ: coverpoint cur.occupancy { bins empty={0}; bins middle={[1:7]}; bins full={8}; }
      cp_event: coverpoint {cur.tx_valid&&cur.tx_ready,cur.ack_valid,cur.nak_valid} {
        bins send={3'b100}; bins ack={3'b010}; bins nak={3'b001}; }
      cp_stall: coverpoint {cur.link_valid,cur.link_ready} { bins transfer={2'b11}; bins stalled={2'b10}; }
      event_x_occ: cross cp_event, cp_occ;
    endgroup
    function new(string name,uvm_component parent); super.new(name,parent); cg=new; endfunction
    function void write(replay_sample t); cur=t; if(t.rst_n) cg.sample(); endfunction
  endclass

  class replay_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(replay_virtual_sequencer)
    replay_sequencer replay_sqr;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
  endclass

  class replay_directed_seq extends uvm_sequence #(replay_item);
    `uvm_object_utils(replay_directed_seq)
    function new(string name="replay_directed_seq"); super.new(name); endfunction
    task emit(replay_op_e op, bit[31:0] data=0, bit[7:0] seq=0, bit ready=1);
      replay_item it=replay_item::type_id::create("it"); start_item(it); it.op=op; it.data=data; it.seq=seq; it.link_ready=ready; finish_item(it);
    endtask
    task body();
      emit(OP_SEND,32'hA11CE001); emit(OP_SEND,32'hA11CE002); emit(OP_SEND,32'hA11CE003);
      repeat(2) emit(OP_IDLE,0,0,0); repeat(4) emit(OP_IDLE);
      emit(OP_NAK,0,1); repeat(3) emit(OP_IDLE); emit(OP_ACK,0,1);
      emit(OP_NAK,0,2); repeat(2) emit(OP_IDLE); emit(OP_ACK,0,2);
    endtask
  endclass

  class replay_random_seq extends uvm_sequence #(replay_item);
    `uvm_object_utils(replay_random_seq)
    function new(string name="replay_random_seq"); super.new(name); endfunction
    task emit(replay_op_e op, bit[31:0] data=0, bit[7:0] seq=0, bit ready=1);
      replay_item it=replay_item::type_id::create("it"); start_item(it); it.op=op; it.data=data; it.seq=seq; it.link_ready=ready; finish_item(it);
    endtask
    task body();
      bit [7:0] first_seq=3, last_seq; int unsigned burst; bit [31:0] payload;
      repeat(100) begin
        assert(std::randomize(burst) with {burst inside {[1:5]};});
        for(int i=0;i<burst;i++) begin assert(std::randomize(payload)); emit(OP_SEND,payload); end
        last_seq=first_seq+burst-1;
        repeat(burst+1) emit(OP_IDLE);
        if(($urandom_range(0,2)==0)) begin emit(OP_NAK,0,first_seq); repeat(burst+1) emit(OP_IDLE); end
        emit(OP_ACK,0,last_seq); first_seq=last_seq+1;
      end
    endtask
  endclass

  class replay_regress_vseq extends uvm_sequence;
    `uvm_object_utils(replay_regress_vseq)
    `uvm_declare_p_sequencer(replay_virtual_sequencer)
    function new(string name="replay_regress_vseq"); super.new(name); endfunction
    task body();
      replay_directed_seq d=replay_directed_seq::type_id::create("d");
      replay_random_seq r=replay_random_seq::type_id::create("r");
      d.start(p_sequencer.replay_sqr); r.start(p_sequencer.replay_sqr);
    endtask
  endclass

  class replay_env extends uvm_env;
    `uvm_component_utils(replay_env)
    replay_agent agent; replay_scoreboard sb; replay_coverage cov; replay_virtual_sequencer vsqr;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      agent=replay_agent::type_id::create("agent",this); sb=replay_scoreboard::type_id::create("sb",this);
      cov=replay_coverage::type_id::create("cov",this); vsqr=replay_virtual_sequencer::type_id::create("vsqr",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(sb.analysis_export); agent.mon.ap.connect(cov.analysis_export); vsqr.replay_sqr=agent.sqr;
    endfunction
  endclass

  class replay_regress_test extends uvm_test;
    `uvm_component_utils(replay_regress_test)
    replay_env env;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase); env=replay_env::type_id::create("env",this); endfunction
    task run_phase(uvm_phase phase);
      replay_regress_vseq v=replay_regress_vseq::type_id::create("v"); phase.raise_objection(this); v.start(env.vsqr); repeat(20) @(posedge env.agent.drv.vif.clk); phase.drop_objection(this);
    endtask
  endclass
endpackage
