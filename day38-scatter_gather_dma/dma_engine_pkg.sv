// Author: Asresh Kuricheti
// Full UVM environment: descriptor and memory agents, monitor, golden memory scoreboard,
// functional coverage, constrained-random sequences, and a coordinating virtual sequence.
package dma_engine_pkg;
  import uvm_pkg::*; `include "uvm_macros.svh"
  class dma_desc extends uvm_sequence_item;
    rand bit[15:0] src,dst; rand bit[7:0] words; rand int idle;
    constraint c {src[1:0]==0;dst[1:0]==0;words inside {[1:16]};idle inside {[0:3]};src inside {[16'h0000:16'h07c0]};dst inside {[16'h1000:16'h17c0]};}
    `uvm_object_utils_begin(dma_desc) `uvm_field_int(src,UVM_HEX) `uvm_field_int(dst,UVM_HEX) `uvm_field_int(words,UVM_DEC) `uvm_field_int(idle,UVM_DEC) `uvm_object_utils_end
    function new(string n="dma_desc");super.new(n);endfunction
  endclass
  class mem_policy extends uvm_sequence_item;
    rand int rd_stall,wr_stall,latency; rand bit inject_error;
    constraint c {rd_stall inside {[0:3]};wr_stall inside {[0:4]};latency inside {[1:5]};inject_error dist {0:=49,1:=1};}
    `uvm_object_utils_begin(mem_policy) `uvm_field_int(rd_stall,UVM_DEC) `uvm_field_int(wr_stall,UVM_DEC) `uvm_field_int(latency,UVM_DEC) `uvm_field_int(inject_error,UVM_BIN) `uvm_object_utils_end
    function new(string n="mem_policy");super.new(n);endfunction
  endclass
  class dma_sample extends uvm_sequence_item;
    bit rst_n,dv,dr,rv,rr,rdv,rde,wv,wr,wl,done,error; bit[15:0]src,dst,ra,wa;bit[7:0]words;bit[31:0]rdata,wdata;bit[8:0]moved;
    `uvm_object_utils(dma_sample) function new(string n="dma_sample");super.new(n);endfunction
  endclass
  class desc_sequencer extends uvm_sequencer#(dma_desc);`uvm_component_utils(desc_sequencer)function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class mem_sequencer extends uvm_sequencer#(mem_policy);`uvm_component_utils(mem_sequencer)function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class desc_driver extends uvm_driver#(dma_desc);`uvm_component_utils(desc_driver)virtual dma_engine_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual dma_engine_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","descriptor driver")endfunction
    task run_phase(uvm_phase p);vif.desc_cb.desc_valid<=0;forever begin seq_item_port.get_next_item(req);repeat(req.idle)@(vif.desc_cb);vif.desc_cb.desc_valid<=1;vif.desc_cb.desc_src<=req.src;vif.desc_cb.desc_dst<=req.dst;vif.desc_cb.desc_words<=req.words;do @(vif.desc_cb);while(!vif.desc_cb.desc_ready);vif.desc_cb.desc_valid<=0;seq_item_port.item_done();end endtask
  endclass
  class mem_driver extends uvm_driver#(mem_policy);`uvm_component_utils(mem_driver)virtual dma_engine_if vif;bit[31:0]mem[0:2047];
    function new(string n,uvm_component p);super.new(n,p);foreach(mem[i])mem[i]=32'hcafe0000+i;endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual dma_engine_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","memory driver")endfunction
    task run_phase(uvm_phase p);int wait_left=0;bit pending=0;bit[15:0]a;bit err;vif.mem_cb.rd_ready<=0;vif.mem_cb.wr_ready<=0;vif.mem_cb.rd_data_valid<=0;forever begin seq_item_port.get_next_item(req);vif.mem_cb.rd_ready<=!pending&&(req.rd_stall==0);vif.mem_cb.wr_ready<=req.wr_stall==0;@(vif.mem_cb);if(vif.mem_cb.rd_valid&&vif.mem_cb.rd_ready)begin pending=1;a=vif.mem_cb.rd_addr;wait_left=req.latency;err=req.inject_error;end if(vif.mem_cb.wr_valid&&vif.mem_cb.wr_ready)mem[vif.mem_cb.wr_addr>>2]=vif.mem_cb.wr_data;if(pending)begin if(wait_left==0)begin vif.mem_cb.rd_data_valid<=1;vif.mem_cb.rd_data<=mem[a>>2];vif.mem_cb.rd_error<=err;pending=0;end else wait_left--;end else vif.mem_cb.rd_data_valid<=0;seq_item_port.item_done();end endtask
  endclass
  class desc_agent extends uvm_agent;`uvm_component_utils(desc_agent)desc_sequencer sqr;desc_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=desc_sequencer::type_id::create("sqr",this);drv=desc_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  class mem_agent extends uvm_agent;`uvm_component_utils(mem_agent)mem_sequencer sqr;mem_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=mem_sequencer::type_id::create("sqr",this);drv=mem_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  class dma_monitor extends uvm_monitor;`uvm_component_utils(dma_monitor)virtual dma_engine_if vif;uvm_analysis_port#(dma_sample)ap;
    function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual dma_engine_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","monitor")endfunction
    task run_phase(uvm_phase p);dma_sample s;forever begin @(vif.mon_cb);s=new;s.rst_n=vif.mon_cb.rst_n;s.dv=vif.mon_cb.desc_valid;s.dr=vif.mon_cb.desc_ready;s.src=vif.mon_cb.desc_src;s.dst=vif.mon_cb.desc_dst;s.words=vif.mon_cb.desc_words;s.rv=vif.mon_cb.rd_valid;s.rr=vif.mon_cb.rd_ready;s.ra=vif.mon_cb.rd_addr;s.rdv=vif.mon_cb.rd_data_valid;s.rdata=vif.mon_cb.rd_data;s.rde=vif.mon_cb.rd_error;s.wv=vif.mon_cb.wr_valid;s.wr=vif.mon_cb.wr_ready;s.wa=vif.mon_cb.wr_addr;s.wdata=vif.mon_cb.wr_data;s.wl=vif.mon_cb.wr_last;s.done=vif.mon_cb.done;s.error=vif.mon_cb.error;s.moved=vif.mon_cb.words_moved;ap.write(s);end endtask
  endclass
  typedef struct {bit[15:0]src,dst;int words,index;bit aborted;} exp_t;
  class dma_scoreboard extends uvm_subscriber#(dma_sample);`uvm_component_utils(dma_scoreboard)exp_t q[$];bit[31:0]srcmem[0:2047];int checks,errors;
    function new(string n,uvm_component p);super.new(n,p);foreach(srcmem[i])srcmem[i]=32'hcafe0000+i;endfunction
    function void write(dma_sample s);exp_t e;if(!s.rst_n)begin q.delete();return;end
      if(s.dv&&s.dr)begin e.src=s.src;e.dst=s.dst;e.words=s.words;e.index=0;e.aborted=0;q.push_back(e);end
      if(s.rv&&s.rr)begin if(!q.size()||s.ra!==q[0].src+4*q[0].index)begin`uvm_error("RDADDR","unexpected read address")errors++;end end
      if(s.rdv&&s.rde&&q.size())q[0].aborted=1;
      if(s.wv&&s.wr)begin checks++;if(!q.size())begin`uvm_error("EXTRA","write without descriptor")errors++;end else begin e=q[0];if(s.wa!==e.dst+4*e.index||s.wdata!==srcmem[(e.src>>2)+e.index]||s.wl!==(e.index==e.words-1))begin`uvm_error("MISMATCH",$sformatf("idx=%0d addr=%h data=%h last=%b",e.index,s.wa,s.wdata,s.wl))errors++;end q[0].index++;end end
      if(s.done)begin if(!q.size())begin`uvm_error("DONE","completion without descriptor")errors++;end else begin e=q.pop_front();if(s.error!==e.aborted||s.moved!==(e.aborted?e.index:e.words))begin`uvm_error("STATUS","bad completion status/count")errors++;end end end
    endfunction
    function void report_phase(uvm_phase p);if(errors==0&&checks>0&&!q.size())`uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d words checked)",checks),UVM_NONE)else`uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** checks=%0d errors=%0d pending=%0d",checks,errors,q.size()))endfunction
  endclass
  class dma_coverage extends uvm_subscriber#(dma_sample);`uvm_component_utils(dma_coverage)dma_sample s;covergroup cg;cp_len:coverpoint s.words iff(s.dv&&s.dr){bins one={1};bins short={[2:4]};bins long={[5:16]};}cp_status:coverpoint s.error iff(s.done);cp_stall:coverpoint {s.wv&&!s.wr,s.rv&&!s.rr};len_x_status:cross cp_len,cp_status;endgroup function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction function void write(dma_sample x);s=x;if(x.rst_n)cg.sample();endfunction endclass
  class dma_env extends uvm_env;`uvm_component_utils(dma_env)desc_agent da;mem_agent ma;dma_monitor mon;dma_scoreboard sb;dma_coverage cov;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);da=desc_agent::type_id::create("da",this);ma=mem_agent::type_id::create("ma",this);mon=dma_monitor::type_id::create("mon",this);sb=dma_scoreboard::type_id::create("sb",this);cov=dma_coverage::type_id::create("cov",this);endfunction function void connect_phase(uvm_phase p);mon.ap.connect(sb.analysis_export);mon.ap.connect(cov.analysis_export);endfunction endclass
  class desc_sequence extends uvm_sequence#(dma_desc);`uvm_object_utils(desc_sequence)function new(string n="desc_sequence");super.new(n);endfunction task body();dma_desc x;int i;for(i=0;i<4;i++)begin x=new;start_item(x);x.src=16'h0040+i*64;x.dst=16'h1040+i*64;x.words=(i==0)?1:(i+2);x.idle=i;finish_item(x);end repeat(80)begin x=new;start_item(x);if(!x.randomize())`uvm_fatal("RAND","descriptor")finish_item(x);end endtask endclass
  class mem_sequence extends uvm_sequence#(mem_policy);`uvm_object_utils(mem_sequence)function new(string n="mem_sequence");super.new(n);endfunction task body();mem_policy x;repeat(5000)begin x=new;start_item(x);void'(x.randomize());finish_item(x);end endtask endclass
  class dma_virtual_sequencer extends uvm_sequencer;`uvm_component_utils(dma_virtual_sequencer)desc_sequencer d;mem_sequencer m;function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class dma_regress_vseq extends uvm_sequence;`uvm_object_utils(dma_regress_vseq)dma_virtual_sequencer vs;function new(string n="dma_regress_vseq");super.new(n);endfunction task body();desc_sequence d=new;mem_sequence m=new;fork d.start(vs.d);m.start(vs.m);join_any disable fork;endtask endclass
  class dma_regress_test extends uvm_test;`uvm_component_utils(dma_regress_test)dma_env e;dma_virtual_sequencer vs;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);e=dma_env::type_id::create("e",this);vs=dma_virtual_sequencer::type_id::create("vs",this);endfunction function void connect_phase(uvm_phase p);vs.d=e.da.sqr;vs.m=e.ma.sqr;endfunction task run_phase(uvm_phase p);dma_regress_vseq v=new;p.raise_objection(this);v.vs=vs;v.start(vs);#2us;p.drop_objection(this);endtask endclass
endpackage
