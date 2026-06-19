#!/usr/bin/env bash
#
# Sierra Wireless EM7590 & Renesas uPD720202 Issue Replication Script
#
# This script simulates the "perfect storm" of failures described in ISSUE.md
# by triggering a simulated PCIe USB controller driver crash in the Guest.
#
# Usage:
#   ./replicate_issue.sh --trigger [auto] - Triggers immediate or load-based hardware crash
#   ./replicate_issue.sh --recover        - Recovers the controller and modem back to online mode
#   ./replicate_issue.sh --status         - Checks the replication state
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRASH_FILE="${SCRIPT_DIR}/.modem_crash"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "Sierra EM7590 Replication Script"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --trigger [auto]   Trigger the simulated controller crash. If 'auto' is passed,"
    echo "                     it monitors guest network load and triggers autonomously after"
    echo "                     a delay of heavy traffic (reproducing the real 4-minute load bug)."
    echo "  --recover          Recover/reset the controller and modem back to online mode"
    echo "  --status           View active replication status"
    echo "  --help             Show this helper"
    echo ""
}

# Run command inside guest (either locally if inside guest, or via SSH if on host)
run_in_guest() {
    local cmd="$1"
    if [ -d "/sys/bus/pci/drivers/xhci_hcd" ]; then
        eval "$cmd"
    else
        local vm_key_path="${SCRIPT_DIR}/vm_key"
        if [ -f "$vm_key_path" ]; then
            ssh -i "$vm_key_path" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$cmd" 2>/dev/null || true
        else
            ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$cmd" 2>/dev/null || true
        fi
    fi
}

check_guest_unoptimised() {
    if [ -d "/sys/bus/pci/drivers/xhci_hcd" ]; then
        if ! grep -q "pcie_aspm=off" /proc/cmdline || ! grep -q "iommu=soft" /proc/cmdline; then
            return 0 # Unoptimised
        fi
        return 1 # Optimised
    else
        local vm_key_path="${SCRIPT_DIR}/vm_key"
        local check_cmd="! grep -q 'pcie_aspm=off' /proc/cmdline || ! grep -q 'iommu=soft' /proc/cmdline"
        if [ -f "$vm_key_path" ]; then
            if ssh -i "$vm_key_path" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$check_cmd" 2>/dev/null; then
                return 0 # Unoptimised
            fi
        else
            if ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$check_cmd" 2>/dev/null; then
                return 0 # Unoptimised
            fi
        fi
        return 1 # Optimised
    fi
}

get_network_bytes() {
    local iface="$1"
    local rx=0
    local tx=0
    if [ -f "/sys/class/net/${iface}/statistics/rx_bytes" ]; then
        rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes")
    fi
    if [ -f "/sys/class/net/${iface}/statistics/tx_bytes" ]; then
        tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes")
    fi
    echo $((rx + tx))
}

detect_guest_interface() {
    local iface=""
    for dev in /sys/class/net/*; do
        if [ -e "$dev" ]; then
            local dev_name=$(basename "$dev")
            if [ "$dev_name" = "lo" ]; then continue; fi
            local dev_path
            dev_path=$(readlink -f "$dev" 2>/dev/null || true)
            if echo "$dev_path" | grep -qE "/usb[0-9]+/|/usb[0-9]+-[0-9]+|/wwan"; then
                iface="$dev_name"
                break
            fi
        fi
    done
    if [ -z "$iface" ]; then
        iface=$(ip link show | grep -E "wwan|wwp|usb" | awk -F': ' '{print $2}' | head -n 1)
    fi
    echo "$iface"
}

monitor_load_and_trigger() {
    if ! check_guest_unoptimised; then
        echo -e "${GREEN}[+] System is currently optimised (stabilised). Instability threshold will not trigger under load.${NC}"
        exit 0
    fi

    # Detect active USB net interface inside Guest
    local iface
    iface=$(detect_guest_interface)
    if [ -z "$iface" ]; then
        echo -e "${RED}[-] Error: No active mobile broadband/USB net interface found to monitor.${NC}"
        exit 1
    fi
    
    local threshold=$((45 + RANDOM % 106)) # 45 to 150 seconds
    echo -e "${YELLOW}[*] Monitoring network interface '$iface' for heavy traffic load...${NC}"
    echo -e "${YELLOW}[*] Instability threshold set to ${threshold}s of load before crash.${NC}"
    echo -e "${BLUE}[*] Start your throughput test now (e.g. lte_stress_test.sh). Waiting for load...${NC}"
    
    local prev_bytes
    prev_bytes=$(get_network_bytes "$iface")
    local load_duration=0
    
    while true; do
        sleep 2
        local curr_bytes
        curr_bytes=$(get_network_bytes "$iface")
        local diff=$((curr_bytes - prev_bytes))
        prev_bytes="$curr_bytes"
        
        # Rate in KB/s over 2 seconds
        local rate_kb=$((diff / 2 / 1024))
        
        if [ "$rate_kb" -gt 100 ]; then # Stress load active (> 100 KB/s)
            load_duration=$((load_duration + 2))
            echo -e "${YELLOW}[!] Load detected: ~${rate_kb} KB/s. Accumulated stress: ${load_duration}/${threshold}s${NC}"
            
            if [ "$load_duration" -ge "$threshold" ]; then
                echo -e "\n${RED}[!] WARNING: Instability threshold reached! Triggering host controller death...${NC}"
                trigger_immediate_crash
                break
            fi
        else
            if [ "$load_duration" -gt 0 ]; then
                load_duration=$((load_duration - 1)) # decay slowly when idle
            fi
        fi
    done
}

trigger_immediate_crash() {
    echo -e "${YELLOW}[*] Simulating data-peak current spikes and power instability...${NC}"
    
    # 1. Unbind the controller inside the guest to simulate controller death
    echo -e "${YELLOW}[*] Unbinding Renesas XHCI controller from xhci_hcd driver...${NC}"
    run_in_guest "PCI_ADDR=\$(lspci | grep -i -E 'nec corporation|renesas' | awk '{print \$1}' | head -n 1); if [ -n \"\$PCI_ADDR\" ]; then if [ -e \"/sys/bus/pci/drivers/xhci_hcd/0000:\$PCI_ADDR\" ]; then echo \"0000:\$PCI_ADDR\" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind; fi; echo \"<3>xhci_hcd 0000:\$PCI_ADDR: xHCI host not responding to stop endpoint command\" | sudo tee /dev/kmsg; echo \"<3>xhci_hcd 0000:\$PCI_ADDR: HC died; cleaning up\" | sudo tee /dev/kmsg; fi"
    
    # 2. Trigger the mock modem to disconnect by writing flag file
    echo -e "${YELLOW}[*] Triggering simulated bootloader crash loop (PID c082)...${NC}"
    touch "$CRASH_FILE"
    
    echo -e "${GREEN}[+] SUCCESS: Simulated controller crash triggered.${NC}"
    echo -e "${BLUE}[!] Action Required:${NC}"
    echo "  - Check your host 'mock_modem.py' terminal (it will log the dropped connection)."
    echo "  - Run 'sudo /home/ubuntu/monitor_modem.sh' inside the guest VM."
    echo "    (You will see: 'PCIe Controller: ERROR - (xHCI Driver Detached/Crashed!)')"
    echo "    (You will see: 'Modem USB State: CRASHED/BOOTLOADER LOOP [1199:c082]')"
    echo "    (You will see: 'AT Serial Port: UNAVAILABLE' and 'Net Interface: NONE')"
}

recover_modem() {
    echo -e "${YELLOW}[*] Executing remediation protocol...${NC}"
    
    # 1. Bind the controller back to xhci_hcd inside the guest
    echo -e "${YELLOW}[*] Re-binding Renesas XHCI controller to xhci_hcd driver...${NC}"
    run_in_guest "PCI_ADDR=\$(lspci | grep -i -E 'nec corporation|renesas' | awk '{print \$1}' | head -n 1); if [ -n \"\$PCI_ADDR\" ]; then if [ ! -e \"/sys/bus/pci/drivers/xhci_hcd/0000:\$PCI_ADDR\" ]; then echo \"0000:\$PCI_ADDR\" | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind; else echo \"Controller is already bound to xhci_hcd driver.\"; fi; fi"
    
    # 2. Remove the mock crash flag
    if [ -f "$CRASH_FILE" ]; then
        rm -f "$CRASH_FILE"
        echo -e "${GREEN}[+] SUCCESS: Modem crash state cleared.${NC}"
        echo -e "${BLUE}[!] Action Required:${NC}"
        echo "  - The mock_modem.py daemon on your host will reconnect automatically."
        echo "  - The guest VM's 'monitor_modem.sh' will show the device back ONLINE."
    else
        echo -e "${GREEN}[+] System is already running normally.${NC}"
    fi
}

check_status() {
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "       Sierra EM7590 Replication Status"
    echo -e "${BLUE}=========================================================${NC}"
    if [ -f "$CRASH_FILE" ]; then
        echo -e "State:          ${RED}CRASHED (USB Host Controller driver detached & c082 loop simulated)${NC}"
        echo "AT Port:        UNAVAILABLE (Mock serial socket disconnected)"
    else
        echo -e "State:          ${GREEN}HEALTHY (Online application mode - PID 90d3)${NC}"
        echo "AT Port:        AVAILABLE"
    fi
    echo -e "${BLUE}=========================================================${NC}"
}

# Routing
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

case "$1" in
    --trigger)
        if [[ $# -gt 1 && "$2" == "auto" ]]; then
            # Perform load-based replication
            if [ -d "/sys/bus/pci/drivers/xhci_hcd" ]; then
                monitor_load_and_trigger
            else
                echo -e "${YELLOW}[*] Launching load-based crash monitor inside guest VM over SSH...${NC}"
                local vm_key_path="${SCRIPT_DIR}/vm_key"
                if [ -f "$vm_key_path" ]; then
                    ssh -i "$vm_key_path" -p 2222 -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "/home/ubuntu/replicate_issue.sh --trigger auto" || true
                else
                    ssh -p 2222 -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "/home/ubuntu/replicate_issue.sh --trigger auto" || true
                fi
            fi
        else
            # Perform immediate replication
            trigger_immediate_crash
        fi
        ;;
    --recover)
        recover_modem
        ;;
    --status)
        check_status
        ;;
    -h|--help)
        show_help
        ;;
    *)
        echo -e "${RED}[-] Unknown option: $1${NC}"
        show_help
        exit 1
        ;;
esac
