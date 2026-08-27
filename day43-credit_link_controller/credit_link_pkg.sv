// Author: Asresh Kuricheti
package credit_link_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int DATA_W = 16;
  parameter int MAX_CREDITS = 8;
  parameter int CREDIT_W = $clog2(MAX_CREDITS+1);
  typedef virtual credit_link_if #(DATA_W,MAX_CREDITS,CREDIT_W) vif_t;

  class flit_item extends uvm_sequence_item;
    rand bit [DATA_W-1:0] data;
    rand bit last;
    constraint useful_data { data dist {16'h0000:=1, 16'hffff:=1, [16'h0001:16'hfffe]:=18}; }
    `uvm_object_utils_begin(flit_item)
      `uvm_field_int(data, UVM_ALL_ON)
      `uvm_field_int(last, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="flit_item"); super.new(name); endfunction
  endclass

  class credit_item extends uvm_sequence_item;
    rand bit cfg;
    rand bit [CREDIT_W-1:0] amount;
    constraint legal_amount { amount inside {[0:MAX_CREDITS]}; }
    `uvm_object_utils_begin(credit_item)
      `uvm_field_int(cfg, UVM_ALL_ON)
      `uvm_field_int(amount, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="credit_item"); super.new(name); endfunction
  endclass

  class cycle_item extends uvm_sequence_item;
    bit rst_n, cfg_valid, req_valid, req_ready, req_last, link_valid, link_last, overflow;
    bit [CREDIT_W-1:0] cfg_credits, credit_return, credit_count;
    bit [DATA_W-1:0] req_data, link_data;
    `uvm_object_utils(cycle_item)
    function new(string name="cycle_item"); super.new(name); endfunction
  endclass

  class flit_sequence extends uvm_sequence #(flit_item);
    rand int unsigned count = 100;
    `uvm_object_utils(flit_sequence)
    function new(string name="flit_sequence"); super.new(name); endfunction
    task body();
      repeat (count) begin
        req = flit_item::type_id::create("req");
        start_item(req); if (!req.randomize()) `uvm_fatal("RAND","flit randomization failed") finish_item(req);
      end
    endtask
  endclass

  class directed_flit_sequence extends uvm_sequence #(flit_item);
    `uvm_object_utils(directed_flit_sequence)
    function new(string name="directed_flit_sequence"); super.new(name); endfunction
    task body();
      bit [DATA_W-1:0] values[6] = '{16'h1001,16'h1002,16'h1003,16'h2001,16'hffff,16'h0000};
      foreach (values[i]) begin
        req=flit_item::type_id::create($sformatf("flit%0d",i)); start_item(req);
        req.data=values[i]; req.last=(i==2 || i==5); finish_item(req);
      end
    endtask
  endclass

  class credit_sequence extends uvm_sequence #(credit_item);
    rand int unsigned cycles = 160;
    `uvm_object_utils(credit_sequence)
    function new(string name="credit_sequence"); super.new(name); endfunction
    task body();
      req=credit_item::type_id::create("configure"); start_item(req); req.cfg=1; req.amount=4; finish_item(req);
      repeat(cycles) begin
        req=credit_item::type_id::create("return"); start_item(req);
        req.cfg=0; req.amount=($urandom_range(0,99)<42) ? 1 : 0; finish_item(req);
      end
    endtask
  endclass

  class flit_sequencer extends uvm_sequencer #(flit_item);
    `uvm_component_utils(flit_sequencer)
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass
  class credit_sequencer extends uvm_sequencer #(credit_item);
    `uvm_component_utils(credit_sequencer)
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass

  class flit_driver extends uvm_driver #(flit_item);
    `uvm_component_utils(flit_driver) vif_t vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); super.build_phase(phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","flit driver") endfunction
    task run_phase(uvm_phase phase);
      vif.drv_cb.req_valid<=0;
      forever begin
        seq_item_port.get_next_item(req); vif.drv_cb.req_valid<=1; vif.drv_cb.req_data<=req.data; vif.drv_cb.req_last<=req.last;
        do @(vif.drv_cb); while(!vif.drv_cb.req_ready);
        vif.drv_cb.req_valid<=0; seq_item_port.item_done();
      end
    endtask
  endclass

  class credit_driver extends uvm_driver #(credit_item);
    `uvm_component_utils(credit_driver) vif_t vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); super.build_phase(phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","credit driver") endfunction
    task run_phase(uvm_phase phase);
      vif.drv_cb.cfg_valid<=0; vif.drv_cb.credit_return<='0;
      forever begin
        seq_item_port.get_next_item(req); @(vif.drv_cb);
        vif.drv_cb.cfg_valid<=req.cfg; vif.drv_cb.cfg_credits<=req.amount;
        vif.drv_cb.credit_return<=req.cfg ? '0 : req.amount; @(vif.drv_cb);
        vif.drv_cb.cfg_valid<=0; vif.drv_cb.credit_return<='0; seq_item_port.item_done();
      end
    endtask
  endclass

  class flit_monitor extends uvm_monitor;
    `uvm_component_utils(flit_monitor) vif_t vif; uvm_analysis_port #(flit_item) accepted_ap, sent_ap;
    function new(string n,uvm_component p); super.new(n,p); accepted_ap=new("accepted_ap",this); sent_ap=new("sent_ap",this); endfunction
    function void build_phase(uvm_phase phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","flit monitor") endfunction
    task run_phase(uvm_phase phase); flit_item t; forever begin @(vif.mon_cb);
      if(vif.mon_cb.rst_n && vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin t=flit_item::type_id::create("accepted"); t.data=vif.mon_cb.req_data; t.last=vif.mon_cb.req_last; accepted_ap.write(t); end
      if(vif.mon_cb.rst_n && vif.mon_cb.link_valid) begin t=flit_item::type_id::create("sent"); t.data=vif.mon_cb.link_data; t.last=vif.mon_cb.link_last; sent_ap.write(t); end
    end endtask
  endclass

  class credit_monitor extends uvm_monitor;
    `uvm_component_utils(credit_monitor) vif_t vif; uvm_analysis_port #(credit_item) ap;
    function new(string n,uvm_component p); super.new(n,p); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","credit monitor") endfunction
    task run_phase(uvm_phase phase); credit_item t; forever begin @(vif.mon_cb); if(vif.mon_cb.rst_n && (vif.mon_cb.cfg_valid || vif.mon_cb.credit_return!=0)) begin t=credit_item::type_id::create("credit"); t.cfg=vif.mon_cb.cfg_valid; t.amount=t.cfg?vif.mon_cb.cfg_credits:vif.mon_cb.credit_return; ap.write(t); end end endtask
  endclass

  class cycle_monitor extends uvm_monitor;
    `uvm_component_utils(cycle_monitor) vif_t vif; uvm_analysis_port #(cycle_item) ap;
    function new(string n,uvm_component p); super.new(n,p); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase); if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","cycle monitor") endfunction
    task run_phase(uvm_phase phase); cycle_item t; forever begin @(vif.mon_cb); t=cycle_item::type_id::create("cycle");
      t.rst_n=vif.mon_cb.rst_n; t.cfg_valid=vif.mon_cb.cfg_valid; t.cfg_credits=vif.mon_cb.cfg_credits;
      t.req_valid=vif.mon_cb.req_valid; t.req_ready=vif.mon_cb.req_ready; t.req_data=vif.mon_cb.req_data; t.req_last=vif.mon_cb.req_last;
      t.credit_return=vif.mon_cb.credit_return; t.link_valid=vif.mon_cb.link_valid; t.link_data=vif.mon_cb.link_data; t.link_last=vif.mon_cb.link_last;
      t.credit_count=vif.mon_cb.credit_count; t.overflow=vif.mon_cb.credit_overflow; ap.write(t); end endtask
  endclass

  class flit_agent extends uvm_agent;
    `uvm_component_utils(flit_agent) flit_sequencer seqr; flit_driver drv; flit_monitor mon;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); seqr=flit_sequencer::type_id::create("seqr",this); drv=flit_driver::type_id::create("drv",this); mon=flit_monitor::type_id::create("mon",this); endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(seqr.seq_item_export); endfunction
  endclass
  class credit_agent extends uvm_agent;
    `uvm_component_utils(credit_agent) credit_sequencer seqr; credit_driver drv; credit_monitor mon;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); seqr=credit_sequencer::type_id::create("seqr",this); drv=credit_driver::type_id::create("drv",this); mon=credit_monitor::type_id::create("mon",this); endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(seqr.seq_item_export); endfunction
  endclass

  class link_scoreboard extends uvm_subscriber #(cycle_item);
    `uvm_component_utils(link_scoreboard)
    flit_item expected[$]; int unsigned model_credits, checks, accepted, sent, stalls, errors; bit prev_accept; bit [DATA_W-1:0] prev_data; bit prev_last;
    covergroup cg with function sample(int credits, bit accept, bit ret, bit last);
      cp_credit: coverpoint credits { bins empty={0}; bins low={[1:2]}; bins high={[3:MAX_CREDITS]}; }
      cp_flow: coverpoint {accept,ret} { bins idle={0}; bins return_only={1}; bins send_only={2}; bins simultaneous={3}; }
      cp_last: coverpoint last; cross cp_credit,cp_flow;
    endgroup
    function new(string n,uvm_component p); super.new(n,p); cg=new; endfunction
    function void write(cycle_item t); flit_item f;
      if(!t.rst_n) begin model_credits=0; expected.delete(); prev_accept=0; return; end
      if(t.link_valid != prev_accept) begin `uvm_error("LATENCY",$sformatf("link_valid=%0b expected=%0b",t.link_valid,prev_accept)) errors++; end
      if(t.link_valid) begin sent++; checks++; if(t.link_data!==prev_data || t.link_last!==prev_last) begin `uvm_error("DATA","launched flit differs from accepted flit") errors++; end end
      if(t.credit_count!=model_credits) begin `uvm_error("CREDIT",$sformatf("count=%0d expected=%0d",t.credit_count,model_credits)) errors++; end
      if(t.cfg_valid) model_credits=(t.cfg_credits>MAX_CREDITS)?MAX_CREDITS:t.cfg_credits;
      else begin model_credits += t.credit_return; if(t.req_valid&&t.req_ready) model_credits--; if(model_credits>MAX_CREDITS) model_credits=MAX_CREDITS; end
      prev_accept=t.req_valid&&t.req_ready; prev_data=t.req_data; prev_last=t.req_last;
      if(t.req_valid&&!t.req_ready) stalls++; if(prev_accept) accepted++;
      cg.sample(t.credit_count,prev_accept,t.credit_return!=0,t.req_last); checks++;
    endfunction
    function void check_phase(uvm_phase phase); if(errors||accepted!=sent) `uvm_error("SUMMARY",$sformatf("errors=%0d accepted=%0d sent=%0d",errors,accepted,sent)); else `uvm_info("SUMMARY",$sformatf("RESULT: *** PASS *** checks=%0d accepted=%0d stalls=%0d",checks,accepted,stalls),UVM_NONE) endfunction
  endclass

  class link_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(link_virtual_sequencer) flit_sequencer flit_seqr; credit_sequencer credit_seqr;
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass
  class link_regress_vseq extends uvm_sequence;
    `uvm_object_utils(link_regress_vseq) `uvm_declare_p_sequencer(link_virtual_sequencer)
    function new(string n="link_regress_vseq"); super.new(n); endfunction
    task body(); directed_flit_sequence d; flit_sequence r; credit_sequence c; d=directed_flit_sequence::type_id::create("d"); r=flit_sequence::type_id::create("r"); c=credit_sequence::type_id::create("c"); r.count=120; c.cycles=220; fork begin d.start(p_sequencer.flit_seqr); r.start(p_sequencer.flit_seqr); end c.start(p_sequencer.credit_seqr); join endtask
  endclass

  class link_env extends uvm_env;
    `uvm_component_utils(link_env) flit_agent flits; credit_agent credits; cycle_monitor cycles; link_scoreboard sb; link_virtual_sequencer vseqr;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); flits=flit_agent::type_id::create("flits",this); credits=credit_agent::type_id::create("credits",this); cycles=cycle_monitor::type_id::create("cycles",this); sb=link_scoreboard::type_id::create("sb",this); vseqr=link_virtual_sequencer::type_id::create("vseqr",this); endfunction
    function void connect_phase(uvm_phase phase); cycles.ap.connect(sb.analysis_export); vseqr.flit_seqr=flits.seqr; vseqr.credit_seqr=credits.seqr; endfunction
  endclass
  class credit_link_test extends uvm_test;
    `uvm_component_utils(credit_link_test) link_env env;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); env=link_env::type_id::create("env",this); endfunction
    task run_phase(uvm_phase phase); link_regress_vseq v; phase.raise_objection(this); v=link_regress_vseq::type_id::create("v"); v.start(env.vseqr); repeat(5) @(env.cycles.vif.mon_cb); phase.drop_objection(this); endtask
  endclass
endpackage
