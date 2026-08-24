// Author: Asresh Kuricheti
//
//  sleep_req   save_done              wake_req   pwr_good  restore_done
//      |           |                     |          |           |
//      v           v                     v          v           v
//   +----------------------------------------------------------------+
//   | ON -> SAVE -> ISOLATE -> OFF -> POWER_WAIT -> RESTORE -> ON    |
//   |                    timeout in any handshake -> SAFE_FAULT       |
//   +----------------------------------------------------------------+
//      |        |          |             |             |
//      v        v          v             v             v
//   clk_en  retention   isolate_en   power_switch_en  status/fault
`timescale 1ns/1ps

module power_domain_controller #(
  parameter int TIMEOUT_CYCLES = 8,
  parameter int COUNT_W = $clog2(TIMEOUT_CYCLES + 1)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic sleep_req,
  input  logic wake_req,
  input  logic save_done,
  input  logic restore_done,
  input  logic pwr_good,
  output logic isolate_en,
  output logic retention_save,
  output logic retention_restore,
  output logic power_switch_en,
  output logic domain_clk_en,
  output logic busy,
  output logic asleep,
  output logic fault,
  output logic [2:0] state_dbg
);
  typedef enum logic [2:0] {
    ST_ON, ST_SAVE, ST_ISOLATE, ST_OFF,
    ST_POWER_WAIT, ST_RESTORE, ST_DEISOLATE, ST_FAULT
  } state_t;

  state_t state, next_state;
  logic [COUNT_W-1:0] wait_count;
  logic timed_out;

  assign timed_out = (wait_count >= TIMEOUT_CYCLES-1);

  always_comb begin
    next_state = state;
    unique case (state)
      ST_ON:         if (sleep_req) next_state = ST_SAVE;
      ST_SAVE:       if (save_done) next_state = ST_ISOLATE;
                     else if (timed_out) next_state = ST_FAULT;
      ST_ISOLATE:    next_state = ST_OFF;
      ST_OFF:        if (wake_req) next_state = ST_POWER_WAIT;
      ST_POWER_WAIT: if (pwr_good) next_state = ST_RESTORE;
                     else if (timed_out) next_state = ST_FAULT;
      ST_RESTORE:    if (restore_done) next_state = ST_DEISOLATE;
                     else if (timed_out) next_state = ST_FAULT;
      ST_DEISOLATE:  next_state = ST_ON;
      default:       next_state = ST_FAULT;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= ST_ON;
      wait_count <= '0;
    end else begin
      state <= next_state;
      if ((next_state != state) ||
          !((state == ST_SAVE) || (state == ST_POWER_WAIT) ||
            (state == ST_RESTORE)))
        wait_count <= '0;
      else if (!timed_out)
        wait_count <= wait_count + 1'b1;
    end
  end

  always_comb begin
    isolate_en       = 1'b1;
    retention_save   = 1'b0;
    retention_restore= 1'b0;
    power_switch_en  = 1'b1;
    domain_clk_en    = 1'b0;
    busy             = 1'b1;
    asleep           = 1'b0;
    fault            = 1'b0;
    state_dbg        = state;

    unique case (state)
      ST_ON: begin
        isolate_en = 1'b0; domain_clk_en = 1'b1; busy = 1'b0;
      end
      ST_SAVE: begin
        isolate_en = 1'b0; domain_clk_en = 1'b1; retention_save = 1'b1;
      end
      ST_ISOLATE: begin
        isolate_en = 1'b1; domain_clk_en = 1'b0;
      end
      ST_OFF: begin
        isolate_en = 1'b1; power_switch_en = 1'b0;
        domain_clk_en = 1'b0; busy = 1'b0; asleep = 1'b1;
      end
      ST_POWER_WAIT: begin
        isolate_en = 1'b1; power_switch_en = 1'b1;
      end
      ST_RESTORE: begin
        isolate_en = 1'b1; retention_restore = 1'b1;
      end
      ST_DEISOLATE: begin
        isolate_en = 1'b0; domain_clk_en = 1'b1;
      end
      default: begin
        // Fail safe: keep the domain powered, isolated, and clock-gated.
        isolate_en = 1'b1; power_switch_en = 1'b1;
        domain_clk_en = 1'b0; fault = 1'b1;
      end
    endcase
  end
endmodule
