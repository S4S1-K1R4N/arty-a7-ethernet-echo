open_hw_manager
connect_hw_server
open_hw_target
set device [get_hw_devices xc7a100t_0]
current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE {./build/eth_echo_top.bit} $device
program_hw_devices $device
refresh_hw_device $device
puts "=== FPGA PROGRAMMED SUCCESSFULLY ==="
close_hw_target
close_hw_manager
