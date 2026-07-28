// -----------------------------------------------------------------------------
// ral_pkg.sv  -  UVM RAL (Register Abstraction Layer) environment for
//                ral_regblock
//
// Demonstrates the standard UVM register-layer flow:
//   * a uvm_reg model (reg_ctrl RW, reg_status RO, reg_intflags W1C,
//     reg_scratch RW) inside a uvm_reg_block with an address map,
//   * a uvm_reg_adapter converting uvm_reg_bus_op <-> apb_txn,
//   * an explicit uvm_reg_predictor fed by the bus monitor,
//   * front-door access (through the map/adapter/sequencer) AND back-door
//     access (peek/poke via HDL paths bound to the DUT storage nodes),
//   * the built-in register sequences uvm_reg_hw_reset_seq and
//     uvm_reg_bit_bash_seq,
//   * register field-value coverage (UVM_CVR_FIELD_VALS).
//
// The bus below reuses a compact APB4 agent (driver/monitor/sequencer).
// -----------------------------------------------------------------------------
package ral_pkg;

    import uvm_pkg::*;
`include "uvm_macros.svh"

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NBYTES     = DATA_WIDTH/8;

    // Byte offsets of the four registers.
    localparam bit [ADDR_WIDTH-1:0] OFF_CTRL   = 8'h00;
    localparam bit [ADDR_WIDTH-1:0] OFF_STATUS = 8'h04;
    localparam bit [ADDR_WIDTH-1:0] OFF_INTF   = 8'h08;
    localparam bit [ADDR_WIDTH-1:0] OFF_SCR    = 8'h0C;

    // =========================================================================
    // Bus transaction (APB)
    // =========================================================================
    class apb_txn extends uvm_sequence_item;
        rand bit                    write;
        rand bit [ADDR_WIDTH-1:0]   addr;
        rand bit [DATA_WIDTH-1:0]   data;
        rand bit [NBYTES-1:0]       strb;
        bit      [DATA_WIDTH-1:0]   rdata;
        bit                         slverr;

        `uvm_object_utils_begin(apb_txn)
            `uvm_field_int(write,  UVM_ALL_ON)
            `uvm_field_int(addr,   UVM_ALL_ON)
            `uvm_field_int(data,   UVM_ALL_ON)
            `uvm_field_int(strb,   UVM_ALL_ON)
            `uvm_field_int(rdata,  UVM_ALL_ON)
            `uvm_field_int(slverr, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "apb_txn");
            super.new(name);
        endfunction
    endclass

    typedef uvm_sequencer #(apb_txn) apb_sequencer;

    // =========================================================================
    // APB driver (two-phase SETUP/ACCESS handshake)
    // =========================================================================
    class apb_driver extends uvm_driver #(apb_txn);
        `uvm_component_utils(apb_driver)
        virtual apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for driver")
        endfunction

        virtual task run_phase(uvm_phase phase);
            drive_idle();
            forever begin
                apb_txn t;
                seq_item_port.get_next_item(t);
                drive_transfer(t);
                seq_item_port.item_done();
            end
        endtask

        task drive_idle();
            vif.drv_cb.PSEL    <= 1'b0;
            vif.drv_cb.PENABLE <= 1'b0;
            vif.drv_cb.PWRITE  <= 1'b0;
            vif.drv_cb.PADDR   <= '0;
            vif.drv_cb.PWDATA  <= '0;
            vif.drv_cb.PSTRB   <= '0;
        endtask

        task drive_transfer(apb_txn t);
            wait (vif.PRESETn === 1'b1);
            @(vif.drv_cb);                       // SETUP
            vif.drv_cb.PSEL    <= 1'b1;
            vif.drv_cb.PENABLE <= 1'b0;
            vif.drv_cb.PWRITE  <= t.write;
            vif.drv_cb.PADDR   <= t.addr;
            vif.drv_cb.PWDATA  <= t.data;
            vif.drv_cb.PSTRB   <= t.write ? t.strb : '0;
            @(vif.drv_cb);                       // ACCESS
            vif.drv_cb.PENABLE <= 1'b1;
            do @(vif.drv_cb); while (vif.drv_cb.PREADY !== 1'b1);
            t.rdata  = vif.drv_cb.PRDATA;
            t.slverr = vif.drv_cb.PSLVERR;
            drive_idle();
        endtask
    endclass

    // =========================================================================
    // APB monitor (reconstructs completed transfers for the predictor)
    // =========================================================================
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual apb_if vif;
        uvm_analysis_port #(apb_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no vif for monitor")
        endfunction
        virtual task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.PRESETn === 1'b1 &&
                    vif.mon_cb.PSEL && vif.mon_cb.PENABLE && vif.mon_cb.PREADY) begin
                    apb_txn t = apb_txn::type_id::create("mon_txn");
                    t.write  = vif.mon_cb.PWRITE;
                    t.addr   = vif.mon_cb.PADDR;
                    t.data   = vif.mon_cb.PWDATA;
                    t.strb   = vif.mon_cb.PSTRB;
                    t.rdata  = vif.mon_cb.PRDATA;
                    t.slverr = vif.mon_cb.PSLVERR;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    // APB agent
    // =========================================================================
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_driver    driver;
        apb_monitor   monitor;
        apb_sequencer sequencer;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = apb_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = apb_driver   ::type_id::create("driver", this);
                sequencer = apb_sequencer::type_id::create("sequencer", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Register model  -  RW / RO / W1C fields, with field-value coverage
    // =========================================================================
    class reg_ctrl extends uvm_reg;                       // RW
        `uvm_object_utils(reg_ctrl)
        rand uvm_reg_field val;
        uvm_reg_data_t m_sample;
        covergroup cg_vals;
            option.per_instance = 1;
            cp_val : coverpoint m_sample[7:0] {
                bins zero    = {8'h00};
                bins allones = {8'hFF};
                bins others  = default;
            }
        endgroup
        function new(string name = "reg_ctrl");
            super.new(name, DATA_WIDTH, build_coverage(UVM_CVR_FIELD_VALS));
            if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
        endfunction
        virtual function void build();
            val = uvm_reg_field::type_id::create("val");
            // configure(parent,size,lsb,access,volatile,reset,has_reset,is_rand,indiv)
            val.configure(this, DATA_WIDTH, 0, "RW", 0, 32'h0, 1, 1, 0);
        endfunction
        virtual function void sample(uvm_reg_data_t data, uvm_reg_byte_en_t byte_en,
                                     bit is_read, uvm_reg_map map);
            super.sample(data, byte_en, is_read, map);
            if (get_coverage(UVM_CVR_FIELD_VALS)) begin m_sample = data; cg_vals.sample(); end
        endfunction
        virtual function void sample_values();
            super.sample_values();
            if (get_coverage(UVM_CVR_FIELD_VALS)) begin m_sample = val.value; cg_vals.sample(); end
        endfunction
    endclass

    class reg_status extends uvm_reg;                     // RO (hardware value)
        `uvm_object_utils(reg_status)
        uvm_reg_field val;
        function new(string name = "reg_status");
            super.new(name, DATA_WIDTH, UVM_NO_COVERAGE);
        endfunction
        virtual function void build();
            val = uvm_reg_field::type_id::create("val");
            val.configure(this, DATA_WIDTH, 0, "RO", 1, 32'hDEAD_BEEF, 1, 0, 0);
        endfunction
    endclass

    class reg_intflags extends uvm_reg;                   // W1C (hardware sets)
        `uvm_object_utils(reg_intflags)
        rand uvm_reg_field flags;
        uvm_reg_data_t m_sample;
        covergroup cg_vals;
            option.per_instance = 1;
            cp_any : coverpoint m_sample[7:0] {
                bins none = {8'h00};
                bins some = {[8'h01:8'hFF]};
            }
        endgroup
        function new(string name = "reg_intflags");
            super.new(name, DATA_WIDTH, build_coverage(UVM_CVR_FIELD_VALS));
            if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
        endfunction
        virtual function void build();
            flags = uvm_reg_field::type_id::create("flags");
            flags.configure(this, DATA_WIDTH, 0, "W1C", 1, 32'h0, 1, 1, 0);
        endfunction
        virtual function void sample(uvm_reg_data_t data, uvm_reg_byte_en_t byte_en,
                                     bit is_read, uvm_reg_map map);
            super.sample(data, byte_en, is_read, map);
            if (get_coverage(UVM_CVR_FIELD_VALS)) begin m_sample = data; cg_vals.sample(); end
        endfunction
        virtual function void sample_values();
            super.sample_values();
            if (get_coverage(UVM_CVR_FIELD_VALS)) begin m_sample = flags.value; cg_vals.sample(); end
        endfunction
    endclass

    class reg_scratch extends uvm_reg;                    // RW
        `uvm_object_utils(reg_scratch)
        rand uvm_reg_field val;
        function new(string name = "reg_scratch");
            super.new(name, DATA_WIDTH, UVM_NO_COVERAGE);
        endfunction
        virtual function void build();
            val = uvm_reg_field::type_id::create("val");
            val.configure(this, DATA_WIDTH, 0, "RW", 0, 32'h0, 1, 1, 0);
        endfunction
    endclass

    // Register block: instantiates the regs, builds a map, binds HDL paths.
    class ral_block extends uvm_reg_block;
        `uvm_object_utils(ral_block)
        rand reg_ctrl     ctrl;
        rand reg_status   status;
        rand reg_intflags intflags;
        rand reg_scratch  scratch;
        uvm_reg_map map;

        function new(string name = "ral_block");
            super.new(name, build_coverage(UVM_CVR_FIELD_VALS));
        endfunction

        virtual function void build();
            ctrl     = reg_ctrl    ::type_id::create("ctrl");
            status   = reg_status  ::type_id::create("status");
            intflags = reg_intflags::type_id::create("intflags");
            scratch  = reg_scratch ::type_id::create("scratch");

            ctrl.configure(this);     ctrl.build();
            status.configure(this);   status.build();
            intflags.configure(this); intflags.build();
            scratch.configure(this);  scratch.build();

            map = create_map("map", 'h0, NBYTES, UVM_LITTLE_ENDIAN, 1);
            map.add_reg(ctrl,     OFF_CTRL,   "RW");
            map.add_reg(status,   OFF_STATUS, "RO");
            map.add_reg(intflags, OFF_INTF,   "RW");
            map.add_reg(scratch,  OFF_SCR,    "RW");

            // Back-door HDL paths -> DUT storage nodes.
            ctrl.add_hdl_path_slice    ("ctrl_q",    0, DATA_WIDTH);
            status.add_hdl_path_slice  ("status_q",  0, DATA_WIDTH);
            intflags.add_hdl_path_slice("intf_q",    0, DATA_WIDTH);
            scratch.add_hdl_path_slice ("scratch_q", 0, DATA_WIDTH);

            lock_model();
        endfunction
    endclass

    // =========================================================================
    // Register adapter  (uvm_reg_bus_op <-> apb_txn)
    // =========================================================================
    class apb_reg_adapter extends uvm_reg_adapter;
        `uvm_object_utils(apb_reg_adapter)
        function new(string name = "apb_reg_adapter");
            super.new(name);
            supports_byte_enable = 0;
            provides_responses   = 0;
        endfunction

        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            apb_txn t = apb_txn::type_id::create("reg2bus");
            t.write = (rw.kind == UVM_WRITE);
            t.addr  = rw.addr;
            t.data  = rw.data;
            t.strb  = '1;
            return t;
        endfunction

        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            apb_txn t;
            if (!$cast(t, bus_item)) begin
                `uvm_fatal("apb_reg_adapter", "bus2reg: item is not apb_txn")
                return;
            end
            rw.kind   = t.write ? UVM_WRITE : UVM_READ;
            rw.addr   = t.addr;
            rw.data   = t.write ? t.data : t.rdata;
            rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
        endfunction
    endclass

    // =========================================================================
    // Environment  -  agent + RAL model + adapter + explicit predictor
    // =========================================================================
    class ral_env extends uvm_env;
        `uvm_component_utils(ral_env)
        apb_agent                    agent;
        ral_block                    model;
        apb_reg_adapter              adapter;
        uvm_reg_predictor #(apb_txn) predictor;
        string                       hdl_root = "tb_top.dut";

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent     = apb_agent::type_id::create("agent", this);
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_txn)::type_id::create("predictor", this);
            if (model == null) begin
                model = ral_block::type_id::create("model");
                model.build();
                model.set_hdl_path_root(hdl_root);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            // Front-door: bind the map to the bus sequencer through the adapter.
            model.map.set_sequencer(agent.sequencer, adapter);
            // Use explicit prediction (predictor) rather than auto-predict.
            model.map.set_auto_predict(0);
            predictor.map     = model.map;
            predictor.adapter = adapter;
            agent.monitor.ap.connect(predictor.bus_in);
        endfunction
    endclass

    // =========================================================================
    // Tests
    // =========================================================================
    class ral_base_test extends uvm_test;
        `uvm_component_utils(ral_base_test)
        ral_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            // Enable register field-value coverage before the model is built.
            void'(uvm_reg::include_coverage("*", UVM_CVR_FIELD_VALS));
            env = ral_env::type_id::create("env", this);
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    // Built-in: read every register and confirm its hardware reset value.
    class ral_hw_reset_test extends ral_base_test;
        `uvm_component_utils(ral_hw_reset_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            uvm_reg_hw_reset_seq seq = uvm_reg_hw_reset_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.model = env.model;
            seq.start(null);
            phase.drop_objection(this);
        endtask
    endclass

    // Built-in: walk 0/1 through every writable bit, honouring RW/RO/W1C.
    class ral_bit_bash_test extends ral_base_test;
        `uvm_component_utils(ral_bit_bash_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            uvm_reg_bit_bash_seq seq = uvm_reg_bit_bash_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.model = env.model;
            seq.start(null);
            phase.drop_objection(this);
        endtask
    endclass

    // Directed: front-door write/read + back-door peek/poke round-trips.
    class ral_frontback_test extends ral_base_test;
        `uvm_component_utils(ral_frontback_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        virtual task run_phase(uvm_phase phase);
            uvm_status_e   st;
            uvm_reg_data_t rd;
            phase.raise_objection(this);

            env.model.reset();

            // ---- Front-door RW round-trip on CTRL ----
            env.model.ctrl.write(st, 32'h1234_5678);
            env.model.ctrl.read (st, rd);
            if (rd !== 32'h1234_5678)
                `uvm_error(get_type_name(), $sformatf(
                    "front-door CTRL read 0x%08h != 0x12345678", rd))

            // ---- Front-door RO: STATUS keeps its hardware value ----
            env.model.status.read(st, rd);
            if (rd !== 32'hDEAD_BEEF)
                `uvm_error(get_type_name(), $sformatf(
                    "STATUS read 0x%08h != 0xDEADBEEF", rd))

            // ---- Back-door poke/peek on SCRATCH ----
            env.model.scratch.poke(st, 32'hA5A5_5A5A);
            env.model.scratch.peek(st, rd);
            if (rd !== 32'hA5A5_5A5A)
                `uvm_error(get_type_name(), $sformatf(
                    "back-door SCRATCH peek 0x%08h != 0xA5A55A5A", rd))

            // Front-door read must now agree with the back-door value.
            env.model.scratch.read(st, rd);
            if (rd !== 32'hA5A5_5A5A)
                `uvm_error(get_type_name(), $sformatf(
                    "front-door SCRATCH read 0x%08h != back-door 0xA5A55A5A", rd))

            phase.drop_objection(this);
        endtask
    endclass

endpackage
