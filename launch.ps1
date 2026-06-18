# ==============================================================================
# QEMU Launcher Script for Windows Hosts (PowerShell)
# ==============================================================================
# Simulates x64 architecture, NEC/Renesas XHCI, and passes through Sierra LTE.

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$IsoPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$Background
)

$ErrorActionPreference = "Stop"

# Get script directory and load configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "vm_config.env"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found at $ConfigFile"
    exit 1
}

# Parse env file manually in PowerShell
Write-Host "[+] Parsing configuration from vm_config.env..." -ForegroundColor Cyan
$Config = @{}
Get-Content $ConfigFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        if ($line -match '^([^=]+)="?(.*?)"?$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $Config[$key] = $value
        }
    }
}

$VmName = $Config["VM_NAME"]
$VmDisk = $Config["VM_DISK"]
$VmDiskSize = $Config["VM_DISK_SIZE"]
$VmMem = $Config["VM_MEM"]
$VmCpus = $Config["VM_CPUS"]
$UsbType = $Config["USB_CONTROLLER_TYPE"]
$UsbId = $Config["USB_CONTROLLER_ID"]
$ModemVid = $Config["MODEM_VENDOR_ID"]
$ModemPid = $Config["MODEM_PRODUCT_ID"]
$MockMode = $Config["MOCK_MODE"]
$MockSerialPort = $Config["MOCK_SERIAL_PORT"]

Write-Host "[+] Initializing Renesas & Sierra QEMU Architecture on Windows..." -ForegroundColor Green

# 1. Dependency Check (QEMU Installation)
$QemuPath = ""
$QemuSearchPaths = @(
    (Join-Path $env:ProgramFiles "qemu\qemu-system-x86_64.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "qemu\qemu-system-x86_64.exe"),
    "qemu-system-x86_64.exe" # If in system PATH
)

foreach ($path in $QemuSearchPaths) {
    if (Test-Path $path) {
        $QemuPath = $path
        break
    }
}

if (-not $QemuPath) {
    # Check PATH environments via Get-Command
    $cmd = Get-Command "qemu-system-x86_64.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        $QemuPath = $cmd.Source
    }
}

if (-not $QemuPath) {
    Write-Error "qemu-system-x86_64.exe was not found. Please install QEMU for Windows and add it to your System PATH or standard installation directory."
    exit 1
}
Write-Host "[+] Found QEMU binary at: $QemuPath" -ForegroundColor Gray

# 2. Disk Image Management
$DiskPath = Join-Path $ScriptDir $VmDisk
$QemuImgPath = Join-Path (Split-Path $QemuPath) "qemu-img.exe"

if (-not (Test-Path $DiskPath)) {
    Write-Host "[+] Disk image not found. Creating a $VmDiskSize QCOW2 image at $DiskPath..." -ForegroundColor Yellow
    if (-not $DryRun) {
        Start-Process $QemuImgPath -ArgumentList "create -f qcow2 `"$DiskPath`" $VmDiskSize" -NoNewWindow -Wait
    }
} else {
    Write-Host "[+] Using existing disk image at: $DiskPath" -ForegroundColor Gray
}

# 2.5 Cloud-Init Configuration (For Ubuntu Cloud Images)
if (-not $IsoPath) {
    # Generate SSH keys if they don't exist or generate fresh ones
    $VmKeyPath = Join-Path $ScriptDir "vm_key"
    $VmKeyPubPath = Join-Path $ScriptDir "vm_key.pub"
    
    Write-Host "[+] Generating fresh SSH key pair (vm_key) for VM login..." -ForegroundColor Green
    if (Test-Path $VmKeyPath) { Remove-Item $VmKeyPath -Force }
    if (Test-Path $VmKeyPubPath) { Remove-Item $VmKeyPubPath -Force }
    
    # Check if ssh-keygen.exe is available
    $SshKeygen = Get-Command "ssh-keygen" -ErrorAction SilentlyContinue
    if ($SshKeygen) {
        if (-not $DryRun) {
            Start-Process ssh-keygen -ArgumentList "-t ed25519 -N `"`" -f `"$VmKeyPath`" -q" -NoNewWindow -Wait
            # Clean up known_hosts port 2222 entries
            Start-Process ssh-keygen -ArgumentList "-R `"[127.0.0.1]:2222`"" -NoNewWindow -Wait -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "[!] Warning: ssh-keygen was not found. SSH key pair generation skipped." -ForegroundColor Yellow
    }

    $CloudInitIso = Join-Path $ScriptDir "cloud-init.iso"
    if (-not (Test-Path $CloudInitIso)) {
        Write-Host "[!] Warning: cloud-init.iso is missing." -ForegroundColor Yellow
        Write-Host "    Without cloud-init.iso, the Ubuntu Cloud Image will not have the SSH key injected." -ForegroundColor Yellow
        Write-Host "    Please run the macOS launcher first or provide an ISO installation media using -IsoPath." -ForegroundColor Yellow
    } else {
        Write-Host "[+] Using existing cloud-init.iso to configure Ubuntu Cloud Image login." -ForegroundColor Gray
    }
}

# 3. CPU Acceleration Verification
# WHPX (Windows Hypervisor Platform) is the native hypervisor API for Windows
$AccelFlags = "-accel whpx -cpu host"
Write-Host "[+] Enabling Windows Hypervisor Platform acceleration (whpx)" -ForegroundColor Gray

# 4. USB Driver & Hardware Configuration (Sierra Wireless EM7590 / Mock Emulation)
$UsbFlags = @()
$PassthroughActive = $false

if ($MockMode -eq "true") {
    Write-Host "[+] Running in 100% Software Emulation / Mock Mode (MOCK_MODE=true)." -ForegroundColor Green
    Write-Host "[+] Attaching virtual USB-serial port linked to TCP port $MockSerialPort (AT commands)..." -ForegroundColor Gray
    Write-Host "[+] Attaching virtual USB-net adapter linked to user network (mobile broadband)..." -ForegroundColor Gray
    
    $UsbFlags += @("-chardev", "socket,id=modem_serial,host=127.0.0.1,port=$MockSerialPort,server=on,wait=off")
    $UsbFlags += @("-device", "usb-serial,bus=$UsbId.0,chardev=modem_serial")
    $UsbFlags += @("-netdev", "user,id=net_modem,net=10.0.3.0/24")
    $UsbFlags += @("-device", "usb-net,bus=$UsbId.0,netdev=net_modem")
} else {
    # Parse Vid/Pid to format suitable for device querying (e.g. 1199 and c081)
    $VidClean = $ModemVid -replace "0x", ""
    $PidClean = $ModemPid -replace "0x", ""

    Write-Host "[+] Checking for physical Sierra Wireless EM7590 (VID: $ModemVid, PID: $ModemPid)..." -ForegroundColor Gray
    # Query connected PNP devices for a match
    $PnpDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    if ($PnpDevices) {
        $MatchingDevice = $PnpDevices | Where-Object { 
            $_.InstanceId -match "VID_$VidClean.+PID_$PidClean" -or 
            $_.HardwareID -match "VID_$VidClean&PID_$PidClean" 
        }
        if ($MatchingDevice) {
            Write-Host "[+] Detected Sierra Wireless EM7590 connected to Windows host USB bus!" -ForegroundColor Green
            $PassthroughActive = $true
        }
    }

    if ($PassthroughActive) {
        # Check for UsbDk installation
        Write-Host "[+] Checking if UsbDk (USB Development Kit) driver is installed..." -ForegroundColor Gray
        $UsbDkService = Get-Service "UsbDk" -ErrorAction SilentlyContinue
        if (-not $UsbDkService -or $UsbDkService.Status -ne "Running") {
            Write-Host "[!] Warning: UsbDk service is not running or not installed." -ForegroundColor Yellow
            Write-Host "    UsbDk is required on Windows hosts for QEMU USB passthrough." -ForegroundColor Yellow
            Write-Host "    Download it from: https://www.spice-space.org/download/windows/usbdk/" -ForegroundColor Yellow
            Write-Host "    Falling back to boot VM without USB modem passthrough." -ForegroundColor Yellow
            $PassthroughActive = $false
        } else {
            # UsbDk requires Admin privileges
            $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
            $IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            
            if (-not $IsAdmin -and -not $DryRun) {
                Write-Host "[!] Privilege Elevation Required: UsbDk USB Passthrough requires Administrator privileges." -ForegroundColor Yellow
                Write-Host "    Relaunching PowerShell script as Administrator..." -ForegroundColor Yellow
                $ArgsList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                if ($IsoPath) { $ArgsList += " -IsoPath `"$IsoPath`"" }
                if ($Background) { $ArgsList += " -Background" }
                Start-Process powershell -ArgumentList $ArgsList -Verb RunAs
                exit
            }
            $UsbFlags = @("-device", "usb-host,bus=$UsbId.0,vendorid=$ModemVid,productid=$ModemPid")
            Write-Host "[+] Configuration: UsbDk USB passthrough enabled." -ForegroundColor Green
        }
    } else {
        Write-Host "[!] Warning: Sierra Wireless EM7590 was not detected on Windows USB bus." -ForegroundColor Yellow
        Write-Host "    The VM will start WITHOUT direct hardware passthrough." -ForegroundColor Yellow
    }
}

# 4.5 UEFI/OVMF Firmware Detection
$UefiCode = ""
$UefiVarsTemplate = ""

$QemuDir = Split-Path $QemuPath
$PossibleUefiPairs = @(
    @{ Code = (Join-Path $QemuDir "share\edk2-x86_64-code.fd"); Vars = (Join-Path $QemuDir "share\edk2-i386-vars.fd") },
    @{ Code = (Join-Path $env:ProgramFiles "qemu\share\edk2-x86_64-code.fd"); Vars = (Join-Path $env:ProgramFiles "qemu\share\edk2-i386-vars.fd") },
    @{ Code = (Join-Path ${env:ProgramFiles(x86)} "qemu\share\edk2-x86_64-code.fd"); Vars = (Join-Path ${env:ProgramFiles(x86)} "qemu\share\edk2-i386-vars.fd") }
)

foreach ($pair in $PossibleUefiPairs) {
    if (Test-Path $pair.Code -and Test-Path $pair.Vars) {
        $UefiCode = $pair.Code
        $UefiVarsTemplate = $pair.Vars
        break
    }
}

$UefiFlags = @()
if ($UefiCode -and $UefiVarsTemplate) {
    Write-Host "[+] UEFI firmware detected:" -ForegroundColor Green
    Write-Host "    Code: $UefiCode" -ForegroundColor Gray
    Write-Host "    Vars template: $UefiVarsTemplate" -ForegroundColor Gray
    
    $LocalVars = Join-Path $ScriptDir "ovmf_vars.fd"
    if (-not (Test-Path $LocalVars)) {
        Write-Host "[+] Copying UEFI NVRAM variables template to $LocalVars..." -ForegroundColor Yellow
        if (-not $DryRun) {
            Copy-Item $UefiVarsTemplate $LocalVars
        }
    }
    
    $UefiFlags = @(
        "-drive", "if=pflash,format=raw,readonly=on,file=`"$UefiCode`"",
        "-drive", "if=pflash,format=raw,file=`"$LocalVars`""
    )
} else {
    Write-Host "[!] Warning: UEFI/OVMF firmware files not found." -ForegroundColor Yellow
    Write-Host "    If you are booting a GPT-partitioned Cloud Image (e.g. disk.qcow2), it may fail to boot." -ForegroundColor Yellow
}

# 5. Build QEMU Arguments
$QemuArgs = @(
    "-name", "`"$VmName`"",
    "-m", $VmMem,
    "-smp", $VmCpus,
    "-machine", "q35",
    "-accel", "whpx",
    "-cpu", "host",
    "-vga", "virtio",
    "-display", "default,show-cursor=on,zoom-to-fit=on",
    "-device", "virtio-net-pci,netdev=net0",
    "-netdev", "user,id=net0,hostfwd=tcp::2222-:22",
    "-drive", "file=`"$DiskPath`",format=qcow2,if=none,id=bootdisk",
    "-device", "virtio-blk-pci,drive=bootdisk,bootindex=1",
    "-device", "$UsbType,id=$UsbId"
)

if ($UefiFlags) {
    $QemuArgs += $UefiFlags
}


if ($UsbFlags) {
    $QemuArgs += $UsbFlags
}

if ($IsoPath) {
    if (-not (Test-Path $IsoPath)) {
        Write-Error "ISO file not found at $IsoPath"
        exit 1
    }
    Write-Host "[+] Attaching ISO installation media: $IsoPath" -ForegroundColor Green
    $QemuArgs += "-drive"
    $QemuArgs += "file=`"$IsoPath`",media=cdrom,readonly=on"
    $QemuArgs += "-boot"
    $QemuArgs += "d"
}

# Attach cloud-init metadata ISO if booting from disk image and cloud-init.iso exists
$CloudInitIso = Join-Path $ScriptDir "cloud-init.iso"
if ((Test-Path $CloudInitIso) -and -not $IsoPath) {
    Write-Host "[+] Attaching cloud-init.iso configuration drive." -ForegroundColor Green
    $QemuArgs += @(
        "-drive", "file=`"$CloudInitIso`",if=none,id=cdrom_cloudinit,media=cdrom,readonly=on",
        "-device", "ide-cd,bus=ide.1,drive=cdrom_cloudinit"
    )
}

# 6. Execute VM or dry run
if ($DryRun) {
    Write-Host "----------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "[+] DRY RUN MODE - Proposed QEMU Execution Command:" -ForegroundColor Cyan
    Write-Host "----------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "$QemuPath $($QemuArgs -join ' ')" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------------" -ForegroundColor Cyan
    exit 0
}

Write-Host "[+] Launching VM instance..." -ForegroundColor Green
if ($Background) {
    Start-Process $QemuPath -ArgumentList $QemuArgs -WindowStyle Hidden
    Write-Host "[+] VM launched in background." -ForegroundColor Green
} else {
    # Execute in current shell window
    Start-Process $QemuPath -ArgumentList $QemuArgs -NoNewWindow -Wait
}
