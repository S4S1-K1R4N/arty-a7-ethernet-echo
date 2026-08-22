#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <arpa/inet.h>
#include <sys/time.h>

#define DEFAULT_IFNAME   "eno1"
#define FPGA_MAC_STR     "00:18:3E:04:C5:52"
#define CUSTOM_ETH_TYPE  0x88B5  // IEEE 802 Local Experimental EtherType
#define BUFFER_SIZE      1518

void print_hex(const unsigned char *buf, int len) {
    for (int i = 0; i < len; i++) {
        printf("%02X ", buf[i]);
        if ((i + 1) % 16 == 0) printf("\n  ");
    }
    printf("\n");
}

int main(int argc, char *argv[]) {
    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        printf("Usage: sudo %s <interface_name> [payload_message]\n", argv[0]);
        printf("Example: sudo %s eth0 \"Hello FPGA!\"\n", argv[0]);
        return 0;
    }

    const char *ifname = (argc > 1) ? argv[1] : DEFAULT_IFNAME;
    const char *msg = (argc > 2) ? argv[2] : "Hello FPGA Ethernet Echo!";

    printf("=== Raw Ethernet Echo Tester ===\n");
    printf("Target Interface: %s\n", ifname);
    printf("FPGA Target MAC:  %s\n", FPGA_MAC_STR);
    if (argc <= 1) {
        printf("(Tip: Pass interface as argument, e.g.: sudo %s eth0 \"Hello FPGA!\")\n", argv[0]);
    }

    // 1. Create raw packet socket
    int sock_fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sock_fd < 0) {
        perror("socket(AF_PACKET) failed (run as root / sudo)");
        return 1;
    }

    // Set receive timeout to 2 seconds
    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    setsockopt(sock_fd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));

    // 2. Get interface index and host MAC address
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    
    if (ioctl(sock_fd, SIOCGIFINDEX, &ifr) < 0) {
        perror("ioctl(SIOCGIFINDEX) failed");
        close(sock_fd);
        return 1;
    }
    int ifindex = ifr.ifr_ifindex;

    if (ioctl(sock_fd, SIOCGIFHWADDR, &ifr) < 0) {
        perror("ioctl(SIOCGIFHWADDR) failed");
        close(sock_fd);
        return 1;
    }
    unsigned char host_mac[6];
    memcpy(host_mac, ifr.ifr_hwaddr.sa_data, 6);

    printf("Host Interface MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
           host_mac[0], host_mac[1], host_mac[2], host_mac[3], host_mac[4], host_mac[5]);

    // Parse FPGA MAC
    unsigned char fpga_mac[6];
    sscanf(FPGA_MAC_STR, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
           &fpga_mac[0], &fpga_mac[1], &fpga_mac[2], &fpga_mac[3], &fpga_mac[4], &fpga_mac[5]);

    // 3. Prepare transmission buffer
    unsigned char tx_frame[BUFFER_SIZE];
    memset(tx_frame, 0, sizeof(tx_frame));

    // Ethernet Header: [Destination MAC (6)] [Source MAC (6)] [EtherType (2)]
    memcpy(tx_frame, fpga_mac, 6);
    memcpy(tx_frame + 6, host_mac, 6);
    tx_frame[12] = (CUSTOM_ETH_TYPE >> 8) & 0xFF;
    tx_frame[13] = CUSTOM_ETH_TYPE & 0xFF;

    // Payload
    int payload_len = strlen(msg);
    memcpy(tx_frame + 14, msg, payload_len);

    int total_tx_len = 14 + payload_len;
    if (total_tx_len < 60) total_tx_len = 60; // Ethernet minimum 60 bytes (before FCS)

    // 4. Setup sockaddr_ll
    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_ifindex = ifindex;
    sll.sll_halen = ETH_ALEN;
    memcpy(sll.sll_addr, fpga_mac, 6);

    printf("\n--> Sending %d bytes packet:\n  ", total_tx_len);
    print_hex(tx_frame, total_tx_len);
    printf("Payload string: \"%s\"\n", msg);

    // Send packet
    ssize_t bytes_sent = sendto(sock_fd, tx_frame, total_tx_len, 0, (struct sockaddr*)&sll, sizeof(sll));
    if (bytes_sent < 0) {
        perror("sendto failed");
        close(sock_fd);
        return 1;
    }

    // 5. Receive echoed packet
    printf("\n<-- Waiting for echo from FPGA...\n");
    unsigned char rx_frame[BUFFER_SIZE];
    while (1) {
        ssize_t bytes_rx = recvfrom(sock_fd, rx_frame, sizeof(rx_frame), 0, NULL, NULL);
        if (bytes_rx < 0) {
            printf("[TIMEOUT] No echo response received from FPGA within timeout.\n");
            break;
        }

        // Check if packet is destined to our host MAC and from FPGA MAC
        if (memcmp(rx_frame, host_mac, 6) == 0 && memcmp(rx_frame + 6, fpga_mac, 6) == 0) {
            printf("[SUCCESS] Echo packet received (%ld bytes)!\n  ", bytes_rx);
            print_hex(rx_frame, bytes_rx);

            // Check EtherType
            uint16_t rx_ethertype = (rx_frame[12] << 8) | rx_frame[13];
            printf("EtherType: 0x%04X\n", rx_ethertype);

            // Check payload
            char rx_payload[1500] = {0};
            int r_len = bytes_rx - 14;
            if (r_len > 0) {
                memcpy(rx_payload, rx_frame + 14, (r_len < (int)sizeof(rx_payload)-1) ? r_len : (int)sizeof(rx_payload)-1);
                printf("Received Payload: \"%s\"\n", rx_payload);
                if (strncmp(rx_payload, msg, payload_len) == 0) {
                    printf(">>> TEST PASSED: Payload perfectly matched! <<<\n");
                } else {
                    printf(">>> Payload contents differ. <<<\n");
                }
            }
            break;
        }
    }

    close(sock_fd);
    return 0;
}
