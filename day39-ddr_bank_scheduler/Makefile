# Author: Asresh Kuricheti
DUT := ddr_bank_scheduler.sv
UVM_SRC := ddr_scheduler_if.sv $(DUT) ddr_scheduler_pkg.sv tb_top.sv
UVM_TESTNAME ?= ddr_regress_test
.PHONY: all icarus waveform vcs questa verilator clean
all: icarus
icarus:
	iverilog -g2012 -Wall -s tb_ddr_scheduler_dump -o simv_icarus $(DUT) tb_ddr_scheduler_dump.sv
	vvp simv_icarus
waveform: icarus
	MPLCONFIGDIR=.mplconfig python3 docs/make_waveform.py tb_ddr_scheduler_dump.vcd
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext +define+DDR_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)
questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+DDR_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm --top-module tb_top +define+DDR_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)
clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir .mplconfig
