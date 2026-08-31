// Author: Asresh Kuricheti
// Parameterized March C- SRAM BIST command generator and read-data checker.
`timescale 1ns/1ps
module march_c_bist #(
  parameter int ADDR_W = 4,
  parameter int DATA_W = 8
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  output logic              busy,
  output logic              done,
  output logic              pass,
  output logic              fail,
  output logic [ADDR_W-1:0] fail_addr,
  output logic [DATA_W-1:0] fail_expected,
  output logic [DATA_W-1:0] fail_actual,
  output logic              mem_valid,
  input  logic              mem_ready,
  output logic              mem_write,
  output logic [ADDR_W-1:0] mem_addr,
  output logic [DATA_W-1:0] mem_wdata,
  input  logic              mem_rsp_valid,
  input  logic [DATA_W-1:0] mem_rdata
);
  localparam logic [ADDR_W-1:0] LAST_ADDR = {ADDR_W{1'b1}};
  typedef enum logic [3:0] {
    S_IDLE, S_W0_UP, S_R0W1_UP, S_R1W0_UP,
    S_R0W1_DN, S_R1W0_DN, S_R0_DN, S_DONE
  } state_t;

  state_t state;
  logic [ADDR_W-1:0] addr_q;
  logic write_part;
  logic waiting_rsp;
  logic expected_bit;

  assign busy      = (state != S_IDLE) && (state != S_DONE);
  assign done      = (state == S_DONE);
  assign pass      = done && !fail;
  assign mem_valid = busy && !waiting_rsp;
  assign mem_addr  = addr_q;
  assign mem_write = (state == S_W0_UP) || write_part;
  assign mem_wdata = (state == S_R0W1_UP || state == S_R0W1_DN) ? {DATA_W{1'b1}} : '0;

  always_comb begin
    case (state)
      S_R0W1_UP, S_R0W1_DN, S_R0_DN: expected_bit = 1'b0;
      default:                          expected_bit = 1'b1;
    endcase
  end

  task automatic advance_element;
    begin
      write_part <= 1'b0;
      case (state)
        S_W0_UP: begin
          if (addr_q == LAST_ADDR) begin state <= S_R0W1_UP; addr_q <= '0; end
          else addr_q <= addr_q + 1'b1;
        end
        S_R0W1_UP: begin
          if (addr_q == LAST_ADDR) begin state <= S_R1W0_UP; addr_q <= '0; end
          else addr_q <= addr_q + 1'b1;
        end
        S_R1W0_UP: begin
          if (addr_q == LAST_ADDR) begin state <= S_R0W1_DN; addr_q <= LAST_ADDR; end
          else addr_q <= addr_q + 1'b1;
        end
        S_R0W1_DN: begin
          if (addr_q == '0) begin state <= S_R1W0_DN; addr_q <= LAST_ADDR; end
          else addr_q <= addr_q - 1'b1;
        end
        S_R1W0_DN: begin
          if (addr_q == '0) begin state <= S_R0_DN; addr_q <= LAST_ADDR; end
          else addr_q <= addr_q - 1'b1;
        end
        S_R0_DN: begin
          if (addr_q == '0) begin state <= S_DONE; addr_q <= '0; end
          else addr_q <= addr_q - 1'b1;
        end
        default: state <= S_IDLE;
      endcase
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      addr_q        <= '0;
      write_part    <= 1'b0;
      waiting_rsp   <= 1'b0;
      fail          <= 1'b0;
      fail_addr     <= '0;
      fail_expected <= '0;
      fail_actual   <= '0;
    end else begin
      if (state == S_IDLE && start) begin
        state         <= S_W0_UP;
        addr_q        <= '0;
        write_part    <= 1'b0;
        waiting_rsp   <= 1'b0;
        fail          <= 1'b0;
        fail_addr     <= '0;
        fail_expected <= '0;
        fail_actual   <= '0;
      end else if (state == S_DONE && !start) begin
        state <= S_IDLE;
      end

      if (mem_valid && mem_ready) begin
        if (mem_write)
          advance_element();
        else
          waiting_rsp <= 1'b1;
      end

      if (waiting_rsp && mem_rsp_valid) begin
        waiting_rsp <= 1'b0;
        if ((mem_rdata !== {DATA_W{expected_bit}}) && !fail) begin
          fail          <= 1'b1;
          fail_addr     <= addr_q;
          fail_expected <= {DATA_W{expected_bit}};
          fail_actual   <= mem_rdata;
        end
        if (state == S_R0_DN)
          advance_element();
        else
          write_part <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  property p_command_stable;
    @(posedge clk) disable iff (!rst_n) mem_valid && !mem_ready |=>
      mem_valid && $stable({mem_write, mem_addr, mem_wdata});
  endproperty
  property p_no_command_while_waiting;
    @(posedge clk) disable iff (!rst_n) waiting_rsp |-> !mem_valid;
  endproperty
  property p_pass_means_no_fail;
    @(posedge clk) pass |-> !fail;
  endproperty
  assert property (p_command_stable);
  assert property (p_no_command_while_waiting);
  assert property (p_pass_means_no_fail);
`endif
endmodule
