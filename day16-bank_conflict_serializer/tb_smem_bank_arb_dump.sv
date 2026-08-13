// -----------------------------------------------------------------------------
// tb_smem_bank_arb_dump.sv - portable, module-based, SELF-CHECKING testbench for
// the GPU shared-memory bank-conflict serializer. Runs on open-source Icarus
// Verilog (which does not implement the UVM class library). It:
//
//   * drives a DIRECTED SHOWCASE - an 8-lane warp whose addresses give bank 0 a
//     3-way conflict WITH a broadcast pair, while four other banks are served in
//     parallel, so the captured VCD tells the classic bank-conflict story
//     (served 0xF9 -> 0x02 -> 0x04 across 3 phases),
//   * runs DIRECTED CORNERS (conflict-free 8-way, full 8-lane broadcast,
//     worst-case 8-way serialized conflict, partial active mask, single lane,
//     and an all-inactive request that still emits one empty phase),
//   * runs a CONSTRAINED-RANDOM regression of random masks/addresses while a
//     golden reference model computes the expected phase stream,
//   * checks the DUT's {ph_served, ph_bank_use, ph_last, ph_index} and the total
//     phase count against the golden model for every request,
//   * dumps a VCD for the waveform image,
//   * enforces a global timeout,
//   * prints "RESULT: *** PASS ***" only if every check passed.
//
// The full UVM environment (agent/driver/monitor/scoreboard/coverage/virtual
// sequences + SVA) lives in smem_bank_arb_pkg.sv + tb_top.sv for a UVM-capable
// simulator; this file exists so the design can be genuinely simulated (and a
// real waveform captured) with a freely available toolchain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_smem_bank_arb_dump;

    localparam int NLANES = 8;
    localparam int NBANKS = 8;
    localparam int ADDR_W = 16;
    localparam int PH_W   = $clog2(NLANES + 1);
    localparam int MAXP   = NLANES;   // worst-case phases = one lane per bank slot

    logic                     clk;
    logic                     rst_n;
    logic                     req_valid;
    logic                     req_ready;
    logic [NLANES-1:0]        req_mask;
    logic [NLANES*ADDR_W-1:0] req_addr;
    logic                     ph_valid;
    logic [NLANES-1:0]        ph_served;
    logic [NBANKS-1:0]        ph_bank_use;
    logic                     ph_last;
    logic [PH_W-1:0]          ph_index;
    logic                     busy;

    integer errors = 0;
    integer checks = 0;

    // ---- current request (unpacked; the driver packs it into req_addr) -------
    logic [NLANES-1:0] req_mask_cur;
    logic [ADDR_W-1:0] req_addr_arr [0:NLANES-1];

    // ---- golden expected phase stream ---------------------------------------
    logic [NLANES-1:0] g_served  [0:MAXP-1];
    logic [NBANKS-1:0] g_bankuse [0:MAXP-1];
    integer            gnp;

    // ---------------------------------------------------------------- DUT -----
    smem_bank_arb #(.NLANES(NLANES), .NBANKS(NBANKS), .ADDR_W(ADDR_W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (req_valid),
        .req_ready  (req_ready),
        .req_mask   (req_mask),
        .req_addr   (req_addr),
        .ph_valid   (ph_valid),
        .ph_served  (ph_served),
        .ph_bank_use(ph_bank_use),
        .ph_last    (ph_last),
        .ph_index   (ph_index),
        .busy       (busy)
    );

    // -------------------------------------------------------------- clock -----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---------------------------------------- golden reference model ----------
    // Compute the expected phase stream for {req_mask_cur, req_addr_arr}:
    // one distinct address per bank per phase, lowest-index pending lane wins,
    // all same-address pending lanes served together (broadcast).
    task golden_compute;
        integer p, l, b, bnk;
        reg [NLANES-1:0] pend;
        reg [NBANKS-1:0] bhit;
        reg [ADDR_W-1:0] waddr [0:NBANKS-1];
        reg [NLANES-1:0] serv;
        begin
            pend = req_mask_cur;
            if (pend == 0) begin
                g_served[0]  = '0;
                g_bankuse[0] = '0;
                gnp          = 1;                 // empty request -> one empty phase
            end else begin
                p = 0;
                while (pend != 0) begin
                    bhit = '0;
                    for (b = 0; b < NBANKS; b = b + 1) waddr[b] = '0;
                    for (l = 0; l < NLANES; l = l + 1) begin
                        if (pend[l]) begin
                            bnk = req_addr_arr[l] % NBANKS;
                            if (!bhit[bnk]) begin
                                bhit[bnk]  = 1'b1;
                                waddr[bnk] = req_addr_arr[l];
                            end
                        end
                    end
                    serv = '0;
                    for (l = 0; l < NLANES; l = l + 1) begin
                        bnk = req_addr_arr[l] % NBANKS;
                        if (pend[l] && bhit[bnk] && (req_addr_arr[l] == waddr[bnk]))
                            serv[l] = 1'b1;
                    end
                    g_served[p]  = serv;
                    g_bankuse[p] = bhit;
                    pend         = pend & ~serv;
                    p            = p + 1;
                end
                gnp = p;
            end
        end
    endtask

    // --------------------------------------- drive one request + check --------
    task run_req;
        integer k, l;
        reg     done, exp_last;
        begin
            golden_compute();
            for (l = 0; l < NLANES; l = l + 1)
                req_addr[l*ADDR_W +: ADDR_W] = req_addr_arr[l];

            // present the request on a cycle where the block is idle/ready
            @(negedge clk);
            while (req_ready !== 1'b1) @(negedge clk);
            req_mask  = req_mask_cur;
            req_valid = 1'b1;
            @(negedge clk);          // the posedge in between latched it
            req_valid = 1'b0;

            // collect the serialized phase beats
            k = 0; done = 1'b0;
            while (!done) begin
                @(negedge clk);
                if (ph_valid === 1'b1) begin
                    checks = checks + 1;
                    if (k >= gnp) begin
                        errors = errors + 1;
                        $display("[%0t] EXTRA phase beat k=%0d exp count=%0d", $time, k, gnp);
                    end else begin
                        if (ph_served !== g_served[k]) begin
                            errors = errors + 1;
                            $display("[%0t] SERVED MISMATCH phase %0d got %b exp %b",
                                     $time, k, ph_served, g_served[k]);
                        end
                        if (ph_bank_use !== g_bankuse[k]) begin
                            errors = errors + 1;
                            $display("[%0t] BANK_USE MISMATCH phase %0d got %b exp %b",
                                     $time, k, ph_bank_use, g_bankuse[k]);
                        end
                        exp_last = (k == (gnp - 1));
                        if (ph_last !== exp_last) begin
                            errors = errors + 1;
                            $display("[%0t] LAST MISMATCH phase %0d got %b exp %b",
                                     $time, k, ph_last, exp_last);
                        end
                        if (ph_index !== k[PH_W-1:0]) begin
                            errors = errors + 1;
                            $display("[%0t] INDEX MISMATCH phase %0d got %0d exp %0d",
                                     $time, k, ph_index, k);
                        end
                    end
                    if (ph_last === 1'b1) done = 1'b1;
                    k = k + 1;
                end
            end
            if (k !== gnp) begin
                errors = errors + 1;
                $display("[%0t] PHASE COUNT MISMATCH got %0d exp %0d", $time, k, gnp);
            end
        end
    endtask

    // helper: load a request from the eight per-lane addresses
    task set_req(input [NLANES-1:0] m,
                 input [ADDR_W-1:0] a0, input [ADDR_W-1:0] a1,
                 input [ADDR_W-1:0] a2, input [ADDR_W-1:0] a3,
                 input [ADDR_W-1:0] a4, input [ADDR_W-1:0] a5,
                 input [ADDR_W-1:0] a6, input [ADDR_W-1:0] a7);
        begin
            req_mask_cur   = m;
            req_addr_arr[0]=a0; req_addr_arr[1]=a1; req_addr_arr[2]=a2; req_addr_arr[3]=a3;
            req_addr_arr[4]=a4; req_addr_arr[5]=a5; req_addr_arr[6]=a6; req_addr_arr[7]=a7;
        end
    endtask

    // -------------------------------------------------------- stimulus --------
    integer w, l;

    initial begin
        req_valid = 1'b0; req_mask = '0; req_addr = '0;
        req_mask_cur = '0;
        for (l = 0; l < NLANES; l = l + 1) req_addr_arr[l] = '0;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("==== DIRECTED SHOWCASE (3-way bank-0 conflict + broadcast) ====");
        // bank = addr % 8.  lanes 0&3 -> addr 0x00 (broadcast), lane1 0x08,
        // lane2 0x10 (bank-0 3-way conflict); lanes 4..7 -> banks 1..4 (parallel)
        set_req(8'hFF, 16'h0000, 16'h0008, 16'h0010, 16'h0000,
                       16'h0001, 16'h0002, 16'h0003, 16'h0004);
        run_req();   // expect phases: served 0xF9, 0x02, 0x04  (3 phases)

        $display("==== DIRECTED CORNERS ====");
        // conflict-free: eight lanes to eight distinct banks -> 1 phase
        set_req(8'hFF, 16'h0000, 16'h0001, 16'h0002, 16'h0003,
                       16'h0004, 16'h0005, 16'h0006, 16'h0007);
        run_req();
        // full broadcast: all lanes hit the SAME address -> 1 phase, all served
        set_req(8'hFF, 16'h0100, 16'h0100, 16'h0100, 16'h0100,
                       16'h0100, 16'h0100, 16'h0100, 16'h0100);
        run_req();
        // worst-case: all eight lanes to bank 0 with distinct addresses -> 8 phases
        set_req(8'hFF, 16'h0000, 16'h0008, 16'h0010, 16'h0018,
                       16'h0020, 16'h0028, 16'h0030, 16'h0038);
        run_req();
        // partial active mask (lanes 0,2,4,6) with a 2-way conflict on bank 0
        set_req(8'b01010101, 16'h0000, 16'h0, 16'h0008, 16'h0,
                             16'h0002, 16'h0, 16'h0003, 16'h0);
        run_req();
        // single active lane
        set_req(8'b00010000, 16'h0, 16'h0, 16'h0, 16'h0,
                             16'h0AA0, 16'h0, 16'h0, 16'h0);
        run_req();
        // all-inactive request -> one empty phase (served=0, last=1)
        set_req(8'h00, 16'h0, 16'h0, 16'h0, 16'h0, 16'h0, 16'h0, 16'h0, 16'h0);
        run_req();

        $display("==== CONSTRAINED-RANDOM REGRESSION ====");
        for (w = 0; w < 400; w = w + 1) begin
            req_mask_cur = $urandom;                 // any mask incl. 0
            for (l = 0; l < NLANES; l = l + 1)
                req_addr_arr[l] = $urandom_range(0, 63);  // stress bank aliasing
            run_req();
        end

        repeat (4) @(negedge clk);
        $display("==== SUMMARY : %0d checks, %0d errors ====", checks, errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // -------------------------------------------------------- timeout ---------
    initial begin
        #2000000;   // 2 ms global watchdog
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

    // ---------------------------------------------------------- dump ----------
    initial begin
        $dumpfile("tb_smem_bank_arb_dump.vcd");
        $dumpvars(0, tb_smem_bank_arb_dump);
    end

endmodule

`default_nettype wire
