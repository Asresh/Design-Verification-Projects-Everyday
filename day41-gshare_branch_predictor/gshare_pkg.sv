// Author: Asresh Kuricheti
package gshare_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int PC_WIDTH=32, GHIST_W=4, INDEX_W=4, ENTRIES=(1<<INDEX_W);

  class branch_txn extends uvm_sequence_item;
    rand bit [PC_WIDTH-1:0] pc;
    rand bit actual_taken;
    bit predicted_taken;
    bit [GHIST_W-1:0] history;
    bit [INDEX_W-1:0] index;
    bit mispredict;
    constraint c_aligned { pc[1:0] == 0; pc inside {[32'h1000:32'h1ffc]}; }
    `uvm_object_utils_begin(branch_txn)
      `uvm_field_int(pc,UVM_ALL_ON)
      `uvm_field_int(actual_taken,UVM_ALL_ON)
      `uvm_field_int(predicted_taken,UVM_ALL_ON)
      `uvm_field_int(history,UVM_ALL_ON)
      `uvm_field_int(index,UVM_ALL_ON)
      `uvm_field_int(mispredict,UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="branch_txn"); super.new(name); endfunction
  endclass

  class pred_sequencer extends uvm_sequencer #(branch_txn);
    `uvm_component_utils(pred_sequencer)
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass

  class update_sequencer extends uvm_sequencer #(branch_txn);
    `uvm_component_utils(update_sequencer)
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass

  class pred_driver extends uvm_driver #(branch_txn);
    `uvm_component_utils(pred_driver)
    virtual gshare_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual gshare_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","prediction driver needs gshare_if")
    endfunction
    task run_phase(uvm_phase phase);
      vif.pred_valid<=0; vif.pred_pc<='0;
      forever begin
        seq_item_port.get_next_item(req);
        @(negedge vif.clk); vif.pred_pc<=req.pc; vif.pred_valid<=1;
        do @(posedge vif.clk); while(!vif.pred_ready);
        @(negedge vif.clk); vif.pred_valid<=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class update_driver extends uvm_driver #(branch_txn);
    `uvm_component_utils(update_driver)
    virtual gshare_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual gshare_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","update driver needs gshare_if")
    endfunction
    task run_phase(uvm_phase phase);
      vif.update_valid<=0;
      forever begin
        seq_item_port.get_next_item(req);
        @(negedge vif.clk);
        vif.update_index<=req.index; vif.update_history<=req.history;
        vif.update_pred_taken<=req.predicted_taken;
        vif.update_actual_taken<=req.actual_taken; vif.update_valid<=1;
        @(posedge vif.clk); @(negedge vif.clk); vif.update_valid<=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class pred_monitor extends uvm_component;
    `uvm_component_utils(pred_monitor)
    virtual gshare_if vif; uvm_analysis_port #(branch_txn) ap;
    function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual gshare_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","prediction monitor needs gshare_if")
    endfunction
    task run_phase(uvm_phase phase); branch_txn t;
      forever begin @(posedge vif.clk);
        if(vif.rst_n && vif.pred_valid && vif.pred_ready) begin
          t=branch_txn::type_id::create("pred_seen"); t.pc=vif.pred_pc;
          t.predicted_taken=vif.pred_taken; t.history=vif.pred_history;
          t.index=vif.pred_index; ap.write(t);
        end
      end
    endtask
  endclass

  class update_monitor extends uvm_component;
    `uvm_component_utils(update_monitor)
    virtual gshare_if vif; uvm_analysis_port #(branch_txn) ap;
    function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual gshare_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","update monitor needs gshare_if")
    endfunction
    task run_phase(uvm_phase phase); branch_txn t;
      forever begin @(posedge vif.clk);
        if(vif.rst_n && vif.update_valid) begin
          t=branch_txn::type_id::create("update_seen");
          t.index=vif.update_index; t.history=vif.update_history;
          t.predicted_taken=vif.update_pred_taken;
          t.actual_taken=vif.update_actual_taken;
          t.mispredict=vif.update_mispredict; ap.write(t);
        end
      end
    endtask
  endclass

  class pred_agent extends uvm_agent;
    `uvm_component_utils(pred_agent)
    pred_sequencer sqr; pred_driver drv; pred_monitor mon;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      sqr=pred_sequencer::type_id::create("sqr",this);
      drv=pred_driver::type_id::create("drv",this);
      mon=pred_monitor::type_id::create("mon",this);
    endfunction
    function void connect_phase(uvm_phase phase);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
  endclass

  class update_agent extends uvm_agent;
    `uvm_component_utils(update_agent)
    update_sequencer sqr; update_driver drv; update_monitor mon;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      sqr=update_sequencer::type_id::create("sqr",this);
      drv=update_driver::type_id::create("drv",this);
      mon=update_monitor::type_id::create("mon",this);
    endfunction
    function void connect_phase(uvm_phase phase);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
  endclass

  `uvm_analysis_imp_decl(_pred)
  `uvm_analysis_imp_decl(_upd)
  class gshare_scoreboard extends uvm_component;
    `uvm_component_utils(gshare_scoreboard)
    uvm_analysis_imp_pred #(branch_txn,gshare_scoreboard) pred_imp;
    uvm_analysis_imp_upd #(branch_txn,gshare_scoreboard) upd_imp;
    bit [1:0] pht[ENTRIES]; bit [GHIST_W-1:0] ghr;
    branch_txn outstanding[$]; int checks, errors;
    function new(string n,uvm_component p);super.new(n,p);pred_imp=new("pred_imp",this);upd_imp=new("upd_imp",this);endfunction
    function void build_phase(uvm_phase phase);foreach(pht[i])pht[i]=2'b01;ghr='0;endfunction
    function void write_pred(branch_txn t); branch_txn q;
      q=branch_txn::type_id::create("expected"); q.copy(t);
      if(t.history!==ghr || t.index!==(t.pc[INDEX_W+1:2]^ghr) || t.predicted_taken!==pht[t.index][1]) begin
        errors++; `uvm_error("PREDICT",$sformatf("pc=%h idx=%0d hist=%h pred=%0b",t.pc,t.index,t.history,t.predicted_taken))
      end
      outstanding.push_back(q); checks++;
    endfunction
    function void write_upd(branch_txn t); branch_txn q;
      if(outstanding.size()==0) begin errors++; `uvm_error("UPDATE","update without prediction") end
      else begin
        q=outstanding.pop_front();
        if(t.index!=q.index || t.history!=q.history || t.predicted_taken!=q.predicted_taken ||
           t.mispredict!=(t.predicted_taken!=t.actual_taken)) begin
          errors++; `uvm_error("UPDATE","update metadata/mispredict mismatch")
        end
        if(t.actual_taken && pht[t.index]!=2'b11) pht[t.index]++;
        if(!t.actual_taken && pht[t.index]!=2'b00) pht[t.index]--;
        ghr={t.history[GHIST_W-2:0],t.actual_taken}; checks++;
      end
    endfunction
    function void report_phase(uvm_phase phase);
      if(errors==0 && outstanding.size()==0) `uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d checks)",checks),UVM_NONE)
      else `uvm_fatal("RESULT",$sformatf("RESULT: *** FAIL *** errors=%0d outstanding=%0d",errors,outstanding.size()))
    endfunction
  endclass

  class gshare_coverage extends uvm_subscriber #(branch_txn);
    `uvm_component_utils(gshare_coverage)
    branch_txn sample;
    covergroup cg;
      cp_actual: coverpoint sample.actual_taken;
      cp_pred: coverpoint sample.predicted_taken;
      cp_miss: coverpoint sample.mispredict;
      cp_idx: coverpoint sample.index { bins all_indices[]={[0:ENTRIES-1]}; }
      cx_accuracy: cross cp_actual,cp_pred;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
    function void write(branch_txn t);sample=t;cg.sample();endfunction
  endclass

  class gshare_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(gshare_virtual_sequencer)
    pred_sequencer pred_sqr; update_sequencer update_sqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass

  class pred_sequence extends uvm_sequence #(branch_txn);
    `uvm_object_utils(pred_sequence)
    bit [PC_WIDTH-1:0] pc; bit actual;
    function new(string n="pred_sequence");super.new(n);endfunction
    task body(); req=branch_txn::type_id::create("req");start_item(req);req.pc=pc;req.actual_taken=actual;finish_item(req);endtask
  endclass

  class update_sequence extends uvm_sequence #(branch_txn);
    `uvm_object_utils(update_sequence)
    branch_txn item;
    function new(string n="update_sequence");super.new(n);endfunction
    task body(); start_item(item); finish_item(item); endtask
  endclass

  class gshare_regress_vseq extends uvm_sequence;
    `uvm_object_utils(gshare_regress_vseq)
    `uvm_declare_p_sequencer(gshare_virtual_sequencer)
    virtual gshare_if vif;
    function new(string n="gshare_regress_vseq");super.new(n);endfunction
    task send_branch(bit[PC_WIDTH-1:0] pc,bit actual);
      pred_sequence ps; update_sequence us; branch_txn u;
      ps=pred_sequence::type_id::create("ps");
      ps.pc=pc; ps.actual=actual; ps.start(p_sequencer.pred_sqr);
      // Capture what the DUT actually predicted; do not reconstruct metadata
      // from sequence intent and accidentally hide an index/history bug.
      u=branch_txn::type_id::create("resolved");
      u.index=vif.pred_index; u.history=vif.pred_history;
      u.predicted_taken=vif.pred_taken; u.actual_taken=actual;
      us=update_sequence::type_id::create("us"); us.item=u;
      us.start(p_sequencer.update_sqr);
    endtask
    task body(); branch_txn random_branch; int i;
      if(vif==null) `uvm_fatal("NOVIF","virtual sequence needs vif")
      repeat(5) send_branch(32'h00001000,1'b1);
      repeat(5) send_branch(32'h00001000,1'b0);
      send_branch(32'h00001040,1'b1);
      send_branch(32'h00001000,1'b0);
      for(i=0;i<16;i++) send_branch(32'h00001000+(i<<2),i[0]);
      for(i=0;i<300;i++) begin
        random_branch=branch_txn::type_id::create("random_branch");
        if(!random_branch.randomize() with { actual_taken dist {1:=62,0:=38}; })
          `uvm_fatal("RAND","branch randomization failed")
        send_branch(random_branch.pc,random_branch.actual_taken);
      end
    endtask
  endclass

  class gshare_env extends uvm_env;
    `uvm_component_utils(gshare_env)
    pred_agent pred; update_agent upd; gshare_scoreboard sb; gshare_coverage cov;
    gshare_virtual_sequencer vsqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      pred=pred_agent::type_id::create("pred",this);upd=update_agent::type_id::create("upd",this);
      sb=gshare_scoreboard::type_id::create("sb",this);cov=gshare_coverage::type_id::create("cov",this);
      vsqr=gshare_virtual_sequencer::type_id::create("vsqr",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      pred.mon.ap.connect(sb.pred_imp);upd.mon.ap.connect(sb.upd_imp);upd.mon.ap.connect(cov.analysis_export);
      vsqr.pred_sqr=pred.sqr;vsqr.update_sqr=upd.sqr;
    endfunction
  endclass

  class gshare_regress_test extends uvm_test;
    `uvm_component_utils(gshare_regress_test)
    gshare_env env; virtual gshare_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      env=gshare_env::type_id::create("env",this);
      if(!uvm_config_db#(virtual gshare_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","test needs vif")
    endfunction
    task run_phase(uvm_phase phase); gshare_regress_vseq vseq;
      phase.raise_objection(this);
      repeat(4)@(posedge vif.clk);
      vseq=gshare_regress_vseq::type_id::create("vseq");
      vseq.vif=vif; vseq.start(env.vsqr);
      repeat(4)@(posedge vif.clk);phase.drop_objection(this);
    endtask
  endclass
endpackage
