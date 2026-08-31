# Author: Asresh Kuricheti
DUT := march_c_bist.sv
IFACE := march_c_bist_if.sv
PKG := march_c_bist_pkg.sv
UVM_TOP := tb_top.sv
PORT_TB := tb_march_c_bist_portable.sv
UVM_TESTNAME ?= march_c_bist_test

.PHONY: all icarus verilator vcs questa clean
all: icarus

icarus:
	iverilog -g2012 -DSYNTHESIS -Wall -s tb_march_c_bist_portable -o simv $(DUT) $(PORT_TB)
	vvp simv

verilator:
	verilator --binary --timing --trace -DSYNTHESIS -Wall -Wno-fatal --top-module tb_march_c_bist_portable $(DUT) $(PORT_TB)
	./obj_dir/Vtb_march_c_bist_portable

vcs:
	vcs -full64 -sverilog -ntb_opts uvm-1.2 $(DUT) $(IFACE) $(PKG) $(UVM_TOP) -o simv_uvm
	./simv_uvm +UVM_TESTNAME=$(UVM_TESTNAME)

questa:
	vlib work
	vlog -sv +incdir+$$UVM_HOME/src $(DUT) $(IFACE) $(PKG) $(UVM_TOP)
	vsim -c tb_top -do "run -all; quit -f" +UVM_TESTNAME=$(UVM_TESTNAME)

clean:
	rm -rf simv simv.daidir simv_uvm obj_dir work transcript vsim.wlf *.vcd ucli.key csrc
