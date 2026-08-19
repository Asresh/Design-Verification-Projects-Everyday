// Author: Asresh Kuricheti
// Portable self-checking companion testbench used by Icarus and waveform capture.
`timescale 1ns/1ps
module tb_page_table_walker_dump;
  localparam bit[21:0] ROOT_PPN=22'h00100;
  logic clk=0,rst_n=0;always #5 clk=~clk;
  logic[21:0]root_ppn=ROOT_PPN;logic req_valid,req_ready;logic[31:0]req_vaddr;logic[1:0]req_access;logic req_user;
  logic mem_req_valid,mem_req_ready;logic[33:0]mem_req_addr;logic mem_rsp_valid;logic[31:0]mem_rsp_pte;
  logic rsp_valid,rsp_ready;logic[33:0]rsp_paddr;logic rsp_fault;logic[1:0]rsp_fault_code;logic rsp_leaf_level;
  integer checks=0,successes=0,invalid_faults=0,permission_faults=0,misaligned_faults=0,l1_leaves=0,l0_leaves=0;
  page_table_walker dut(.*);

  function automatic logic[31:0] mkpte(input logic[21:0]ppn,input logic v,r,w,x,u,a,d);
    mkpte={ppn,2'b0,d,a,1'b0,u,x,w,r,v};
  endfunction
  function automatic logic pte_invalid(input logic[31:0]p);pte_invalid=!p[0]||(!p[1]&&p[2]);endfunction
  function automatic logic pte_leaf(input logic[31:0]p);pte_leaf=p[1]||p[3];endfunction
  function automatic logic permit(input logic[31:0]p,input logic[1:0]a,input logic u);
    logic ok;begin case(a)0:ok=p[1];1:ok=p[2];2:ok=p[3];default:ok=0;endcase
      permit=ok&&p[6]&&(!u||p[4])&&((a!=1)||p[7]);end
  endfunction

  task automatic serve_pte(input logic[33:0]expected_addr,input logic[31:0]pte,input integer req_stall,input integer rsp_delay);
    begin
      repeat(req_stall)@(negedge clk);mem_req_ready=1;
      do @(posedge clk);while(!mem_req_valid);
      if(mem_req_addr!==expected_addr)$fatal(1,"PTE address mismatch exp=%09x got=%09x",expected_addr,mem_req_addr);
      #1;mem_req_ready=0;
      repeat(rsp_delay)@(negedge clk);mem_rsp_pte=pte;mem_rsp_valid=1;
      @(posedge clk);#1;mem_rsp_valid=0;
    end
  endtask

  task automatic do_walk(
    input logic[31:0]va,input logic[1:0]access,input logic user_mode,
    input logic[31:0]pte1,input logic has_pte0,input logic[31:0]pte0,input integer seed
  );
    logic[33:0]exp_pa,exp_l1_addr,exp_l0_addr;logic exp_fault,exp_level;logic[1:0]exp_code;
    begin
      exp_pa='0;exp_fault=0;exp_code=0;exp_level=1;
      if(pte_invalid(pte1))begin exp_fault=1;exp_code=1;end
      else if(pte_leaf(pte1))begin
        if(pte1[19:10]!=0)begin exp_fault=1;exp_code=3;end
        else if(!permit(pte1,access,user_mode))begin exp_fault=1;exp_code=2;end
        else exp_pa={pte1[31:20],va[21:0]};
      end else begin
        exp_level=0;
        if(!has_pte0||pte_invalid(pte0)||!pte_leaf(pte0))begin exp_fault=1;exp_code=1;end
        else if(!permit(pte0,access,user_mode))begin exp_fault=1;exp_code=2;end
        else exp_pa={pte0[31:10],va[11:0]};
      end
      @(negedge clk);req_vaddr=va;req_access=access;req_user=user_mode;req_valid=1;rsp_ready=0;
      do @(posedge clk);while(!req_ready);#1;req_valid=0;
      exp_l1_addr={ROOT_PPN,12'b0}+{22'b0,va[31:22],2'b0};
      serve_pte(exp_l1_addr,pte1,seed%3,(seed/3)%3);
      if(!pte_invalid(pte1)&&!pte_leaf(pte1))begin
        exp_l0_addr={pte1[31:10],12'b0}+{22'b0,va[21:12],2'b0};
        serve_pte(exp_l0_addr,pte0,(seed/5)%3,(seed/7)%3);
      end
      repeat((seed/11)%3)@(negedge clk);rsp_ready=1;
      do @(posedge clk);while(!rsp_valid);
      checks=checks+1;
      if(rsp_paddr!==exp_pa||rsp_fault!==exp_fault||rsp_fault_code!==exp_code||rsp_leaf_level!==exp_level)
        $fatal(1,"walk mismatch va=%08x pa=%09x/%09x fault=%0b/%0b code=%0d/%0d level=%0b/%0b",va,rsp_paddr,exp_pa,rsp_fault,exp_fault,rsp_fault_code,exp_code,rsp_leaf_level,exp_level);
      if(!exp_fault)begin successes=successes+1;if(exp_level)l1_leaves=l1_leaves+1;else l0_leaves=l0_leaves+1;end
      else case(exp_code)1:invalid_faults=invalid_faults+1;2:permission_faults=permission_faults+1;3:misaligned_faults=misaligned_faults+1;endcase
      #1;rsp_ready=0;@(negedge clk);
    end
  endtask

  initial begin integer n,kind;logic[31:0]va,p1,p0;logic[21:0]table_ppn,leaf_ppn;logic[1:0]access;logic user_mode;
    $dumpfile("tb_page_table_walker_dump.vcd");$dumpvars(0,tb_page_table_walker_dump);
    req_valid=0;req_vaddr=0;req_access=0;req_user=0;mem_req_ready=0;mem_rsp_valid=0;mem_rsp_pte=0;rsp_ready=0;
    repeat(4)@(posedge clk);rst_n=1;
    // Directed: 4 KiB read, 4 MiB execute, invalid PTE, dirty-bit write fault,
    // user permission fault, and misaligned superpage.
    do_walk(32'h1234_5678,0,1,mkpte(22'h00200,1,0,0,0,0,0,0),1,mkpte(22'h12345,1,1,1,0,1,1,1),1);
    do_walk(32'h4080_0120,2,0,mkpte(22'h28000,1,1,0,1,0,1,0),0,0,2);
    do_walk(32'h2000_1000,0,0,0,0,0,3);
    do_walk(32'h2000_2000,1,1,mkpte(22'h00210,1,0,0,0,0,0,0),1,mkpte(22'h23456,1,1,1,0,1,1,0),4);
    do_walk(32'h3000_3000,0,1,mkpte(22'h00220,1,0,0,0,0,0,0),1,mkpte(22'h34567,1,1,0,0,0,1,0),5);
    do_walk(32'h5000_4000,0,0,mkpte(22'h28001,1,1,0,0,0,1,0),0,0,6);
    for(n=0;n<200;n=n+1)begin
      va=$urandom;access=$urandom_range(0,2);user_mode=$urandom_range(0,1);kind=$urandom_range(0,6);
      table_ppn=$urandom_range(22'h00300,22'h003ff);leaf_ppn=$urandom;
      case(kind)
        0:p1=0;
        1:begin leaf_ppn[9:0]=0;p1=mkpte(leaf_ppn,1,1,0,1,1,1,0);end
        2:begin leaf_ppn[9:0]=0;p1=mkpte(leaf_ppn,1,1,1,1,1,1,1);end
        default:p1=mkpte(table_ppn,1,0,0,0,0,0,0);
      endcase
      case(kind)
        3:p0=0;
        4:p0=mkpte(leaf_ppn,1,1,0,0,0,1,0);
        5:p0=mkpte(leaf_ppn,1,1,1,0,1,1,0);
        default:p0=mkpte(leaf_ppn,1,1,1,1,1,1,1);
      endcase
      do_walk(va,access,user_mode,p1,!((kind==0)||(kind==1)||(kind==2)),p0,n+9);
    end
    if(l1_leaves==0||l0_leaves==0||invalid_faults==0||permission_faults==0||misaligned_faults==0)$fatal(1,"coverage intent not reached");
    $display("PTW checks=%0d success=%0d L1=%0d L0=%0d invalid=%0d permission=%0d misaligned=%0d",checks,successes,l1_leaves,l0_leaves,invalid_faults,permission_faults,misaligned_faults);
    $display("RESULT: *** PASS ***");#10;$finish;
  end
  initial begin #1000000;$fatal(1,"PTW timeout");end
endmodule
