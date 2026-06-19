#!/usr/bin/env bash
#
# Sierra Wireless EM7590 & Renesas uPD720202 Issue Replication Script
#
# This script simulates the "perfect storm" of failures described in ISSUE.md
# within the software-emulated virtual machine.
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
    echo "  --trigger   Trigger the simulated modem crash / bootloader loop"
    echo "  --recover   Recover/reset the modem back to online mode"
    echo "  --status    View active replication status"
    echo "  --help      Show this helper"
    echo ""
}

trigger_crash() {
    echo -e "${YELLOW}[*] Simulating data-peak current spikes and power instability...${NC}"
    echo -e "${YELLOW}[*] Triggering simulated bootloader crash loop (PID c082)...${NC}"
    touch "$CRASH_FILE"
    echo -e "${GREEN}[+] SUCCESS: Simulated crash triggered.${NC}"
    echo -e "${BLUE}[!] Action Required:${NC}"
    echo "  - Check your host 'mock_modem.py' terminal (it will log the dropped connection)."
    echo "  - Run 'sudo /home/ubuntu/monitor_modem.sh' inside the guest VM."
    echo "    (You will see: 'Modem USB State: CRASHED/BOOTLOADER LOOP [1199:c082]')"
    echo "    (You will see: 'AT Serial Port: UNAVAILABLE')"
}

recover_modem() {
    echo -e "${YELLOW}[*] Executing remediation protocol...${NC}"
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
        echo -e "State:          ${RED}CRASHED (Bootloader loop simulated - PID c082)${NC}"
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
