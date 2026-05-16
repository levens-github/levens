#!/bin/bash
# Linux NVMe diagnostic probe for the failing Samsung PM9A1.
# Run from a Ubuntu Live USB session as: sudo bash linux-nvme-probe.sh
#
# All operations are READ-ONLY on the drive. The NVMe short self-test is
# a controller-internal integrity check that does not modify user data.
#
# Output is written to /tmp/nvme_probe/ and zipped to /tmp/nvme_probe.zip.
# At the end, the script will print instructions for copying the zip back.

set -u
OUT=/tmp/nvme_probe
ZIP=/tmp/nvme_probe.zip
rm -rf "$OUT" "$ZIP"
mkdir -p "$OUT"

LOG="$OUT/_log.txt"
exec > >(tee "$LOG") 2>&1

echo "=== Linux NVMe probe ==="
echo "Date: $(date)"
echo "Kernel: $(uname -a)"
echo

# 0. Must be root for /dev/nvmeN access
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must run as root. Try: sudo bash $0"
    exit 1
fi

# Ensure nvme-cli and smartmontools are available.
# SystemRescue ships them pre-installed (pacman-based Arch).
# Ubuntu Live needs apt-get install.
# Script auto-detects which package manager to use.
echo "--- Ensuring nvme-cli and smartmontools are installed ---"
if command -v nvme >/dev/null 2>&1 && command -v smartctl >/dev/null 2>&1; then
    echo "  Both tools already installed (likely SystemRescue or similar)."
    nvme --version 2>&1 | head -1
    smartctl --version 2>&1 | head -1
elif command -v apt-get >/dev/null 2>&1; then
    echo "  Ubuntu/Debian detected. Installing via apt-get..."
    apt-get update -qq 2>&1 | tail -5
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvme-cli smartmontools 2>&1 | tail -10
elif command -v pacman >/dev/null 2>&1; then
    echo "  Arch detected. Installing via pacman..."
    pacman -Sy --noconfirm nvme-cli smartmontools 2>&1 | tail -10
else
    echo "  WARNING: no recognized package manager. Relying on tools being preinstalled."
fi

# Final sanity check
for t in nvme smartctl; do
    if ! command -v $t >/dev/null 2>&1; then
        echo "ERROR: '$t' not available. Cannot continue."
        exit 1
    fi
done
echo

# 1. Identify the NVMe device(s)
echo "=== Block device tree ==="
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT > "$OUT/lsblk.txt"
cat "$OUT/lsblk.txt"
echo

echo "=== nvme list ==="
nvme list > "$OUT/nvme_list.txt" 2>&1
cat "$OUT/nvme_list.txt"
echo

# Pick first NVMe controller (most laptops have one)
DEV=$(nvme list | awk 'NR>2 && /\/dev\/nvme/ {print $1; exit}' | sed 's/n1$//')
if [ -z "$DEV" ]; then
    DEV=/dev/nvme0
    echo "WARNING: nvme list parse failed, defaulting to $DEV"
fi
echo "Primary NVMe controller: $DEV"
echo "Primary NVMe namespace : ${DEV}n1"
echo

# 2. NVMe identify (controller capabilities, firmware features)
echo "=== NVMe identify controller ==="
nvme id-ctrl "$DEV" > "$OUT/id_ctrl.txt" 2>&1
head -50 "$OUT/id_ctrl.txt"
echo

# 3. NVMe SMART/Health log (LID 0x02) - the most important page
echo "=== NVMe SMART/Health log ==="
nvme smart-log "$DEV" > "$OUT/smart_log.txt" 2>&1
cat "$OUT/smart_log.txt"
echo

# 4. NVMe error log (LID 0x01) - last 64 errors recorded by controller
echo "=== NVMe error log ==="
nvme error-log "$DEV" > "$OUT/error_log.txt" 2>&1
head -80 "$OUT/error_log.txt"
echo

# 5. smartctl full dump for cross-reference
echo "=== smartctl -a ==="
smartctl -a "$DEV" > "$OUT/smartctl_all.txt" 2>&1
head -80 "$OUT/smartctl_all.txt"
echo

echo "=== smartctl -x (extended) ==="
smartctl -x "$DEV" > "$OUT/smartctl_extended.txt" 2>&1

# 6. NVMe short self-test
echo "=== Starting NVMe short self-test (~2 min) ==="
nvme device-self-test "$DEV" -s 1 2>&1 | tee "$OUT/selftest_start.txt"
echo "Waiting 150 seconds..."
sleep 150
nvme self-test-log "$DEV" > "$OUT/selftest_result.txt" 2>&1
cat "$OUT/selftest_result.txt"
echo

# 7. PCIe link state for the NVMe controller (was it downtraining?)
echo "=== PCIe link state ==="
NVME_PCI=$(readlink -f /sys/class/nvme/$(basename "$DEV")/device 2>/dev/null)
if [ -n "$NVME_PCI" ]; then
    echo "PCIe device path: $NVME_PCI"
    {
        echo "Current link:"
        cat "$NVME_PCI/current_link_speed" 2>/dev/null
        cat "$NVME_PCI/current_link_width" 2>/dev/null
        echo "Max link:"
        cat "$NVME_PCI/max_link_speed" 2>/dev/null
        cat "$NVME_PCI/max_link_width" 2>/dev/null
    } > "$OUT/pcie_link.txt"
    cat "$OUT/pcie_link.txt"
fi
echo

lspci -vv > "$OUT/lspci_vv.txt" 2>&1
echo

# 8. Start dmesg watcher in background, then do read sweep
echo "=== Starting dmesg watcher (will capture any NVMe errors during read sweep) ==="
dmesg -T --follow-new > "$OUT/dmesg_during_read.txt" 2>&1 &
DMESG_PID=$!
trap "kill $DMESG_PID 2>/dev/null || true" EXIT

# 9. Read sweep: read every sector and discard. This is the "100% confirmation".
# If the drive has bad NAND or throws timeouts, this will surface them.
# Block size 4M for speed, status=progress to show progress.
echo "=== Read sweep of ${DEV}n1 ==="
echo "Reading entire drive into /dev/null. This validates every block is readable."
echo "Expected duration: 5-15 minutes for a 1TB drive."
echo "If the drive hangs or returns errors, dd will report them."
echo
( time dd if="${DEV}n1" of=/dev/null bs=4M iflag=direct status=progress ) > "$OUT/read_sweep.txt" 2>&1
RC=$?
echo "Read sweep exit code: $RC" | tee -a "$OUT/read_sweep.txt"
tail -5 "$OUT/read_sweep.txt"
echo

# Stop dmesg watcher
sleep 2
kill $DMESG_PID 2>/dev/null || true

# 10. Final SMART pull (compare against initial - did any counter tick up during the test?)
echo "=== Final NVMe SMART/Health log (post read sweep) ==="
nvme smart-log "$DEV" > "$OUT/smart_log_final.txt" 2>&1
cat "$OUT/smart_log_final.txt"
echo

echo "=== dmesg NVMe events (filtered) ==="
dmesg -T | grep -i 'nvme\|i/o error\|critical' | tail -40 > "$OUT/dmesg_nvme.txt"
cat "$OUT/dmesg_nvme.txt"
echo

# 11. Compute diffs we care about between initial and final SMART
echo "=== Diff initial vs final SMART ==="
diff "$OUT/smart_log.txt" "$OUT/smart_log_final.txt" > "$OUT/smart_diff.txt" 2>&1
cat "$OUT/smart_diff.txt"
echo

# 12. Wrap up
cd /tmp
zip -qr "$ZIP" "$(basename "$OUT")"
ls -la "$ZIP"
echo
echo "=================================================="
echo "DONE. Bundle written to: $ZIP"
echo "=================================================="
echo
echo "To copy this back to your Mac:"
echo "  Option A - via the same USB stick (probably easiest):"
echo "    1. Plug in a writeable USB drive."
echo "    2. In Files app, copy $ZIP to that drive."
echo "    3. Plug into Mac, copy to the Jay Laptop folder."
echo
echo "  Option B - via SSH back to Mac (if Mac has Remote Login enabled):"
echo "    scp $ZIP dennis@<your-mac-ip>:'~/Documents/Claude/Projects/Jay\\ Laptop/'"
echo
echo "  Option C - quick: tell me the values from the four key sections above:"
echo "    - NVMe SMART/Health log (Critical Warning, Available Spare, Media and Data Integrity Errors)"
echo "    - NVMe error log (number of entries)"
echo "    - Read sweep exit code and last few lines"
echo "    - dmesg NVMe events (any errors during read sweep)"
