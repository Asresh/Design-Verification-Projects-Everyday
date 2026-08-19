// Author: Asresh Kuricheti
// Reusable UVM environment: request/PTE-response agents, virtual sequence,
// pin-level monitor, independent page-walk scoreboard, and functional coverage.
package ptw_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam bit [21:0] ROOT_PPN = 22'h00100;

  class ptw_req_item extends uvm_sequence_item;
    rand bit [31:0] vaddr;
    rand bit [1:0] access;
    rand bit user_mode;
    rand int unsigned idle_cycles;
    rand int unsigned rsp_stall;
    constraint legal_c { access inside {0,1,2}; idle_cycles inside {[0:3]}; rsp_stall inside {[0:3]}; }
    `uvm_object_utils_begin(ptw_req_item)
      `uvm_field_int(vaddr,UVM_HEX) `uvm_field_int(access,UVM_DEC)
      `uvm_field_int(user_mode,UVM_BIN) `uvm_field_int(idle_cycles,UVM_DEC)
      `uvm_field_int(rsp_stall,UVM_DEC)
    `uvm_object_utils_end
    function new(string name="ptw_req_item"); super.new(name); endfunction
  endclass

  class pte_rsp_item extends uvm_sequence_item;
    rand bit [31:0] pte;
    rand int unsigned req_stall;
    rand int unsigned rsp_delay;
    constraint delay_c { req_stall inside {[0:4]}; rsp_delay inside {[0:4]}; }
    `uvm_object_utils_begin(pte_rsp_item)
      `uvm_field_int(pte,UVM_HEX) `uvm_field_int(req_stall,UVM_DEC) `uvm_field_int(rsp_delay,UVM_DEC)
    `uvm_object_utils_end
    function new(string name="pte_rsp_item"); super.new(name); endfunction
  endclass

  class ptw_sample extends uvm_sequence_item;
    bit rst_n;
    bit [21:0] root_ppn;
    bit req_valid,req_ready,user_mode;
    bit [31:0] vaddr;
    bit [1:0] access;
    bit mem_req_valid,mem_req_ready;
    bit [33:0] mem_req_addr;
    bit mem_rsp_valid;
    bit [31:0] pte;
    bit rsp_valid,rsp_ready;
    bit [33:0] paddr;
    bit fault,leaf_level;
    bit [1:0] fault_code;
    `uvm_object_utils(ptw_sample)
    function new(string name="ptw_sample"); super.new(name); endfunction
  endclass

  class ptw_req_sequencer extends uvm_sequencer #(ptw_req_item);
    `uvm_component_utils(ptw_req_sequencer)
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass
  class pte_mem_sequencer extends uvm_sequencer #(pte_rsp_item);
    `uvm_component_utils(pte_mem_sequencer)
    function new(string n,uvm_component p); super.new(n,p); endfunction
  endclass

  class ptw_req_driver extends uvm_driver #(ptw_req_item);
    `uvm_component_utils(ptw_req_driver)
    virtual ptw_if vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual ptw_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","request driver")
    endfunction
    task run_phase(uvm_phase phase);
      vif.req_cb.req_valid<=0; vif.req_cb.rsp_ready<=0;
      forever begin
        seq_item_port.get_next_item(req);
        repeat(req.idle_cycles) @(vif.req_cb);
        vif.req_cb.req_valid<=1; vif.req_cb.req_vaddr<=req.vaddr;
        vif.req_cb.req_access<=req.access; vif.req_cb.req_user<=req.user_mode;
        do @(vif.req_cb); while(!vif.req_cb.req_ready);
        vif.req_cb.req_valid<=0;
        repeat(req.rsp_stall) @(vif.req_cb);
        vif.req_cb.rsp_ready<=1;
        do @(vif.req_cb); while(!vif.req_cb.rsp_valid);
        vif.req_cb.rsp_ready<=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class pte_mem_driver extends uvm_driver #(pte_rsp_item);
    `uvm_component_utils(pte_mem_driver)
    virtual ptw_if vif;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual ptw_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","PTE memory driver")
    endfunction
    task run_phase(uvm_phase phase);
      vif.mem_cb.mem_req_ready<=0; vif.mem_cb.mem_rsp_valid<=0; vif.mem_cb.mem_rsp_pte<='0;
      forever begin
        seq_item_port.get_next_item(req);
        repeat(req.req_stall) @(vif.mem_cb);
        vif.mem_cb.mem_req_ready<=1;
        do @(vif.mem_cb); while(!vif.mem_cb.mem_req_valid);
        vif.mem_cb.mem_req_ready<=0;
        repeat(req.rsp_delay) @(vif.mem_cb);
        vif.mem_cb.mem_rsp_pte<=req.pte; vif.mem_cb.mem_rsp_valid<=1;
        @(vif.mem_cb); vif.mem_cb.mem_rsp_valid<=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class ptw_req_agent extends uvm_agent;
    `uvm_component_utils(ptw_req_agent)
    ptw_req_sequencer sqr; ptw_req_driver drv;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); sqr=ptw_req_sequencer::type_id::create("sqr",this); drv=ptw_req_driver::type_id::create("drv",this); endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
  endclass
  class pte_mem_agent extends uvm_agent;
    `uvm_component_utils(pte_mem_agent)
    pte_mem_sequencer sqr; pte_mem_driver drv;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void build_phase(uvm_phase phase); sqr=pte_mem_sequencer::type_id::create("sqr",this); drv=pte_mem_driver::type_id::create("drv",this); endfunction
    function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
  endclass

  class ptw_monitor extends uvm_monitor;
    `uvm_component_utils(ptw_monitor)
    virtual ptw_if vif; uvm_analysis_port #(ptw_sample) ap;
    function new(string n,uvm_component p); super.new(n,p); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual ptw_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","monitor")
    endfunction
    task run_phase(uvm_phase phase); ptw_sample s;
      forever begin @(vif.mon_cb); s=new;
        s.rst_n=vif.mon_cb.rst_n; s.root_ppn=vif.mon_cb.root_ppn;
        s.req_valid=vif.mon_cb.req_valid; s.req_ready=vif.mon_cb.req_ready;
        s.vaddr=vif.mon_cb.req_vaddr; s.access=vif.mon_cb.req_access; s.user_mode=vif.mon_cb.req_user;
        s.mem_req_valid=vif.mon_cb.mem_req_valid; s.mem_req_ready=vif.mon_cb.mem_req_ready; s.mem_req_addr=vif.mon_cb.mem_req_addr;
        s.mem_rsp_valid=vif.mon_cb.mem_rsp_valid; s.pte=vif.mon_cb.mem_rsp_pte;
        s.rsp_valid=vif.mon_cb.rsp_valid; s.rsp_ready=vif.mon_cb.rsp_ready; s.paddr=vif.mon_cb.rsp_paddr;
        s.fault=vif.mon_cb.rsp_fault; s.fault_code=vif.mon_cb.rsp_fault_code; s.leaf_level=vif.mon_cb.rsp_leaf_level;
        ap.write(s);
      end
    endtask
  endclass

  class ptw_scoreboard extends uvm_subscriber #(ptw_sample);
    `uvm_component_utils(ptw_scoreboard)
    typedef enum int {M_IDLE,M_L1_REQ,M_L1_RSP,M_L0_REQ,M_L0_RSP,M_OUT} model_state_t;
    model_state_t ms=M_IDLE;
    bit [31:0] va_q; bit [1:0] access_q; bit user_q;
    bit [21:0] root_q,l0_ppn_q;
    bit [33:0] exp_pa; bit exp_fault,exp_level; bit [1:0] exp_code;
    int checks,errors,l1_leaves,l0_leaves;
    function new(string n,uvm_component p); super.new(n,p); endfunction
    function void bad(string msg); `uvm_error("PTW_SB",msg) errors++; endfunction
    function bit invalid(bit[31:0] p); return !p[0]||(!p[1]&&p[2]); endfunction
    function bit leaf(bit[31:0] p); return p[1]||p[3]; endfunction
    function bit permit(bit[31:0] p,bit[1:0] a,bit u);
      bit ok; case(a)0:ok=p[1];1:ok=p[2];2:ok=p[3];default:ok=0;endcase
      return ok&&p[6]&&(!u||p[4])&&((a!=1)||p[7]);
    endfunction
    function void make_fault(bit[1:0] code,bit level); exp_pa='0;exp_fault=1;exp_code=code;exp_level=level;ms=M_OUT; endfunction
    function void consume_pte(bit[31:0] p,bit level);
      if(invalid(p)) make_fault(1,level);
      else if(level && !leaf(p)) begin l0_ppn_q=p[31:10];ms=M_L0_REQ;end
      else if(!leaf(p)) make_fault(1,level);
      else if(level && p[19:10]!=0) make_fault(3,1);
      else if(!permit(p,access_q,user_q)) make_fault(2,level);
      else begin
        exp_pa=level?{p[31:20],va_q[21:0]}:{p[31:10],va_q[11:0]};
        exp_fault=0;exp_code=0;exp_level=level;ms=M_OUT;
        if(level)l1_leaves++;else l0_leaves++;
      end
    endfunction
    function void write(ptw_sample s); bit[33:0] expected_addr;
      if(!s.rst_n)begin ms=M_IDLE;return;end
      if(s.req_valid&&s.req_ready)begin
        if(ms!=M_IDLE)bad("new request while model busy");
        va_q=s.vaddr;access_q=s.access;user_q=s.user_mode;root_q=s.root_ppn;ms=M_L1_REQ;
      end
      if(s.mem_req_valid&&s.mem_req_ready)begin
        if(ms==M_L1_REQ)expected_addr={root_q,12'b0}+{22'b0,va_q[31:22],2'b0};
        else if(ms==M_L0_REQ)expected_addr={l0_ppn_q,12'b0}+{22'b0,va_q[21:12],2'b0};
        else begin expected_addr='0;bad("unexpected PTE request");end
        if(s.mem_req_addr!==expected_addr)bad($sformatf("PTE address exp=%09x got=%09x",expected_addr,s.mem_req_addr));
        if(ms==M_L1_REQ)ms=M_L1_RSP;else if(ms==M_L0_REQ)ms=M_L0_RSP;
      end
      if(s.mem_rsp_valid)begin
        if(ms==M_L1_RSP)consume_pte(s.pte,1);
        else if(ms==M_L0_RSP)consume_pte(s.pte,0);
        else bad("unexpected PTE response");
      end
      if(s.rsp_valid&&s.rsp_ready)begin
        checks++;if(ms!=M_OUT)bad("translation response before model result");
        else begin
          if(s.paddr!==exp_pa||s.fault!==exp_fault||s.fault_code!==exp_code||s.leaf_level!==exp_level)
            bad($sformatf("result mismatch pa=%09x/%09x fault=%0b/%0b code=%0d/%0d level=%0b/%0b",s.paddr,exp_pa,s.fault,exp_fault,s.fault_code,exp_code,s.leaf_level,exp_level));
          ms=M_IDLE;
        end
      end
    endfunction
    function void report_phase(uvm_phase phase);
      if(errors==0&&checks>0&&ms==M_IDLE) `uvm_info("RESULT",$sformatf("RESULT: *** PASS *** (%0d walks, L1=%0d L0=%0d)",checks,l1_leaves,l0_leaves),UVM_NONE)
      else `uvm_error("RESULT",$sformatf("RESULT: *** FAIL *** checks=%0d errors=%0d state=%0d",checks,errors,ms))
    endfunction
  endclass

  class ptw_coverage extends uvm_subscriber #(ptw_sample);
    `uvm_component_utils(ptw_coverage)
    bit[1:0] access_q,fault_code_q; bit user_q,level_q,fault_q;
    covergroup cg;
      cp_access:coverpoint access_q{bins read={0};bins write={1};bins exec={2};}
      cp_user:coverpoint user_q;
      cp_fault:coverpoint fault_code_q{bins success={0};bins invalid={1};bins permission={2};bins misaligned={3};}
      cp_level:coverpoint level_q iff(!fault_q);
      access_x_result:cross cp_access,cp_fault;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
    function void write(ptw_sample s);
      if(s.req_valid&&s.req_ready)begin access_q=s.access;user_q=s.user_mode;end
      if(s.rsp_valid&&s.rsp_ready)begin fault_q=s.fault;fault_code_q=s.fault_code;level_q=s.leaf_level;cg.sample();end
    endfunction
  endclass

  class ptw_env extends uvm_env;
    `uvm_component_utils(ptw_env)
    ptw_req_agent req_agent; pte_mem_agent mem_agent; ptw_monitor mon; ptw_scoreboard sb; ptw_coverage cov;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      req_agent=ptw_req_agent::type_id::create("req_agent",this);mem_agent=pte_mem_agent::type_id::create("mem_agent",this);
      mon=ptw_monitor::type_id::create("mon",this);sb=ptw_scoreboard::type_id::create("sb",this);cov=ptw_coverage::type_id::create("cov",this);
    endfunction
    function void connect_phase(uvm_phase phase);mon.ap.connect(sb.analysis_export);mon.ap.connect(cov.analysis_export);endfunction
  endclass

  class ptw_one_req_seq extends uvm_sequence #(ptw_req_item);
    `uvm_object_utils(ptw_one_req_seq)
    bit[31:0]vaddr;bit[1:0]access;bit user_mode;int idle_cycles,rsp_stall;
    function new(string n="ptw_one_req_seq");super.new(n);endfunction
    task body();ptw_req_item x=new;start_item(x);x.vaddr=vaddr;x.access=access;x.user_mode=user_mode;x.idle_cycles=idle_cycles;x.rsp_stall=rsp_stall;finish_item(x);endtask
  endclass
  class pte_script_seq extends uvm_sequence #(pte_rsp_item);
    `uvm_object_utils(pte_script_seq)
    bit[31:0]ptes[$];int stalls[$],delays[$];
    function new(string n="pte_script_seq");super.new(n);endfunction
    task body();pte_rsp_item x;foreach(ptes[i])begin x=new;start_item(x);x.pte=ptes[i];x.req_stall=stalls[i];x.rsp_delay=delays[i];finish_item(x);end endtask
  endclass
  class ptw_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(ptw_virtual_sequencer)
    ptw_req_sequencer req_sqr;pte_mem_sequencer mem_sqr;
    function new(string n,uvm_component p);super.new(n,p);endfunction
  endclass
  class ptw_regress_vseq extends uvm_sequence;
    `uvm_object_utils(ptw_regress_vseq)
    ptw_virtual_sequencer vs;
    function new(string n="ptw_regress_vseq");super.new(n);endfunction
    function bit[31:0] mkpte(bit[21:0]ppn,bit v,bit r,bit w,bit x,bit u,bit a,bit d);
      return {ppn,2'b0,d,a,1'b0,u,x,w,r,v};
    endfunction
    task run_case(bit[31:0]va,bit[1:0]access,bit user,bit[31:0]p1,bit has_p0,bit[31:0]p0,int seed);
      ptw_one_req_seq r=new;pte_script_seq m=new;
      r.vaddr=va;r.access=access;r.user_mode=user;r.idle_cycles=seed%4;r.rsp_stall=(seed/3)%4;
      m.ptes.push_back(p1);m.stalls.push_back(seed%5);m.delays.push_back((seed/5)%5);
      if(has_p0)begin m.ptes.push_back(p0);m.stalls.push_back((seed/7)%5);m.delays.push_back((seed/11)%5);end
      fork r.start(vs.req_sqr);m.start(vs.mem_sqr);join
    endtask
    task body();bit[31:0]va,p1,p0;bit[21:0]table_ppn,leaf_ppn;bit[1:0]a;bit u;int kind;
      run_case(32'h1234_5678,0,1,mkpte(22'h00200,1,0,0,0,0,0,0),1,mkpte(22'h12345,1,1,1,0,1,1,1),1);
      run_case(32'h4080_0120,2,0,mkpte(22'h28000,1,1,0,1,0,1,0),0,0,2);
      run_case(32'h2000_1000,0,0,0,0,0,3);
      run_case(32'h2000_2000,1,1,mkpte(22'h00210,1,0,0,0,0,0,0),1,mkpte(22'h23456,1,1,1,0,1,1,0),4);
      run_case(32'h3000_3000,0,0,mkpte(22'h28001,1,1,0,0,0,1,0),0,0,5);
      repeat(120)begin
        va=$urandom;a=$urandom_range(0,2);u=$urandom_range(0,1);kind=$urandom_range(0,5);
        table_ppn=$urandom_range(22'h00300,22'h003ff);leaf_ppn=$urandom;
        case(kind)
          0:p1=0;
          1:begin leaf_ppn[9:0]=0;p1=mkpte(leaf_ppn,1,1,0,1,1,1,0);end
          2:begin leaf_ppn[9:0]=0;p1=mkpte(leaf_ppn,1,1,1,1,1,1,1);end
          default:p1=mkpte(table_ppn,1,0,0,0,0,0,0);
        endcase
        p0=mkpte(leaf_ppn,1,1,(kind!=3),1,(kind!=4),1,(kind!=5));
        run_case(va,a,u,p1,!((kind==0)||(kind==1)||(kind==2)),p0,$urandom_range(0,1000));
      end
    endtask
  endclass
  class ptw_regress_test extends uvm_test;
    `uvm_component_utils(ptw_regress_test)
    ptw_env env;ptw_virtual_sequencer vs;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);env=ptw_env::type_id::create("env",this);vs=ptw_virtual_sequencer::type_id::create("vs",this);endfunction
    function void connect_phase(uvm_phase phase);vs.req_sqr=env.req_agent.sqr;vs.mem_sqr=env.mem_agent.sqr;endfunction
    task run_phase(uvm_phase phase);ptw_regress_vseq seq=new;phase.raise_objection(this);seq.vs=vs;seq.start(vs);repeat(10)@(posedge env.mon.vif.clk);phase.drop_objection(this);endtask
  endclass
endpackage
