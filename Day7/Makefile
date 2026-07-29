# -----------------------------------------------------------------------------
# Day7 - arb_rr : parameterized round-robin arbiter UVM verification
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=arb_smoke_test      # Synopsys VCS
#   make questa      UVM_TESTNAME=arb_regress_test    # Siemens Questa
#   make verilator   UVM_TESTNAME=arb_smoke_test      # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                  # Icarus Verilog + VCD
#   make waveform                                     # VCD -> docs PNG
#
#   make clean
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := arb_rr.sv
IF         := arb_if.sv
PKG        := arb_rr_pkg.sv
UVM_TOP    := tb_top.sv
UVM_SRC    := $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_arb_rr_dump.sv
DUMP_SRC   := $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= arb_smoke_test
TIMEOUT      ?= 50us

.PHONY: all icarus_dump waveform vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus does not implement the UVM class library, so this target runs the
# portable companion testbench (tb_arb_rr_dump.sv). It self-checks every cycle
# against an independent golden round-robin reference model and prints
# "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_arb_rr_dump.vcd

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all +define+ARB_RR_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME) +UVM_TIMEOUT=$(TIMEOUT)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm +define+ARB_RR_SVA $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top +define+ARB_RR_SVA \
		$(UVM_SRC) -o simv_verilator +define+UVM_NO_DPI
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
