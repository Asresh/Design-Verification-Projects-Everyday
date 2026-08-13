DUT := noc_router.sv
IF := noc_router_if.sv
REF := noc_ref_pkg.sv
PKG := noc_router_pkg.sv
TOP := tb_top.sv
UVM_SRC := $(REF) $(IF) $(DUT) $(PKG) $(TOP)
UVM_TESTNAME ?= noc_router_regress_test

.PHONY: all icarus_dump waveform vcs questa verilator clean
all: icarus_dump

icarus_dump:
	iverilog -g2012 -o simv_dump $(REF) $(DUT) tb_noc_router_dump.sv
	vvp simv_dump

waveform: icarus_dump
	python3 docs/make_waveform.py tb_noc_router_dump.vcd

vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext \
		+define+NOC_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+NOC_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm \
		--top-module tb_top +define+NOC_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir
