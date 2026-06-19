#!/usr/bin/env bash
#
# Sierra EM7590 / Renesas uPD720202 Integration & Testing Tool
# This script automates toggling between the STABLE (Stabilised) environment 
# and the BUG (Reproduction) environment on standard Linux (Debian/Ubuntu/Arch) hosts.
#
# Usage:
#   sudo ./configure_baseline.sh --stabilise
#   sudo ./configure_baseline.sh --reproduce
#   sudo ./configure_baseline.sh --status
#

set -e

# System Paths
GRUB_DEFAULT="/etc/default/grub"
UDEV_RULE_PATH="/etc/udev/rules.d/99-sierra-em7590.rules"
MODEM_VID="1199"
MODEM_PID_APP="90d3"
MODEM_PID_BOOT1="c081"
MODEM_PID_BOOT2="c082"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Please run this script as root (sudo)." >&2
    exit 1
fi

# Helper: Detect GRUB update command
update_grub_config() {
    echo "[*] Rebuilding GRUB bootloader configuration..."
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "[!] Warning: Could not find update-grub or grub-mkconfig."
        echo "    Please manually rebuild your GRUB configuration file."
    fi
}

show_status() {
    echo "========================================================="
    echo " Current System Configuration & Troubleshooting Status"
    echo "========================================================="
    
    # Check Active State Power Management (ASPM) in running kernel
    echo -n "Active ASPM State: "
    if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
        cat /sys/module/pcie_aspm/parameters/policy
    else
        echo "Not available / Unknown"
    fi

    # Check GRUB command line
    echo -n "Kernel Boot Command Line: "
    cat /proc/cmdline
    echo ""

    # Check udev rules
    if [ -f "$UDEV_RULE_PATH" ]; then
        echo "[+] Sierra EM7590 Active udev Rules ($UDEV_RULE_PATH):"
        cat "$UDEV_RULE_PATH"
    else
        echo "[-] No active udev rules found at $UDEV_RULE_PATH (Default OS configuration)"
    fi
    echo "========================================================="
}

apply_stabilised() {
    echo "========================================================="
    echo " Applying Stabilisation Configurations"
    echo "========================================================="

    # 1. Disable PCIe ASPM (Active State Power Management)
    # This prevents the Renesas uPD720202 from dropping into low-power states
    # that the Sierra EM7590 modem cannot recover from.
    if [ -f "$GRUB_DEFAULT" ]; then
        echo "[*] Configuring kernel boot parameters in $GRUB_DEFAULT..."
        # Remove any existing pcie_aspm or iommu parameters to prevent duplication
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)pcie_aspm=[a-zA-Z]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)intel_iommu=[a-zA-Z0-9]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)iommu=[a-zA-Z0-9]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        
        # Insert target configuration (ASPM off, soft IOMMU to mitigate Renesas controller timeouts)
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off iommu=soft /' "$GRUB_DEFAULT"
        # Clean up any trailing/double spaces
        sed -i 's/  */ /g' "$GRUB_DEFAULT"
        echo "[+] Added 'pcie_aspm=off iommu=soft' to GRUB default parameters."
        update_grub_config
    else
        echo "[-] Error: $GRUB_DEFAULT not found. Cannot configure boot parameters." >&2
    fi

    # 2. Configure udev rules to disable USB Autosuspend
    # Forces the Renesas controller to maintain an active power channel.
    echo "[*] Creating udev rules for Sierra EM7590 (VID: $MODEM_VID)..."
    cat <<EOF > "$UDEV_RULE_PATH"
# Disable USB autosuspend for Sierra Wireless / Semtech EM7590 Modem
# VID: 1199, PIDs: 90d3 (App Mode), c081 (Bootloader), c082 (Bootloader loop)

ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="$MODEM_VID", ATTR{idProduct}=="$MODEM_PID_APP", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="$MODEM_VID", ATTR{idProduct}=="$MODEM_PID_BOOT1", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="$MODEM_VID", ATTR{idProduct}=="$MODEM_PID_BOOT2", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF
    echo "[+] Created $UDEV_RULE_PATH with autosuspend overrides."
    
    # Reload udev rules
    echo "[*] Triggering udev rules reload..."
    udevadm control --reload-rules
    udevadm trigger
    
    echo ""
    echo "[+] SUCCESS: System configured for STABILITY."
    echo "[!] A system REBOOT is required to apply the kernel boot parameters."
    echo "========================================================="
}

apply_reproduce() {
    echo "========================================================="
    echo " Restoring Unoptimised Settings (Reproduction Mode)"
    echo "========================================================="

    # 1. Enable default PCIe ASPM & Force full hardware IOMMU
    # This exposes the Renesas controller's sensitivity to LPM transitions
    # and forces high-overhead xHCI command tracking, triggering timeouts.
    if [ -f "$GRUB_DEFAULT" ]; then
        echo "[*] Restoring buggy kernel boot parameters in $GRUB_DEFAULT..."
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)pcie_aspm=[a-zA-Z]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)intel_iommu=[a-zA-Z0-9]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)iommu=[a-zA-Z0-9]*\(.*\)"/\1\2"/' "$GRUB_DEFAULT"
        
        # Set to native hardware IOMMU and leave ASPM to default configuration (active power saving)
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on /' "$GRUB_DEFAULT"
        sed -i 's/  */ /g' "$GRUB_DEFAULT"
        echo "[+] Restored default ASPM policies and enabled active hardware IOMMU ('intel_iommu=on')."
        update_grub_config
    else
        echo "[-] Error: $GRUB_DEFAULT not found. Cannot configure boot parameters." >&2
    fi

    # 2. Remove udev rules to restore default 2000ms USB Autosuspend
    if [ -f "$UDEV_RULE_PATH" ]; then
        echo "[*] Deleting udev rules..."
        rm -f "$UDEV_RULE_PATH"
        echo "[+] Deleted $UDEV_RULE_PATH. Modem will revert to default 2000ms idle sleep."
    else
        echo "[+] No custom udev rules are active. System already runs default USB autosuspend."
    fi

    # Reload udev rules to clear state
    echo "[*] Triggering udev rules reload..."
    udevadm control --reload-rules
    udevadm trigger

    echo ""
    echo "[+] SUCCESS: System returned to UNOPTIMISED BASELINE."
    echo "[!] A system REBOOT is required to activate the IOMMU parameters."
    echo "========================================================="
}

# Main routing
case "$1" in
    --stabilise|--stabilize)
        apply_stabilised
        ;;
    --reproduce)
        apply_reproduce
        ;;
    --status)
        show_status
        ;;
    *)
        echo "Usage: sudo $0 {--stabilise|--reproduce|--status}"
        echo ""
        echo "  --stabilise   Apply kernel parameters and udev rules to resolve modem freezes"
        echo "  --reproduce   Restore default power settings to attempt reproducing the issue"
        echo "  --status      Inspect the current GRUB commandline and active udev overrides"
        exit 1
        ;;
esac
