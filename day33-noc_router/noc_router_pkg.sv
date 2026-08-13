package noc_router_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import noc_ref_pkg::*;

    class noc_item extends uvm_sequence_item;
        rand bit [1:0] dst;
        rand bit [31:0] data;
        rand bit last;
        int unsigned src;
        constraint c_dst { dst < NPORT; }
        `uvm_object_utils_begin(noc_item)
            `uvm_field_int(dst,UVM_ALL_ON)
            `uvm_field_int(data,UVM_HEX)
            `uvm_field_int(last,UVM_ALL_ON)
            `uvm_field_int(src,UVM_ALL_ON)
        `uvm_object_utils_end
        function new(string name="noc_item"); super.new(name); endfunction
    endclass

    class noc_event extends uvm_object;
        noc_item tr;
        bit is_output;
        int unsigned port;
        `uvm_object_utils(noc_event)
        function new(string name="noc_event"); super.new(name); endfunction
    endclass

    class noc_input_sequence extends uvm_sequence #(noc_item);
        int unsigned source, count=120;
        bit directed;
        `uvm_object_utils(noc_input_sequence)
        function new(string name="noc_input_sequence"); super.new(name); endfunction
        task body;
            repeat(count) begin
                req=noc_item::type_id::create("req");
                start_item(req);
                if (directed) begin
                    req.src=source; req.dst=1; req.last=($urandom_range(0,4)==0);
                    req.data=$urandom; req.data[31:30]=source[1:0];
                end else if (!req.randomize() with {
                    data[31:30] == source[1:0];
                    dst dist {0:=3,1:=6,2:=3};
                    last dist {0:=4,1:=1};
                }) `uvm_fatal("RAND","noc_item randomization failed")
                req.src=source;
                finish_item(req);
            end
        endtask
    endclass

    class noc_sink_item extends uvm_sequence_item;
        rand bit [NPORT-1:0] ready;
        constraint c_some_ready { ready != '0; }
        `uvm_object_utils(noc_sink_item)
        function new(string name="noc_sink_item"); super.new(name); endfunction
    endclass

    class noc_sink_sequence extends uvm_sequence #(noc_sink_item);
        int unsigned count=500;
        `uvm_object_utils(noc_sink_sequence)
        function new(string name="noc_sink_sequence"); super.new(name); endfunction
        task body;
            repeat(count) begin
                req=noc_sink_item::type_id::create("ready");
                start_item(req);
                if (!req.randomize()) `uvm_fatal("RAND","ready randomization failed")
                finish_item(req);
            end
        endtask
    endclass

    class noc_input_driver extends uvm_driver #(noc_item);
        `uvm_component_utils(noc_input_driver)
        virtual noc_router_if vif;
        int unsigned port_id;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if(!uvm_config_db#(virtual noc_router_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","noc interface not configured")
            if(!uvm_config_db#(int unsigned)::get(this,"","port_id",port_id))
                `uvm_fatal("NOPORT","input driver port_id missing")
        endfunction
        task run_phase(uvm_phase phase);
            vif.in_valid[port_id]=0;
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.in_valid[port_id]=1;
                vif.in_dest[port_id*2 +: 2]=req.dst;
                vif.in_flit[port_id*32 +: 32]=req.data;
                vif.in_last[port_id]=req.last;
                do @(negedge vif.clk); while(!vif.in_ready[port_id]);
                vif.in_valid[port_id]=0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class noc_sink_driver extends uvm_driver #(noc_sink_item);
        `uvm_component_utils(noc_sink_driver)
        virtual noc_router_if vif;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);
            if(!uvm_config_db#(virtual noc_router_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","noc interface not configured")
        endfunction
        task run_phase(uvm_phase phase);
            vif.out_ready='1;
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk); vif.out_ready=req.ready;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class noc_monitor extends uvm_component;
        `uvm_component_utils(noc_monitor)
        virtual noc_router_if vif;
        uvm_analysis_port #(noc_event) ap;
        function new(string n,uvm_component p);super.new(n,p);ap=new("ap",this);endfunction
        function void build_phase(uvm_phase phase);
            if(!uvm_config_db#(virtual noc_router_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","noc interface not configured")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if(!vif.rst_n) continue;
                for(int p=0;p<NPORT;p++) begin
                    if(vif.mon_cb.in_valid[p]&&vif.mon_cb.in_ready[p]) publish(0,p,
                        vif.mon_cb.in_dest[p*2 +: 2],vif.mon_cb.in_flit[p*32 +: 32],vif.mon_cb.in_last[p]);
                    if(vif.mon_cb.out_valid[p]&&vif.mon_cb.out_ready[p]) publish(1,p,
                        vif.mon_cb.out_dest[p*2 +: 2],vif.mon_cb.out_flit[p*32 +: 32],vif.mon_cb.out_last[p]);
                end
            end
        endtask
        function void publish(bit outp,int p,bit[1:0] d,bit[31:0] data,bit last);
            noc_event e=noc_event::type_id::create("event");
            e.tr=noc_item::type_id::create("tr");
            e.is_output=outp; e.port=p; e.tr.dst=d; e.tr.data=data; e.tr.last=last;
            e.tr.src=outp ? data[31:30] : p;
            ap.write(e);
        endfunction
    endclass

    class noc_scoreboard extends uvm_subscriber #(noc_event);
        `uvm_component_utils(noc_scoreboard)
        noc_item expected[NPORT][NPORT][$];
        int unsigned inputs,outputs;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void write(noc_event e);
            noc_item x;
            if(!e.is_output) begin
                if(route(e.tr.dst)!=e.tr.dst || !source_tag_ok(e.port,e.tr.data))
                    `uvm_error("REF","input violates route/source contract")
                $cast(x,e.tr.clone()); expected[e.tr.dst][e.port].push_back(x); inputs++;
            end else begin
                int s=e.tr.src;
                outputs++;
                if(e.tr.dst!=e.port || s>=NPORT || expected[e.port][s].size()==0)
                    `uvm_error("ROUTE",$sformatf("unexpected output port=%0d src=%0d",e.port,s))
                else begin
                    x=expected[e.port][s].pop_front();
                    if(x.data!==e.tr.data || x.last!==e.tr.last)
                        `uvm_error("ORDER",$sformatf("data/order mismatch port=%0d src=%0d",e.port,s))
                end
            end
        endfunction
        function void check_phase(uvm_phase phase);
            foreach(expected[o,s]) if(expected[o][s].size()!=0)
                `uvm_error("LOSS",$sformatf("%0d flits left for output %0d source %0d",expected[o][s].size(),o,s))
            if(inputs!=outputs) `uvm_error("COUNT",$sformatf("inputs=%0d outputs=%0d",inputs,outputs))
        endfunction
        function void report_phase(uvm_phase phase);
            uvm_report_server rs=uvm_report_server::get_server();
            if(rs.get_severity_count(UVM_ERROR)==0 && rs.get_severity_count(UVM_FATAL)==0)
                $display("RESULT: *** PASS ***");
        endfunction
    endclass

    class noc_coverage extends uvm_subscriber #(noc_event);
        `uvm_component_utils(noc_coverage)
        int src,dst; bit last,is_output;
        covergroup cg;
            cp_src: coverpoint src { bins ports[]={[0:NPORT-1]}; }
            cp_dst: coverpoint dst { bins ports[]={[0:NPORT-1]}; }
            cp_last: coverpoint last;
            cp_side: coverpoint is_output;
            route_cross: cross cp_src,cp_dst,cp_last;
        endgroup
        function new(string n,uvm_component p);super.new(n,p);cg=new;endfunction
        function void write(noc_event e);
            src=e.tr.src; dst=e.tr.dst; last=e.tr.last; is_output=e.is_output; cg.sample();
        endfunction
    endclass

    class noc_input_agent extends uvm_agent;
        `uvm_component_utils(noc_input_agent)
        uvm_sequencer #(noc_item) sqr; noc_input_driver drv;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);
            sqr=uvm_sequencer#(noc_item)::type_id::create("sqr",this);
            drv=noc_input_driver::type_id::create("drv",this);
        endfunction
        function void connect_phase(uvm_phase phase);drv.seq_item_port.connect(sqr.seq_item_export);endfunction
    endclass

    class noc_virtual_sequencer extends uvm_sequencer;
        `uvm_component_utils(noc_virtual_sequencer)
        uvm_sequencer #(noc_item) in_sqr[NPORT];
        uvm_sequencer #(noc_sink_item) sink_sqr;
        function new(string n,uvm_component p);super.new(n,p);endfunction
    endclass

    class noc_regress_vseq extends uvm_sequence;
        `uvm_object_utils(noc_regress_vseq)
        `uvm_declare_p_sequencer(noc_virtual_sequencer)
        function new(string name="noc_regress_vseq");super.new(name);endfunction
        task body;
            noc_input_sequence seq[NPORT]; noc_sink_sequence sink;
            sink=noc_sink_sequence::type_id::create("sink"); sink.count=900;
            fork sink.start(p_sequencer.sink_sqr); join_none
            for(int p=0;p<NPORT;p++) begin
                automatic int q=p;
                fork begin
                    seq[q]=noc_input_sequence::type_id::create($sformatf("directed%0d",q));
                    seq[q].source=q; seq[q].count=20; seq[q].directed=1;
                    seq[q].start(p_sequencer.in_sqr[q]);
                    seq[q]=noc_input_sequence::type_id::create($sformatf("random%0d",q));
                    seq[q].source=q; seq[q].count=220;
                    seq[q].start(p_sequencer.in_sqr[q]);
                end join_none
            end
            wait fork;
        endtask
    endclass

    class noc_env extends uvm_env;
        `uvm_component_utils(noc_env)
        noc_input_agent in_agent[NPORT];
        uvm_sequencer #(noc_sink_item) sink_sqr;
        noc_sink_driver sink_drv; noc_monitor mon; noc_scoreboard sb; noc_coverage cov;
        noc_virtual_sequencer vsqr;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);
            for(int p=0;p<NPORT;p++) begin
                uvm_config_db#(int unsigned)::set(this,$sformatf("in_agent[%0d].drv",p),"port_id",p);
                in_agent[p]=noc_input_agent::type_id::create($sformatf("in_agent[%0d]",p),this);
            end
            sink_sqr=uvm_sequencer#(noc_sink_item)::type_id::create("sink_sqr",this);
            sink_drv=noc_sink_driver::type_id::create("sink_drv",this);
            mon=noc_monitor::type_id::create("mon",this); sb=noc_scoreboard::type_id::create("sb",this);
            cov=noc_coverage::type_id::create("cov",this);
            vsqr=noc_virtual_sequencer::type_id::create("vsqr",this);
        endfunction
        function void connect_phase(uvm_phase phase);
            sink_drv.seq_item_port.connect(sink_sqr.seq_item_export);
            mon.ap.connect(sb.analysis_export); mon.ap.connect(cov.analysis_export);
            for(int p=0;p<NPORT;p++) vsqr.in_sqr[p]=in_agent[p].sqr;
            vsqr.sink_sqr=sink_sqr;
        endfunction
    endclass

    class noc_router_regress_test extends uvm_test;
        `uvm_component_utils(noc_router_regress_test)
        noc_env env;
        function new(string n,uvm_component p);super.new(n,p);endfunction
        function void build_phase(uvm_phase phase);env=noc_env::type_id::create("env",this);endfunction
        task run_phase(uvm_phase phase);
            noc_regress_vseq vseq;
            phase.raise_objection(this); ref_selfcheck();
            vseq=noc_regress_vseq::type_id::create("vseq");
            vseq.start(env.vsqr); repeat(30) @(posedge env.mon.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
