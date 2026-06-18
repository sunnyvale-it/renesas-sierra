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

# 3. CPU Acceleration Verification
# WHPX (Windows Hypervisor Platform) is the native hypervisor API for Windows
$AccelFlags = "-accel whpx -cpu host"
Write-Host "[+] Enabling Windows Hypervisor Platform acceleration (whpx)" -ForegroundColor Gray

# 4. USB Driver & Hardware Passthrough Verification (UsbDk)
$UsbFlags = ""
$PassthroughActive = $false

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
        $UsbFlags = "-device usb-host,bus=$UsbId.0,vendorid=$ModemVid,productid=$ModemPid"
        Write-Host "[+] Configuration: UsbDk USB passthrough enabled." -ForegroundColor Green
    }
} else {
    Write-Host "[!] Warning: Sierra Wireless EM7590 was not detected on Windows USB bus." -ForegroundColor Yellow
    Write-Host "    The VM will start WITHOUT direct hardware passthrough." -ForegroundColor Yellow
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
    "-drive", "file=`"$DiskPath`",format=qcow2,if=virtio",
    "-device", "$UsbType,id=$UsbId"
)

if ($UsbFlags) {
    # Add raw string flags split by whitespace
    $QemuArgs += "-device"
    $QemuArgs += "usb-host,bus=$UsbId.0,vendorid=$ModemVid,productid=$ModemPid"
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
