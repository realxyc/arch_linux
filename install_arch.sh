#!/bin/bash
#
# Arch Linux installer for dual-booting alongside an existing Windows
# install. Handles the three ways of dealing with the EFI partition:
#
#   1) new dedicated ESP just for Arch
#   2) reuse the existing Windows ESP directly (systemd-boot + UKI)
#   3) reuse the existing Windows ESP for the GRUB stub only, kernel and
#      initramfs live inside the Arch root partition (safe even on a
#      tiny shared ESP)
#
# Windows partitions are never touched. Nothing is written to disk until
# you type YES at the confirmation prompt.

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"

clear
echo "Arch Linux dual-boot installer"
echo "-------------------------------"

# --- pick disk -------------------------------------------------------

echo
lsblk -d -p -n -o NAME,SIZE,MODEL | grep -v loop
echo
read -rp "Disk to install to (e.g. /dev/nvme0n1): " DISK
[ -b "$DISK" ] || die "'$DISK' is not a block device"

DISK_MODEL=$(lsblk -d -n -o MODEL "$DISK")
DISK_SIZE=$(lsblk -d -n -o SIZE "$DISK")

echo
echo "Current layout (check your Windows partitions are here):"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo

# --- find the windows ESP, if any -------------------------------------

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
WIN_ESP=$(lsblk -rno NAME,PARTTYPE "$DISK" \
    | awk -v g="$ESP_GUID" 'tolower($2)==g {print $1; exit}')

if [ -n "$WIN_ESP" ]; then
    WIN_ESP="/dev/$WIN_ESP"
    WIN_ESP_FREE_MIB=$(df --output=avail -m "$WIN_ESP" | tail -1 | tr -d ' ')
    echo "Found existing ESP: $WIN_ESP (${WIN_ESP_FREE_MIB} MiB free)"
else
    echo "No existing ESP found on $DISK."
fi
echo

# --- boot mode ---------------------------------------------------------

cat <<'MENU'
Boot partition setup:

  1) New dedicated EFI partition for Arch, systemd-boot + UKI
  2) Reuse the existing Windows ESP as-is, systemd-boot + UKI
     (fine if the ESP has plenty of room, breaks on small shared ESPs)
  3) Reuse the existing Windows ESP for the bootloader only (GRUB),
     kernel/initramfs go in the Arch root partition instead
     (works regardless of how small the ESP is)

MENU
read -rp "Choice [1-3]: " MODE
case "$MODE" in
    1|2|3) ;;
    *) die "invalid choice" ;;
esac

if [ "$MODE" != "1" ] && [ -z "$WIN_ESP" ]; then
    die "mode $MODE needs an existing ESP but none was found"
fi

if [ "$MODE" = "2" ] && [ "${WIN_ESP_FREE_MIB:-9999}" -lt 300 ]; then
    echo
    echo "Only ${WIN_ESP_FREE_MIB} MiB free on the existing ESP. A UKI"
    echo "usually needs more than that, especially with more than one"
    echo "GPU. Mode 1 or 3 will be more reliable."
    read -rp "Continue with mode 2 anyway? (yes/no): " ans
    [ "$ans" = "yes" ] || die "aborted"
fi

# --- sizing -------------------------------------------------------------

echo
parted -s "$DISK" unit MiB print free
echo

FREE_MIB=$(parted -s "$DISK" unit MiB print free \
    | awk '/Free Space/ {gsub("MiB","",$3); if ($3+0>m) m=$3+0} END{print m+0}')
[ "$FREE_MIB" -gt 0 ] || die "no free space found on $DISK"
echo "Largest free region: ${FREE_MIB} MiB"

to_mib() {
    local n u
    n=$(sed -E 's/([0-9.]+).*/\1/' <<<"$1")
    u=$(sed -E 's/[0-9.]+([A-Za-z]*)/\1/' <<<"$1" | tr '[:lower:]' '[:upper:]')
    case "$u" in
        G|GIB|GB) awk -v n="$n" 'BEGIN{printf "%d", n*1024}' ;;
        M|MIB|MB|"") awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
        *) die "unrecognized size unit in '$1'" ;;
    esac
}

NEW_ESP_MIB=0
if [ "$MODE" = "1" ]; then
    read -rp "New Arch ESP size [1G]: " esp_in
    NEW_ESP_MIB=$(to_mib "${esp_in:-1G}")
fi

read -rp "Root partition size [200G]: " root_in
ROOT_MIB=$(to_mib "${root_in:-200G}")

TOTAL_MIB=$((NEW_ESP_MIB + ROOT_MIB))
[ "$TOTAL_MIB" -le "$FREE_MIB" ] || die "requested size (${TOTAL_MIB} MiB) exceeds free space (${FREE_MIB} MiB)"

# --- confirm -------------------------------------------------------------

clear
echo "About to partition $DISK ($DISK_MODEL, $DISK_SIZE)"
echo
case "$MODE" in
    1) echo "  new ESP:  ${esp_in:-1G} FAT32, label ARCH_ESP" ;;
    2) echo "  ESP:      reusing $WIN_ESP as-is, not formatted" ;;
    3) echo "  ESP:      reusing $WIN_ESP for GRUB stub only, not formatted" ;;
esac
echo "  root:     ${root_in:-200G} ext4, label LINUX_ROOT"
echo
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo
read -rp "Type YES to proceed: " confirm
[ "$confirm" = "YES" ] || die "aborted, nothing was touched"

# --- partition ------------------------------------------------------------

if [ "$MODE" = "1" ]; then
    sgdisk -n 0:0:+"${esp_in:-1G}" -t 0:ef00 -c 0:ARCH_ESP "$DISK"
fi
sgdisk -n 0:0:+"${root_in:-200G}" -t 0:8300 -c 0:LINUX_ROOT "$DISK"

partprobe "$DISK"
udevadm settle

ROOT_PART="/dev/$(lsblk -rno NAME,PARTLABEL "$DISK" | awk '$2=="LINUX_ROOT"{print $1}')"
[ -b "$ROOT_PART" ] || die "could not find the new root partition"

ARCH_ESP=""
if [ "$MODE" = "1" ]; then
    ARCH_ESP="/dev/$(lsblk -rno NAME,PARTLABEL "$DISK" | awk '$2=="ARCH_ESP"{print $1}')"
    [ -b "$ARCH_ESP" ] || die "could not find the new ESP"
fi

# --- format + mount ---------------------------------------------------------

# wipefs first: mkfs only writes its own superblock, it doesn't clear
# leftover signatures from a filesystem that previously lived in this
# spot (e.g. from an earlier aborted install), which can otherwise
# confuse mount's filesystem autodetection later.
wipefs -a "$ROOT_PART"
mkfs.ext4 -qF "$ROOT_PART"
mount "$ROOT_PART" /mnt

case "$MODE" in
    1)
        wipefs -a "$ARCH_ESP"
        mkfs.fat -F32 "$ARCH_ESP" >/dev/null
        mkdir -p /mnt/boot
        mount "$ARCH_ESP" /mnt/boot
        ;;
    2)
        mkdir -p /mnt/boot
        mount "$WIN_ESP" /mnt/boot
        ;;
    3)
        mkdir -p /mnt/boot/efi
        mount "$WIN_ESP" /mnt/boot/efi
        ;;
esac

echo "mounted, ready for archinstall"

# --- archinstall -------------------------------------------------------------

pacman -Sy --noconfirm archlinux-keyring archinstall

echo
echo "Launching archinstall. Disk config: pre-mounted, target /mnt."
case "$MODE" in
    1|2) echo "Bootloader: systemd-boot, kernel image: UKI." ;;
    3)   echo "Bootloader: pick GRUB. This script fixes up the config"
         echo "afterward either way, so don't worry about getting it"
         echo "perfect in the menu." ;;
esac
echo
read -rp "Press enter to launch archinstall..." _

archinstall --mountpoint /mnt

[ -f /mnt/etc/fstab ] || die "archinstall didn't finish (no fstab found)"

# --- mode 3 cleanup: force the non-UKI / GRUB layout regardless of what
# archinstall's own bootloader step did, since its behaviour with a split
# /boot + /boot/efi mount isn't something to rely on -----------------------

if [ "$MODE" = "3" ]; then
    echo "Finalizing GRUB setup..."
    arch-chroot /mnt bash <<'CHROOT'
set -e
rm -rf /boot/efi/EFI/Linux /boot/efi/loader /boot/efi/EFI/systemd 2>/dev/null || true

if [ -f /etc/mkinitcpio.d/linux.preset ]; then
    sed -i 's/^default_uki=/#default_uki=/'   /etc/mkinitcpio.d/linux.preset
    sed -i 's/^fallback_uki=/#fallback_uki=/' /etc/mkinitcpio.d/linux.preset
    sed -i 's/^#default_image=/default_image=/'   /etc/mkinitcpio.d/linux.preset
    sed -i 's/^#fallback_image=/fallback_image=/' /etc/mkinitcpio.d/linux.preset
fi
mkinitcpio -P

pacman -S --noconfirm --needed grub os-prober ntfs-3g efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi
CHROOT
    genfstab -U /mnt > /mnt/etc/fstab
fi

# --- nvme module check (matters for modes 1/2, which may build a UKI) ------

UKI_FILE=$(find /mnt/boot -iname '*.efi' 2>/dev/null | head -n1 || true)
if [ -n "$UKI_FILE" ] && arch-chroot /mnt which lsinitcpio &>/dev/null; then
    if ! arch-chroot /mnt lsinitcpio "${UKI_FILE#/mnt}" 2>/dev/null | grep -q nvme; then
        echo "nvme module missing from the kernel image, adding it..."
        arch-chroot /mnt sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvme)/' /etc/mkinitcpio.conf
        arch-chroot /mnt mkinitcpio -P
    fi
fi

# --- if grub ended up installed, make sure it actually found windows ------

if arch-chroot /mnt pacman -Qq grub &>/dev/null; then
    arch-chroot /mnt pacman -S --noconfirm --needed os-prober ntfs-3g
    out=$(arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>&1)
    echo "$out"
    echo "$out" | grep -qi 'windows boot manager' \
        || echo "note: GRUB didn't report finding Windows. Disable Fast Startup in Windows and re-run grub-mkconfig after booting into Windows once."
fi

# --- more than one bootloader installed? keep one, drop the rest ----------

found=()
arch-chroot /mnt pacman -Qq grub   &>/dev/null && found+=(grub)
[ -f /mnt/boot/loader/loader.conf ]            && found+=(systemd-boot)
arch-chroot /mnt pacman -Qq refind &>/dev/null && found+=(refind)
arch-chroot /mnt pacman -Qq limine &>/dev/null && found+=(limine)

if [ "${#found[@]}" -gt 1 ]; then
    echo
    echo "More than one bootloader is installed:"
    for i in "${!found[@]}"; do echo "  $((i+1))) ${found[$i]}"; done
    read -rp "Which one do you want to keep? " keep_idx
    if ! [[ "$keep_idx" =~ ^[0-9]+$ ]] || [ "$keep_idx" -lt 1 ] || [ "$keep_idx" -gt "${#found[@]}" ]; then
        echo "invalid choice, leaving both installed, clean this up manually"
    else
        keep="${found[$((keep_idx-1))]}"
        for bl in "${found[@]}"; do
            [ "$bl" = "$keep" ] && continue
            case "$bl" in
                grub)         arch-chroot /mnt pacman -Rns --noconfirm grub; rm -rf /mnt/boot/grub ;;
                systemd-boot) arch-chroot /mnt bootctl --esp-path=/boot remove || true
                              rm -rf /mnt/boot/loader /mnt/boot/EFI/systemd ;;
                refind)       arch-chroot /mnt pacman -Rns --noconfirm refind; rm -rf /mnt/boot/EFI/refind ;;
                limine)       arch-chroot /mnt pacman -Rns --noconfirm limine
                              rm -f /mnt/boot/limine.cfg; rm -rf /mnt/boot/EFI/BOOT/limine* ;;
            esac
            case "$bl" in
                grub)         label=GRUB ;;
                systemd-boot) label="Linux Boot Manager" ;;
                refind)       label=rEFInd ;;
                limine)       label=Limine ;;
            esac
            while read -r num; do
                [ -n "$num" ] && efibootmgr -b "$num" -B
            done < <(efibootmgr -v | grep -i "$label" | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
        done
        echo "kept: $keep"
    fi
fi

umount -R /mnt
echo
echo "Done. Reboot when ready."
