# -----------------------------------------------------------------------------
# Day16 - smem_bank_arb : GPU shared-memory bank-conflict serializer DV
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=smem_smoke_test      # Synopsys VCS
#   make questa      UVM_TESTNAME=smem_regress_test    # Siemens Questa
#   make verilator   UVM_TESTNAME=smem_smoke_test      # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                   # Icarus Verilog + VCD
#   make waveform                                      # VCD -> docs PNG
#
#   make clean
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := smem_bank_arb.sv
IF         := smem_bank_arb_if.sv
PKG        := smem_bank_arb_pkg.sv
UVM_TOP    := tb_top.sv
UVM_SRC    := $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_smem_bank_arb_dump.sv
DUMP_SRC   := $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= smem_smoke_test

.PHONY: all icarus_dump waveform vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus does not implement the UVM class library, so this target runs the
# portable companion testbench (tb_smem_bank_arb_dump.sv). It drives the
# directed 3-way-conflict-plus-broadcast showcase, directed corners
# (conflict-free, full broadcast, worst-case 8-way conflict, partial mask,
# single lane, all-inactive empty phase), and a constrained-random regression,
# checks the DUT's {ph_served, ph_bank_use, ph_last, ph_index} and phase count
# against a golden reference model for every request, and prints
# "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_smem_bank_arb_dump.vcd

# ---- Synopsys VCS (UVM) ----
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
		-assert svaext -debug_access+all +define+SMEM_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

# ---- Siemens Questa / ModelSim (UVM) ----
questa:
	vlib work
	vlog -sv +acc -mfcu -L uvm +define+SMEM_SVA $(UVM_SRC)
	vsim -c -uvm -voptargs=+acc tb_top \
		+UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

# ---- Verilator (UVM support requires Verilator >= 5.x built with --uvm) ----
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		-timescale 1ns/1ps --top-module tb_top +define+SMEM_SVA \
		$(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf obj_dir simv_* work transcript *.vcd *.wlf *.daidir csrc \
		ucli.key vc_hdrs.h *.log .simvision *.key
