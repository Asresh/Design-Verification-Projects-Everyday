# -----------------------------------------------------------------------------
# Day31 - cache_ctrl : direct-mapped, write-back, write-allocate cache
#                      controller verification (hit/miss prediction, dirty
#                      eviction, line fill, byte-strobe merge, maintenance
#                      flush, reset-discards-dirty).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=cache_ctrl_smoke_test     # Synopsys VCS
#   make questa      UVM_TESTNAME=cache_ctrl_regress_test   # Siemens Questa
#   make verilator   UVM_TESTNAME=cache_ctrl_smoke_test     # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                        # Icarus + VCD
#   make waveform                                           # VCD -> docs PNG
#   make clean
#
# The SVA in cache_ctrl.sv and cache_ctrl_if.sv is guarded by +define+CACHE_SVA,
# which the vcs / questa / verilator targets pass and the Icarus target does
# not - Icarus does not implement concurrent assertions.
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := cache_ctrl.sv
IF         := cache_ctrl_if.sv
REF        := cache_ref_pkg.sv
PKG        := cache_ctrl_pkg.sv
UVM_TOP    := tb_top.sv

# cache_ref_pkg must be compiled before anything that imports it, and the
# interface before the UVM package that declares a virtual handle to it.
UVM_SRC    := $(REF) $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_cache_ctrl_dump.sv
DUMP_SRC   := $(REF) $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= cache_ctrl_smoke_test

.PHONY: all icarus_dump waveform vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus implements neither the UVM class library nor a constraint solver, so
# this target runs the portable companion testbench (tb_cache_ctrl_dump.sv).
# It first makes the reference model re-prove its own invariants inside the
# simulator, then runs eighteen directed scenarios - cold miss, line hits,
# write hit, dirty eviction, write-allocate, byte-strobe merge, flush with and
# without dirty lines, flush-does-not-invalidate, index thrash, memory
# backpressure with non-zero read latency, a flush racing an in-flight access,
# reset discarding dirty data, back-to-back requests, every set - followed by
# 2000 constrained-random accesses with a hostile memory, periodic flushes and
# a mid-stream reset.  Every response is compared against cache_ref_pkg, the
# physical memory is compared word for word against the model after every
# flush, and the memory traffic is reconciled against the number of line
# writebacks and fills the model says were required, before it prints
# "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_cache_ctrl_dump.vcd

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all +define+CACHE_SVA \
		$(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm +define+CACHE_SVA $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top +define+CACHE_SVA \
		$(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
