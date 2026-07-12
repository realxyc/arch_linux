#!/bin/bash
# Exit immediately if any command fails to prevent catastrophic errors
set -e

clear
echo "================================================="
echo "     Welcome to Arch Linux Hybrid Installer      "
echo "================================================="

# 0. UEFI PRE-FLIGHT CHECK
if [ ! -d /sys/firmware/efi ]; then
    echo "Error: System is not booted in UEFI mode. This script targets UEFI dual-boot. Aborting."
    exit 1
fi

# 1. DRIVE SELECTION
echo -e "\nScanning for available drives...\n"
lsblk -d -p -n -o NAME,SIZE,MODEL | grep -v "loop"
echo "-------------------------------------------------"

read -p "Enter the FULL PATH of the drive you want to install on (e.g., /dev/nvme0n1): " DISK

if [ ! -b "$DISK" ]; then
    echo "Error: '$DISK' is not a valid drive. Exiting for safety."
    exit 1
fi

DRIVE_MODEL=$(lsblk -d -n -o MODEL "$DISK")
DRIVE_SIZE=$(lsblk -d -n -o SIZE "$DISK")

echo "-------------------------------------------------"
echo "Current drive layout on $DISK (verify your Windows partitions!):"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,PARTTYPE "$DISK"
echo "-------------------------------------------------"

# 2. LOCATE EXISTING WINDOWS ESP
# We do NOT create a second EFI partition. Windows already has one, and
# systemd-boot/UEFI firmware expect a single ESP per disk for reliable
# dual-boot detection. We reuse it and just mount it, never format it.
echo "Searching for existing EFI System Partition on $DISK..."

ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
PART_ESP=$(lsblk -rno NAME,PARTTYPE "$DISK" | awk -v guid="$ESP_TYPE_GUID" \
    'tolower($2)==guid {print $1; exit}')

if [[ -z "$PART_ESP" ]]; then
    echo "Error: No existing EFI System Partition found on $DISK."
    echo "If this is genuinely a fresh disk with no Windows install, create"
    echo "an ESP manually first — this script intentionally will not do it"
    echo "for you to avoid ending up with a stray, unused ESP."
    exit 1
fi
PART_ESP="/dev/$PART_ESP"
echo "Found existing ESP: $PART_ESP (will be reused, not reformatted)"
echo "-------------------------------------------------"

# 3. FREE SPACE CHECK FOR ROOT PARTITION
echo "Free space regions on $DISK:"
parted -s "$DISK" unit MiB print free || { echo "Error: parted could not read $DISK. Aborting."; exit 1; }
echo "-------------------------------------------------"

LARGEST_FREE_MIB=$(parted -s "$DISK" unit MiB print free \
    | awk '/Free Space/ {gsub("MiB","",$3); if ($3+0 > max) max=$3+0} END {print max+0}')

if [[ -z "$LARGEST_FREE_MIB" || "$LARGEST_FREE_MIB" == "0" ]]; then
    echo "Error: No usable free space found on $DISK. Aborting."
    exit 1
fi

echo "Largest contiguous free region: ${LARGEST_FREE_MIB} MiB"
read -p "Root Partition Size (e.g., 200G, 500G) [Default: 200G]: " INPUT_ROOT
ROOT_SIZE=${INPUT_ROOT:-200G}

size_to_mib() {
    local size="$1" num unit
    num=$(echo "$size" | sed -E 's/([0-9.]+).*/\1/')
    unit=$(echo "$size" | sed -E 's/[0-9.]+([A-Za-z]*)/\1/' | tr '[:lower:]' '[:upper:]')
    case "$unit" in
        G|GIB|GB) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        M|MIB|MB|"") awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        *) echo "Error: Unrecognized size unit '$unit' in '$size'." >&2; exit 1 ;;
    esac
}

ROOT_SIZE_MIB=$(size_to_mib "$ROOT_SIZE")
if (( ROOT_SIZE_MIB > LARGEST_FREE_MIB )); then
    echo "Error: Requested Root size (${ROOT_SIZE_MIB} MiB) exceeds the largest"
    echo "contiguous free region (${LARGEST_FREE_MIB} MiB) on $DISK. Aborting."
    exit 1
fi
echo "Requested root size fits within available free space."

# 4. FINAL SUMMARY & CONFIRMATION
clear
echo "================================================="
echo "       FINAL PARTITIONING SUMMARY        "
echo "================================================="
echo "TARGET HARDWARE:"
echo "  Drive Path:     $DISK"
echo "  Drive Model:    $DRIVE_MODEL"
echo "  Total Size:     $DRIVE_SIZE"
echo "-------------------------------------------------"
echo "PLANNED ACTIONS:"
echo "  1. Reuse existing ESP: $PART_ESP  (mounted at /mnt/boot, NOT formatted)"
echo "  2. Create new Root:    $ROOT_SIZE (Type: EXT4, Label: LINUX_ROOT, in free space)"
echo "-------------------------------------------------"
echo "AFTER PARTITIONING:"
echo "  - archinstall will launch interactively, pointed at the pre-mounted"
echo "    /mnt target instead of re-partitioning."
echo "  - Choose 'systemd-boot' as the bootloader inside archinstall."
echo "  - This script performs NO bootloader installation of its own —"
echo "    archinstall's own choice is final, nothing overwrites it."
echo "================================================="
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo "================================================="

echo -e "\nPOINT OF NO RETURN"
read -p "Are you absolutely sure everything above is correct? Type 'YES' in all caps to proceed: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Installation aborted by user. Your disks have not been touched."
    exit 1
fi
echo "Safety check passed. Commencing partitioning..."

# 5. PARTITIONING (root only — free space)
echo "Carving out ${ROOT_SIZE} Root from free space on $DISK..."
sgdisk -n 0:0:+"$ROOT_SIZE" -t 0:8300 -c 0:"LINUX_ROOT" "$DISK"

echo "Syncing partition tables..."
partprobe "$DISK"
udevadm settle

PART_ROOT_NAME=$(lsblk -o NAME,PARTLABEL -rn "$DISK" | grep "LINUX_ROOT" | awk '{print $1}')
if [[ -z "$PART_ROOT_NAME" ]]; then
    echo "Error: Could not locate newly created root partition by label on $DISK. Aborting."
    exit 1
fi
PART_ROOT="/dev/$PART_ROOT_NAME"
echo "ROOT Partition created at: $PART_ROOT"

# 6. FORMAT ROOT + MOUNT (ESP is reused, never formatted)
echo "Formatting root partition..."
mkfs.ext4 -F "$PART_ROOT"

echo "Mounting partitions..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_ESP" /mnt/boot

mountpoint -q /mnt || { echo "Error: /mnt not mounted, aborting."; exit 1; }
mountpoint -q /mnt/boot || { echo "Error: /mnt/boot not mounted, aborting."; exit 1; }

echo -e "\n✅ Partitions ready: root fresh, ESP reused untouched, both mounted."

# 7. UPDATE PACMAN & LAUNCH ARCHINSTALL (INTERACTIVE)
echo "Updating pacman, keyring, and installing archinstall..."
pacman -Sy --noconfirm archlinux-keyring archinstall

echo "-------------------------------------------------"
echo "Launching archinstall interactively."
echo "IMPORTANT in the archinstall menu:"
echo "  - Disk configuration: use the pre-mounted /mnt target, do NOT let"
echo "    archinstall repartition $DISK — it's already partitioned."
echo "  - Bootloader: choose systemd-boot (not GRUB)."
echo "  - If offered, choose UKI as the kernel image type."
echo "-------------------------------------------------"
read -p "Press Enter to launch archinstall..." _

archinstall --mountpoint /mnt

echo -e "\narchinstall has exited. Resuming script for verification..."

# 8. POST-INSTALL VERIFICATION
echo "Verifying fstab was generated successfully by archinstall..."
if [ ! -f /mnt/etc/fstab ]; then
    echo "Error: /mnt/etc/fstab not found. archinstall may not have completed successfully. Aborting."
    exit 1
fi
cat /mnt/etc/fstab
echo "-------------------------------------------------"

# Make sure the NVMe driver is actually in whatever image archinstall built —
# this is the exact check that would have caught the earlier kernel panic
# (missing nvme module in the initramfs/UKI) before ever rebooting.
echo "Checking that the nvme module is present in the installed kernel image..."
UKI_FILE=$(find /mnt/boot -iname "*.efi" 2>/dev/null | head -n1)
if [[ -n "$UKI_FILE" ]] && arch-chroot /mnt which lsinitcpio &>/dev/null; then
    if ! arch-chroot /mnt lsinitcpio "${UKI_FILE#/mnt}" 2>/dev/null | grep -q "nvme"; then
        echo "WARNING: nvme module not found in $UKI_FILE."
        echo "Adding it and regenerating to prevent a boot-time panic..."
        arch-chroot /mnt sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvme)/' /etc/mkinitcpio.conf
        arch-chroot /mnt mkinitcpio -P
    else
        echo "nvme module present — good."
    fi
else
    echo "Could not verify automatically (non-UKI setup or lsinitcpio unavailable)."
    echo "Manually confirm 'nvme' is in MODULES=() in /mnt/etc/mkinitcpio.conf if this is an NVMe drive."
fi

# 9. CLEANUP
echo "Unmounting and finishing up..."
umount -R /mnt
echo "Installation finished! You can now type 'reboot'."
