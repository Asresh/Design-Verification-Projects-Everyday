// Author: Asresh Kuricheti
// Full UVM environment: requester/flow agents, virtual sequences, shadow directory, coverage.
package chi_snoop_filter_pkg;
  import uvm_pkg::*; `include "uvm_macros.svh"
  typedef enum bit[1:0] {READ_SHARED,READ_UNIQUE,EVICT} sf_op_e;
  class sf_item extends uvm_sequence_item;
    rand bit[1:0] node; rand bit[15:0] addr; rand sf_op_e op; rand int idle;
    constraint c {addr[1:0]==0; idle inside {[0:2]}; op dist {READ_SHARED:=5,READ_UNIQUE:=4,EVICT:=2};}
    `uvm_object_utils_begin(sf_item) `uvm_field_int(node,UVM_DEC) `uvm_field_int(addr,UVM_HEX) `uvm_field_enum(sf_op_e,op,UVM_DEFAULT) `uvm_field_int(idle,UVM_DEC) `uvm_object_utils_end
    function new(string n="sf_item");super.new(n);endfunction
  endclass
  class flow_item extends uvm_sequence_item;
    rand bit ready; constraint c {ready dist {1:=8,0:=2};}
    `uvm_object_utils_begin(flow_item) `uvm_field_int(ready,UVM_BIN) `uvm_object_utils_end
    function new(string n="flow_item");super.new(n);endfunction
  endclass
  class sf_sample extends uvm_sequence_item;
    bit rst_n,req_valid,req_ready,rsp_valid,rsp_ready,dir_hit,snoop_valid,snoop_invalidate;
    bit[1:0] node,op; bit[15:0] addr; bit[3:0] old_sharers,snoop_mask,new_sharers;
    `uvm_object_utils(sf_sample) function new(string n="sf_sample");super.new(n);endfunction
  endclass
  class sf_sequencer extends uvm_sequencer#(sf_item);`uvm_component_utils(sf_sequencer) function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class flow_sequencer extends uvm_sequencer#(flow_item);`uvm_component_utils(flow_sequencer) function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class sf_driver extends uvm_driver#(sf_item);`uvm_component_utils(sf_driver) virtual chi_snoop_filter_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual chi_snoop_filter_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","sf driver") endfunction
    task run_phase(uvm_phase p);vif.req_cb.req_valid<=0;forever begin seq_item_port.get_next_item(req);repeat(req.idle)@(vif.req_cb);vif.req_cb.req_valid<=1;vif.req_cb.req_node<=req.node;vif.req_cb.req_addr<=req.addr;vif.req_cb.req_op<=req.op;do @(vif.req_cb);while(!vif.req_cb.req_ready);vif.req_cb.req_valid<=0;seq_item_port.item_done();end endtask
  endclass
  class flow_driver extends uvm_driver#(flow_item);`uvm_component_utils(flow_driver) virtual chi_snoop_filter_if vif;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual chi_snoop_filter_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","flow driver") endfunction
    task run_phase(uvm_phase p);vif.flow_cb.rsp_ready<=0;forever begin seq_item_port.get_next_item(req);vif.flow_cb.rsp_ready<=req.ready;@(vif.flow_cb);seq_item_port.item_done();end endtask
  endclass
  class sf_monitor extends uvm_monitor;`uvm_component_utils(sf_monitor) virtual chi_snoop_filter_if vif;uvm_analysis_port#(sf_sample)ap;
    function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual chi_snoop_filter_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","monitor") endfunction
    task run_phase(uvm_phase p);sf_sample s;forever begin @(vif.mon_cb);s=sf_sample::type_id::create("s");s.rst_n=vif.mon_cb.rst_n;s.req_valid=vif.mon_cb.req_valid;s.req_ready=vif.mon_cb.req_ready;s.node=vif.mon_cb.req_node;s.addr=vif.mon_cb.req_addr;s.op=vif.mon_cb.req_op;s.rsp_valid=vif.mon_cb.rsp_valid;s.rsp_ready=vif.mon_cb.rsp_ready;s.dir_hit=vif.mon_cb.dir_hit;s.old_sharers=vif.mon_cb.old_sharers;s.snoop_valid=vif.mon_cb.snoop_valid;s.snoop_mask=vif.mon_cb.snoop_mask;s.snoop_invalidate=vif.mon_cb.snoop_invalidate;s.new_sharers=vif.mon_cb.new_sharers;ap.write(s);end endtask
  endclass
  class sf_agent extends uvm_agent;`uvm_component_utils(sf_agent) sf_sequencer sqr;sf_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=sf_sequencer::type_id::create("sqr",this);drv=sf_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  class flow_agent extends uvm_agent;`uvm_component_utils(flow_agent) flow_sequencer sqr;flow_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=flow_sequencer::type_id::create("sqr",this);drv=flow_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  typedef struct packed {bit hit;bit[3:0] oldm;bit sv;bit[3:0] sm;bit inv;bit[3:0] newm;} exp_t;
  class sf_scoreboard extends uvm_subscriber#(sf_sample);`uvm_component_utils(sf_scoreboard)
    bit valid[8],dirty[8];bit[15:0]tag[8];bit[3:0]sh[8];bit[1:0]owner[8];int repl;exp_t q[$];int checks,errors;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void write(sf_sample s);int i,h=-1,f=-1,sel;bit[3:0]b,oldm,newm,sm;exp_t e;
      if(!s.rst_n)begin foreach(valid[i])valid[i]=0;q.delete();repl=0;return;end
      if(s.req_valid&&s.req_ready)begin for(i=0;i<8;i++)begin if(valid[i]&&tag[i]==s.addr)h=i;if(!valid[i]&&f<0)f=i;end b=4'b1<<s.node;oldm=(h>=0)?sh[h]:0;sm=0;newm=oldm;sel=(h>=0)?h:((f>=0)?f:repl);
        case(s.op) READ_SHARED:begin if(h>=0&&dirty[h]&&owner[h]!=s.node)sm=oldm&~b;newm=oldm|b;valid[sel]=1;tag[sel]=s.addr;sh[sel]=newm;dirty[sel]=0;end READ_UNIQUE:begin sm=oldm&~b;newm=b;valid[sel]=1;tag[sel]=s.addr;sh[sel]=b;dirty[sel]=1;owner[sel]=s.node;end default:begin newm=oldm&~b;if(h>=0)begin sh[h]=newm;if(!newm)begin valid[h]=0;dirty[h]=0;end else if(dirty[h]&&owner[h]==s.node)dirty[h]=0;end end endcase
        if(h<0&&f<0&&s.op!=EVICT)repl=(repl+1)%8;e='{h>=0,oldm,|sm,sm,(s.op==READ_UNIQUE)&&(|sm),newm};q.push_back(e);end
      if(s.rsp_valid&&s.rsp_ready)begin checks++;if(!q.size())begin`uvm_error("EXTRA","response without request")errors++;end else begin e=q.pop_front();if({s.dir_hit,s.old_sharers,s.snoop_valid,s.snoop_mask,s.snoop_invalidate,s.new_sharers}!==e)begin`uvm_error("MISMATCH",$sformatf("expected=%b got=%b",e,{s.dir_hit,s.old_sharers,s.snoop_valid,s.snoop_mask,s.snoop_invalidate,s.new_sharers}))errors++;end end end
    endfunction
    function void report_phase(uvm_phase p);if(errors==0&&checks>0&&!q.size())`uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d coherent operations)",checks),UVM_NONE)else`uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** checks=%0d errors=%0d pending=%0d",checks,errors,q.size()))endfunction
  endclass
  class sf_coverage extends uvm_subscriber#(sf_sample);`uvm_component_utils(sf_coverage)sf_sample c;covergroup cg;cp_op:coverpoint c.op iff(c.req_valid&&c.req_ready){bins ops[]={0,1,2};}cp_node:coverpoint c.node iff(c.req_valid&&c.req_ready);cp_hit:coverpoint c.dir_hit iff(c.rsp_valid&&c.rsp_ready);cp_snoop:coverpoint c.snoop_valid iff(c.rsp_valid&&c.rsp_ready);op_x_node:cross cp_op,cp_node;endgroup function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction function void write(sf_sample s);c=s;if(s.rst_n)cg.sample();endfunction endclass
  class sf_env extends uvm_env;`uvm_component_utils(sf_env)sf_agent a;flow_agent f;sf_monitor m;sf_scoreboard sb;sf_coverage cov;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);a=sf_agent::type_id::create("a",this);f=flow_agent::type_id::create("f",this);m=sf_monitor::type_id::create("m",this);sb=sf_scoreboard::type_id::create("sb",this);cov=sf_coverage::type_id::create("cov",this);endfunction function void connect_phase(uvm_phase p);m.ap.connect(sb.analysis_export);m.ap.connect(cov.analysis_export);endfunction endclass
  class sf_sequence extends uvm_sequence#(sf_item);`uvm_object_utils(sf_sequence)int count=300;function new(string n="sf_sequence");super.new(n);endfunction
    task send(sf_op_e op,bit[1:0]node,bit[15:0]addr,int idle=0);sf_item x;x=sf_item::type_id::create("directed");start_item(x);x.op=op;x.node=node;x.addr=addr;x.idle=idle;finish_item(x);endtask
    task body();sf_item x;
      send(READ_SHARED,0,16'h1000);send(READ_SHARED,1,16'h1000);send(READ_UNIQUE,2,16'h1000);
      send(READ_SHARED,3,16'h1000,1);send(EVICT,2,16'h1000);send(READ_UNIQUE,1,16'h1000);
      repeat(count)begin x=sf_item::type_id::create("random");start_item(x);if(!x.randomize()with{addr[15:8]==0;})`uvm_fatal("RAND","sf item")finish_item(x);end
    endtask
  endclass
  class flow_sequence extends uvm_sequence#(flow_item);`uvm_object_utils(flow_sequence)function new(string n="flow_sequence");super.new(n);endfunction task body();flow_item x;repeat(1200)begin x=flow_item::type_id::create("x");start_item(x);void'(x.randomize());finish_item(x);end endtask endclass
  class sf_virtual_sequencer extends uvm_sequencer;`uvm_component_utils(sf_virtual_sequencer)sf_sequencer s;flow_sequencer f;function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class sf_regress_vseq extends uvm_sequence;`uvm_object_utils(sf_regress_vseq)sf_virtual_sequencer vs;function new(string n="sf_regress_vseq");super.new(n);endfunction task body();sf_sequence a;flow_sequence f;a=new;f=new;fork a.start(vs.s);f.start(vs.f);join_any disable fork;endtask endclass
  class sf_regress_test extends uvm_test;`uvm_component_utils(sf_regress_test)sf_env e;sf_virtual_sequencer vs;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);e=sf_env::type_id::create("e",this);vs=sf_virtual_sequencer::type_id::create("vs",this);endfunction function void connect_phase(uvm_phase p);vs.s=e.a.sqr;vs.f=e.f.sqr;endfunction task run_phase(uvm_phase p);sf_regress_vseq v=new;p.raise_objection(this);v.vs=vs;v.start(vs);#200ns;p.drop_objection(this);endtask endclass
endpackage
