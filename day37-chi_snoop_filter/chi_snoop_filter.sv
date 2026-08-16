// Author: Asresh Kuricheti
// Parameterized coherent-interconnect snoop filter / directory slice.
module chi_snoop_filter #(
  parameter int ADDR_W=16, NODES=4, ENTRIES=8,
  parameter int NODE_W=$clog2(NODES), IDX_W=$clog2(ENTRIES)
) (
  input logic clk, rst_n,
  input logic req_valid, output logic req_ready,
  input logic [NODE_W-1:0] req_node,
  input logic [ADDR_W-1:0] req_addr,
  input logic [1:0] req_op, // 0=ReadShared, 1=ReadUnique, 2=Evict
  output logic rsp_valid, input logic rsp_ready,
  output logic dir_hit,
  output logic [NODES-1:0] old_sharers,
  output logic snoop_valid, output logic [NODES-1:0] snoop_mask,
  output logic snoop_invalidate, output logic [NODES-1:0] new_sharers
);
  localparam logic [1:0] READ_SHARED=2'd0, READ_UNIQUE=2'd1, EVICT=2'd2;
  logic valid [ENTRIES];
  logic [ADDR_W-1:0] tag [ENTRIES];
  logic [NODES-1:0] sharers [ENTRIES];
  logic dirty [ENTRIES];
  logic [NODE_W-1:0] owner [ENTRIES];
  logic [IDX_W-1:0] replace_ptr;
  integer i, hit_idx, free_idx, sel;
  logic found, free_found;
  logic [NODES-1:0] prior, next_mask, req_bit, targets;

  assign req_ready = ~rsp_valid | rsp_ready;
  always_comb begin
    found=0; free_found=0; hit_idx=0; free_idx=0;
    for(i=0;i<ENTRIES;i=i+1) begin
      if(valid[i] && tag[i]==req_addr) begin found=1; hit_idx=i; end
      if(!valid[i] && !free_found) begin free_found=1; free_idx=i; end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rsp_valid<=0; dir_hit<=0; old_sharers<='0; snoop_valid<=0;
      snoop_mask<='0; snoop_invalidate<=0; new_sharers<='0; replace_ptr<='0;
      for(i=0;i<ENTRIES;i=i+1) begin valid[i]<=0; tag[i]<='0; sharers[i]<='0; dirty[i]<=0; owner[i]<='0; end
    end else begin
      if(rsp_valid && rsp_ready) rsp_valid<=0;
      if(req_valid && req_ready) begin
        req_bit={{(NODES-1){1'b0}},1'b1} << req_node;
        prior=found ? sharers[hit_idx] : '0;
        targets='0; next_mask=prior; sel=found ? hit_idx : (free_found ? free_idx : replace_ptr);
        dir_hit<=found; old_sharers<=prior; snoop_invalidate<=0;
        case(req_op)
          READ_SHARED: begin
            if(found && dirty[hit_idx] && owner[hit_idx]!=req_node) targets=prior & ~req_bit;
            next_mask=prior | req_bit;
            valid[sel]<=1; tag[sel]<=req_addr; sharers[sel]<=next_mask; dirty[sel]<=0; owner[sel]<='0;
          end
          READ_UNIQUE: begin
            targets=prior & ~req_bit; next_mask=req_bit;
            valid[sel]<=1; tag[sel]<=req_addr; sharers[sel]<=next_mask; dirty[sel]<=1; owner[sel]<=req_node;
            snoop_invalidate<=|targets;
          end
          default: begin
            next_mask=prior & ~req_bit;
            if(found) begin
              sharers[sel]<=next_mask;
              if(!(next_mask)) begin valid[sel]<=0; dirty[sel]<=0; end
              else if(dirty[sel] && owner[sel]==req_node) dirty[sel]<=0;
            end
          end
        endcase
        if(!found && !free_found && req_op!=EVICT) replace_ptr<=replace_ptr+1'b1;
        snoop_mask<=targets; snoop_valid<=|targets; new_sharers<=next_mask; rsp_valid<=1;
      end
    end
  end

`ifdef CHI_SF_SVA
  property p_rsp_stable; @(posedge clk) disable iff(!rst_n) rsp_valid&&!rsp_ready |=> rsp_valid&&$stable({dir_hit,old_sharers,snoop_valid,snoop_mask,snoop_invalidate,new_sharers}); endproperty
  property p_no_self_snoop; @(posedge clk) disable iff(!rst_n) req_valid&&req_ready |=> !(snoop_mask[$past(req_node)]); endproperty
  property p_snoop_consistent; @(posedge clk) disable iff(!rst_n) rsp_valid |-> (snoop_valid==(|snoop_mask)); endproperty
  property p_unique_single_owner; @(posedge clk) disable iff(!rst_n) req_valid&&req_ready&&req_op==READ_UNIQUE |=> $onehot(new_sharers); endproperty
  assert property(p_rsp_stable); assert property(p_no_self_snoop);
  assert property(p_snoop_consistent); assert property(p_unique_single_owner);
`endif
endmodule
