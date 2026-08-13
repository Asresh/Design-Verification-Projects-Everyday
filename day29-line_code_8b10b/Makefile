# -----------------------------------------------------------------------------
# Day29 - codec_8b10b : IEEE 802.3 / PCIe / SATA 8b/10b line-code encoder and
#                       decoder verification (running disparity, K control
#                       symbols, comma framing, code and disparity errors).
#
# UVM targets (need a UVM-capable simulator):
#   make vcs         UVM_TESTNAME=codec_8b10b_smoke_test     # Synopsys VCS
#   make questa      UVM_TESTNAME=codec_8b10b_regress_test   # Siemens Questa
#   make verilator   UVM_TESTNAME=codec_8b10b_smoke_test     # Verilator (>=5, --uvm)
#
# Portable / open-source target (NO UVM - runs the module-based self-checking
# testbench and captures the committed waveform):
#   make icarus_dump                                         # Icarus + VCD
#   make waveform                                            # VCD -> docs PNG
#
#   make kat                                                 # re-prove the code
#   make clean
#
# Default target runs the Icarus dump TB (the one that runs everywhere).
# -----------------------------------------------------------------------------

DUT        := codec_8b10b.sv
IF         := codec_8b10b_if.sv
REF        := codec_8b10b_ref_pkg.sv
PKG        := codec_8b10b_pkg.sv
UVM_TOP    := tb_top.sv

# codec_8b10b_ref_pkg must be compiled before anything that imports it, and the
# interface before the UVM package that declares a virtual handle to it.
UVM_SRC    := $(REF) $(IF) $(DUT) $(PKG) $(UVM_TOP)

DUMP_TB    := tb_codec_8b10b_dump.sv
DUMP_SRC   := $(REF) $(DUT) $(DUMP_TB)

UVM_TESTNAME ?= codec_8b10b_smoke_test

.PHONY: all icarus_dump waveform kat vcs questa verilator clean

all: icarus_dump

# ---- Icarus Verilog: module-based self-checking TB (no UVM) ----
# Icarus implements neither the UVM class library nor a constraint solver, so
# this target runs the portable companion testbench (tb_codec_8b10b_dump.sv).
# It re-proves the code's defining properties inside the simulator and replays
# the 48-vector Known-Answer Table through the reference model, then drives
# ~4900 symbols - the directed showcase, all 256 data bytes, all 12 control
# symbols from both running-disparity states, the alternate-encoding corners,
# a bit-flip walk across all ten wire positions, a single-bit error detection
# latency sweep and a pseudo-random regression - pairing every codeword and
# every decoded symbol against codec_8b10b_ref_pkg in arrival order, and
# prints "RESULT: *** PASS ***".
icarus_dump:
	iverilog -g2012 -o simv_dump $(DUMP_SRC)
	vvp simv_dump

# ---- Render the committed waveform from the captured VCD ----
waveform: icarus_dump
	python3 docs/make_waveform.py tb_codec_8b10b_dump.vcd

# ---- Re-prove the 8b/10b tables and regenerate the reference model ----
# Checks DC balance, bounded running disparity, run length <= 5 across every
# legal codeword junction, unique decodability and comma uniqueness; derives
# the K.28.7 successor restriction; rewrites docs/codec_8b10b_kat.txt and the
# generated table block inside codec_8b10b_ref_pkg.sv.
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
