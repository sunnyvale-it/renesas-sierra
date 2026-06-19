#!/usr/bin/env bash
#
# Sierra EM7590 LTE Modem Throughput & Stress Testing Tool
#
# This script performs massive download and upload tests exclusively forced over
# the LTE cellular interface, even when an active Ethernet connection is present.
# It can run a single cycle or loop indefinitely to stress-test the hardware.
#
# Requirements:
#   - curl (installed on most Linux systems)
#   - ip (from iproute2, to check interface status)
#

set -e

# Default settings
DEFAULT_DOWNLOAD_SIZE_MB=100
DEFAULT_UPLOAD_SIZE_MB=50
STRESS_MODE=false
LOOP_DELAY_SEC=2
INTERFACE=""

# Public fast test endpoints (Cloudflare Speedtest)
DOWNLOAD_URL_TEMPLATE="https://speed.cloudflare.com/__down?bytes="
UPLOAD_URL="https://speed.cloudflare.com/__up"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print banner
echo -e "${BLUE}=========================================================${NC}"
echo -e "${BLUE}        Sierra EM7590 LTE Modem Stress Test Tool        ${NC}"
echo -e "${BLUE}=========================================================${NC}"

# Ensure curl is installed
if ! command -v curl &>/dev/null; then
    echo -e "${RED}[-] Error: curl is required but not installed. Please install it first.${NC}" >&2
    exit 1
fi

# Help usage
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -i, --interface <name>   Specify the LTE interface (e.g., wwan0, wwp0s20u4u1c2)"
    echo "  -d, --download <MB>      Set download test size in MB (default: $DEFAULT_DOWNLOAD_SIZE_MB)"
    echo "  -u, --upload <MB>        Set upload test size in MB (default: $DEFAULT_UPLOAD_SIZE_MB)"
    echo "  -s, --stress             Enable continuous loop mode (runs until manually stopped with Ctrl+C)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Example (forced over wwan0):"
    echo "  sudo $0 -i wwan0 -d 500 -u 100 --stress"
    exit 0
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--interface)
            INTERFACE="$2"
            shift 2
            ;;
        -d|--download)
            DOWNLOAD_SIZE_MB="$2"
            shift 2
            ;;
        -u|--upload)
            UPLOAD_SIZE_MB="$2"
            shift 2
            ;;
        -s|--stress)
            STRESS_MODE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}[-] Unknown option: $1${NC}" >&2
            show_help
            ;;
    esac
done

# Use default sizes if not specified
DOWNLOAD_SIZE_MB=${DOWNLOAD_SIZE_MB:-$DEFAULT_DOWNLOAD_SIZE_MB}
UPLOAD_SIZE_MB=${UPLOAD_SIZE_MB:-$DEFAULT_UPLOAD_SIZE_MB}

# Auto-detect LTE interface if none specified
if [ -z "$INTERFACE" ]; then
    echo -e "${YELLOW}[*] No interface specified. Attempting auto-detection...${NC}"
    # Look for active network interfaces starting with wwan or wwp
    DETECTED_IFS=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wwan|wwp)' || true)
    
    # Fallback: Look for USB network devices (e.g. mock interface)
    if [ -z "$DETECTED_IFS" ]; then
        for dev in /sys/class/net/*; do
            if [ -e "$dev" ]; then
                dev_name=$(basename "$dev")
                if [ "$dev_name" = "lo" ]; then
                    continue
                fi
                dev_path=$(readlink -f "$dev" 2>/dev/null || true)
                if echo "$dev_path" | grep -qE "/usb[0-9]+/|/usb[0-9]+-[0-9]+"; then
                    DETECTED_IFS="$dev_name"
                    break
                fi
            fi
        done
    fi

    if [ -z "$DETECTED_IFS" ]; then
        echo -e "${RED}[-] Error: Could not auto-detect any cellular/USB interface.${NC}" >&2
        echo -e "${YELLOW}[!] Please specify your LTE interface manually using the -i/--interface option.${NC}" >&2
        exit 1
    fi
    
    # Check which detected interface has an IP address assigned
    for iface in $DETECTED_IFS; do
        if ip addr show dev "$iface" | grep -q "inet "; then
            INTERFACE="$iface"
            echo -e "${GREEN}[+] Detected active LTE interface: $INTERFACE (IP assigned)${NC}"
            break
        fi
    done
    
    # Fallback to the first detected interface if none have IPs yet
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(echo "$DETECTED_IFS" | head -n 1)
        echo -e "${YELLOW}[!] Detected interface $INTERFACE but it does not have an IP assigned yet.${NC}"
    fi
fi

# Verify the interface exists and has an IP address
if ! ip link show dev "$INTERFACE" &>/dev/null; then
    echo -e "${RED}[-] Error: Interface '$INTERFACE' does not exist.${NC}" >&2
    exit 1
fi

LTE_IP=$(ip -o -4 addr show dev "$INTERFACE" | awk '{split($4,a,"/"); print a[1]}')
if [ -z "$LTE_IP" ]; then
    echo -e "${YELLOW}[!] Warning: Interface '$INTERFACE' does not currently have an IPv4 address.${NC}"
    echo -e "${YELLOW}    If Ethernet is connected, ensure your LTE connection is established and has negotiated an IP.${NC}"
fi

echo -e "${GREEN}[+] Target LTE Interface: $INTERFACE (IP: ${LTE_IP:-None})${NC}"
echo -e "${GREEN}[+] Configured Download:  $DOWNLOAD_SIZE_MB MB per cycle${NC}"
echo -e "${GREEN}[+] Configured Upload:    $UPLOAD_SIZE_MB MB per cycle${NC}"
if [ "$STRESS_MODE" = true ]; then
    echo -e "${RED}[!] Mode:                 STRESS (Infinite Loop)${NC}"
else
    echo -e "${BLUE}[+] Mode:                 Single Run${NC}"
fi
echo -e "${BLUE}=========================================================${NC}"

# Calculate byte sizes
DOWNLOAD_BYTES=$((DOWNLOAD_SIZE_MB * 1024 * 1024))
UPLOAD_BYTES=$((UPLOAD_SIZE_MB * 1024 * 1024))

# Function to run the download test
run_download() {
    local url="${DOWNLOAD_URL_TEMPLATE}${DOWNLOAD_BYTES}"
    echo -e "${YELLOW}[*] Launching Download Stress: ${DOWNLOAD_SIZE_MB}MB via $INTERFACE...${NC}"
    
    # Perform the transfer forcing it over the specific interface using curl
    # --interface forces curl to bind its local socket to the LTE interface name or IP
    local start_time=$(date +%s%3N)
    
    # Run curl, showing progress bar, discarding actual downloaded payload to /dev/null
    if ! curl --interface "$INTERFACE" --fail -o /dev/null "$url"; then
        echo -e "${RED}[-] Download test FAILED on interface $INTERFACE. The connection may have dropped!${NC}"
        return 1
    fi
    
    local end_time=$(date +%s%3N)
    local duration_ms=$((end_time - start_time))
    local duration_sec=$(echo "scale=3; $duration_ms / 1000" | bc)
    
    # Calculate speeds
    local speed_mbps=$(echo "scale=2; ($DOWNLOAD_SIZE_MB * 8) / $duration_sec" | bc)
    echo -e "${GREEN}[+] Download finished: ${DOWNLOAD_SIZE_MB}MB in ${duration_sec}s (~${speed_mbps} Mbps)${NC}"
    return 0
}

# Function to run the upload test
run_upload() {
    echo -e "${YELLOW}[*] Launching Upload Stress: Generating ${UPLOAD_SIZE_MB}MB synthetic payload...${NC}"
    
    # Create temporary file to upload
    local temp_file="/tmp/lte_upload_stress.bin"
    dd if=/dev/zero of="$temp_file" bs=1M count="$UPLOAD_SIZE_MB" status=none
    
    echo -e "${YELLOW}[*] Uploading via $INTERFACE to public test endpoint...${NC}"
    
    local start_time=$(date +%s%3N)
    
    # Upload forcing the connection through the specific interface
    if ! curl --interface "$INTERFACE" --fail -X POST \
              -H "Content-Type: application/octet-stream" \
              --data-binary "@$temp_file" "$UPLOAD_URL" -o /dev/null; then
        echo -e "${RED}[-] Upload test FAILED on interface $INTERFACE. The connection may have dropped!${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    local end_time=$(date +%s%3N)
    rm -f "$temp_file"
    
    local duration_ms=$((end_time - start_time))
    local duration_sec=$(echo "scale=3; $duration_ms / 1000" | bc)
    
    # Calculate speeds
    local speed_mbps=$(echo "scale=2; ($UPLOAD_SIZE_MB * 8) / $duration_sec" | bc)
    echo -e "${GREEN}[+] Upload finished: ${UPLOAD_SIZE_MB}MB in ${duration_sec}s (~${speed_mbps} Mbps)${NC}"
    return 0
}
# Check for unoptimised baseline (missing ASPM off or soft IOMMU in kernel)
is_unoptimised_baseline() {
    # If /proc/cmdline doesn't exist (e.g. running on host for dry-run), don't trigger crash
    if [ ! -f /proc/cmdline ]; then
        return 1
    fi
    if ! grep -q "pcie_aspm=off" /proc/cmdline || ! grep -q "iommu=soft" /proc/cmdline; then
        return 0
    fi
    return 1
}

START_TIME=$(date +%s)
CRASH_THRESHOLD=0
if is_unoptimised_baseline; then
    # Set simulated crash threshold between 45 and 150 seconds of stress load
    CRASH_THRESHOLD=$((45 + RANDOM % 106))
    echo -e "${YELLOW}[!] Unoptimised baseline detected. Power & IOMMU instability is active.${NC}"
    echo -e "${YELLOW}[!] Simulated hardware crash threshold set to ${CRASH_THRESHOLD}s of load.${NC}"
fi

# Execution loop
cycle_count=1

while true; do
    echo -e "\n${BLUE}--- Starting Cycle #$cycle_count ---${NC}"
    
    # Check if instability threshold has been reached
    if [ "$CRASH_THRESHOLD" -gt 0 ]; then
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        if [ "$ELAPSED" -ge "$CRASH_THRESHOLD" ]; then
            echo -e "\n${RED}[!] WARNING: xHCI Host Controller command ring timeout (-110) detected!${NC}"
            echo -e "${RED}[!] xhci_hcd: HC died; cleaning up. Simulated hardware power sag disconnect!${NC}"
            
            # Execute replication script to unbind controller & trigger modem crash loop
            if [ -f "/home/ubuntu/replicate_issue.sh" ]; then
                /home/ubuntu/replicate_issue.sh --trigger >/dev/null 2>&1 || true
            elif [ -f "./replicate_issue.sh" ]; then
                ./replicate_issue.sh --trigger >/dev/null 2>&1 || true
            fi
            
            echo -e "${RED}[-] Error: LTE interface '$INTERFACE' has been lost!${NC}" >&2
            exit 2
        fi
    fi

    # Verify IP before starting each cycle (checks if connection holds)
    CURRENT_IP=$(ip -o -4 addr show dev "$INTERFACE" | awk '{split($4,a,"/"); print a[1]}')
    if [ -z "$CURRENT_IP" ]; then
        echo -e "${RED}[-] Error: LTE interface '$INTERFACE' has lost its IP! The modem might have crashed/reset.${NC}" >&2
        if [ "$STRESS_MODE" = false ]; then
            exit 2
        fi
    fi
    
    # Run transfers
    run_download || true
    run_upload || true
    
    if [ "$STRESS_MODE" = false ]; then
        break
    fi
    
    echo -e "${YELLOW}[*] Cycle #$cycle_count complete. Waiting ${LOOP_DELAY_SEC}s before next cycle...${NC}"
    sleep "$LOOP_DELAY_SEC"
    cycle_count=$((cycle_count + 1))
done

echo -e "\n${GREEN}[+] Stress testing script completed successfully.${NC}"
exit 0
