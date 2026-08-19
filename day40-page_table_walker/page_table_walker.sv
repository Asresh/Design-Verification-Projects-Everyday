// Author: Asresh Kuricheti
`timescale 1ns/1ps

// Compact Sv32-style two-level page-table walker.
// PTE layout: [31:10] PPN, [7] D, [6] A, [4] U, [3] X, [2] W, [1] R, [0] V.
module page_table_walker #(
  parameter int VA_W = 32,
  parameter int PA_W = 34,
  parameter int PPN_W = 22
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [PPN_W-1:0]  root_ppn,
  input  logic              req_valid,
  output logic              req_ready,
  input  logic [VA_W-1:0]   req_vaddr,
  input  logic [1:0]        req_access, // 0=read, 1=write, 2=execute
  input  logic              req_user,
  output logic              mem_req_valid,
  input  logic              mem_req_ready,
  output logic [PA_W-1:0]   mem_req_addr,
  input  logic              mem_rsp_valid,
  input  logic [31:0]       mem_rsp_pte,
  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [PA_W-1:0]   rsp_paddr,
  output logic              rsp_fault,
  output logic [1:0]        rsp_fault_code, // 1=invalid, 2=permission, 3=misaligned superpage
  output logic              rsp_leaf_level  // 1=level-1 superpage, 0=level-0 page
);
  typedef enum logic [2:0] {IDLE, ISSUE_L1, WAIT_L1, ISSUE_L0, WAIT_L0, RESP} state_t;
  state_t state;
  logic [VA_W-1:0] va_q;
  logic [1:0] access_q;
  logic user_q;
  logic [PPN_W-1:0] l0_ppn_q;
  logic [PA_W-1:0] paddr_q;
  logic fault_q, level_q;
  logic [1:0] fault_code_q;

  function automatic logic pte_invalid(input logic [31:0] pte);
    pte_invalid = !pte[0] || (!pte[1] && pte[2]);
  endfunction
  function automatic logic pte_leaf(input logic [31:0] pte);
    pte_leaf = pte[1] || pte[3];
  endfunction
  function automatic logic permission_ok(
    input logic [31:0] pte, input logic [1:0] access_kind, input logic user_mode
  );
    logic access_ok;
    begin
      case (access_kind)
        2'd0: access_ok = pte[1];
        2'd1: access_ok = pte[2];
        2'd2: access_ok = pte[3];
        default: access_ok = 1'b0;
      endcase
      permission_ok = access_ok && pte[6] && (!user_mode || pte[4]) &&
                      ((access_kind != 2'd1) || pte[7]);
    end
  endfunction

  assign req_ready      = (state == IDLE);
  assign mem_req_valid  = (state == ISSUE_L1) || (state == ISSUE_L0);
  assign mem_req_addr   = (state == ISSUE_L1)
                        ? ({root_ppn, 12'b0} + {{(PA_W-12){1'b0}}, va_q[31:22], 2'b00})
                        : ({l0_ppn_q, 12'b0} + {{(PA_W-12){1'b0}}, va_q[21:12], 2'b00});
  assign rsp_valid      = (state == RESP);
  assign rsp_paddr      = paddr_q;
  assign rsp_fault      = fault_q;
  assign rsp_fault_code = fault_code_q;
  assign rsp_leaf_level = level_q;

  task automatic finish_fault(input logic [1:0] code, input logic level);
    begin
      paddr_q <= '0;
      fault_q <= 1'b1;
      fault_code_q <= code;
      level_q <= level;
      state <= RESP;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      va_q <= '0;
      access_q <= '0;
      user_q <= 1'b0;
      l0_ppn_q <= '0;
      paddr_q <= '0;
      fault_q <= 1'b0;
      fault_code_q <= '0;
      level_q <= 1'b0;
    end else begin
      case (state)
        IDLE: if (req_valid) begin
          va_q <= req_vaddr;
          access_q <= req_access;
          user_q <= req_user;
          state <= ISSUE_L1;
        end
        ISSUE_L1: if (mem_req_ready) state <= WAIT_L1;
        WAIT_L1: if (mem_rsp_valid) begin
          if (pte_invalid(mem_rsp_pte)) finish_fault(2'd1, 1'b1);
          else if (pte_leaf(mem_rsp_pte)) begin
            if (mem_rsp_pte[19:10] != 10'b0) finish_fault(2'd3, 1'b1);
            else if (!permission_ok(mem_rsp_pte, access_q, user_q)) finish_fault(2'd2, 1'b1);
            else begin
              paddr_q <= {mem_rsp_pte[31:20], va_q[21:0]};
              fault_q <= 1'b0;
              fault_code_q <= 2'd0;
              level_q <= 1'b1;
              state <= RESP;
            end
          end else begin
            l0_ppn_q <= mem_rsp_pte[31:10];
            state <= ISSUE_L0;
          end
        end
        ISSUE_L0: if (mem_req_ready) state <= WAIT_L0;
        WAIT_L0: if (mem_rsp_valid) begin
          if (pte_invalid(mem_rsp_pte) || !pte_leaf(mem_rsp_pte)) finish_fault(2'd1, 1'b0);
          else if (!permission_ok(mem_rsp_pte, access_q, user_q)) finish_fault(2'd2, 1'b0);
          else begin
            paddr_q <= {mem_rsp_pte[31:10], va_q[11:0]};
            fault_q <= 1'b0;
            fault_code_q <= 2'd0;
            level_q <= 1'b0;
            state <= RESP;
          end
        end
        RESP: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end

`ifdef PTW_SVA
  assert property (@(posedge clk) disable iff (!rst_n)
    mem_req_valid && !mem_req_ready |=> mem_req_valid && $stable(mem_req_addr));
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable({rsp_paddr,rsp_fault,rsp_fault_code,rsp_leaf_level}));
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid |-> (rsp_fault == (rsp_fault_code != 0)));
  assert property (@(posedge clk) disable iff (!rst_n)
    req_valid && req_ready |-> req_access inside {2'd0,2'd1,2'd2});
  assert property (@(posedge clk) disable iff (!rst_n)
    mem_rsp_valid |-> state inside {WAIT_L1,WAIT_L0});
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid |-> !$isunknown({rsp_paddr,rsp_fault,rsp_fault_code,rsp_leaf_level}));
`endif
endmodule
