// Author: Asresh Kuricheti
// Full UVM environment: request and command-flow agents, monitor, timing-aware golden scoreboard,
// functional coverage, directed/constrained-random sequences, and coordinating virtual sequence.
package ddr_scheduler_pkg;
  import uvm_pkg::*;`include "uvm_macros.svh"
  localparam int TRCD=2,TRP=2,TRAS=4;localparam bit[1:0]ACT=0,RD=1,WR=2,PRE=3;
  class ddr_req extends uvm_sequence_item;
    rand bit write;rand bit[7:0]row;rand bit[1:0]bank;rand bit[5:0]col;rand bit[31:0]data;rand int idle;
    constraint c{idle inside{[0:3]};row dist{[0:7]:=4,[8:255]:=1};col inside{[0:63]};}
    `uvm_object_utils_begin(ddr_req)`uvm_field_int(write,UVM_BIN)`uvm_field_int(row,UVM_HEX)`uvm_field_int(bank,UVM_DEC)`uvm_field_int(col,UVM_HEX)`uvm_field_int(data,UVM_HEX)`uvm_object_utils_end
    function new(string n="ddr_req");super.new(n);endfunction
  endclass
  class ready_item extends uvm_sequence_item;rand int stall;constraint c{stall dist{0:=7,[1:4]:=3};}`uvm_object_utils(ready_item)function new(string n="ready_item");super.new(n);endfunction endclass
  class ddr_sample extends uvm_sequence_item;bit rst_n,rv,rr,write,cv,cr,done;bit[15:0]addr;bit[31:0]data,cdata;bit[1:0]cmd,bank;bit[7:0]row;bit[5:0]col;`uvm_object_utils(ddr_sample)function new(string n="ddr_sample");super.new(n);endfunction endclass
  class req_sequencer extends uvm_sequencer#(ddr_req);`uvm_component_utils(req_sequencer)function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class ready_sequencer extends uvm_sequencer#(ready_item);`uvm_component_utils(ready_sequencer)function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class req_driver extends uvm_driver#(ddr_req);`uvm_component_utils(req_driver)virtual ddr_scheduler_if vif;function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual ddr_scheduler_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","request driver")endfunction
    task run_phase(uvm_phase p);vif.req_cb.req_valid<=0;forever begin seq_item_port.get_next_item(req);repeat(req.idle)@(vif.req_cb);vif.req_cb.req_valid<=1;vif.req_cb.req_write<=req.write;vif.req_cb.req_addr<={req.row,req.bank,req.col};vif.req_cb.req_wdata<=req.data;do @(vif.req_cb);while(!vif.req_cb.req_ready);vif.req_cb.req_valid<=0;wait(vif.req_done);seq_item_port.item_done();end endtask
  endclass
  class ready_driver extends uvm_driver#(ready_item);`uvm_component_utils(ready_driver)virtual ddr_scheduler_if vif;function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual ddr_scheduler_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","ready driver")endfunction
    task run_phase(uvm_phase p);vif.sink_cb.cmd_ready<=0;forever begin seq_item_port.get_next_item(req);vif.sink_cb.cmd_ready<=0;repeat(req.stall)@(vif.sink_cb);vif.sink_cb.cmd_ready<=1;@(vif.sink_cb);seq_item_port.item_done();end endtask
  endclass
  class req_agent extends uvm_agent;`uvm_component_utils(req_agent)req_sequencer sqr;req_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=req_sequencer::type_id::create("sqr",this);drv=req_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  class ready_agent extends uvm_agent;`uvm_component_utils(ready_agent)ready_sequencer sqr;ready_driver drv;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);sqr=ready_sequencer::type_id::create("sqr",this);drv=ready_driver::type_id::create("drv",this);endfunction function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction endclass
  class ddr_monitor extends uvm_monitor;`uvm_component_utils(ddr_monitor)virtual ddr_scheduler_if vif;uvm_analysis_port#(ddr_sample)ap;function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
    function void build_phase(uvm_phase p);if(!uvm_config_db#(virtual ddr_scheduler_if)::get(this,"","vif",vif))`uvm_fatal("NOVIF","monitor")endfunction
    task run_phase(uvm_phase p);ddr_sample s;forever begin @(vif.mon_cb);s=new;s.rst_n=vif.mon_cb.rst_n;s.rv=vif.mon_cb.req_valid;s.rr=vif.mon_cb.req_ready;s.write=vif.mon_cb.req_write;s.addr=vif.mon_cb.req_addr;s.data=vif.mon_cb.req_wdata;s.cv=vif.mon_cb.cmd_valid;s.cr=vif.mon_cb.cmd_ready;s.cmd=vif.mon_cb.cmd;s.bank=vif.mon_cb.cmd_bank;s.row=vif.mon_cb.cmd_row;s.col=vif.mon_cb.cmd_col;s.cdata=vif.mon_cb.cmd_wdata;s.done=vif.mon_cb.req_done;ap.write(s);end endtask
  endclass
  typedef struct{bit write;bit[7:0]row;bit[1:0]bank;bit[5:0]col;bit[31:0]data;} exp_req_t;
  class ddr_scoreboard extends uvm_subscriber#(ddr_sample);`uvm_component_utils(ddr_scoreboard)exp_req_t q[$];bit opn[4];bit[7:0]orow[4];int ras[4],rcd[4],rp[4];int checks,errors;
    function new(string n,uvm_component p);super.new(n,p);foreach(rp[i])rp[i]=TRP;endfunction
    function void bad(string m);`uvm_error("DDR_SB",m)errors++;endfunction
    function void write(ddr_sample s);exp_req_t e;int b;if(!s.rst_n)begin q.delete();foreach(opn[i])begin opn[i]=0;ras[i]=0;rcd[i]=0;rp[i]=TRP;end return;end
      foreach(opn[i])if(opn[i])begin ras[i]++;rcd[i]++;end else rp[i]++;
      if(s.rv&&s.rr)begin e.write=s.write;e.row=s.addr[15:8];e.bank=s.addr[7:6];e.col=s.addr[5:0];e.data=s.data;q.push_back(e);end
      if(s.cv&&s.cr)begin checks++;if(!q.size())bad("command without request");else begin e=q[0];b=e.bank;if(s.bank!==b||s.row!==e.row||s.col!==e.col||s.cdata!==e.data)bad("command payload does not match request");
        case(s.cmd)ACT:if(opn[b]||rp[b]<TRP)bad("illegal ACT timing/state");else begin opn[b]=1;orow[b]=e.row;ras[b]=0;rcd[b]=0;end
          PRE:if(!opn[b]||orow[b]==e.row||ras[b]<TRAS)bad("illegal PRE timing/state");else begin opn[b]=0;rp[b]=0;end
          RD,WR:begin if(!opn[b]||orow[b]!=e.row||rcd[b]<TRCD||s.cmd!=(e.write?WR:RD))bad("illegal data command");void'(q.pop_front());end
          default:bad("unknown command");endcase end end
      if(s.done&&q.size()!=0)bad("done before request retired");
    endfunction
    function void report_phase(uvm_phase p);if(errors==0&&checks>0&&!q.size())`uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d commands checked)",checks),UVM_NONE)else`uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** checks=%0d errors=%0d pending=%0d",checks,errors,q.size()))endfunction
  endclass
  class ddr_coverage extends uvm_subscriber#(ddr_sample);`uvm_component_utils(ddr_coverage)ddr_sample s;bit[1:0]kind;covergroup cg;cp_op:coverpoint s.cmd iff(s.cv&&s.cr){bins act={ACT};bins rd={RD};bins wr={WR};bins pre={PRE};}cp_bank:coverpoint s.bank iff(s.cv&&s.cr);cp_kind:coverpoint kind iff(s.done){bins cold={0};bins hit={1};bins conflict={2};}op_x_bank:cross cp_op,cp_bank;endgroup function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction function void write(ddr_sample x);s=x;if(x.cv&&x.cr)begin if(x.cmd==ACT)kind=0;else if(x.cmd==PRE)kind=2;else kind=1;end if(x.rst_n)cg.sample();endfunction endclass
  class ddr_env extends uvm_env;`uvm_component_utils(ddr_env)req_agent ra;ready_agent ca;ddr_monitor mon;ddr_scoreboard sb;ddr_coverage cov;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);ra=req_agent::type_id::create("ra",this);ca=ready_agent::type_id::create("ca",this);mon=ddr_monitor::type_id::create("mon",this);sb=ddr_scoreboard::type_id::create("sb",this);cov=ddr_coverage::type_id::create("cov",this);endfunction function void connect_phase(uvm_phase p);mon.ap.connect(sb.analysis_export);mon.ap.connect(cov.analysis_export);endfunction endclass
  class req_sequence extends uvm_sequence#(ddr_req);`uvm_object_utils(req_sequence)function new(string n="req_sequence");super.new(n);endfunction task send(bit w,bit[7:0]r,bit[1:0]b,bit[5:0]c);ddr_req x=new;start_item(x);x.write=w;x.row=r;x.bank=b;x.col=c;x.data=$urandom;x.idle=0;finish_item(x);endtask task body();ddr_req x;send(0,8'h10,0,1);send(1,8'h10,0,2);send(0,8'h20,0,3);send(1,8'h30,3,4);repeat(100)begin x=new;start_item(x);if(!x.randomize())`uvm_fatal("RAND","request")finish_item(x);end endtask endclass
  class ready_sequence extends uvm_sequence#(ready_item);`uvm_object_utils(ready_sequence)function new(string n="ready_sequence");super.new(n);endfunction task body();ready_item x;repeat(3000)begin x=new;start_item(x);void'(x.randomize());finish_item(x);end endtask endclass
  class ddr_virtual_sequencer extends uvm_sequencer;`uvm_component_utils(ddr_virtual_sequencer)req_sequencer r;ready_sequencer c;function new(string n,uvm_component p);super.new(n,p);endfunction endclass
  class ddr_regress_vseq extends uvm_sequence;`uvm_object_utils(ddr_regress_vseq)ddr_virtual_sequencer vs;function new(string n="ddr_regress_vseq");super.new(n);endfunction task body();req_sequence r=new;ready_sequence c=new;fork r.start(vs.r);c.start(vs.c);join_any disable fork;endtask endclass
  class ddr_regress_test extends uvm_test;`uvm_component_utils(ddr_regress_test)ddr_env e;ddr_virtual_sequencer vs;function new(string n,uvm_component p);super.new(n,p);endfunction function void build_phase(uvm_phase p);e=ddr_env::type_id::create("e",this);vs=ddr_virtual_sequencer::type_id::create("vs",this);endfunction function void connect_phase(uvm_phase p);vs.r=e.ra.sqr;vs.c=e.ca.sqr;endfunction task run_phase(uvm_phase p);ddr_regress_vseq v=new;p.raise_objection(this);v.vs=vs;v.start(vs);#2us;p.drop_objection(this);endtask endclass
endpackage
