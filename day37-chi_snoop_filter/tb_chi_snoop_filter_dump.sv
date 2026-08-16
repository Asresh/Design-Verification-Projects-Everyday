// Author: Asresh Kuricheti
// Portable self-checking regression and VCD source used for the checked-in image.
module tb_chi_snoop_filter_dump;
  logic clk=0,rst_n=0,req_valid,rsp_ready;logic[1:0]req_node,req_op;logic[15:0]req_addr;wire req_ready,rsp_valid,dir_hit,snoop_valid,snoop_invalidate;wire[3:0]old_sharers,snoop_mask,new_sharers;
  chi_snoop_filter dut(.*);always #5 clk=~clk;
  bit valid[8],dirty[8];bit[15:0]tag[8];bit[3:0]sh[8];bit[1:0]owner[8];integer repl=0,checks=0,errors=0;
  task automatic transact(input[1:0]op,input[1:0]node,input[15:0]addr,input integer stall);
    integer i,h,f,sel;bit[3:0]b,oldm,newm,sm;bit ehit,esv,einv;
    begin h=-1;f=-1;for(i=0;i<8;i=i+1)begin if(valid[i]&&tag[i]==addr)h=i;if(!valid[i]&&f<0)f=i;end b=4'b1<<node;oldm=(h>=0)?sh[h]:0;sm=0;newm=oldm;sel=(h>=0)?h:((f>=0)?f:repl);
      case(op)0:begin if(h>=0&&dirty[h]&&owner[h]!=node)sm=oldm&~b;newm=oldm|b;valid[sel]=1;tag[sel]=addr;sh[sel]=newm;dirty[sel]=0;end 1:begin sm=oldm&~b;newm=b;valid[sel]=1;tag[sel]=addr;sh[sel]=b;dirty[sel]=1;owner[sel]=node;end default:begin newm=oldm&~b;if(h>=0)begin sh[h]=newm;if(!newm)begin valid[h]=0;dirty[h]=0;end else if(dirty[h]&&owner[h]==node)dirty[h]=0;end end endcase
      if(h<0&&f<0&&op!=2)repl=(repl+1)%8;ehit=h>=0;esv=|sm;einv=(op==1)&&esv;
      @(negedge clk);req_valid=1;req_op=op;req_node=node;req_addr=addr;while(!req_ready)@(negedge clk);@(negedge clk);req_valid=0;rsp_ready=0;repeat(stall)@(negedge clk);rsp_ready=1;@(posedge clk);#1;checks++;
      if({dir_hit,old_sharers,snoop_valid,snoop_mask,snoop_invalidate,new_sharers}!={ehit,oldm,esv,sm,einv,newm})begin $display("ERROR op=%0d node=%0d addr=%h exp=%b got=%b",op,node,addr,{ehit,oldm,esv,sm,einv,newm},{dir_hit,old_sharers,snoop_valid,snoop_mask,snoop_invalidate,new_sharers});errors++;end
    end
  endtask
  integer k;initial begin $dumpfile("tb_chi_snoop_filter_dump.vcd");$dumpvars(0,tb_chi_snoop_filter_dump);req_valid=0;rsp_ready=0;repeat(3)@(posedge clk);rst_n=1;
    transact(0,0,16'h1000,0);transact(0,1,16'h1000,0);transact(1,2,16'h1000,2);transact(0,3,16'h1000,0);transact(2,2,16'h1000,0);transact(1,1,16'h1000,1);
    for(k=0;k<120;k=k+1)transact($urandom_range(2,0),$urandom_range(3,0),16'h2000+($urandom_range(7,0)<<2),$urandom_range(2,0));
    if(errors==0)$display("RESULT: *** PASS *** (%0d coherent operations checked)",checks);else $display("RESULT: *** FAIL *** (%0d errors)",errors);#20;$finish;end
  initial begin #200000;$fatal(1,"timeout");end
endmodule
