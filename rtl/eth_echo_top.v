`timescale 1ns / 1ps

module eth_echo_top #(
    parameter [47:0] FPGA_MAC = 48'h00183E04C552
)(
    // 100 MHz system clock from onboard oscillator
    input  wire        CLK100MHZ,
    input  wire        btn0,        // Active high reset button (btn[0])

    // Status LEDs
    output wire [3:0]  led,         // LED0: heartbeat, LED1: RX, LED2: TX, LED3: PHY ready

    // MII Ethernet Interface (TI DP83848J PHY)
    output wire        eth_ref_clk, // 25 MHz PHY reference clock
    output wire        eth_rstn,    // PHY active-low reset
    input  wire        eth_rx_clk,  // RX clock from PHY (25 MHz for 100Mbps)
    input  wire        eth_rx_dv,   // RX data valid
    input  wire [3:0]  eth_rxd,     // RX data [3:0]
    input  wire        eth_rxerr,   // RX error
    input  wire        eth_tx_clk,  // TX clock from PHY (25 MHz for 100Mbps)
    output reg         eth_tx_en,   // TX enable
    output reg  [3:0]  eth_txd      // TX data [3:0]
);

    //--------------------------------------------------------------------------
    // 1. Clocks and Reset
    //--------------------------------------------------------------------------
    // Generate 25 MHz eth_ref_clk from 100 MHz CLK100MHZ
    reg [1:0] clk_div = 2'b00;
    always @(posedge CLK100MHZ) begin
        clk_div <= clk_div + 1'b1;
    end
    assign eth_ref_clk = clk_div[1]; // 100 MHz / 4 = 25 MHz

    // Power-on reset generator for PHY (~100ms reset pulse)
    reg [23:0] rst_cnt = 24'd0;
    reg phy_rstn_reg = 1'b0;
    always @(posedge CLK100MHZ) begin
        if (btn0) begin
            rst_cnt <= 24'd0;
            phy_rstn_reg <= 1'b0;
        end else if (rst_cnt < 24'd10_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            phy_rstn_reg <= 1'b0;
        end else begin
            phy_rstn_reg <= 1'b1;
        end
    end
    assign eth_rstn = phy_rstn_reg;

    // Heartbeat counter for LED[0]
    reg [25:0] heartbeat_cnt = 26'd0;
    always @(posedge CLK100MHZ) heartbeat_cnt <= heartbeat_cnt + 1'b1;

    //--------------------------------------------------------------------------
    // 2. RX Path (Clock domain: eth_rx_clk)
    //--------------------------------------------------------------------------
    // MII transmits low nibble [3:0] first, then high nibble [7:4]
    reg rx_nibble_toggle = 1'b0;
    reg [3:0] rx_low_nibble = 4'd0;
    reg rx_in_frame = 1'b0;
    reg [1:0] rx_preamble_state = 2'd0;

    // Packet Buffer RAM (Dual Port: 2048 bytes)
    reg [7:0] rx_buffer [0:2047];
    reg [10:0] rx_wr_addr = 11'd0;
    reg [10:0] rx_packet_len = 11'd0;
    reg rx_packet_done = 1'b0;

    // Pulse stretcher for RX LED
    reg [19:0] rx_led_cnt = 20'd0;

    always @(posedge eth_rx_clk or negedge eth_rstn) begin
        if (!eth_rstn) begin
            rx_nibble_toggle <= 1'b0;
            rx_in_frame <= 1'b0;
            rx_preamble_state <= 2'd0;
            rx_wr_addr <= 11'd0;
            rx_packet_len <= 11'd0;
            rx_packet_done <= 1'b0;
            rx_led_cnt <= 20'd0;
        end else begin
            rx_packet_done <= 1'b0;

            if (rx_led_cnt > 0) rx_led_cnt <= rx_led_cnt - 1'b1;

            if (eth_rx_dv) begin
                if (!rx_in_frame) begin
                    // Preamble synchronization: Preamble is 0x55, SFD is 0xD5 (nibbles 0x5 then 0xD)
                    if (eth_rxd == 4'h5) begin
                        rx_preamble_state <= 2'd1;
                    end else if (rx_preamble_state == 2'd1 && eth_rxd == 4'hD) begin
                        // SFD detected! Next nibble is start of MAC Destination Address
                        rx_in_frame <= 1'b1;
                        rx_nibble_toggle <= 1'b0;
                        rx_wr_addr <= 11'd0;
                        rx_preamble_state <= 2'd0;
                    end else begin
                        rx_preamble_state <= 2'd0;
                    end
                end else begin
                    // Inside frame: assemble bytes
                    if (!rx_nibble_toggle) begin
                        rx_low_nibble <= eth_rxd;
                        rx_nibble_toggle <= 1'b1;
                    end else begin
                        rx_nibble_toggle <= 1'b0;
                        if (rx_wr_addr < 11'd2040) begin
                            rx_buffer[rx_wr_addr] <= {eth_rxd, rx_low_nibble};
                            rx_wr_addr <= rx_wr_addr + 1'b1;
                        end
                    end
                end
            end else begin
                // End of Frame (eth_rx_dv dropped)
                if (rx_in_frame) begin
                    rx_in_frame <= 1'b0;
                    rx_nibble_toggle <= 1'b0;
                    rx_preamble_state <= 2'd0;
                    // Check minimum valid packet length (14 bytes header + data + 4 bytes FCS)
                    if (rx_wr_addr >= 11'd18) begin
                        rx_packet_len <= rx_wr_addr - 11'd4; // Exclude received FCS
                        rx_packet_done <= 1'b1;
                        rx_led_cnt <= 20'hFFFFF;
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 3. CDC Handshake (RX clock domain -> TX clock domain)
    //--------------------------------------------------------------------------
    reg rx_done_toggle = 1'b0;
    always @(posedge eth_rx_clk or negedge eth_rstn) begin
        if (!eth_rstn)
            rx_done_toggle <= 1'b0;
        else if (rx_packet_done)
            rx_done_toggle <= ~rx_done_toggle;
    end

    reg [2:0] tx_sync_done = 3'd0;
    always @(posedge eth_tx_clk or negedge eth_rstn) begin
        if (!eth_rstn)
            tx_sync_done <= 3'd0;
        else
            tx_sync_done <= {tx_sync_done[1:0], rx_done_toggle};
    end
    wire tx_packet_trigger = (tx_sync_done[2] ^ tx_sync_done[1]);

    //--------------------------------------------------------------------------
    // 4. CRC32 Calculation
    //--------------------------------------------------------------------------
    reg [31:0] crc32 = 32'hFFFFFFFF;

    function [31:0] next_crc32;
        input [7:0] data;
        input [31:0] current_crc;
        reg [31:0] c;
        integer i;
        begin
            c = current_crc;
            for (i = 0; i < 8; i = i + 1) begin
                if ((c[0] ^ data[i]) == 1'b1)
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
            end
            next_crc32 = c;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 5. TX State Machine & Echo Engine (Clock domain: eth_tx_clk)
    //--------------------------------------------------------------------------
    localparam TX_IDLE      = 4'd0;
    localparam TX_PREAMBLE  = 4'd1;
    localparam TX_SFD       = 4'd2;
    localparam TX_PAYLOAD   = 4'd3;
    localparam TX_CRC       = 4'd4;
    localparam TX_IFG       = 4'd5;

    reg [3:0] tx_state = TX_IDLE;
    reg [10:0] tx_len = 11'd0;
    reg [10:0] tx_byte_idx = 11'd0;
    reg tx_nibble_sel = 1'b0;
    reg [4:0] tx_cnt = 5'd0;
    reg [7:0] tx_curr_byte = 8'd0;
    reg [31:0] final_crc = 32'd0;
    reg [19:0] tx_led_cnt = 20'd0;

    // Byte select helper for echo frame construction
    reg [7:0] next_tx_byte;
    always @(*) begin
        if (tx_byte_idx < 11'd6) begin
            // Destination MAC = Source MAC of received frame (bytes 6..11)
            next_tx_byte = rx_buffer[tx_byte_idx + 11'd6];
        end else if (tx_byte_idx < 11'd12) begin
            // Source MAC = FPGA Hardware MAC
            case (tx_byte_idx)
                11'd6:  next_tx_byte = FPGA_MAC[47:40];
                11'd7:  next_tx_byte = FPGA_MAC[39:32];
                11'd8:  next_tx_byte = FPGA_MAC[31:24];
                11'd9:  next_tx_byte = FPGA_MAC[23:16];
                11'd10: next_tx_byte = FPGA_MAC[15:8];
                11'd11: next_tx_byte = FPGA_MAC[7:0];
                default: next_tx_byte = 8'h00;
            endcase
        end else if (tx_byte_idx < rx_packet_len) begin
            // EtherType + Payload from received frame
            next_tx_byte = rx_buffer[tx_byte_idx];
        end else begin
            // Padding up to 60 bytes minimum frame length
            next_tx_byte = 8'h00;
        end
    end

    always @(posedge eth_tx_clk or negedge eth_rstn) begin
        if (!eth_rstn) begin
            tx_state <= TX_IDLE;
            eth_tx_en <= 1'b0;
            eth_txd <= 4'h0;
            tx_len <= 11'd0;
            tx_byte_idx <= 11'd0;
            tx_nibble_sel <= 1'b0;
            tx_cnt <= 5'd0;
            crc32 <= 32'hFFFFFFFF;
            tx_led_cnt <= 20'd0;
        end else begin
            if (tx_led_cnt > 0) tx_led_cnt <= tx_led_cnt - 1'b1;

            case (tx_state)
                TX_IDLE: begin
                    eth_tx_en <= 1'b0;
                    eth_txd <= 4'h0;
                    tx_nibble_sel <= 1'b0;
                    if (tx_packet_trigger) begin
                        tx_len <= (rx_packet_len < 11'd60) ? 11'd60 : rx_packet_len;
                        tx_state <= TX_PREAMBLE;
                        tx_cnt <= 5'd0;
                        crc32 <= 32'hFFFFFFFF;
                        tx_led_cnt <= 20'hFFFFF;
                    end
                end

                TX_PREAMBLE: begin
                    // Send 7 bytes of 0x55 (14 nibbles of 0x5)
                    eth_tx_en <= 1'b1;
                    eth_txd <= 4'h5;
                    tx_cnt <= tx_cnt + 1'b1;
                    if (tx_cnt == 5'd13) begin
                        tx_state <= TX_SFD;
                        tx_cnt <= 5'd0;
                    end
                end

                TX_SFD: begin
                    // Send SFD 0xD5 (nibbles: 0x5, then 0xD)
                    eth_tx_en <= 1'b1;
                    if (tx_cnt == 5'd0) begin
                        eth_txd <= 4'h5;
                        tx_cnt <= 5'd1;
                    end else begin
                        eth_txd <= 4'hD;
                        tx_state <= TX_PAYLOAD;
                        tx_byte_idx <= 11'd0;
                        tx_nibble_sel <= 1'b0;
                        tx_cnt <= 5'd0;
                    end
                end

                TX_PAYLOAD: begin
                    eth_tx_en <= 1'b1;
                    if (!tx_nibble_sel) begin
                        tx_curr_byte <= next_tx_byte;
                        eth_txd <= next_tx_byte[3:0]; // Low nibble
                        tx_nibble_sel <= 1'b1;
                    end else begin
                        eth_txd <= tx_curr_byte[7:4]; // High nibble
                        tx_nibble_sel <= 1'b0;

                        crc32 <= next_crc32(tx_curr_byte, crc32);

                        if (tx_byte_idx == tx_len - 1'b1) begin
                            tx_state <= TX_CRC;
                            tx_cnt <= 5'd0;
                            final_crc <= ~next_crc32(tx_curr_byte, crc32);
                        end else begin
                            tx_byte_idx <= tx_byte_idx + 1'b1;
                        end
                    end
                end

                TX_CRC: begin
                    // Send 4-byte CRC (8 nibbles, LSB first)
                    eth_tx_en <= 1'b1;
                    case (tx_cnt)
                        5'd0: eth_txd <= final_crc[3:0];
                        5'd1: eth_txd <= final_crc[7:4];
                        5'd2: eth_txd <= final_crc[11:8];
                        5'd3: eth_txd <= final_crc[15:12];
                        5'd4: eth_txd <= final_crc[19:16];
                        5'd5: eth_txd <= final_crc[23:20];
                        5'd6: eth_txd <= final_crc[27:24];
                        5'd7: eth_txd <= final_crc[31:28];
                    endcase

                    if (tx_cnt == 5'd7) begin
                        tx_state <= TX_IFG;
                        tx_cnt <= 5'd0;
                    end else begin
                        tx_cnt <= tx_cnt + 1'b1;
                    end
                end

                TX_IFG: begin
                    // Inter-frame gap: minimum 24 nibble clocks
                    eth_tx_en <= 1'b0;
                    eth_txd <= 4'h0;
                    if (tx_cnt == 5'd24) begin
                        tx_state <= TX_IDLE;
                    end else begin
                        tx_cnt <= tx_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    // LED indicators:
    assign led[0] = heartbeat_cnt[25];  // Blinks when clock is active
    assign led[1] = (rx_led_cnt > 0);   // Flashes on RX
    assign led[2] = (tx_led_cnt > 0);   // Flashes on TX
    assign led[3] = eth_rstn;           // On when PHY reset is de-asserted (normal run mode)

endmodule
