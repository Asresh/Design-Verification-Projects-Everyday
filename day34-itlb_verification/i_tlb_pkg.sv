// Author: Asresh Kuricheti
// Complete UVM environment: item, sequences, driver, monitor, agent, model/scoreboard, coverage, and virtual sequence.
package i_tlb_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import tlb_ref_pkg::*;

    class tlb_item extends uvm_sequence_item;
        rand tlb_op_e op;
        rand bit [VA_W-1:0] vaddr, paddr;
        rand bit [ASID_W-1:0] asid;
        rand bit global_map, superpage, executable;
        rand bit inv_all, inv_asid_valid, inv_vaddr_valid;
        bit hit, exec_fault; bit [PA_W-1:0] translated;
        constraint c_align { if (superpage && op==TLB_FILL) {vaddr[20:0]==0;paddr[20:0]==0;} }
        constraint c_inv { if (op==TLB_INVALIDATE) inv_all || inv_asid_valid || inv_vaddr_valid; }
        `uvm_object_utils_begin(tlb_item)
          `uvm_field_enum(tlb_op_e,op,UVM_ALL_ON) `uvm_field_int(vaddr,UVM_HEX)
          `uvm_field_int(paddr,UVM_HEX) `uvm_field_int(asid,UVM_HEX)
          `uvm_field_int(global_map,UVM_ALL_ON) `uvm_field_int(superpage,UVM_ALL_ON)
          `uvm_field_int(executable,UVM_ALL_ON) `uvm_field_int(inv_all,UVM_ALL_ON)
          `uvm_field_int(inv_asid_valid,UVM_ALL_ON) `uvm_field_int(inv_vaddr_valid,UVM_ALL_ON)
          `uvm_field_int(hit,UVM_ALL_ON) `uvm_field_int(exec_fault,UVM_ALL_ON)
          `uvm_field_int(translated,UVM_HEX)
        `uvm_object_utils_end
        function new(string name="tlb_item"); super.new(name); endfunction
    endclass

    class tlb_directed_sequence extends uvm_sequence #(tlb_item);
        `uvm_object_utils(tlb_directed_sequence)
        function new(string name="tlb_directed_sequence");super.new(name);endfunction
        task send(tlb_op_e op, bit[31:0] va, bit[31:0] pa=0, bit[7:0] asid=1,
                  bit global_map=0, bit superpage=0, bit executable=1,
                  bit inv_all=0, bit ias=0, bit iva=0);
            req=tlb_item::type_id::create("req"); start_item(req);
            req.op=op;req.vaddr=va;req.paddr=pa;req.asid=asid;req.global_map=global_map;
            req.superpage=superpage;req.executable=executable;req.inv_all=inv_all;
            req.inv_asid_valid=ias;req.inv_vaddr_valid=iva; finish_item(req);
        endtask
        task body;
            send(TLB_QUERY,32'h0040_1234);                                      // cold miss
            send(TLB_FILL,32'h0040_1000,32'h1040_1000,8'h11);                  // 4 KiB map
            send(TLB_QUERY,32'h0040_1abc,0,8'h11);                             // hit + offset
            send(TLB_QUERY,32'h0040_1abc,0,8'h22);                             // ASID isolation
            send(TLB_FILL,32'h0080_0000,32'h2080_0000,8'h22,1,1,1);            // 2 MiB global
            send(TLB_QUERY,32'h009a_bcde,0,8'h99);                             // global superpage hit
            send(TLB_FILL,32'h00c0_0000,32'h30c0_0000,8'h11,0,0,0);            // execute-never
            send(TLB_QUERY,32'h00c0_0040,0,8'h11);                             // permission fault
            send(TLB_INVALIDATE,32'h0040_1000,0,8'h11,0,0,1,0,1,1);           // VA+ASID invalidate
            send(TLB_QUERY,32'h0040_1234,0,8'h11);                             // now miss
            send(TLB_INVALIDATE,0,0,0,0,0,1,1,0,0);                           // global flush
        endtask
    endclass

    class tlb_random_sequence extends uvm_sequence #(tlb_item);
        `uvm_object_utils(tlb_random_sequence) int unsigned count=600;
        function new(string name="tlb_random_sequence");super.new(name);endfunction
        task body;
            repeat(count) begin
                req=tlb_item::type_id::create("req"); start_item(req);
                if(!req.randomize() with {op dist {TLB_QUERY:=7,TLB_FILL:=2,TLB_INVALIDATE:=1};
                    asid inside {[0:7]}; global_map dist {0:=7,1:=1}; superpage dist {0:=7,1:=1};
                    executable dist {1:=7,0:=1}; inv_all dist {0:=9,1:=1};
                    inv_asid_valid dist {0:=2,1:=3}; inv_vaddr_valid dist {0:=2,1:=3};})
                    `uvm_fatal("RAND","TLB transaction randomization failed")
                finish_item(req);
            end
        endtask
    endclass

    class tlb_driver extends uvm_driver #(tlb_item);
        `uvm_component_utils(tlb_driver) virtual i_tlb_if vif;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);
            if(!uvm_config_db#(virtual i_tlb_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","i_tlb_if missing")
        endfunction
        task clear_bus;
            vif.drv_cb.query_valid<=0;vif.drv_cb.fill_valid<=0;vif.drv_cb.inv_valid<=0;
        endtask
        task run_phase(uvm_phase phase);
            clear_bus(); forever begin
                seq_item_port.get_next_item(req); @(vif.drv_cb); clear_bus();
                case(req.op)
                  TLB_QUERY: begin vif.drv_cb.query_valid<=1;vif.drv_cb.query_vaddr<=req.vaddr;vif.drv_cb.query_asid<=req.asid;end
                  TLB_FILL: begin vif.drv_cb.fill_valid<=1;vif.drv_cb.fill_vaddr<=req.vaddr;vif.drv_cb.fill_paddr<=req.paddr;
                    vif.drv_cb.fill_asid<=req.asid;vif.drv_cb.fill_global<=req.global_map;vif.drv_cb.fill_superpage<=req.superpage;vif.drv_cb.fill_exec<=req.executable;end
                  default: begin vif.drv_cb.inv_valid<=1;vif.drv_cb.inv_all<=req.inv_all;vif.drv_cb.inv_asid_valid<=req.inv_asid_valid;
                    vif.drv_cb.inv_asid<=req.asid;vif.drv_cb.inv_vaddr_valid<=req.inv_vaddr_valid;vif.drv_cb.inv_vaddr<=req.vaddr;end
                endcase
                @(vif.drv_cb); clear_bus(); seq_item_port.item_done();
            end
        endtask
    endclass

    class tlb_monitor extends uvm_component;
        `uvm_component_utils(tlb_monitor) virtual i_tlb_if vif; uvm_analysis_port#(tlb_item) ap;
        function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
        function void build_phase(uvm_phase phase);
            if(!uvm_config_db#(virtual i_tlb_if)::get(this,"","vif",vif)) `uvm_fatal("NOVIF","i_tlb_if missing")
        endfunction
        task run_phase(uvm_phase phase); tlb_item t;
            forever begin @(vif.mon_cb); if(!vif.mon_cb.rst_n) continue;
                if(vif.mon_cb.query_valid||vif.mon_cb.fill_valid||vif.mon_cb.inv_valid) begin
                    t=tlb_item::type_id::create("observed");
                    if(vif.mon_cb.query_valid) t.op=TLB_QUERY; else if(vif.mon_cb.fill_valid) t.op=TLB_FILL; else t.op=TLB_INVALIDATE;
                    t.vaddr=vif.mon_cb.query_valid?vif.mon_cb.query_vaddr:(vif.mon_cb.fill_valid?vif.mon_cb.fill_vaddr:vif.mon_cb.inv_vaddr);
                    t.paddr=vif.mon_cb.fill_paddr;t.asid=vif.mon_cb.query_valid?vif.mon_cb.query_asid:(vif.mon_cb.fill_valid?vif.mon_cb.fill_asid:vif.mon_cb.inv_asid);
                    t.global_map=vif.mon_cb.fill_global;t.superpage=vif.mon_cb.fill_superpage;t.executable=vif.mon_cb.fill_exec;
                    t.inv_all=vif.mon_cb.inv_all;t.inv_asid_valid=vif.mon_cb.inv_asid_valid;t.inv_vaddr_valid=vif.mon_cb.inv_vaddr_valid;
                    t.hit=vif.mon_cb.query_hit;t.exec_fault=vif.mon_cb.query_exec_fault;t.translated=vif.mon_cb.query_paddr;ap.write(t);
                end
            end
        endtask
    endclass

    class tlb_scoreboard extends uvm_subscriber #(tlb_item);
        `uvm_component_utils(tlb_scoreboard)
        typedef struct {bit valid;bit[31:0] va,pa;bit[7:0] asid;bit global_map,superpage,executable;} entry_s;
        entry_s model[ENTRIES]; int unsigned replace_idx,queries,hits,faults;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void write(tlb_item t); int match=-1,victim=-1;bit found_invalid=0;
            if(t.op==TLB_QUERY) begin
                queries++;
                for(int i=0;i<ENTRIES;i++) if(match<0&&model[i].valid&&(model[i].global_map||model[i].asid==t.asid)&&page_matches(model[i].va,t.vaddr,model[i].superpage)) match=i;
                if(t.hit!==(match>=0)) `uvm_error("HIT",$sformatf("VA %08x ASID %02x expected hit=%0b got=%0b",t.vaddr,t.asid,match>=0,t.hit))
                if(match>=0) begin bit[31:0] exp=translate(model[match].pa,t.vaddr,model[match].superpage); hits++;
                    if(t.translated!==exp) `uvm_error("PA",$sformatf("expected %08x got %08x",exp,t.translated))
                    if(t.exec_fault!==!model[match].executable) `uvm_error("PERM","execute permission mismatch")
                    if(!model[match].executable) faults++;
                end else if(t.exec_fault) `uvm_error("MISSFAULT","miss asserted permission fault");
            end else if(t.op==TLB_FILL) begin
                victim=replace_idx; for(int i=0;i<ENTRIES;i++) if(!found_invalid&&!model[i].valid) begin victim=i;found_invalid=1;end
                model[victim]='{1,t.vaddr,t.paddr,t.asid,t.global_map,t.superpage,t.executable}; replace_idx=(victim+1)%ENTRIES;
            end else begin
                for(int i=0;i<ENTRIES;i++) if(model[i].valid && (t.inv_all ||
                    ((!t.inv_asid_valid||(!model[i].global_map&&model[i].asid==t.asid))&&
                     (!t.inv_vaddr_valid||page_matches(model[i].va,t.vaddr,model[i].superpage))))) model[i].valid=0;
            end
        endfunction
        function void report_phase(uvm_phase phase);uvm_report_server rs=uvm_report_server::get_server();
            `uvm_info("SUMMARY",$sformatf("queries=%0d hits=%0d permission_faults=%0d",queries,hits,faults),UVM_LOW)
            if(rs.get_severity_count(UVM_ERROR)==0&&rs.get_severity_count(UVM_FATAL)==0) $display("RESULT: *** PASS ***");
        endfunction
    endclass

    class tlb_coverage extends uvm_subscriber #(tlb_item);
        `uvm_component_utils(tlb_coverage) tlb_op_e op;bit hit,fault,superpage,global_map;bit[7:0] asid;
        covergroup cg; cp_op:coverpoint op;cp_hit:coverpoint hit;cp_fault:coverpoint fault;cp_size:coverpoint superpage;
          cp_global:coverpoint global_map;cp_asid:coverpoint asid{bins low[]={[0:7]};bins other=default;}
          query_result:cross cp_op,cp_hit,cp_fault; fill_kind:cross cp_op,cp_size,cp_global;
        endgroup
        function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
        function void write(tlb_item t);op=t.op;hit=t.hit;fault=t.exec_fault;superpage=t.superpage;global_map=t.global_map;asid=t.asid;cg.sample();endfunction
    endclass

    class tlb_agent extends uvm_agent;
        `uvm_component_utils(tlb_agent) uvm_sequencer#(tlb_item) sqr;tlb_driver drv;tlb_monitor mon;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase p);sqr=uvm_sequencer#(tlb_item)::type_id::create("sqr",this);drv=tlb_driver::type_id::create("drv",this);mon=tlb_monitor::type_id::create("mon",this);endfunction
        function void connect_phase(uvm_phase p);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
    endclass
    class tlb_virtual_sequencer extends uvm_sequencer;
        `uvm_component_utils(tlb_virtual_sequencer) uvm_sequencer#(tlb_item) tlb_sqr;
        function new(string n,uvm_component p);super.new(n,p);endfunction
    endclass
    class tlb_regress_vseq extends uvm_sequence;
        `uvm_object_utils(tlb_regress_vseq) `uvm_declare_p_sequencer(tlb_virtual_sequencer)
        function new(string n="tlb_regress_vseq");super.new(n);endfunction
        task body;tlb_directed_sequence d=tlb_directed_sequence::type_id::create("directed");tlb_random_sequence r=tlb_random_sequence::type_id::create("random");d.start(p_sequencer.tlb_sqr);r.start(p_sequencer.tlb_sqr);endtask
    endclass
    class tlb_env extends uvm_env;
        `uvm_component_utils(tlb_env) tlb_agent agent;tlb_scoreboard sb;tlb_coverage cov;tlb_virtual_sequencer vsqr;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase p);agent=tlb_agent::type_id::create("agent",this);sb=tlb_scoreboard::type_id::create("sb",this);cov=tlb_coverage::type_id::create("cov",this);vsqr=tlb_virtual_sequencer::type_id::create("vsqr",this);endfunction
        function void connect_phase(uvm_phase p);agent.mon.ap.connect(sb.analysis_export);agent.mon.ap.connect(cov.analysis_export);vsqr.tlb_sqr=agent.sqr;endfunction
    endclass
    class tlb_regress_test extends uvm_test;
        `uvm_component_utils(tlb_regress_test) tlb_env env;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase p);env=tlb_env::type_id::create("env",this);endfunction
        task run_phase(uvm_phase p);tlb_regress_vseq v=tlb_regress_vseq::type_id::create("vseq");p.raise_objection(this);v.start(env.vsqr);#50ns;p.drop_objection(this);endtask
    endclass
endpackage
