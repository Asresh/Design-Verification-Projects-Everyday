# Design Verification Projects — Everyday

A daily series of self-contained design-verification projects in SystemVerilog/UVM. One documented, simulate-able verification exercise per day.

Each day lives in its own folder (`DayN/`) containing a self-contained project with source, a self-checking testbench, a Makefile, a waveform image, and a README write-up.

## Index

| Day | Project | Key concepts | Folder |
|-----|---------|--------------|--------|
| 1 | Constrained-Random FIFO Scoreboard | Reference-model scoreboard, `$`-queue golden model, directed + constrained-random stimulus, functional coverage, SVA assertions | [Day1/](Day1/) |
| 2 | UVM APB4 Register-File Verification | Full UVM agent (driver/monitor/sequencer), golden reference-model scoreboard, layered sequences, virtual sequencer + virtual sequences, functional coverage, APB protocol SVA | [Day2/](Day2/) |
| 3 | UVM AXI4-Lite Register-Block Verification | Five-channel AXI4-Lite agent (driver/monitor/sequencer), golden reference-model scoreboard, layered + virtual sequences, functional coverage, AXI4-Lite protocol SVA (VALID/READY stability, response codes) | [Day3/](Day3/) |
| 4 | UVM UART Verification Environment | TX + RX agents, serial-line monitors that reconstruct bytes, dual sent-vs-serialized / on-wire-vs-received scoreboard, directed + random sequences across baud settings, data×baud coverage, start/stop framing SVA | [Day4/](Day4/) |
| 5 | UVM RAL (Register Abstraction Layer) Demo | `uvm_reg` model with RW/RO/W1C fields, `uvm_reg_adapter` + explicit `uvm_reg_predictor`, front-door and back-door access, built-in `uvm_reg_hw_reset_seq` / `uvm_reg_bit_bash_seq`, register field-value coverage | [Day5/](Day5/) |
