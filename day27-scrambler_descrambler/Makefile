# -----------------------------------------------------------------------------
# Day27 - scrambler : self-synchronizing (multiplicative) scrambler/descrambler
#                     link verification (G(x)=1+x^39+x^58, 10GBASE-R PCS).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=scrambler_smoke_test     # Synopsys VCS
#   make questa      UVM_TESTNAME=scrambler_regress_test   # Siemens Questa
#   make verilator   UVM_TESTNAME=scrambler_smoke_test     # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                       # Icarus Verilog + VCD
#   make waveform                                          # VCD -> docs PNG
#
#   make clean
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := scrambler.sv
IF         := scrambler_if.sv
PKG        := scrambler_pkg.sv
UVM_TOP    := tb_top.sv
UVM_SRC    := $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_scrambler_dump.sv
DUMP_SRC   := $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= scrambler_smoke_test

.PHONY: all icarus_dump waveform vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus does not implement the UVM class library, so this target runs the
# portable companion testbench (tb_scrambler_dump.sv). It drives the chained
# scrambler->wire->descrambler link, checks the scrambled midpoint and the
# recovered stream against an INDEPENDENT bit-serial golden model (pinned to a
# Python Known-Answer vector), proves the descrambler self-synchronizes from a
# wrong seed, exercises a single-bit wire-error corner (bounded burst + re-lock),
# runs a large constrained-random regression, and prints "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_scrambler_dump.vcd

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top \
		$(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
