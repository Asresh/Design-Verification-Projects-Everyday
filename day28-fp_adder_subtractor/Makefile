# -----------------------------------------------------------------------------
# Day28 - fp32_add : IEEE-754 binary32 floating-point adder / subtractor
#                    verification (round-to-nearest-even, subnormals, inf/NaN).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=fp32_add_smoke_test     # Synopsys VCS
#   make questa      UVM_TESTNAME=fp32_add_regress_test   # Siemens Questa
#   make verilator   UVM_TESTNAME=fp32_add_smoke_test     # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                      # Icarus Verilog + VCD
#   make waveform                                         # VCD -> docs PNG
#
#   make kat                                              # regenerate the KAT
#   make clean
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := fp32_add.sv
IF         := fp32_add_if.sv
REF        := fp32_ref_pkg.sv
PKG        := fp32_add_pkg.sv
UVM_TOP    := tb_top.sv

# fp32_ref_pkg must be compiled before anything that imports it, and the
# interface before the UVM package that declares a virtual handle to it.
UVM_SRC    := $(REF) $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_fp32_add_dump.sv
DUMP_SRC   := $(REF) $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= fp32_add_smoke_test

.PHONY: all icarus_dump waveform kat vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus implements neither the UVM class library nor a constraint solver, so
# this target runs the portable companion testbench (tb_fp32_add_dump.sv). It
# self-checks the shared golden model against 48 numpy-generated Known-Answer
# vectors, then drives ~6000 operations - the KAT replayed through the RTL, the
# 16x16x{add,sub} landmark cross-product, a round-to-nearest-EVEN half-ULP
# campaign, the subnormal exponent floor, the overflow boundary and a shaped
# pseudo-random regression - pairing every result against fp32_ref_pkg::fp_ref
# in arrival order, and prints "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_fp32_add_dump.vcd

# ---- Regenerate the Known-Answer Table from numpy float32 ----
# Prints the SystemVerilog kat_add(...) block for fp32_ref_pkg.sv and rewrites
# docs/fp32_kat.txt. Needs numpy.
kat:
	python3 docs/gen_kat.py

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
