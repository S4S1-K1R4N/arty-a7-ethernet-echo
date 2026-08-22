# Makefile for Ethernet Echo FPGA Project (Digilent Arty A7-100T)

CC = gcc
CFLAGS = -O2 -Wall

SIM_SRCS = rtl/eth_echo_top.v sim/tb_eth_echo.v

.PHONY: all sim software bitstream program clean

all: software

# Build host C testing utility
software: software/test_echo

software/test_echo: software/test_echo.c
	$(CC) $(CFLAGS) -o $@ $<

# Run simulation (defaults to iverilog if available, or Vivado xsim)
sim: sim-iverilog

sim-iverilog:
	@echo "Running Icarus Verilog simulation..."
	iverilog -o sim/sim_out.vvp -s tb_eth_echo $(SIM_SRCS)
	vvp sim/sim_out.vvp

sim-vivado:
	@echo "Running Vivado simulator (xsim)..."
	xvlog $(SIM_SRCS)
	xelab -debug typical tb_eth_echo -s tb_eth_echo_sim
	xsim tb_eth_echo_sim -R

# Synthesize and generate bitstream with Vivado in batch mode
bitstream:
	vivado -mode batch -source scripts/build_bitstream.tcl

# Program FPGA using Vivado Hardware Manager
program:
	vivado -mode batch -source scripts/program_fpga.tcl

clean:
	rm -rf build xsim.dir .Xil
	rm -f *.log *.jou *.pb *.rpt *.dcp clockInfo.txt
	rm -f software/test_echo sim/sim_out.vvp
