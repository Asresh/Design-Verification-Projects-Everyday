# Author: Asresh Kuricheti
DUT := page_table_walker.sv
UVM_SRC := ptw_if.sv $(DUT) ptw_pkg.sv tb_top.sv
UVM_TESTNAME ?= ptw_regress_test
.PHONY: all icarus waveform vcs questa verilator clean
all: icarus
icarus:
	iverilog -g2012 -Wall -s tb_page_table_walker_dump -o simv_icarus $(DUT) tb_page_table_walker_dump.sv
	vvp simv_icarus
waveform: icarus
	MPLCONFIGDIR=.mplconfig python3 docs/make_waveform.py tb_page_table_walker_dump.vcd
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext +define+PTW_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)
questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+PTW_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm --top-module tb_top +define+PTW_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)
clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir .mplconfig
