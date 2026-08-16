// Author: Asresh Kuricheti
// Portable self-checking directed + randomized regression and real VCD capture.
`timescale 1ns/1ps
module tb_axi_read_reorder_dump;
  localparam ADDR_W=16, DATA_W=32, ID_W=2, DEPTH=8, TAG_W=3;
  logic clk=0, rst_n=0;
  logic ar_valid=0, ar_ready; logic [ID_W-1:0] ar_id=0; logic [ADDR_W-1:0] ar_addr=0;
  logic mem_req_valid, mem_req_ready=1; logic [TAG_W-1:0] mem_req_tag;
  logic [ID_W-1:0] mem_req_id; logic [ADDR_W-1:0] mem_req_addr;
  logic mem_rsp_valid=0; logic [TAG_W-1:0] mem_rsp_tag=0;
  logic [DATA_W-1:0] mem_rsp_data=0; logic mem_rsp_error=0;
  logic r_valid, r_ready=1; logic [ID_W-1:0] r_id; logic [DATA_W-1:0] r_data;
  logic r_error; logic [$clog2(DEPTH+1)-1:0] occupancy;
  logic [ADDR_W-1:0] tag_addr[0:DEPTH-1];
  logic tag_pending[0:DEPTH-1];
  logic [32:0] exp0[$], exp1[$], exp2[$], exp3[$];
  integer issued=0, checks=0, errors=0, i, batch, n, pick, tmp;
  integer tags[0:DEPTH-1];
  logic random_backpressure=0;
  always #5 clk=~clk;

  axi_read_reorder #(.ADDR_W(ADDR_W),.DATA_W(DATA_W),.ID_W(ID_W),.DEPTH(DEPTH)) dut(.*);

  function automatic [32:0] golden(input [15:0] addr);
    golden={(addr[5:2]==4'hf),{addr,(addr^16'h5a3c)}};
  endfunction
  task fail(input [8*120-1:0] msg);
    begin $display("ERROR: %0s at %0t",msg,$time); errors=errors+1; end
  endtask
  task push_expected(input [1:0] id,input [15:0] addr);
    begin case(id) 0:exp0.push_back(golden(addr)); 1:exp1.push_back(golden(addr));
      2:exp2.push_back(golden(addr)); 3:exp3.push_back(golden(addr)); endcase end
  endtask
  task issue_read(input [1:0] id,input [15:0] addr,output integer tag);
    begin
      @(negedge clk); ar_id=id; ar_addr=addr; ar_valid=1;
      do @(posedge clk); while(!ar_ready);
      tag=mem_req_tag; tag_addr[tag]=addr; tag_pending[tag]=1;
      push_expected(id,addr); issued=issued+1;
      @(negedge clk); ar_valid=0;
    end
  endtask
  task complete_tag(input integer tag);
    reg [32:0] val;
    begin
      if(!tag_pending[tag]) fail("attempted completion of inactive tag");
      val=golden(tag_addr[tag]);
      @(negedge clk); mem_rsp_tag=tag[TAG_W-1:0]; mem_rsp_error=val[32];
      mem_rsp_data=val[31:0]; mem_rsp_valid=1;
      @(posedge clk); tag_pending[tag]=0;
      @(negedge clk); mem_rsp_valid=0;
    end
  endtask
  task wait_for_all;
    integer guard;
    begin guard=0; while(checks<issued && guard<400) begin @(posedge clk); guard=guard+1; end
      if(checks!=issued) fail("responses did not drain"); end
  endtask

  always @(negedge clk) if(rst_n && random_backpressure) r_ready <= ($urandom_range(0,9)>2);
  always @(posedge clk) begin reg [32:0] exp;
    if(rst_n && r_valid && r_ready) begin
      checks=checks+1;
      case(r_id)
        0: if(exp0.size()) exp=exp0.pop_front(); else begin exp='x; fail("extra ID0 response"); end
        1: if(exp1.size()) exp=exp1.pop_front(); else begin exp='x; fail("extra ID1 response"); end
        2: if(exp2.size()) exp=exp2.pop_front(); else begin exp='x; fail("extra ID2 response"); end
        3: if(exp3.size()) exp=exp3.pop_front(); else begin exp='x; fail("extra ID3 response"); end
      endcase
      if({r_error,r_data}!==exp) begin
        $display("MISMATCH id=%0d expected=%09x got=%09x",r_id,exp,{r_error,r_data}); fail("per-ID response mismatch");
      end
    end
  end

  initial begin
    $dumpfile("tb_axi_read_reorder_dump.vcd"); $dumpvars(0,tb_axi_read_reorder_dump);
    for(i=0;i<DEPTH;i=i+1) tag_pending[i]=0;
    repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
    if(occupancy!==0 || r_valid) fail("reset state");

    // Directed: younger ID0 completions arrive first; ID1 is allowed to bypass.
    issue_read(0,16'h0100,tags[0]);
    issue_read(0,16'h0104,tags[1]);
    issue_read(1,16'h0200,tags[2]);
    issue_read(0,16'h013c,tags[3]);
    issue_read(2,16'h103c,tags[4]);
    complete_tag(tags[1]); complete_tag(tags[3]); complete_tag(tags[2]);
    complete_tag(tags[4]);
    repeat(2) @(posedge clk);
    if(exp0.size()!=3) fail("younger same-ID response escaped before oldest");
    complete_tag(tags[0]);
    random_backpressure=1; wait_for_all();

    // Constrained-random batches: unique tags, mixed IDs, errors, and reverse/random completion order.
    for(batch=0;batch<35;batch=batch+1) begin
      n=$urandom_range(1,DEPTH);
      for(i=0;i<n;i=i+1) issue_read($urandom_range(0,3),{$urandom_range(0,4095),2'b00},tags[i]);
      for(i=n-1;i>0;i=i-1) begin pick=$urandom_range(0,i); tmp=tags[i]; tags[i]=tags[pick]; tags[pick]=tmp; end
      for(i=0;i<n;i=i+1) complete_tag(tags[i]);
      wait_for_all();
    end
    random_backpressure=0; r_ready=1; repeat(5) @(posedge clk);
    if(exp0.size()+exp1.size()+exp2.size()+exp3.size()!=0) fail("golden queues not empty");
    if(occupancy!=0) fail("DUT not empty after regression");
    if(errors==0) $display("RESULT: *** PASS *** (%0d reads checked)",checks);
    else $display("RESULT: *** FAIL *** errors=%0d checks=%0d",errors,checks);
    #10; $finish;
  end
  initial begin #500000; $display("RESULT: *** FAIL *** timeout"); $finish; end
endmodule
