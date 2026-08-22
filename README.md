# FPGA 100BASE-TX Ethernet Echo MAC (Digilent Arty A7-100T)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Verilog](https://img.shields.io/badge/HDL-Verilog--2001-blue.svg)](rtl/eth_echo_top.v)
[![Target Board](https://img.shields.io/badge/FPGA-Arty%20A7--100T-red.svg)](https://digilent.com/reference/programmable-logic/arty-a7/start)

A synthesizable, bare-metal hardware 10/100 Ethernet MAC and packet echo engine written in Verilog for the **Digilent Arty A7-100T (Xilinx Artix-7 `xc7a100tcsg324-1`)**.

The design connects to the onboard Texas Instruments **DP83848J** Ethernet PHY over the **MII (Media Independent Interface)**, receives standard Ethernet frames, filters/swaps destination and source MAC addresses in hardware, recalculates the **Ethernet CRC32 / FCS** on the fly, and echoes the packet payload back to the host at wire speed.

---

## 🌟 Key Features

- **Full MII Protocol Support**: Native 4-bit nibble TX/RX interfaces running at 25 MHz (100 Mbps).
- **Zero Soft-Core Overhead**: Pure Verilog hardware pipeline—no MicroBlaze, soft processor, or RTOS required.
- **Hardware MAC Address Swapping**: Seamlessly swaps sender and receiver MAC addresses for round-trip echo response.
- **On-the-fly Hardware CRC32 / FCS Generator**: Computes and appends IEEE 802.3 compliant Frame Check Sequence (polynomial `0xEDB88320` reflected) dynamically during packet transmission.
- **Clock Domain Crossing (CDC) Safe**: Implemented with dual-clock RAM buffering and handshake synchronization between 100 MHz system clock, 25 MHz RX clock, and 25 MHz TX clock domains.
- **Board Status Diagnostics**:
  - `LED[0]`: 100 MHz System Heartbeat (flashes continuously).
  - `LED[1]`: RX Activity pulse stretcher.
  - `LED[2]`: TX Activity pulse stretcher.
  - `LED[3]`: PHY Power-on Reset Complete / Ready.
- **Host Testing Utility**: Includes a high-performance Linux C program utilizing Raw Sockets (`AF_PACKET`) to benchmark latency and verify data integrity.

---

## 📁 Repository Structure

```
.
├── constraints/
│   └── arty_a7_100t_eth.xdc   # Vivado pinouts, IO standards, and CDC timing constraints
├── docs/                      # Architectural diagrams and documentation
├── rtl/
│   └── eth_echo_top.v         # Top-level Verilog module (PHY reset, RX/TX FSMs, CRC32, RAM)
├── scripts/
│   ├── build_bitstream.tcl    # Non-project batch script for Vivado synthesis & bitstream gen
│   └── program_fpga.tcl       # Hardware manager programming script
├── sim/
│   └── tb_eth_echo.v          # Self-checking testbench for Verilog simulation
├── software/
│   └── test_echo.c            # Linux Raw Socket (AF_PACKET) host verification tool
├── .gitignore                 # Ignore Vivado logs, bitstreams, and binaries
├── Makefile                   # Unified automation build file
└── README.md
```

---

## 🚀 Getting Started

### Prerequisites

- **Hardware**: Digilent Arty A7-100T FPGA board (`xc7a100tcsg324-1`), Micro-USB cable (for JTAG programming), and standard RJ45 Cat5e/Cat6 Ethernet cable.
- **Simulation**: [Icarus Verilog](http://iverilog.icarus.com/) (`sudo apt install iverilog`) or Vivado Simulator (`xsim`).
- **Synthesis & Implementation**: AMD/Xilinx Vivado (ML Standard / Lab Edition 2020.1 or newer).
- **Host Testing**: Linux OS with standard `gcc` and `make`.

### Vivado Environment Setup

To run `make bitstream` or `make program` from the command line, make sure Vivado's environment variables are sourced in your shell:

```bash
# Example for default Vivado installation path on Linux:
source /tools/Xilinx/Vivado/202x.x/settings64.sh

# Or ensure 'vivado' is in your PATH:
export PATH=$PATH:/path/to/Xilinx/Vivado/202x.x/bin
```

*(Alternatively, you can open the Vivado GUI, create an RTL project with `rtl/eth_echo_top.v` as design source, `constraints/arty_a7_100t_eth.xdc` as constraints, and click **Generate Bitstream**).*

---

## 🔨 Building and Running

A top-level [`Makefile`](Makefile) is provided for easy project navigation:

```bash
# View available make targets
make sim         # Run testbench simulation (via Icarus Verilog)
make software    # Build the C host testing tool
make bitstream   # Run non-project Vivado synthesis and generate bitstream (.bit)
make program     # Program the connected Arty A7 FPGA
make clean       # Clean up temporary build artifacts and logs
```

### 1. Simulation Verification

Verify the packet reception, MAC swap, and CRC calculation without hardware:

```bash
make sim
```
Or run specifically using Icarus Verilog:
```bash
make sim-iverilog
```

*Expected output:*
```text
=== STARTING ETHERNET ECHO SIMULATION ===
--> Test Packet Injected into RX. Waiting for TX Echo response...
55 55 55 55 55 55 55 d5 30 13 8b c1 3c ce 00 18 
3e 04 c5 52 88 b5 48 45 4c 4c 4f 20 46 50 47 41 
21 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 
...
=== [SIM MONITOR] Transmitted frame complete! Total bytes: 72 ===

=== SIMULATION PASSED ===
```

### 2. Synthesize & Generate Bitstream

To run batch non-project synthesis, place & route, and generate the bitstream under `build/eth_echo_top.bit`:

```bash
make bitstream
```

### 3. Program the FPGA

Connect your Arty A7 board via USB and run:

```bash
make program
```
*Verify that `LED[0]` starts blinking (heartbeat) and `LED[3]` turns ON solid (PHY reset finished).*

---

## 🧪 Testing with Host PC (Linux)

1. Connect the Arty A7 Ethernet port directly to your PC's Ethernet interface (e.g. `eth0` or `eno1`), or via a network switch.
2. Compile the host utility:
   ```bash
   make software
   ```
3. Run the test program with `sudo` (raw packet sockets require root or `CAP_NET_RAW` privileges):
   ```bash
   sudo ./software/test_echo <interface_name> [optional_message]
   ```

**Example Run:**
```bash
sudo ./software/test_echo eno1 "Hello FPGA 100Mbps Ethernet!"
```

**Output:**
```text
=== Raw Ethernet Echo Tester ===
Target Interface: eno1
FPGA Target MAC:  00:18:3E:04:C5:52
Host Interface MAC: 30:13:8B:C1:3C:CE

--> Sending 60 bytes packet:
  00 18 3E 04 C5 52 30 13 8B C1 3C CE 88 B5 48 65 
  6C 6C 6F 20 46 50 47 41 20 31 30 30 4D 62 70 73 
  20 45 74 68 65 72 6E 65 74 21 00 00 00 00 00 00 
  00 00 00 00 00 00 00 00 00 00 00 00 
Payload string: "Hello FPGA 100Mbps Ethernet!"

<-- Waiting for echo from FPGA...
[SUCCESS] Echo packet received (60 bytes)!
  30 13 8B C1 3C CE 00 18 3E 04 C5 52 88 B5 48 65 
  6C 6C 6F 20 46 50 47 41 20 31 30 30 4D 62 70 73 
  20 45 74 68 65 72 6E 65 74 21 00 00 00 00 00 00 
  00 00 00 00 00 00 00 00 00 00 00 00 
EtherType: 0x88B5
Received Payload: "Hello FPGA 100Mbps Ethernet!"
>>> TEST PASSED: Payload perfectly matched! <<<
```

---

## ⚙️ Architecture & Packet Pipeline

```
              +-------------------------------------------------------+
              |               Arty A7 FPGA (Artix-7)                  |
              |                                                       |
 [RJ45 Cable] |   +-----------------+        +---------------------+  |
   =========> |-->|   MII RX FSM    |------->| Dual-Port Packet RAM|  |
              |   | (Preamble / SFD)|  Data  | (2048 x 8-bit)      |  |
              |   +-----------------+        +----------+----------+  |
              |                                         |             |
              |   +-----------------+                   |             |
              |   |   MII TX FSM    |<------------------+             |
   <========= |<--| + CRC32 Engine  | (Swap MAC & Compute FCS)        |
 [Echo Reply] |   +-----------------+                                 |
              +-------------------------------------------------------+
```

1. **PHY Initialization**: The system clock divider generates a clean 25 MHz reference clock (`eth_ref_clk`) and drives the PHY reset line (`eth_rstn`) for ~100 ms.
2. **Packet Capture (`eth_rx_clk`)**: Incoming nibbles are synchronized on the preamble `0x55` followed by SFD `0xD5`. Once synced, bytes are assembled and written into dual-port packet RAM.
3. **Trigger & MAC Swap (`eth_tx_clk`)**: When reception finishes, the transmission FSM is triggered. It transmits standard 7-byte preamble + 1-byte SFD, swaps Destination and Source MACs, forwards payload bytes from RAM, and calculates the 32-bit CRC in real time.
4. **FCS Injection**: Appends the 4-byte CRC checksum at the tail of the packet to form a strictly compliant standard Ethernet frame.

---

## 📜 License

This project is open-source under the [MIT License](LICENSE).
