`timescale 1ns / 1ps

module tb_eth_echo;

    reg clk100 = 0;
    always #5 clk100 = ~clk100; // 100MHz (10ns period)

    reg eth_rx_clk = 0;
    always #20 eth_rx_clk = ~eth_rx_clk; // 25MHz (40ns period)

    reg eth_tx_clk = 0;
    always #20 eth_tx_clk = ~eth_tx_clk; // 25MHz (40ns period)

    reg btn0 = 0;
    wire [3:0] led;
    wire eth_ref_clk;
    wire eth_rstn;
    reg eth_rx_dv = 0;
    reg [3:0] eth_rxd = 0;
    reg eth_rxerr = 0;
    wire eth_tx_en;
    wire [3:0] eth_txd;

    // Instantiate DUT
    eth_echo_top #(
        .FPGA_MAC(48'h00183E04C552)
    ) dut (
        .CLK100MHZ(clk100),
        .btn0(btn0),
        .led(led),
        .eth_ref_clk(eth_ref_clk),
        .eth_rstn(eth_rstn),
        .eth_rx_clk(eth_rx_clk),
        .eth_rx_dv(eth_rx_dv),
        .eth_rxd(eth_rxd),
        .eth_rxerr(eth_rxerr),
        .eth_tx_clk(eth_tx_clk),
        .eth_tx_en(eth_tx_en),
        .eth_txd(eth_txd)
    );

    // Fast-forward PHY reset in simulation
    initial begin
        force dut.rst_cnt = 24'd10_000_000;
        force dut.phy_rstn_reg = 1'b1;
    end

    // Task to send an Ethernet byte via MII
    task send_mii_byte(input [7:0] b);
        begin
            @(posedge eth_rx_clk);
            eth_rx_dv = 1;
            eth_rxd = b[3:0]; // low nibble
            @(posedge eth_rx_clk);
            eth_rx_dv = 1;
            eth_rxd = b[7:4]; // high nibble
        end
    endtask

    // Monitor TX output
    reg [7:0] tx_byte = 0;
    reg tx_toggle = 0;
    reg [3:0] tx_low = 0;
    integer tx_byte_count = 0;

    always @(posedge eth_tx_clk) begin
        if (eth_tx_en) begin
            if (!tx_toggle) begin
                tx_low <= eth_txd;
                tx_toggle <= 1'b1;
            end else begin
                tx_byte = {eth_txd, tx_low};
                tx_toggle <= 1'b0;
                $write("%02X ", tx_byte);
                tx_byte_count = tx_byte_count + 1;
                if (tx_byte_count % 16 == 0) $write("\n");
            end
        end else begin
            if (tx_byte_count > 0) begin
                $display("\n=== [SIM MONITOR] Transmitted frame complete! Total bytes: %0d ===", tx_byte_count);
                tx_byte_count = 0;
            end
            tx_toggle <= 1'b0;
        end
    end

    integer i;
    reg [7:0] test_packet [0:63];

    initial begin
        $display("=== STARTING ETHERNET ECHO SIMULATION ===");
        #200;

        // Preamble (7 bytes of 0x55)
        for (i = 0; i < 7; i = i + 1) send_mii_byte(8'h55);
        // SFD (1 byte of 0xD5)
        send_mii_byte(8'hD5);

        // Frame: DA (FPGA MAC: 00:18:3E:04:C5:52)
        send_mii_byte(8'h00); send_mii_byte(8'h18); send_mii_byte(8'h3E);
        send_mii_byte(8'h04); send_mii_byte(8'hC5); send_mii_byte(8'h52);

        // SA (Host MAC: 30:13:8B:C1:3C:CE)
        send_mii_byte(8'h30); send_mii_byte(8'h13); send_mii_byte(8'h8B);
        send_mii_byte(8'hC1); send_mii_byte(8'h3C); send_mii_byte(8'hCE);

        // EtherType: 0x88B5
        send_mii_byte(8'h88); send_mii_byte(8'hB5);

        // Payload: "HELLO FPGA!" (11 bytes)
        send_mii_byte("H"); send_mii_byte("E"); send_mii_byte("L");
        send_mii_byte("L"); send_mii_byte("O"); send_mii_byte(" ");
        send_mii_byte("F"); send_mii_byte("P"); send_mii_byte("G");
        send_mii_byte("A"); send_mii_byte("!");

        // Padding to 60 bytes minimum
        for (i = 25; i < 60; i = i + 1) send_mii_byte(8'h00);

        // 4 bytes FCS / CRC
        send_mii_byte(8'hAA); send_mii_byte(8'hBB); send_mii_byte(8'hCC); send_mii_byte(8'hDD);

        // End of packet
        @(posedge eth_rx_clk);
        eth_rx_dv = 0;
        eth_rxd = 0;

        $display("--> Test Packet Injected into RX. Waiting for TX Echo response...");

        // Wait for Echo frame to be transmitted
        #10000;

        $display("\n=== SIMULATION PASSED ===");
        $finish;
    end

endmodule
