#!/usr/bin/env bash
# ==============================================================================
# QEMU Launcher Script for macOS / Linux Hosts
# ==============================================================================
# Simulates x64 architecture, NEC/Renesas XHCI, and passes through Sierra LTE.

set -euo pipefail

# Find script directory and load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/vm_config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[-] Error: Configuration file not found at ${CONFIG_FILE}" >&2
    exit 1
fi

# Source configuration variables
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Default ISO and dry-run parameters
ISO_PATH=""
DRY_RUN=false
DETACHED=false

# Help message
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -i, --iso <path>       Path to OS installation ISO (optional)"
    echo "  -d, --dry-run          Show the QEMU command that would run, but do not execute"
    echo "  -b, --background       Run VM in the background (detached mode)"
    echo "  -h, --help             Show this help message"
    echo ""
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iso)
            ISO_PATH="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -b|--background)
            DETACHED=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            usage
            ;;
    esac
done

echo "[+] Initializing Renesas & Sierra QEMU Architecture on macOS..."

# 1. Dependency Check
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo "[-] Error: qemu-system-x86_64 is not installed." >&2
    echo "    Install it using: brew install qemu" >&2
    exit 1
fi

# 2. Disk Image Management
DISK_PATH="${SCRIPT_DIR}/${VM_DISK}"
if [[ ! -f "$DISK_PATH" ]]; then
    echo "[+] Disk image not found. Creating a $VM_DISK_SIZE QCOW2 image at:"
    echo "    $DISK_PATH"
    if [[ "$DRY_RUN" = false ]]; then
        qemu-img create -f qcow2 "$DISK_PATH" "$VM_DISK_SIZE"
    fi
else
    echo "[+] Using existing disk image at: $DISK_PATH"
    if [[ "$DRY_RUN" = false ]]; then
        echo "[+] Ensuring disk image is resized to $VM_DISK_SIZE..."
        qemu-img resize "$DISK_PATH" "$VM_DISK_SIZE" > /dev/null 2>&1 || true
    fi
fi

# 2.5 Cloud-Init Configuration (For Ubuntu Cloud Images)
if [[ -z "$ISO_PATH" ]]; then
    # Automatically generate an SSH key pair for passwordless SSH access
    echo "[+] Generating fresh SSH key pair (vm_key) for VM login..."
    rm -f "${SCRIPT_DIR}/vm_key" "${SCRIPT_DIR}/vm_key.pub"
    ssh-keygen -t ed25519 -N "" -f "${SCRIPT_DIR}/vm_key" -q
    SSH_PUB_KEY=$(cat "${SCRIPT_DIR}/vm_key.pub")
    
    # Automatically prune conflicting host key entries on port 2222
    ssh-keygen -R "[127.0.0.1]:2222" &>/dev/null || true

    if command -v hdiutil &> /dev/null; then
        echo "[+] Generating cloud-init.iso to configure Ubuntu Cloud Image login..."
        rm -f "${SCRIPT_DIR}/cloud-init.iso"
        TEMP_DIR=$(mktemp -d)
        
        cat <<EOF > "${TEMP_DIR}/user-data"
#cloud-config
ssh_pwauth: True
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
chpasswd:
  list: |
    ubuntu:password123
  expire: False
mounts:
  - [ host_share, /mnt/host_share, 9p, "trans=virtio,version=9p2000.L,_netdev", "0", "0" ]
runcmd:
  - apt-get update
  - apt-get install -y linux-modules-extra-\$(uname -r)
  - modprobe ftdi_sio
  - modprobe cdc_ether
  - cp /mnt/host_share/configure_baseline.sh /home/ubuntu/
  - cp /mnt/host_share/monitor_modem.sh /home/ubuntu/
  - cp /mnt/host_share/lte_stress_test.sh /home/ubuntu/
  - chown ubuntu:ubuntu /home/ubuntu/*.sh
  - chmod +x /home/ubuntu/*.sh
EOF

        echo "local-hostname: renesas-sierra-vm" > "${TEMP_DIR}/meta-data"
        echo "instance-id: i-renesas-sierra-vm-$(date +%s)" >> "${TEMP_DIR}/meta-data"

        cat <<EOF > "${TEMP_DIR}/network-config"
version: 2
ethernets:
  enp0s2:
    dhcp4: true
    optional: true
  all-en:
    match:
      name: "en*"
    dhcp4: true
    optional: true
  all-usb:
    match:
      name: "usb*"
    dhcp4: true
    optional: true
EOF

        hdiutil makehybrid -o "${SCRIPT_DIR}/cloud-init.iso" -hfs -joliet -iso -default-volume-name cidata "${TEMP_DIR}" > /dev/null 2>&1 || true
        rm -rf "${TEMP_DIR}"
        echo "[+] Created cloud-init.iso (Username: 'ubuntu', Password: 'password123')."
    fi
fi


# 3. CPU Acceleration Detection
HOST_ARCH="$(uname -m)"
ACCEL_FLAGS=""

echo "[+] Host architecture detected: ${HOST_ARCH}"
if [[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "i386" ]]; then
    echo "[+] Enabling hardware acceleration via macOS Hypervisor.framework (hvf)"
    ACCEL_FLAGS="-accel hvf -cpu host"
else
    echo "[!] Warning: Host is ARM64 (Apple Silicon). x64 virtualization requires TCG software emulation."
    echo "    Performance will be significantly reduced."
    ACCEL_FLAGS="-accel tcg,thread=multi -cpu max"
fi

# 4. Hardware USB Configuration (Sierra Wireless EM7590 / Mock Emulation)
USB_FLAGS=""
PASSTHROUGH_ACTIVE=false

if [[ "${MOCK_MODE:-false}" == "true" ]]; then
    echo "[+] Running in 100% Software Emulation / Mock Mode (MOCK_MODE=true)."
    echo "[+] Attaching virtual USB-serial port linked to TCP port ${MOCK_SERIAL_PORT} (AT commands)..."
    echo "[+] Attaching virtual USB-net adapter linked to user network (mobile broadband)..."
    
    USB_FLAGS="-chardev socket,id=modem_serial,host=127.0.0.1,port=${MOCK_SERIAL_PORT},server=on,wait=off"
    USB_FLAGS+=" -device usb-serial,bus=${USB_CONTROLLER_ID}.0,chardev=modem_serial"
    USB_FLAGS+=" -netdev user,id=net_modem,net=10.0.3.0/24 -device usb-net,bus=${USB_CONTROLLER_ID}.0,netdev=net_modem"
else
    # On macOS, check if the USB device is present using system_profiler
    echo "[+] Checking for physical Sierra Wireless EM7590 (VID: $MODEM_VENDOR_ID, PID: $MODEM_PRODUCT_ID)..."
    if command -v system_profiler &> /dev/null; then
        # Convert config IDs (e.g. 0x1199) to lower-case standard formats for grepping
        V_ID=$(echo "$MODEM_VENDOR_ID" | tr '[:upper:]' '[:lower:]')
        P_ID=$(echo "$MODEM_PRODUCT_ID" | tr '[:upper:]' '[:lower:]')
        
        # system_profiler reports USB devices. We check for vendor and product matches.
        USB_PROFILE=$(system_profiler SPUSBDataType 2>/dev/null || true)
        
        if echo "$USB_PROFILE" | grep -qi "Vendor ID: ${V_ID}" && echo "$USB_PROFILE" | grep -qi "Product ID: ${P_ID}"; then
            echo "[+] Detected Sierra Wireless EM7590 on the host USB bus!"
            PASSTHROUGH_ACTIVE=true
        else
            # Fallback check removing leading 0x
            V_SHORT=${V_ID#0x}
            P_SHORT=${P_ID#0x}
            if echo "$USB_PROFILE" | grep -qi "${V_SHORT}" && echo "$USB_PROFILE" | grep -qi "${P_SHORT}"; then
                echo "[+] Detected Sierra Wireless EM7590 on the host USB bus!"
                PASSTHROUGH_ACTIVE=true
            fi
        fi
    fi

    if [[ "$PASSTHROUGH_ACTIVE" = true ]]; then
        # Since we are doing USB passthrough, macOS requires root access to detach host claim
        if [[ "$EUID" -ne 0 && "$DRY_RUN" = false ]]; then
            echo "[!] Privilege Elevation Required: USB Passthrough on macOS requires 'sudo' privileges."
            echo "    Re-running script under sudo..."
            exec sudo "$0" "$@"
        fi
        USB_FLAGS="-device usb-host,bus=${USB_CONTROLLER_ID}.0,vendorid=${MODEM_VENDOR_ID},productid=${MODEM_PRODUCT_ID}"
        echo "[+] Configuration: Direct USB passthrough enabled."
    else
        echo "[!] Warning: Sierra Wireless EM7590 was not detected on the host USB bus."
        echo "    The VM will start WITHOUT direct hardware passthrough."
        echo "    (You can connect it later, or configure emulation interfaces.)"
    fi
fi

# 4.5 UEFI/OVMF Firmware Detection
UEFI_CODE=""
UEFI_VARS_TEMPLATE=""

# List of possible UEFI code/vars paths
# Array of colon-separated pairs: CODE_PATH:VARS_PATH
POSSIBLE_UEFI_PAIRS=(
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd:/opt/homebrew/share/qemu/edk2-i386-vars.fd"
    "/usr/local/share/qemu/edk2-x86_64-code.fd:/usr/local/share/qemu/edk2-i386-vars.fd"
    "/usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/ovmf/OVMF_CODE.fd:/usr/share/ovmf/OVMF_VARS.fd"
    "/usr/share/ovmf/x64/OVMF_CODE.fd:/usr/share/ovmf/x64/OVMF_VARS.fd"
)

for pair in "${POSSIBLE_UEFI_PAIRS[@]}"; do
    code_path="${pair%%:*}"
    vars_path="${pair#*:}"
    if [[ -f "$code_path" && -f "$vars_path" ]]; then
        UEFI_CODE="$code_path"
        UEFI_VARS_TEMPLATE="$vars_path"
        break
    fi
done

UEFI_FLAGS=()
if [[ -n "$UEFI_CODE" && -n "$UEFI_VARS_TEMPLATE" ]]; then
    echo "[+] UEFI firmware detected:"
    echo "    Code: $UEFI_CODE"
    echo "    Vars template: $UEFI_VARS_TEMPLATE"
    
    LOCAL_VARS="${SCRIPT_DIR}/ovmf_vars.fd"
    if [[ ! -f "$LOCAL_VARS" ]]; then
        echo "[+] Copying UEFI NVRAM variables template to $LOCAL_VARS..."
        if [[ "$DRY_RUN" = false ]]; then
            cp "$UEFI_VARS_TEMPLATE" "$LOCAL_VARS"
            chmod 644 "$LOCAL_VARS"
        fi
    fi
    
    UEFI_FLAGS=(
        -drive "if=pflash,format=raw,readonly=on,file=$UEFI_CODE"
        -drive "if=pflash,format=raw,file=$LOCAL_VARS"
    )
else
    echo "[!] Warning: UEFI/OVMF firmware files not found on host."
    echo "    If you are booting a GPT-partitioned Cloud Image (e.g. disk.qcow2), it may fail to boot."
    echo "    To fix this, install 'qemu' (macOS) or 'ovmf'/'edk2-ovmf' (Linux)."
fi

# 5. Build QEMU Execution Command
QEMU_CMD=(
    qemu-system-x86_64
    -name "$VM_NAME"
    -m "$VM_MEM"
    -smp "$VM_CPUS"
    -machine q35
)

# Append CPU acceleration configuration
# shellcheck disable=SC2206
QEMU_CMD+=($ACCEL_FLAGS)

# Append UEFI flags if detected
if [[ ${#UEFI_FLAGS[@]} -gt 0 ]]; then
    QEMU_CMD+=("${UEFI_FLAGS[@]}")
fi

# Standard peripherals and graphics (virtio / cocoa for macOS)
QEMU_CMD+=(
    -vga virtio
    -display cocoa,show-cursor=on,zoom-to-fit=on
    -device virtio-net-pci,netdev=net0
    -netdev user,id=net0,hostfwd=tcp::2222-:22
    -drive "file=${DISK_PATH},format=qcow2,if=none,id=bootdisk"
    -device "virtio-blk-pci,drive=bootdisk,bootindex=1"
    -serial telnet:127.0.0.1:4445,server=on,wait=off
    -fsdev local,id=fsdev0,path="${SCRIPT_DIR}",security_model=none
    -device virtio-9p-pci,fsdev=fsdev0,mount_tag=host_share
)

# Append Renesas uPD720202 compatible XHCI controller
QEMU_CMD+=(
    -device "${USB_CONTROLLER_TYPE},id=${USB_CONTROLLER_ID}"
)

# Append Sierra Wireless EM7590 USB passthrough if detected
if [[ -n "$USB_FLAGS" ]]; then
    # shellcheck disable=SC2206
    QEMU_CMD+=($USB_FLAGS)
fi

# Optional boot ISO configuration
if [[ -n "$ISO_PATH" ]]; then
    if [[ ! -f "$ISO_PATH" ]]; then
        echo "[-] Error: Specified ISO file not found at ${ISO_PATH}" >&2
        exit 1
    fi
    echo "[+] Attaching ISO installation media: ${ISO_PATH}"
    QEMU_CMD+=(
        -drive "file=${ISO_PATH},if=none,id=cdrom_iso,media=cdrom,readonly=on"
        -device "ide-cd,bus=ide.0,drive=cdrom_iso"
        -boot d
    )
fi

# Attach cloud-init metadata ISO if booting from disk image and cloud-init.iso exists
if [[ -f "${SCRIPT_DIR}/cloud-init.iso" && -z "$ISO_PATH" ]]; then
    echo "[+] Attaching cloud-init.iso configuration drive."
    QEMU_CMD+=(
        -drive "file=${SCRIPT_DIR}/cloud-init.iso,if=none,id=cdrom_cloudinit,media=cdrom,readonly=on"
        -device "ide-cd,bus=ide.1,drive=cdrom_cloudinit"
    )
fi

# 6. Execute VM or dry run output
if [[ "$DRY_RUN" = true ]]; then
    echo "----------------------------------------------------------------------"
    echo "[+] DRY RUN MODE - Proposed QEMU Execution Command:"
    echo "----------------------------------------------------------------------"
    echo "${QEMU_CMD[*]}"
    echo "----------------------------------------------------------------------"
    exit 0
fi

echo "[+] Launching VM instance..."
if [[ "$DETACHED" = true ]]; then
    "${QEMU_CMD[@]}" > /dev/null 2>&1 &
    echo "[+] VM launched in background (PID: $!)."
else
    exec "${QEMU_CMD[@]}"
fi
