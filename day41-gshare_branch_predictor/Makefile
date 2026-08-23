# Author: Asresh Kuricheti
DUT := gshare_branch_predictor.sv
UVM_SRC := gshare_if.sv $(DUT) gshare_pkg.sv tb_top.sv
UVM_TESTNAME ?= gshare_regress_test
.PHONY: all icarus vcs questa verilator clean
all: icarus
icarus:
	iverilog -g2012 -Wall -s tb_gshare_portable -o simv_icarus $(DUT) tb_gshare_portable.sv
	vvp simv_icarus
vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext +define+GSHARE_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)
questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+GSHARE_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"
verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm --top-module tb_top +define+GSHARE_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)
clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir
