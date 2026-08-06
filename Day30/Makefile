# -----------------------------------------------------------------------------
# Day30 - jtag_tap : IEEE 1149.1 JTAG Test Access Port controller verification
#                    (sixteen-state TAP FSM, instruction register, BYPASS /
#                    IDCODE / boundary-scan / user data-register chains).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=jtag_tap_smoke_test     # Synopsys VCS
#   make questa      UVM_TESTNAME=jtag_tap_regress_test   # Siemens Questa
#   make verilator   UVM_TESTNAME=jtag_tap_smoke_test     # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                      # Icarus + VCD
#   make waveform                                         # VCD -> docs PNG
#   make clean
#
# The SVA in jtag_tap.sv and jtag_tap_if.sv is guarded by +define+JTAG_SVA,
# which the vcs / questa / verilator targets pass and the Icarus target does
# not - Icarus does not implement concurrent assertions.
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := jtag_tap.sv
IF         := jtag_tap_if.sv
REF        := jtag_tap_ref_pkg.sv
PKG        := jtag_tap_pkg.sv
UVM_TOP    := tb_top.sv

# jtag_tap_ref_pkg must be compiled before anything that imports it, and the
# interface before the UVM package that declares a virtual handle to it.
UVM_SRC    := $(REF) $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_jtag_tap_dump.sv
DUMP_SRC   := $(REF) $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= jtag_tap_smoke_test

.PHONY: all icarus_dump waveform vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus implements neither the UVM class library nor a constraint solver, so
# this target runs the portable companion testbench (tb_jtag_tap_dump.sv).  It
# first makes the reference model re-prove the standard's mandatory properties
# inside the simulator, then drives sixteen directed scenarios - TRST_n, the
# five-TMS=1 reset from Shift-DR, IDCODE with no IR scan, the Capture-IR
# pattern, BYPASS, an unimplemented opcode, SAMPLE/PRELOAD, EXTEST, CLAMP, the
# user register, chain isolation, Pause-DR, Pause-IR, the short way home from
# Select-IR-Scan, all sixteen opcodes, TRST_n mid-scan - followed by a 6000
# cycle random TMS/TDI walk with the system pins moving and 300 random complete
# scans.  Every rising and falling edge is compared against
# jtag_tap_ref_pkg::ref_tap_cycle, and the run reports state and transition
# coverage before printing "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_jtag_tap_dump.vcd

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all +define+JTAG_SVA \
		$(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm +define+JTAG_SVA $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top +define+JTAG_SVA \
		$(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
