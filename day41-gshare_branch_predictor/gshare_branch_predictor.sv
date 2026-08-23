// Author: Asresh Kuricheti
`timescale 1ns/1ps

module gshare_branch_predictor #(
  parameter int PC_WIDTH = 32,
  parameter int GHIST_W  = 4,
  parameter int INDEX_W  = 4
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 pred_valid,
  output logic                 pred_ready,
  input  logic [PC_WIDTH-1:0]  pred_pc,
  output logic                 pred_rsp_valid,
  output logic                 pred_taken,
  output logic [GHIST_W-1:0]   pred_history,
  output logic [INDEX_W-1:0]   pred_index,

  input  logic                 update_valid,
  input  logic [INDEX_W-1:0]   update_index,
  input  logic [GHIST_W-1:0]   update_history,
  input  logic                 update_pred_taken,
  input  logic                 update_actual_taken,
  output logic                 update_mispredict,
  output logic [GHIST_W-1:0]   global_history
);
  localparam int ENTRIES = 1 << INDEX_W;
  logic [1:0] pht [0:ENTRIES-1];
  logic [GHIST_W-1:0] ghr;
  integer i;

  always_comb begin
    pred_ready       = 1'b1;
    pred_rsp_valid   = pred_valid;
    pred_history     = ghr;
    pred_index       = pred_pc[INDEX_W+1:2] ^ ghr[INDEX_W-1:0];
    pred_taken       = pht[pred_index][1];
    update_mispredict = update_valid &&
                        (update_pred_taken != update_actual_taken);
    global_history   = ghr;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ghr <= '0;
      for (i = 0; i < ENTRIES; i = i + 1)
        pht[i] <= 2'b01; // weakly not taken
    end else if (update_valid) begin
      if (update_actual_taken) begin
        if (pht[update_index] != 2'b11)
          pht[update_index] <= pht[update_index] + 2'b01;
      end else begin
        if (pht[update_index] != 2'b00)
          pht[update_index] <= pht[update_index] - 2'b01;
      end
      // Restore the prediction-time history, then append the resolved result.
      // This recovers correctly even when speculative history has moved on.
      ghr <= {update_history[GHIST_W-2:0], update_actual_taken};
    end
  end

endmodule
