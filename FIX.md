# Resolution Guide: Renesas uPD720202 & Sierra EM7590 Stability Fixes

This document details the root causes and remediation steps for the driver crashes, USB disconnects, and system freezes affecting the integration of the **Renesas uPD720202 PCIe USB 3.0 controller** and high-bandwidth USB devices such as the **Sierra Wireless EM7590 LTE modem**.

---

## 1. The Core Kernel Bug (Bugzilla: 199627)

* **Bugzilla Reference**: [Bug 199627 - issues installing Renesas Technology Corp. uPD720202 USB 3.0 Host Controller](https://bugzilla.kernel.org/show_bug.cgi?id=199627)
* **Status**: `RESOLVED CODE_FIX`
* **Resolving Commit**: [`0e1f0eaed6c20db41ff61e024b361ee3ec9d686c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0e1f0eaed6c20db41ff61e024b361ee3ec9d686c) (authored by Marc Zyngier)
* **First Kernel Versions with Fix**: Mainline **Linux 4.13** (first merged in the `4.13-rc1` release candidate) and backported to stable **Linux 4.12.8**.

### The Technical Issue
The Renesas uPD72020x series host controllers have a hardware flaw where they fail to clear or reset their internal DMA addressing logic across standard xHCI resets. 

Specifically, if the controller was previously initialized using a **64-bit DMA address space**, and the driver subsequently attempts to reprogram it to use **32-bit DMA addresses** (which commonly occurs when hardware IOMMU page tracking is active), the controller ignores the upper 32 bits (which should be zeroed) and continues using the stale high-order bits from the previous configuration. This results in bad memory accesses, page translation errors, and driver load failure (`probe of 0000:xx:xx.x failed with error -110`).

### The Official Code Fix
The official kernel fix introduces a hardware-level reset routine specifically triggered for the Renesas uPD72020x chipsets during initialization. This routine forces the PCI registers to clear the stale DMA pointers, allowing the driver to probe and bind successfully.

---

## 2. Runtime Stability Issues (The "Perfect Storm" of Conflicts)

Even on kernels containing the official reset patch, the combination of the Renesas controller and a high-bandwidth USB cellular modem (like the Sierra EM7590) still experiences severe **runtime driver crashes** and **bus freezes** due to two distinct physical conflict vectors:

### A. IOMMU Translation Latency (xHCI Command Ring Timeouts)
* **The Symptom**: Under high upload/download data loads, system logs print `xhci_hcd: Command timeout` followed by `xhci_hcd: HC died; cleaning up`. All connected USB interfaces disappear, and the modem is thrown offline.
* **The Cause**: When hardware IOMMU translation (`iommu=on` or `intel_iommu=on`) is enforced at the kernel level, the high volume of DMA mapping and translation requests introduces latency. The Renesas controller's command scheduler encounters a race condition, stalls the xHCI command ring, and the kernel declares the host controller "dead."

### B. Power Management & Wakeup Failures (ASPM/Autosuspend Freezes)
* **The Symptom**: When the cellular link goes idle for more than 2000ms, the modem suddenly disconnects from the bus, serial ports disappear, and the connection cannot be restored without a hard reboot.
* **The Cause**: The Linux kernel enforces aggressive Active State Power Management (ASPM L1/L1.1/L1.2 states) and a 2000ms idle timer for USB autosuspend. During these transitions, firmware and electrical mismatches between the Renesas controller and the Sierra modem prevent a proper link wakeup sequence. The link remains frozen, forcing the modem into its `c082` bootloader recovery crash loop.

---

## 3. The Stabilization Protocol (Remediation)

To stabilize the hardware integration, we apply a set of operational workarounds to configure the kernel parameters and udev power rules. This protocol mirrors the community-tested solutions discussed in the Bugzilla thread (such as Comments 27 and 33).

The stabilization protocol is automated via the [configure_baseline.sh](configure_baseline.sh) 

```bash
sudo /home/ubuntu/configure_baseline.sh --stabilise
```

### Applied Changes & Explanations

| Parameter / Rule | Target Action | Technical Rationale |
| :--- | :--- | :--- |
| **`iommu=soft`** *(Kernel Parameter)* | Fall back to software IOMMU bounce buffers (SWIOTLB). | Bypasses the overhead of hardware IOMMU translation tables, preventing xHCI command ring timeouts and subsequent `HC died` driver crashes under heavy traffic loads. |
| **`pcie_aspm=off`** *(Kernel Parameter)* | Disable Active State Power Management globally on the PCIe bus. | Prevents the Renesas controller from dropping into low-power L1 link states, maintaining a constant and stable power state. |
| **`usb autosuspend=-1`** *(udev Rule)* | Disable USB idle autosuspend for the Sierra vendor ID (`1199`). | Forces the USB port to remain powered and active, preventing low-power state transitions that the modem cannot recover from. |

### Verification of the Fix
After running the script, reboot the VM. You can verify that the mitigations have been successfully applied by running:

```bash
sudo configure_baseline.sh --status
```
* **Expected Output**:
  * **ASPM State**: `performance` or `Not available` (verifying `pcie_aspm=off`).
  * **Kernel Command Line**: Should contain `pcie_aspm=off iommu=soft`.
  * **Active udev Rules**: The rule file `/etc/udev/rules.d/99-sierra-em7590.rules` should be active and list `power/autosuspend="-1"`.
