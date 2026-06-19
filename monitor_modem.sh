#!/usr/bin/env bash
#
# Sierra Wireless EM7590 & Renesas uPD720202 Live Monitoring Script
# This script monitors the PCIe USB Controller, USB Device States, 
# Serial Interface Port, Network Interface, and system logs to diagnose
# the 4-minute boot/reset loop and controller failure.
#
# Run this script during your replication/stress testing:
#   sudo ./monitor_modem.sh
#

# ANSI Color Codes for clean output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Hardware IDs
RENESAS_PCI="1912:0015"
RENESAS_PCI_MOCK="1033:0194"
SIERRA_VID="1199"
MOCK_SERIAL_VID_PID="0403:6001"
MOCK_NET_VID_PID="0525:a4a2"
PID_APP="90d3"
PID_BOOT1="c081"
PID_BOOT2="c082"

# Ports & Interfaces
AT_PORT="/dev/ttyUSB2"
if [ ! -c "$AT_PORT" ] && [ -c "/dev/ttyUSB0" ]; then
    AT_PORT="/dev/ttyUSB0"
fi

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}        Sierra EM7590 & Renesas uPD720202 Hardware Monitor       ${NC}"
echo -e "${BLUE}=================================================================${NC}"
echo -e "Press [CTRL+C] to stop monitoring.\n"

# Check if lspci and lsusb are installed
if ! command -v lspci &>/dev/null || ! command -v lsusb &>/dev/null; then
    echo -e "${RED}[!] Error: lspci or lsusb tools are missing. Please install pciutils and usbutils.${NC}"
    exit 1
fi

# Monitoring Loop
INTERVAL=2
SECONDS_ELAPSED=0

while true; do
    echo -e "${BLUE}--- [Time Elapsed: ${SECONDS_ELAPSED}s] ---${NC}"

    # 1. Check PCIe Bus for Renesas Controller
    PCI_STATUS=$(lspci -d "$RENESAS_PCI" 2>/dev/null)
    if [ -z "$PCI_STATUS" ]; then
        PCI_STATUS=$(lspci -d "$RENESAS_PCI_MOCK" 2>/dev/null)
    fi
    if [ -n "$PCI_STATUS" ]; then
        echo -e "PCIe Controller:  ${GREEN}DETECTED${NC} - $PCI_STATUS"
    else
        echo -e "PCIe Controller:  ${RED}MISSING${NC} (The Renesas card might have disappeared from the PCIe bus!)"
    fi

    # 2. Check USB Bus for Sierra EM7590 State
    USB_STATUS=$(lsusb -d "$SIERRA_VID:" 2>/dev/null)
    USB_STATUS_MOCK=$(lsusb -d "$MOCK_SERIAL_VID_PID" 2>/dev/null)
    if [ -n "$USB_STATUS" ]; then
        if echo "$USB_STATUS" | grep -q "$PID_APP"; then
            echo -e "Modem USB State:  ${GREEN}ONLINE (Application Mode)${NC} [1199:$PID_APP]"
        elif echo "$USB_STATUS" | grep -q "$PID_BOOT1"; then
            echo -e "Modem USB State:  ${YELLOW}BOOT/RESET MODE${NC} [1199:$PID_BOOT1] (Stuck in bootloader / loading FW)"
        elif echo "$USB_STATUS" | grep -q "$PID_BOOT2"; then
            echo -e "Modem USB State:  ${RED}CRASHED/BOOTLOADER LOOP${NC} [1199:$PID_BOOT2]"
        else
            echo -e "Modem USB State:  ${YELLOW}UNKNOWN SIERRA STATE${NC} ($USB_STATUS)"
        fi
    elif [ -n "$USB_STATUS_MOCK" ]; then
        if [ -f "/mnt/host_share/.modem_crash" ]; then
            echo -e "Modem USB State:  ${RED}CRASHED/BOOTLOADER LOOP (Simulated)${NC} [1199:$PID_BOOT2]"
        else
            echo -e "Modem USB State:  ${GREEN}ONLINE (MOCK MODE)${NC} [$MOCK_SERIAL_VID_PID]"
        fi
    else
        echo -e "Modem USB State:  ${RED}DISCONNECTED/OFFLINE${NC} (Not visible on the USB bus)"
    fi

    # 3. Check for Serial Command Port
    if [ -c "$AT_PORT" ]; then
        echo -e "AT Serial Port:   ${GREEN}AVAILABLE${NC} ($AT_PORT is open)"
    else
        echo -e "AT Serial Port:   ${RED}UNAVAILABLE${NC} (Check if the option serial driver is loaded or if ModemManager has locked it)"
    fi

    # 4. Check for Network Interface
    WWAN_IFACE=""
    # First try: Look at sysfs to identify USB network interfaces or wwan
    for dev in /sys/class/net/*; do
        if [ -e "$dev" ]; then
            dev_name=$(basename "$dev")
            if [ "$dev_name" = "lo" ]; then
                continue
            fi
            dev_path=$(readlink -f "$dev" 2>/dev/null || true)
            if echo "$dev_path" | grep -qE "/usb[0-9]+/|/usb[0-9]+-[0-9]+|/wwan"; then
                WWAN_IFACE="$dev_name"
                break
            fi
        fi
    done

    # Second try: Fallback to name heuristic
    if [ -z "$WWAN_IFACE" ]; then
        WWAN_IFACE=$(ip link show | grep -E "wwan|wwp|usb" | awk -F': ' '{print $2}' | head -n 1)
    fi

    if [ -n "$WWAN_IFACE" ]; then
        IFACE_STATE=$(ip -br link show dev "$WWAN_IFACE" | awk '{print $2}')
        if [ "$IFACE_STATE" = "UP" ] || [ "$IFACE_STATE" = "UNKNOWN" ]; then
            echo -e "Net Interface:    ${GREEN}UP${NC} ($WWAN_IFACE is active)"
        else
            echo -e "Net Interface:    ${YELLOW}DOWN${NC} ($WWAN_IFACE exists but is inactive)"
        fi
    else
        echo -e "Net Interface:    ${RED}NONE${NC} (No mobile broadband interface found)"
    fi

    # 5. Check Kernel Log for Controller Deaths or Command Timeouts
    KERNEL_ERRORS=$(dmesg | tail -n 50 | grep -Ei "xhci_hcd|hc died|command timeout|not responding" | tail -n 2)
    if [ -n "$KERNEL_ERRORS" ]; then
        echo -e "${RED}[!] Kernel Alert detected in xHCI host controller logs:${NC}"
        echo -e "$KERNEL_ERRORS"
    fi

    echo ""
    sleep $INTERVAL
    SECONDS_ELAPSED=$((SECONDS_ELAPSED + INTERVAL))
done
