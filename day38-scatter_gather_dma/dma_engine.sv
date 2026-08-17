// Author: Asresh Kuricheti
// Parameterized single-descriptor DMA data mover with independent read/write backpressure.
module dma_engine #(
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32,
  parameter int LEN_W  = 8
) (
  input  logic clk, rst_n,
  input  logic desc_valid, output logic desc_ready,
  input  logic [ADDR_W-1:0] desc_src, desc_dst,
  input  logic [LEN_W-1:0] desc_words,
  output logic rd_valid, input logic rd_ready,
  output logic [ADDR_W-1:0] rd_addr,
  input  logic rd_data_valid,
  input  logic [DATA_W-1:0] rd_data,
  input  logic rd_error,
  output logic wr_valid, input logic wr_ready,
  output logic [ADDR_W-1:0] wr_addr,
  output logic [DATA_W-1:0] wr_data,
  output logic wr_last,
  output logic done, error,
  output logic [LEN_W:0] words_moved
);
  typedef enum logic [1:0] {IDLE, ISSUE_READ, WAIT_DATA, ISSUE_WRITE} state_t;
  state_t state;
  logic [ADDR_W-1:0] src_q, dst_q;
  logic [LEN_W-1:0] remaining;
  logic [DATA_W-1:0] data_q;

  assign desc_ready = (state == IDLE);
  assign rd_valid   = (state == ISSUE_READ);
  assign rd_addr    = src_q;
  assign wr_valid   = (state == ISSUE_WRITE);
  assign wr_addr    = dst_q;
  assign wr_data    = data_q;
  assign wr_last    = (state == ISSUE_WRITE) && (remaining == 1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; src_q <= '0; dst_q <= '0; remaining <= '0;
      data_q <= '0; done <= 0; error <= 0; words_moved <= '0;
    end else begin
      done <= 0;
      case (state)
        IDLE: if (desc_valid) begin
          src_q <= desc_src; dst_q <= desc_dst; remaining <= desc_words;
          words_moved <= '0; error <= 0;
          if (desc_words == 0) begin done <= 1; error <= 1; end
          else state <= ISSUE_READ;
        end
        ISSUE_READ: if (rd_ready) state <= WAIT_DATA;
        WAIT_DATA: if (rd_data_valid) begin
          if (rd_error) begin error <= 1; done <= 1; state <= IDLE; end
          else begin data_q <= rd_data; state <= ISSUE_WRITE; end
        end
        ISSUE_WRITE: if (wr_ready) begin
          words_moved <= words_moved + 1'b1;
          if (remaining == 1) begin done <= 1; state <= IDLE; end
          else begin
            remaining <= remaining - 1'b1;
            src_q <= src_q + DATA_W/8; dst_q <= dst_q + DATA_W/8;
            state <= ISSUE_READ;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end

`ifdef DMA_SVA
  property p_read_stable; @(posedge clk) disable iff(!rst_n)
    rd_valid && !rd_ready |=> rd_valid && $stable(rd_addr); endproperty
  property p_write_stable; @(posedge clk) disable iff(!rst_n)
    wr_valid && !wr_ready |=> wr_valid && $stable({wr_addr,wr_data,wr_last}); endproperty
  property p_no_overlap; @(posedge clk) disable iff(!rst_n) !(rd_valid && wr_valid); endproperty
  property p_done_pulse; @(posedge clk) disable iff(!rst_n) done |=> !done; endproperty
  property p_count_bound; @(posedge clk) disable iff(!rst_n) words_moved <= {1'b0,desc_words} or !desc_ready; endproperty
  assert property(p_read_stable); assert property(p_write_stable);
  assert property(p_no_overlap); assert property(p_done_pulse);
`endif
endmodule
