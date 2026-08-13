# -----------------------------------------------------------------------------
# Day1 - sync_fifo self-checking testbench
# Run targets for the four common SystemVerilog simulators.
#
#   make verilator   # open-source, needs a small C++ harness (--binary mode)
#   make vcs         # Synopsys VCS
#   make questa      # Siemens Questa/ModelSim
#   make icarus      # Icarus Verilog (SVA/covergroups are limited)
#   make clean
#
# Default target runs Icarus if present, else prints guidance.
# -----------------------------------------------------------------------------

TOP     := tb_sync_fifo
DUT     := sync_fifo.sv
TB      := tb_sync_fifo.sv
SRC     := $(DUT) $(TB)
VCD     := sync_fifo.vcd

.PHONY: all verilator vcs questa icarus clean

all: icarus

# ---- Verilator (binary mode; --assert enables SVA) ----
verilator:
	verilator --binary --assert --timing -Wall -Wno-DECLFILENAME \
		--top-module $(TOP) $(SRC) -o simv_verilator
	./obj_dir/simv_verilator

# ---- Synopsys VCS ----
vcs:
	vcs -full64 -sverilog -assert svaext +vcs+lic+wait \
		-debug_access+all $(SRC) -o simv_vcs
	./simv_vcs

# ---- Siemens Questa / ModelSim ----
questa:
	vlib work
	vlog -sv +acc $(SRC)
	vsim -c -voptargs=+acc $(TOP) -do "run -all; quit -f"

# ---- Icarus Verilog ----
# Note: Icarus has partial SVA / covergroup support; the scoreboard still runs.
icarus:
	iverilog -g2012 -o simv_icarus $(SRC)
	vvp simv_icarus

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log
