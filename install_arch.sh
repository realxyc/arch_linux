#!/bin/bash
# Exit immediately if any command fails to prevent catastrophic errors
set -e 

clear
echo "================================================="
echo "     Welcome to Arch Linux Hybrid Installer      "
echo "================================================="

# ==========================================
# 1. CONFIG SELECTION
# ==========================================
echo "Choose your system profile:"
options=("Cosmic Desktop [1]" "Minimal [2]" "Quit [q]")

select opt in "${options[@]}"
do
    case $REPLY in
        1)
            CONFIG_PATH="$(pwd)/desktop/user_configuration.json"
            PROFILE="Cosmic Desktop"
            echo "Profile: $PROFILE"
            break
            ;;
        2)
            CONFIG_PATH="$(pwd)/minimal/user_configuration.json"
            PROFILE="Minimal"
            echo "Profile: $PROFILE"
            break
            ;;
        q|Q|[Qq]uit)
            echo "Exiting..."
            exit 0
            ;;
        *) 
            echo "Invalid option. Please press 1, 2, or q."
            ;;
    esac
done

CREDS_PATH="$(pwd)/user_credentials.json"

# ==========================================
# 2. DRIVE SELECTION
# ==========================================
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
read -p "EFI Partition Size (e.g., 1G, 512M) [Default: 1G]: " INPUT_EFI
EFI_SIZE=${INPUT_EFI:-1G}

read -p "Root Partition Size (e.g., 500G, 200G) [Default: 500G]: " INPUT_ROOT
ROOT_SIZE=${INPUT_ROOT:-500G}

CONFIG_FILE="user_configuration.json"
CREDS_FILE="user_credentials.json"

# ==========================================
# 3. THE FINAL SUMMARY
# ==========================================
clear 

echo "================================================="
echo "       FINAL INSTALLATION SUMMARY        "
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
echo "CONFIGURATION FILES:"
echo "  - Settings:     $CONFIG_FILE"
echo "  - Credentials:  $CREDS_FILE"
echo "================================================="
echo "CURRENT DRIVE LAYOUT (Verify your Windows partition!):"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo "================================================="

echo -e "\nPOINT OF NO RETURN"
echo "This script will carve out the planned partitions from the UNALLOCATED free space on $DISK."
read -p "Are you absolutely sure? Type 'YES' in all caps to proceed: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation aborted by user. Your disks have not been touched."
    exit 1
fi

echo "Safety check passed. Commencing installation..."

# ==========================================
# 3. UPDATE PACMAN & KEYRING
# ==========================================
echo "Updating pacman, keyring, and installing archinstall..."
#pacman -Syu --noconfirm
pacman -Sy --noconfirm archlinux-keyring archinstall

# ==========================================
# 4. PARTITIONING (Targeting Free Space)
# ==========================================
echo "Carving out ${EFI_SIZE} EFI and ${ROOT_SIZE} Root from free space on $DISK..."

sgdisk -n 0:0:+"$EFI_SIZE" -t 0:ef00 -c 0:"EFI_BOOT" "$DISK"
sgdisk -n 0:0:+"$ROOT_SIZE" -t 0:8300 -c 0:"LINUX_ROOT" "$DISK"

echo "Syncing partition tables..."
partprobe "$DISK"
sleep 3 

PART_EFI_NAME=$(lsblk -o NAME,PARTLABEL -r | grep "EFI_BOOT" | awk '{print $1}')
PART_ROOT_NAME=$(lsblk -o NAME,PARTLABEL -r | grep "LINUX_ROOT" | awk '{print $1}')

PART_EFI="/dev/$PART_EFI_NAME"
PART_ROOT="/dev/$PART_ROOT_NAME"

echo "EFI Partition created at: $PART_EFI"
echo "ROOT Partition created at: $PART_ROOT"

# ==========================================
# 5. FORMATTING & MOUNTING
# ==========================================
echo "Formatting partitions..."
mkfs.fat -F 32 "$PART_EFI"
mkfs.ext4 -F "$PART_ROOT"

echo "Mounting partitions..."
mount "$PART_ROOT" /mnt
mkdir /mnt/boot
mount "$PART_EFI" /mnt/boot

# ==========================================
# 6. ARCHINSTALL
# ==========================================
echo "Invoking archinstall silently with saved configuration and credentials..."

if [[ ! -f "$CONFIG_FILE" || ! -f "$CREDS_FILE" ]]; then
    echo "Error: $CONFIG_FILE or $CREDS_FILE not found in the current directory!"
    umount -R /mnt
    exit 1
fi

# The --silent flag ensures it doesn't pause to ask about chrooting
archinstall --config "$CONFIG_FILE" --creds "$CREDS_FILE" --mountpoint /mnt --silent

# ==========================================
# 7. POST-INSTALL VERIFICATION & CHROOT
# ==========================================
echo "Verifying fstab was generated successfully by archinstall..."
cat /mnt/etc/fstab
echo "-------------------------------------------------"

echo "Archinstall finished. Entering chroot to finalize system..."

arch-chroot /mnt /bin/bash <<EOF
echo "Fixing Windows dual-boot hardware clock sync..."
hwclock --systohc --localtime

echo "Installing bootloader dependencies..."
pacman -S --noconfirm grub efibootmgr os-prober dosfstools mtools

echo "Enabling os-prober to detect Windows..."
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

echo "Installing GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

echo "Generating GRUB config..."
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# ==========================================
# 8. CLEANUP
# ==========================================
echo "Unmounting and finishing up..."
umount -R /mnt
echo "Installation completely automated and finished! You can now type 'reboot'."
