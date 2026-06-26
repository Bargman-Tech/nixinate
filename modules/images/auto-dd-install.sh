#!/usr/bin/env bash
set -euo pipefail

# Auto-Installer script
# Decompresses zstd-compressed system image to internal NVMe and resizes root

# === Trap for cleanup on interruption ===
trap 'echo "ERROR: Script interrupted at line $LINENO"; exit 1' INT TERM

# === Reduce system to minimal state for maximum I/O bandwidth ===
echo "=== Lowering system to minimal state ==="

# Stop display manager and desktop (frees GPU, display I/O)
systemctl stop display-manager 2>/dev/null || true
systemctl stop lightdm 2>/dev/null || true

# Stop Plymouth (frees framebuffer)
systemctl stop plymouth-quit 2>/dev/null || true
systemctl stop plymouthd 2>/dev/null || true

# Stop any background services that might do I/O
systemctl stop polkit 2>/dev/null || true
systemctl stop ModemManager 2>/dev/null || true
systemctl stop wpa_supplicant 2>/dev/null || true

# Kill any user processes that might interfere
pkill -u daemon 2>/dev/null || true

# Settle and sync before heavy I/O
sync
udevadm settle --timeout=10

echo "System lowered. Starting installer..."
echo ""

# === Configuration ===
TARGET="${INSTALL_TARGET:-/dev/nvme0n1}"
MIN_DISK_GB="${INSTALL_MIN_DISK_GB:-64}"

# Image path is required
if [ -z "${INSTALLER_IMAGE:-}" ]; then
  echo "ERROR: INSTALLER_IMAGE not set."
  exit 1
fi
SOURCE="$INSTALLER_IMAGE"

echo "======================================================================"
echo "               Auto-Installer (dd)"
echo "======================================================================"
echo "Auto-installer service is running automatically on boot"
echo ""
echo "DD source: embedded zstd-compressed installer image"
echo "DD target: $TARGET"
echo ""
echo "Image: $SOURCE"
echo ""

# === Safety Validations ===
if [ ! -b "$TARGET" ]; then
  echo "ERROR: Target device $TARGET not found or not a block device."
  lsblk -nd -o NAME,SIZE,TYPE,MODEL
  exit 1
fi

# Check if source image exists
if [ ! -f "$SOURCE" ]; then
  echo "ERROR: Installer image not found: $SOURCE"
  exit 1
fi

if [ "$SOURCE" = "$TARGET" ]; then
  echo "ERROR: Source and target are the same device. Aborting."
  exit 1
fi

# Check if target has mounted partitions (critical safety check)
if findmnt --source "${TARGET}" &>/dev/null; then
  echo "ERROR: Target device $TARGET is mounted."
  findmnt --source "${TARGET}" || true
  exit 1
fi

# Reject if any target partition is mounted (root, boot, etc.)
if lsblk -nrpo NAME "$TARGET" | while read -r dev; do findmnt --source "$dev" &>/dev/null && echo "$dev"; done | grep -q .; then
  echo "ERROR: One or more partitions on $TARGET are mounted."
  lsblk -nrpo NAME "$TARGET" | while read -r dev; do findmnt --source "$dev" || true; done
  exit 1
fi

# Reject if current root filesystem is backed by target disk
ROOT_SRC=$(findmnt -n -o SOURCE / || true)
if [ -n "$ROOT_SRC" ]; then
  ROOT_SRC_REAL=$(readlink -f "$ROOT_SRC" || true)
  ROOT_PARENT=$(lsblk -no PKNAME "$ROOT_SRC_REAL" 2>/dev/null || true)
  if [ -n "$ROOT_PARENT" ] && [ "/dev/$ROOT_PARENT" = "$TARGET" ]; then
    echo "ERROR: Refusing to overwrite current boot/root disk ($TARGET)."
    echo "Root source: $ROOT_SRC_REAL"
    exit 1
  fi
fi

# Check if target is removable (should not be for internal NVMe)
if lsblk -n -o RM "$TARGET" | grep -q "1"; then
  echo "WARNING: Target appears to be removable media."
  echo "This is unusual for an internal NVMe. Proceeding with caution."
fi

# Get actual physical disk size for validation (not partition-table-derived)
DISK_SIZE_BYTES=$(blockdev --getsize64 "$TARGET" 2>/dev/null || true)
if [ -z "$DISK_SIZE_BYTES" ] || [ "$DISK_SIZE_BYTES" -le 0 ]; then
  DISK_SIZE_BYTES=$(lsblk -dn -b -o SIZE "$TARGET" | tr -d ' ')
fi

if [ -z "$DISK_SIZE_BYTES" ]; then
  echo "ERROR: Could not determine disk size."
  exit 1
fi

DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))

# Minimum disk size check
if [ "$DISK_SIZE_GB" -lt "$MIN_DISK_GB" ]; then
  echo "ERROR: Target disk is too small (<${MIN_DISK_GB}GB)."
  exit 1
fi

# Warn about data destruction
echo "WARNING: This operation will COMPLETELY ERASE all data on $TARGET"
echo "Current layout on target:"
lsblk -f "$TARGET"
echo ""

echo "Proceeding with installation..."

echo ""
echo "=== Starting dd copy of system image ==="
echo "Decompressing zstd image and writing to $TARGET..."
echo "Source: $SOURCE ($(stat --format=%s "$SOURCE" | numfmt --to=iec))"
echo ""

# === FUNDAMENTAL DD COMMAND ===
# Decompress zstd image directly to target (no temp file needed)
zstd -d -c "$SOURCE" | dd of="$TARGET" bs=4M status=progress conv=fsync

echo ""
echo "=== DD completed successfully. Starting post-processing ==="

# Always refresh kernel partition view after raw dd write.
echo "=== Refreshing partition table after dd ==="
partprobe "$TARGET" || echo "WARNING: partprobe failed; continuing"
udevadm settle --timeout=30 || true

# Move GPT backup header to actual end-of-disk after dd from a smaller image.
# Without this, tooling may report the image's original disk size (e.g. ~17GB).
echo "=== Relocating GPT backup header to end of disk ==="
if ! sgdisk -e "$TARGET"; then
  echo "ERROR: Failed to relocate GPT backup header with sgdisk -e"
  exit 1
fi
partprobe "$TARGET" || true
udevadm settle --timeout=10 || true

# === POST-DD: Expand root into available space ===
# Disk layout from disko schema: ESP(p1) → swap(p2) → root(p3)
# Swap is embedded in the raw image. Root is the last partition and can expand.

echo "Disk size: ${DISK_SIZE_GB}GB"

# Grow root partition (p3 — last partition) to fill remaining disk space
echo "=== Growing root partition (p3) to fill disk ==="
if ! growpart "$TARGET" 3; then
  echo "ERROR: growpart failed"
  parted -s "$TARGET" unit MiB print free || true
  exit 1
fi

if [ ! -b "${TARGET}p3" ]; then
  echo "ERROR: ${TARGET}p3 missing after growpart"
  exit 1
fi

# Resize ext4 filesystem to fill grown partition
echo "=== Resizing root filesystem ==="
e2fsck_exit=0
e2fsck -fy "${TARGET}p3" || e2fsck_exit=$?
if [ $e2fsck_exit -gt 1 ]; then
  echo "ERROR: e2fsck failed with exit code $e2fsck_exit"
  exit 1
fi
resize2fs "${TARGET}p3"

sync
udevadm settle --timeout=10
partprobe "$TARGET"

echo ""
echo "=== Final partition layout ==="
lsblk -f "$TARGET"
parted -s "$TARGET" unit MiB print free

echo ""
echo "======================================================================"
echo "INSTALLATION COMPLETE"
echo "Layout: ESP | root (resized)"
echo ""
echo "Shutting down in 5 seconds..."
echo "Remove USB, then power on to boot from the internal disk."
echo "======================================================================"

sleep 5
shutdown -h now
