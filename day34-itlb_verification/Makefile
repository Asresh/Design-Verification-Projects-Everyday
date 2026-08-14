# Author: Asresh Kuricheti
DUT := i_tlb.sv
IF := i_tlb_if.sv
REF := tlb_ref_pkg.sv
PKG := i_tlb_pkg.sv
TOP := tb_top.sv
UVM_SRC := $(REF) $(IF) $(DUT) $(PKG) $(TOP)
UVM_TESTNAME ?= tlb_regress_test

.PHONY: all icarus waveform vcs questa verilator clean
all: icarus

icarus:
	iverilog -g2012 -Wall -s tb_i_tlb_dump -o simv_icarus $(DUT) tb_i_tlb_dump.sv
	vvp simv_icarus

waveform: icarus
	python3 docs/make_waveform.py tb_i_tlb_dump.vcd

vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext +define+TLB_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+TLB_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm --top-module tb_top +define+TLB_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir
