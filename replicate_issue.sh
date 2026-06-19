#!/usr/bin/env bash
#
# Sierra Wireless EM7590 & Renesas uPD720202 Issue Replication Script
#
# This script simulates the "perfect storm" of failures described in ISSUE.md
# by triggering a simulated PCIe USB controller driver crash in the Guest.
#
# Usage:
#   ./replicate_issue.sh --trigger   - Triggers the simulated hardware crash loop (PID c082)
#   ./replicate_issue.sh --recover   - Recovers the modem back to healthy state (PID 90d3)
#   ./replicate_issue.sh --status    - Checks the replication state
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
    echo "  --trigger   Trigger the simulated controller crash / bootloader loop"
    echo "  --recover   Recover/reset the controller and modem back to online mode"
    echo "  --status    View active replication status"
    echo "  --help      Show this helper"
    echo ""
}

# Run command inside guest (either locally if inside guest, or via SSH if on host)
run_in_guest() {
    local cmd="$1"
    if [ -d "/sys/bus/pci/drivers/xhci_hcd" ]; then
        # Running directly inside the guest
        eval "$cmd"
    else
        # Running on host, execute via SSH
        local vm_key_path="${SCRIPT_DIR}/vm_key"
        if [ -f "$vm_key_path" ]; then
            ssh -i "$vm_key_path" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$cmd" 2>/dev/null || true
        else
            # Try to run ssh anyway with default config
            ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 "$cmd" 2>/dev/null || true
        fi
    fi
}

trigger_crash() {
    echo -e "${YELLOW}[*] Simulating data-peak current spikes and power instability...${NC}"
    
    # 1. Unbind the controller inside the guest to simulate controller death
    echo -e "${YELLOW}[*] Unbinding Renesas XHCI controller from xhci_hcd driver...${NC}"
    run_in_guest "PCI_ADDR=\$(lspci | grep -i -E 'nec corporation|renesas' | awk '{print \$1}' | head -n 1); if [ -n \"\$PCI_ADDR\" ]; then echo \"0000:\$PCI_ADDR\" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind; echo \"<3>xhci_hcd 0000:\$PCI_ADDR: xHCI host not responding to stop endpoint command\" | sudo tee /dev/kmsg; echo \"<3>xhci_hcd 0000:\$PCI_ADDR: HC died; cleaning up\" | sudo tee /dev/kmsg; fi"
    
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
    run_in_guest "PCI_ADDR=\$(lspci | grep -i -E 'nec corporation|renesas' | awk '{print \$1}' | head -n 1); if [ -n \"\$PCI_ADDR\" ]; then echo \"0000:\$PCI_ADDR\" | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind; fi"
    
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
        trigger_crash
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
