# -----------------------------------------------------------------------------
# Day32 - mesi_cache : MESI snooping cache-coherence verification
#                      (E-state exclusivity, silent E->M upgrade, cache-to-cache
#                      flush, BusUpgr invalidation, dirty eviction, the
#                      upgrade-vs-invalidate race, and the SWMR safety property).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=mesi_smoke_test      # Synopsys VCS
#   make questa      UVM_TESTNAME=mesi_regress_test    # Siemens Questa
#   make verilator   UVM_TESTNAME=mesi_smoke_test      # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                   # Icarus + VCD
#   make waveform                                      # VCD -> docs PNG
#   make mutants                                       # prove the checker works
#   make clean
#
# The SVA in mesi_cache.sv and mesi_cache_if.sv is guarded by +define+MESI_SVA,
# which the vcs / questa / verilator targets pass and the Icarus target does
# not - Icarus implements no concurrent assertions.
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := mesi_cache.sv
IF         := mesi_cache_if.sv
REF        := mesi_ref_pkg.sv
PKG        := mesi_cache_pkg.sv
UVM_TOP    := tb_top.sv

# mesi_ref_pkg must be compiled before anything that imports it, and the
# interfaces before the UVM package that declares virtual handles to them.
UVM_SRC    := $(REF) $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_mesi_cache_dump.sv
DUMP_SRC   := $(REF) $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= mesi_smoke_test

.PHONY: all icarus_dump waveform mutants vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus implements neither the UVM class library nor a constraint solver, so
# this target runs the portable companion testbench (tb_mesi_cache_dump.sv).
# It first makes the golden model re-prove its own protocol rules inside the
# simulator, then runs 22 scenarios: the five-access MESI showcase (cold read
# miss -> E, silent E->M store, remote read flushing M->S, BusUpgr, BusRdX),
# read/write hits, two readers sharing, clean and dirty eviction, writeback to
# the victim's own address, remote-store invalidation, a migratory line
# ping-ponging between the cores, three-tag index thrash, every set from both
# cores, the concurrent upgrade race, and a reset that discards dirty data -
# followed by 2000 constrained-random accesses split across four memory
# behaviours from zero-latency to 70% stalls with 8-cycle reads, including a
# mid-stream reset.  SWMR, no-two-dirty and sharer agreement are checked every
# cycle straight off both caches' tag/state arrays; the data-value invariant is
# checked on every completion; the model is fully reconciled against the DUT at
# every quiesce point; and memory traffic is reconciled against the protocol
# events that required it, before it prints "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_mesi_cache_dump.vcd

# ---- Prove the checker can actually fail ----
# Introduces one realistic single-line coherence bug at a time and requires
# every one of them to be caught.  A green regression that survives mutation
# is a green regression that means something.
mutants:
	python3 docs/mutation_test.py

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all +define+MESI_SVA \
		$(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm +define+MESI_SVA $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top +define+MESI_SVA \
		$(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
