#!/bin/bash
# Exit immediately if any command fails to prevent catastrophic errors
set -e

clear
echo "================================================="
echo "     Welcome to Arch Linux Hybrid Installer      "
echo "================================================="

# 0. UEFI check
if [ ! -d /sys/firmware/efi ]; then
    echo "Error: System is not booted in UEFI mode. This script targets UEFI/GRUB dual-boot. Aborting."
    exit 1
fi

# 1. drive selection
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
echo "Current free space regions on $DISK:"
parted -s "$DISK" unit MiB print free || { echo "Error: parted could not read $DISK. Aborting."; exit 1; }
echo "-------------------------------------------------"

# Find the largest contiguous "Free Space" region (in MiB) so we can validate
# the requested EFI + Root sizes actually fit before touching the disk.
LARGEST_FREE_MIB=$(parted -s "$DISK" unit MiB print free \
    | awk '/Free Space/ {gsub("MiB","",$3); if ($3+0 > max) max=$3+0} END {print max+0}')

if [[ -z "$LARGEST_FREE_MIB" || "$LARGEST_FREE_MIB" == "0" ]]; then
    echo "Error: No usable free space found on $DISK. Aborting."
    exit 1
fi

echo "Largest contiguous free region: ${LARGEST_FREE_MIB} MiB"
echo "-------------------------------------------------"

read -p "EFI Partition Size (e.g., 1G, 512M) [Default: 1G]: " INPUT_EFI
EFI_SIZE=${INPUT_EFI:-1G}

read -p "Root Partition Size (e.g., 500G, 200G) [Default: 500G]: " INPUT_ROOT
ROOT_SIZE=${INPUT_ROOT:-500G}

# Convert human sizes (G/M suffix) to MiB for comparison against free space.
size_to_mib() {
    local size="$1"
    local num unit
    num=$(echo "$size" | sed -E 's/([0-9.]+).*/\1/')
    unit=$(echo "$size" | sed -E 's/[0-9.]+([A-Za-z]*)/\1/' | tr '[:lower:]' '[:upper:]')
    case "$unit" in
        G|GIB|GB) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        M|MIB|MB|"") awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        *) echo "Error: Unrecognized size unit '$unit' in '$size'." >&2; exit 1 ;;
    esac
}

EFI_SIZE_MIB=$(size_to_mib "$EFI_SIZE")
ROOT_SIZE_MIB=$(size_to_mib "$ROOT_SIZE")
REQUIRED_MIB=$(( EFI_SIZE_MIB + ROOT_SIZE_MIB ))

echo "Requested total: ${REQUIRED_MIB} MiB (EFI: ${EFI_SIZE_MIB} MiB + Root: ${ROOT_SIZE_MIB} MiB)"

if (( REQUIRED_MIB > LARGEST_FREE_MIB )); then
    echo "Error: Requested EFI+Root (${REQUIRED_MIB} MiB) exceeds the largest"
    echo "contiguous free region (${LARGEST_FREE_MIB} MiB) on $DISK."
    echo "Shrink your requested sizes, free up more space, or pick a different disk. Aborting."
    exit 1
fi

echo "✅ Requested sizes fit within available free space."

# 2. summary
clear

echo "================================================="
echo "       FINAL PARTITIONING SUMMARY        "
echo "================================================="
echo "TARGET HARDWARE:"
echo "  Drive Path:     $DISK"
echo "  Drive Model:    $DRIVE_MODEL"
echo "  Total Size:     $DRIVE_SIZE"
echo "-------------------------------------------------"
echo "PLANNED ACTIONS (In Unallocated Space):"
echo "  1. Create EFI:  $EFI_SIZE (Type: FAT32, Label: EFI_BOOT)"
echo "  2. Create Root: $ROOT_SIZE (Type: EXT4, Label: LINUX_ROOT)"
echo "-------------------------------------------------"
echo "AFTER PARTITIONING:"
echo "  - archinstall will launch interactively."
echo "  - Point its disk configuration step at the pre-mounted"
echo "    /mnt (and /mnt/boot) target instead of re-partitioning."
echo "  - After archinstall finishes, this script resumes to"
echo "    handle GRUB + os-prober dual-boot finalization."
echo "================================================="
echo "CURRENT DRIVE LAYOUT (Verify your Windows partition!):"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo "================================================="

echo -e "\nPOINT OF NO RETURN"
echo "This script will carve out the planned partitions from the UNALLOCATED free space on $DISK."
read -p "Are you absolutely sure everything above is correct? Type 'YES' in all caps to proceed: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation aborted by user. Your disks have not been touched."
    exit 1
fi

echo "Safety check passed. Commencing partitioning..."

# 3. partitioning (targeting free space)
echo "Carving out ${EFI_SIZE} EFI and ${ROOT_SIZE} Root from free space on $DISK..."

sgdisk -n 0:0:+"$EFI_SIZE" -t 0:ef00 -c 0:"EFI_BOOT" "$DISK"
sgdisk -n 0:0:+"$ROOT_SIZE" -t 0:8300 -c 0:"LINUX_ROOT" "$DISK"

echo "Syncing partition tables..."
partprobe "$DISK"
udevadm settle

PART_EFI_NAME=$(lsblk -o NAME,PARTLABEL -rn "$DISK" | grep "EFI_BOOT" | awk '{print $1}')
PART_ROOT_NAME=$(lsblk -o NAME,PARTLABEL -rn "$DISK" | grep "LINUX_ROOT" | awk '{print $1}')

if [[ -z "$PART_EFI_NAME" || -z "$PART_ROOT_NAME" ]]; then
    echo "Error: Could not locate newly created partitions by label on $DISK. Aborting."
    exit 1
fi

PART_EFI="/dev/$PART_EFI_NAME"
PART_ROOT="/dev/$PART_ROOT_NAME"

echo "EFI Partition created at: $PART_EFI"
echo "ROOT Partition created at: $PART_ROOT"

# 4. FORMATTING & MOUNTING
echo "Formatting partitions..."
mkfs.fat -F 32 "$PART_EFI"
mkfs.ext4 -F "$PART_ROOT"

echo "Mounting partitions..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

mountpoint -q /mnt || { echo "Error: /mnt not mounted, aborting."; exit 1; }
mountpoint -q /mnt/boot || { echo "Error: /mnt/boot not mounted, aborting."; exit 1; }

echo -e "\n✅ Partitions ready and mounted at /mnt and /mnt/boot."

# 5. update pacman and open archinstall (yeah it's interactive)
echo "Updating pacman, keyring, and installing archinstall..."
pacman -Sy --noconfirm archlinux-keyring archinstall

echo "-------------------------------------------------"
echo "Launching archinstall interactively."
echo "IMPORTANT: In the disk configuration step, choose the option"
echo "to use the already-mounted target (/mnt) rather than letting"
echo "archinstall re-partition $DISK — it is already partitioned."
echo "Set the mountpoint used by archinstall to: /mnt"
echo "-------------------------------------------------"
read -p "Press Enter to launch archinstall..." _

archinstall --mountpoint /mnt

echo -e "\narchinstall has exited. Resuming script for finalization..."

# 6. post-install verification
echo "Verifying fstab was generated successfully by archinstall..."
if [ ! -f /mnt/etc/fstab ]; then
    echo "Error: /mnt/etc/fstab not found. archinstall may not have completed successfully. Aborting."
    exit 1
fi
cat /mnt/etc/fstab
echo "-------------------------------------------------"

# 7. chroot: to check grub installation
echo "Entering chroot to finalize system..."

arch-chroot /mnt /bin/bash <<'EOF'
set -e

echo "Fixing Windows dual-boot hardware clock sync..."
hwclock --systohc --localtime

echo "Installing bootloader dependencies..."
pacman -S --noconfirm grub efibootmgr os-prober dosfstools mtools

echo "Enabling os-prober to detect Windows..."
if grep -q "^GRUB_DISABLE_OS_PROBER=" /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
fi

echo "Installing GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

echo "Generating GRUB config..."
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# 8. CLEANUP
echo "Unmounting and finishing up..."
umount -R /mnt
echo "Installation completely automated and finished! You can now type 'reboot'."
