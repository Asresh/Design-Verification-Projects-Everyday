# Design Verification Projects — Everyday

A daily series of self-contained design-verification projects in SystemVerilog/UVM. One documented, simulate-able verification exercise per day.

Each day lives in its own folder (`DayN/`) containing a self-contained project with source, a self-checking testbench, a Makefile, a waveform image, and a README write-up.

## Index

| Day | Project | Key concepts | Folder |
|-----|---------|--------------|--------|
| 1 | Constrained-Random FIFO Scoreboard | Reference-model scoreboard, `$`-queue golden model, directed + constrained-random stimulus, functional coverage, SVA assertions | [Day1/](Day1/) |
| 2 | UVM APB4 Register-File Verification | Full UVM agent (driver/monitor/sequencer), golden reference-model scoreboard, layered sequences, virtual sequencer + virtual sequences, functional coverage, APB protocol SVA | [Day2/](Day2/) |
