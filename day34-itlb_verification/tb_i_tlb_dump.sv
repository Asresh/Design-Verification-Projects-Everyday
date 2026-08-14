// Author: Asresh Kuricheti
// Portable self-checking companion testbench used by Icarus and waveform capture.
`timescale 1ns/1ps
module tb_i_tlb_dump;
    localparam ENTRIES=8; localparam VA_W=32;localparam PA_W=32;localparam ASID_W=8;
    logic clk=0,rst_n=0;always #5 clk=~clk;
    logic query_valid;logic[31:0]query_vaddr;logic[7:0]query_asid;logic query_hit,query_exec_fault;logic[31:0]query_paddr;logic[2:0]query_index;
    logic fill_valid;logic[31:0]fill_vaddr,fill_paddr;logic[7:0]fill_asid;logic fill_global,fill_superpage,fill_exec;
    logic inv_valid,inv_all,inv_asid_valid;logic[7:0]inv_asid;logic inv_vaddr_valid;logic[31:0]inv_vaddr;
    i_tlb #(.ENTRIES(ENTRIES)) dut(.*);

    logic ref_valid[ENTRIES];logic[31:0]ref_va[ENTRIES],ref_pa[ENTRIES];logic[7:0]ref_asid[ENTRIES];
    logic ref_global[ENTRIES],ref_super[ENTRIES],ref_exec[ENTRIES];
    integer ref_replace=0,checks=0,hits=0,misses=0,faults=0,invalidations=0;

    function automatic logic page_match(input logic[31:0] a,b,input logic superpage);
        page_match=superpage?(a[31:21]==b[31:21]):(a[31:12]==b[31:12]);
    endfunction
    function automatic logic[31:0] ref_translate(input logic[31:0] base,va,input logic superpage);
        ref_translate=superpage?{base[31:21],va[20:0]}:{base[31:12],va[11:0]};
    endfunction

    task automatic ref_fill(input logic[31:0] va,pa,input logic[7:0] asid,input logic g,s,x);
        integer victim,i;logic found;begin victim=ref_replace;found=0;
            for(i=0;i<ENTRIES;i=i+1)if(!found&&!ref_valid[i])begin victim=i;found=1;end
            ref_valid[victim]=1;ref_va[victim]=va;ref_pa[victim]=pa;ref_asid[victim]=asid;
            ref_global[victim]=g;ref_super[victim]=s;ref_exec[victim]=x;ref_replace=(victim==ENTRIES-1)?0:victim+1;
        end
    endtask
    task automatic do_fill(input logic[31:0] va,pa,input logic[7:0] asid,input logic g,s,x);
        begin @(negedge clk);fill_valid=1;fill_vaddr=va;fill_paddr=pa;fill_asid=asid;fill_global=g;fill_superpage=s;fill_exec=x;
            @(posedge clk);#1;ref_fill(va,pa,asid,g,s,x);@(negedge clk);fill_valid=0;end
    endtask
    task automatic do_query(input logic[31:0] va,input logic[7:0] asid);
        integer i,match;logic[31:0]exp_pa;logic exp_fault;begin
            @(negedge clk);query_valid=1;query_vaddr=va;query_asid=asid;#1;match=-1;
            for(i=0;i<ENTRIES;i=i+1)if(match<0&&ref_valid[i]&&(ref_global[i]||ref_asid[i]==asid)&&page_match(ref_va[i],va,ref_super[i]))match=i;
            checks=checks+1;
            if(query_hit!==(match>=0))$fatal(1,"hit mismatch VA=%08x ASID=%02x exp=%0d got=%0b",va,asid,match>=0,query_hit);
            if(match>=0)begin hits=hits+1;exp_pa=ref_translate(ref_pa[match],va,ref_super[match]);exp_fault=!ref_exec[match];
                if(query_paddr!==exp_pa)$fatal(1,"translation mismatch VA=%08x exp=%08x got=%08x",va,exp_pa,query_paddr);
                if(query_exec_fault!==exp_fault)$fatal(1,"permission mismatch VA=%08x",va);if(exp_fault)faults=faults+1;
            end else begin misses=misses+1;if(query_exec_fault)$fatal(1,"permission fault on miss");end
            @(negedge clk);query_valid=0;
        end
    endtask
    task automatic do_inv(input logic all,input logic asid_en,input logic[7:0] asid,input logic va_en,input logic[31:0] va);
        integer i;begin @(negedge clk);inv_valid=1;inv_all=all;inv_asid_valid=asid_en;inv_asid=asid;inv_vaddr_valid=va_en;inv_vaddr=va;
            @(posedge clk);#1;for(i=0;i<ENTRIES;i=i+1)if(ref_valid[i]&&(all||((!asid_en||(!ref_global[i]&&ref_asid[i]==asid))&&(!va_en||page_match(ref_va[i],va,ref_super[i])))))ref_valid[i]=0;
            invalidations=invalidations+1;@(negedge clk);inv_valid=0;
        end
    endtask

    initial begin integer i,n,slot;logic[31:0]va,pa;logic[7:0]asid;logic g,s,x;
        $dumpfile("tb_i_tlb_dump.vcd");$dumpvars(0,tb_i_tlb_dump);
        query_valid=0;fill_valid=0;inv_valid=0;inv_all=0;inv_asid_valid=0;inv_vaddr_valid=0;
        for(i=0;i<ENTRIES;i=i+1)ref_valid[i]=0;
        repeat(4)@(posedge clk);rst_n=1;
        do_query(32'h0040_1234,8'h11);
        do_fill(32'h0040_1000,32'h1040_1000,8'h11,0,0,1);
        do_query(32'h0040_1abc,8'h11);do_query(32'h0040_1abc,8'h22);
        do_fill(32'h0080_0000,32'h2080_0000,8'h22,1,1,1);
        do_query(32'h009a_bcde,8'h99);
        do_fill(32'h00c0_0000,32'h30c0_0000,8'h11,0,0,0);
        do_query(32'h00c0_0040,8'h11);
        do_inv(0,1,8'h11,1,32'h0040_1000);do_query(32'h0040_1234,8'h11);
        do_inv(1,0,0,0,0);do_query(32'h009a_bcde,8'h99);
        for(n=0;n<300;n=n+1)begin
            if(n%5==0)begin
                va={$urandom,12'b0};pa={$urandom,12'b0};asid=$urandom_range(0,7);g=($urandom_range(0,7)==0);s=($urandom_range(0,7)==0);x=($urandom_range(0,7)!=0);
                if(s)begin va[20:0]=0;pa[20:0]=0;end do_fill(va,pa,asid,g,s,x);
            end else if(n%29==0)do_inv(0,1,$urandom_range(0,7),0,0);
            else begin slot=$urandom_range(0,ENTRIES-1);if(ref_valid[slot]&&n%3!=0)begin va=ref_va[slot]|(ref_super[slot]?$urandom_range(0,21'h1fffff):$urandom_range(0,12'hfff));asid=ref_global[slot]?$urandom_range(0,7):ref_asid[slot];end
                else begin va=$urandom;asid=$urandom_range(0,7);end do_query(va,asid);
            end
        end
        do_inv(1,0,0,0,0);do_query(32'h0040_1000,8'h11);
        $display("TLB checks=%0d hits=%0d misses=%0d permission_faults=%0d invalidations=%0d",checks,hits,misses,faults,invalidations);
        $display("RESULT: *** PASS ***");#10;$finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
