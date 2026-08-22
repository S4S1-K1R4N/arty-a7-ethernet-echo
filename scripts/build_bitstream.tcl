# Script to run non-project mode synthesis, implementation, and bitstream generation

# Root directory is the repository root
set outputDir ./build
file mkdir $outputDir

# 1. Read sources and constraints
read_verilog rtl/eth_echo_top.v
read_xdc constraints/arty_a7_100t_eth.xdc

# 2. Synthesis
synth_design -top eth_echo_top -part xc7a100tcsg324-1
write_checkpoint -force $outputDir/post_synth.dcp
report_timing_summary -file $outputDir/post_synth_timing_summary.rpt

# 3. Implementation
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $outputDir/post_route.dcp
report_timing_summary -file $outputDir/post_route_timing_summary.rpt
report_utilization -file $outputDir/post_route_util.rpt

# 4. Generate Bitstream
write_bitstream -force $outputDir/eth_echo_top.bit
puts "=== BITSTREAM GENERATION COMPLETE: $outputDir/eth_echo_top.bit ==="

