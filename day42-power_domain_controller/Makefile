# Author: Asresh Kuricheti
#
# Sources -> compile -> run selected UVM test -> VCD/PASS
DUT := power_domain_controller.sv
UVM_SRC := power_domain_if.sv $(DUT) power_domain_pkg.sv tb_top.sv
UVM_TESTNAME ?= power_domain_regress_test
.PHONY: all icarus vcs questa verilator clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s tb_power_domain_portable -o simv_icarus $(DUT) tb_power_domain_portable.sv
	vvp simv_icarus

vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext +define+POWER_DOMAIN_SVA $(UVM_SRC) -o simv_vcs
	./simv_vcs +UVM_TESTNAME=$(UVM_TESTNAME)

questa:
	vlib work
	vlog -sv -mfcu -L uvm +define+POWER_DOMAIN_SVA $(UVM_SRC)
	vsim -c -uvm tb_top +UVM_TESTNAME=$(UVM_TESTNAME) -do "run -all; quit -f"

verilator:
	verilator --binary --timing --assert -Wno-fatal --uvm --top-module tb_top +define+POWER_DOMAIN_SVA $(UVM_SRC) -o simv_verilator
	./obj_dir/simv_verilator +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf simv_* obj_dir work transcript *.vcd *.wlf *.log csrc *.daidir
