#!/bin/bash

# Debian 13 Full Disk Encryption Autosetup Script
# v2.40

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BOOT_PART_SIZE="512M"
EFI_PART_SIZE="1G"
LOG_FILE="/var/log/debian-fde-setup.log"
ENCRYPTION_MODE=""  # "password" or "usb-keyfile"
INSTALL_MODE=""     # "fresh", "reinstall", or "change-keys"

# ---------------------------------------------------------------------------
# Visual formatting helpers
# ---------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'

msg()  { echo -e "${C_BOLD}${C_BLUE}[*]${C_RESET} $*" >&2; }
ok()   { echo -e "${C_BOLD}${C_GREEN}[✓]${C_RESET} $*" >&2; }
warn() { echo -e "${C_BOLD}${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()  { echo -e "${C_BOLD}${C_RED}[✗]${C_RESET} $*" >&2; }
step() { echo -e "\n${C_BOLD}${C_CYAN}▶ $*${C_RESET}" >&2; }
sub()  { echo -e "  ${C_DIM}→${C_RESET} $*" >&2; }
die()  { err "$@" && exit 1; }

# ---------------------------------------------------------------------------
# Password entry helper with confirmation and retry
# ---------------------------------------------------------------------------
get_password_with_confirmation() {
    local prompt="$1"
    local password=""
    local confirm=""

    while true; do
        read -s -rp "$prompt: " password
        echo >&2
        read -s -rp "Confirm password: " confirm
        echo >&2

        if [[ "$password" == "$confirm" ]]; then
            echo "$password"
            return 0
        else
            err "Passwords don't match. Please try again."
        fi
    done
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# ---------------------------------------------------------------------------
# Pre-install checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root"
TARGET_USER="${SUDO_USER:-$USER}"
LIVE_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$LIVE_HOME" ]] || die "Cannot determine home directory for user '$TARGET_USER'"

# Detect boot mode EARLY (before package installation)
BOOT_MODE="BIOS"
[[ -d /sys/firmware/efi ]] && BOOT_MODE="UEFI"
echo
msg "Detected boot mode: $BOOT_MODE"

# ---------------------------------------------------------------------------
# Installation Mode Selection
# ---------------------------------------------------------------------------
select_install_mode() {
    echo -e "\n═════════════════════════════════════════════════════════\n" >&2
    echo -e "${C_CYAN}Debian 13 LUKS Full Disk Encryption Setup Script${C_RESET}" >&2
    echo -e "${C_CYAN}Select Operation Mode:${C_RESET}\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}1) Fresh FDE desktop install${C_RESET}" >&2
    echo -e "  ${C_DIM}   (Wipes everything)${C_RESET}" >&2
    echo -e "     • Creates new partition table" >&2
    echo -e "     • Sets up fresh LUKS encryption" >&2
    echo -e "     • Installs new desktop environment\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}2) Re-install FDE desktop${C_RESET}" >&2
    echo -e "  ${C_DIM}   (Keep user data)${C_RESET}" >&2
    echo -e "     • Keeps existing partition structure" >&2
    echo -e "     • Preserves all home data" >&2
    echo -e "     • Preserves LUKS keys" >&2
    echo -e "     • Formats only root and swap\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}3) Change LUKS Keys${C_RESET}" >&2
    echo -e "  ${C_DIM}   (Key management only)${C_RESET}" >&2
    echo -e "     • Change encryption password" >&2
    echo -e "     • Regenerate keyfile" >&2
    echo -e "     • No system modifications\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}<< BACKUP YOUR DATA BEFORE PROCEEDING!! >>${C_RESET}\n" >&2
    echo -e "═════════════════════════════════════════════════════════\n" >&2

    while true; do
        read -rp "Select operation mode [1-3]: " choice
        case "$choice" in
            1)
                INSTALL_MODE="fresh"
                ok "Selected: Fresh Install"
                return 0
                ;;
            2)
                INSTALL_MODE="reinstall"
                ok "Selected: Re-install (Keep LUKS Keys and Data)"
                return 0
                ;;
            3)
                INSTALL_MODE="change-keys"
                ok "Selected: Change LUKS Keys"
                return 0
                ;;
            *)
                err "Invalid selection. Choose 1, 2, or 3."
                ;;
        esac
    done
}

# Execute installation mode selection
select_install_mode

# ---------------------------------------------------------------------------
# Encryption Mode Selection
# ---------------------------------------------------------------------------
select_encryption_mode() {
    echo -e "\n${C_CYAN}Select Encryption Mode:${C_RESET}\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}1) Single Password Mode${C_RESET}" >&2
    echo -e "  ${C_DIM}   (Very strong security)${C_RESET}" >&2
    echo -e "     • Encrypted /boot partition" >&2
    echo -e "     ${C_GREEN}✓${C_RESET} Keyfile on /boot auto-unlocks LVM" >&2
    echo -e "     ${C_GREEN}✓${C_RESET} Single password unlocks everything" >&2
    echo -e "     ${C_RED}✗${C_RESET} Password always required at boot" >&2
    echo -e "     ${C_RED}✗${C_RESET} Slower boot time\n" >&2

    echo -e "  ${C_BOLD}${C_YELLOW}2) USB Keyfile Mode${C_RESET}" >&2
    echo -e "  ${C_DIM}   (Strong security)${C_RESET}" >&2
    echo -e "     • Unencrypted /boot on USB" >&2
    echo -e "     ${C_GREEN}✓${C_RESET} Keyfile on USB unlocks LVM" >&2
    echo -e "     ${C_GREEN}✓${C_RESET} Automatic boot (no password needed)" >&2
    echo -e "     ${C_RED}✗${C_RESET} USB stick required" >&2
    echo -e "     ${C_RED}✗${C_RESET} USB theft/loss compromises security\n" >&2

    while true; do
        read -rp "Select encryption mode [1-2]: " choice
        case "$choice" in
            1)
                ENCRYPTION_MODE="password"
                ok "Selected: Single Password Mode"
                return 0
                ;;
            2)
                ENCRYPTION_MODE="usb-keyfile"
                ok "Selected: USB Keyfile Mode"
                return 0
                ;;
            *)
                err "Invalid selection. Choose 1 or 2."
                ;;
        esac
    done
}

# Execute encryption selection only for fresh install
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    select_encryption_mode
fi

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
step "Installing required packages"
apt-get update -qq

PACKAGES="gdisk parted cryptsetup lvm2 debootstrap e2fsprogs dosfstools mtools zstd file initramfs-tools whois"

# Only install the appropriate GRUB package for the boot mode
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    PACKAGES="$PACKAGES grub-efi-amd64"
else
    PACKAGES="$PACKAGES grub-pc"
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y -q $PACKAGES
ok "Dependencies installed"

# ---------------------------------------------------------------------------
# Device selection
# ---------------------------------------------------------------------------
# Detect if a NVME disk exists
part_suffix() {
    [[ "$1" == *"nvme"* ]] && echo "p" || echo ""
}

# Select target disk
step "Device selection"
lsblk -d -p -o NAME,SIZE,MODEL,TYPE | sed 's/^/  /' >&2
echo >&2

if [[ "$INSTALL_MODE" == "fresh" ]]; then
    read -rp "Enter target disk (e.g. /dev/sda): " TARGET_DISK
    [[ -b "$TARGET_DISK" ]] || die "Invalid device: $TARGET_DISK"

    if [[ "$ENCRYPTION_MODE" == "usb-keyfile" ]]; then
        read -rp "Enter USB device for keyfile (e.g. /dev/sdb): " USB_DEVICE
        [[ -b "$USB_DEVICE" ]] || die "Invalid USB device: $USB_DEVICE"
        [[ "$USB_DEVICE" != "$TARGET_DISK" ]] || die "Target and USB devices must be different"
    fi

    echo >&2
    warn "This will DESTROY ALL DATA on selected devices"
    read -p "Type YES (in capitals) to confirm: " confirm
    [[ "$confirm" == "YES" ]] || die "Not confirmed"
elif [[ "$INSTALL_MODE" == "reinstall" ]]; then
    # For reinstall, detect existing encrypted partitions
    read -rp "Enter target disk (e.g. /dev/sda): " TARGET_DISK
    [[ -b "$TARGET_DISK" ]] || die "Invalid device: $TARGET_DISK"

    # Detect LUKS partitions
    echo >&2
    msg "Detecting existing encrypted partitions..."
    LUKS_PARTS=$(lsblk -o NAME,TYPE,FSTYPE "$TARGET_DISK" | grep -i "crypto_LUKS" || true)

    if [[ -z "$LUKS_PARTS" ]]; then
        die "No LUKS partitions found on $TARGET_DISK"
    fi

    echo -e "${C_CYAN}Found LUKS partitions:${C_RESET}" >&2
    echo "$LUKS_PARTS" | sed 's/^/  /' >&2
    echo >&2

    # Determine LUKS partition (usually the largest one)
    LUKS_PART_NUM=$(lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DISK" | grep -i "crypto_LUKS" | sort -k4 -h -r | head -1 | awk '{print $1}')
    sfx="$(part_suffix "$TARGET_DISK")"
    LUKS_PART="${TARGET_DISK}${sfx}${LUKS_PART_NUM##*[!0-9]}"

    # Check if boot partition is encrypted
    BOOT_PART_NUM=$(lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DISK" | grep -i "crypto_LUKS" | sort -k4 -h | head -1 | awk '{print $1}')

    if [[ "$BOOT_PART_NUM" != "$LUKS_PART_NUM" ]]; then
        ENCRYPTION_MODE="password"
        BOOT_PART="${TARGET_DISK}${sfx}${BOOT_PART_NUM##*[!0-9]}"
        msg "Detected password mode (encrypted boot)"
    else
        ENCRYPTION_MODE="usb-keyfile"
        # For USB mode, need to detect USB device
        read -rp "Enter USB device for boot/keyfile (e.g. /dev/sdb): " USB_DEVICE
        [[ -b "$USB_DEVICE" ]] || die "Invalid USB device: $USB_DEVICE"

        # Detect boot partition on USB
        USB_BOOT_PART="${USB_DEVICE}1"
        USB_KEYFILE_PART="${USB_DEVICE}2"
        msg "Detected USB keyfile mode"
    fi

    # For UEFI, detect EFI partition
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        EFI_PART_NUM=$(sgdisk -p "$TARGET_DISK" | grep -i "EF00" | awk '{print $1}')
        if [[ -n "$EFI_PART_NUM" ]]; then
            EFI_PART="${TARGET_DISK}${sfx}${EFI_PART_NUM}"
        fi
    fi

    echo >&2
    warn "This will format root and swap partitions but PRESERVE /home data"
    read -p "Type YES (in capitals) to confirm: " confirm
    [[ "$confirm" == "YES" ]] || die "Not confirmed"
elif [[ "$INSTALL_MODE" == "change-keys" ]]; then
    # For key change, detect and open existing encrypted partitions
    read -rp "Enter target disk (e.g. /dev/sda): " TARGET_DISK
    [[ -b "$TARGET_DISK" ]] || die "Invalid device: $TARGET_DISK"

    # Detect LUKS partitions
    echo >&2
    msg "Detecting existing encrypted partitions..."
    LUKS_PARTS=$(lsblk -o NAME,TYPE,FSTYPE "$TARGET_DISK" | grep -i "crypto_LUKS" || true)

    if [[ -z "$LUKS_PARTS" ]]; then
        die "No LUKS partitions found on $TARGET_DISK"
    fi

    echo -e "\n${C_CYAN}Found LUKS partitions:${C_RESET}" >&2
    echo "$LUKS_PARTS" | sed 's/^/  /' >&2
    echo >&2

    # Determine if password mode (two LUKS partitions) or USB mode (one LUKS partition)
    LUKS_PART_COUNT=$(echo "$LUKS_PARTS" | wc -l)

    if [[ "$LUKS_PART_COUNT" -ge 2 ]]; then
        ENCRYPTION_MODE="password"

        # Get both LUKS partitions
        LUKS_PART_NUM=$(lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DISK" | grep -i "crypto_LUKS" | sort -k4 -h -r | head -1 | awk '{print $1}')
        BOOT_PART_NUM=$(lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DISK" | grep -i "crypto_LUKS" | sort -k4 -h | head -1 | awk '{print $1}')

        sfx="$(part_suffix "$TARGET_DISK")"
        LUKS_PART="${TARGET_DISK}${sfx}${LUKS_PART_NUM##*[!0-9]}"
        BOOT_PART="${TARGET_DISK}${sfx}${BOOT_PART_NUM##*[!0-9]}"

        msg "Detected password mode (encrypted boot)"
        msg "Boot partition: $BOOT_PART"
        msg "LUKS partition: $LUKS_PART"
    else
        ENCRYPTION_MODE="usb-keyfile"

        LUKS_PART_NUM=$(lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DISK" | grep -i "crypto_LUKS" | sort -k4 -h -r | head -1 | awk '{print $1}')
        sfx="$(part_suffix "$TARGET_DISK")"
        LUKS_PART="${TARGET_DISK}${sfx}${LUKS_PART_NUM##*[!0-9]}"

        read -rp "Enter USB device for keyfile (e.g. /dev/sdb): " USB_DEVICE
        [[ -b "$USB_DEVICE" ]] || die "Invalid USB device: $USB_DEVICE"
        USB_KEYFILE_PART="${USB_DEVICE}2"

        msg "Detected USB keyfile mode"
        msg "LUKS partition: $LUKS_PART"
        msg "USB keyfile partition: $USB_KEYFILE_PART"
    fi
fi

# ---------------------------------------------------------------------------
# Desktop Environment Selection (skip for change-keys mode)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODE" != "change-keys" ]]; then
    step "Desktop environment selection"
    echo -e "  ${C_DIM}(minimum disk space required)${C_RESET}" >&2
    echo -e "  1) KDE Plasma  ${C_DIM}(10GB)${C_RESET}" >&2
    echo -e "  2) GNOME       ${C_DIM}(15GB)${C_RESET}" >&2
    echo -e "  3) MATE        ${C_DIM}(8GB)${C_RESET}" >&2
    echo -e "  4) XFCE        ${C_DIM}(6GB)${C_RESET}" >&2
    echo -e "  5) <Cancel>\n" >&2

    while true; do
        read -rp "Select desktop [1-5]: " n
        case "$n" in
            1) DE="KDE"; break ;;
            2) DE="GNOME"; break ;;
            3) DE="MATE"; break ;;
            4) DE="XFCE"; break ;;
            5) die "No desktop selected" ;;
            *) err "Invalid selection" ;;
        esac
    done
    ok "Selected: $DE"
fi

# ---------------------------------------------------------------------------
# Get target partition sizes (only for fresh install)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    step "Partition sizes"
    while true; do
        read -rp "Enter root partition size in GB e.g. 50: " ROOT_SIZE
        if [[ ! "$ROOT_SIZE" =~ ^[0-9]+$ ]]; then
            err "Invalid size. Positive numerical values only."
        elif [[ "$ROOT_SIZE" -le "5" ]]; then
            err "Size selected is too small. Modern linux desktop require at least 6GB."
        elif [[ "$ROOT_SIZE" -gt "100" ]]; then
            err "Size selected is too large. Root should contain system packages while home will hold all your user data. 50GB+ is plenty for most usecases."
        else
            export ROOT_SIZE
            break
        fi
    done

    while true; do
        read -rp "Enter swap partition size in GB e.g. 4 (or 0 to skip): " SWAP_GB
        if [[ ! "$SWAP_GB" =~ ^[0-9]+$ ]]; then
            err "Invalid size. Positive numerical values only."
        elif [[ "$SWAP_GB" -eq "0" ]]; then
            msg "No swap will be created."
            export SWAP_GB
            break
        elif [[ "$SWAP_GB" -gt "64" ]]; then
            err "Swap is too large. Beyond 64GB fills up disk storage for no real benefit. Choose a smaller size."
        else
            export SWAP_GB
            break
        fi
    done
fi

# ---------------------------------------------------------------------------
# Helper: Find which keyslot a given keyfile currently occupies (LVM partition)
# Prints the slot number (0-7) on stdout, or nothing if not found.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
find_keyfile_slot() {
    local kf="$1"
    local part="$2"
    local slot

    if [[ ! -f "$kf" ]]; then
        return 1
    fi

    for slot in 0 1 2 3 4 5 6 7; do
        if cryptsetup open --test-passphrase \
                --key-slot="$slot" \
                --key-file="$kf" \
                "$part" >/dev/null 2>&1; then
            printf '%s' "$slot"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Find first free keyslot on a LUKS partition (0-7)
# Prints the slot number on stdout, or nothing if all are occupied.
# ---------------------------------------------------------------------------
find_free_slot() {
    local part="$1"
    local slot dump

    dump=$(cryptsetup luksDump "$part" 2>/dev/null) || return 1

    for slot in 0 1 2 3 4 5 6 7; do
        if ! grep -qE "^[[:space:]]*${slot}:[[:space:]]+luks[12]" <<<"$dump"; then
            printf '%s' "$slot"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Validate a keyslot variable is a non-empty numeric 0-7
# Returns 0 if valid, 1 if invalid.
# ---------------------------------------------------------------------------
is_valid_keyslot() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 7 ))
}

# ---------------------------------------------------------------------------
# Rebuild initramfs and GRUB inside the encrypted system
# ---------------------------------------------------------------------------
rebuild_initramfs_and_grub() {
    # Mounts the encrypted system, chroots, rebuilds initramfs + grub, unmounts.
    # Requires BOOT_PART, LUKS_PART, and (optionally) EFI_PART to be set.

    step "Rebuilding initramfs and GRUB (mandatory after keyfile change)"

    # Ensure no stale mappings
    cryptsetup close crypt-boot-temp 2>/dev/null || true
    cryptsetup close crypt-boot 2>/dev/null || true
    cryptsetup close crypt-disk 2>/dev/null || true
    vgchange -an vg0 2>/dev/null || true

    # Open boot partition
    echo -e "\n${C_YELLOW}Enter boot partition password:${C_RESET}" >&2
    cryptsetup open "$BOOT_PART" crypt-boot || die "Failed to open boot partition"

    # Open LUKS partition using the (new) keyfile on boot
    mkdir -p /mnt/rebuild-boot
    mount /dev/mapper/crypt-boot /mnt/rebuild-boot || die "Failed to mount crypt-boot"

    if [[ ! -f /mnt/rebuild-boot/luks-lvm.keyfile ]]; then
        umount /mnt/rebuild-boot 2>/dev/null || true
        cryptsetup close crypt-boot 2>/dev/null || true
        die "Keyfile not found on boot partition; cannot proceed"
    fi

    cryptsetup open --key-file /mnt/rebuild-boot/luks-lvm.keyfile "$LUKS_PART" crypt-disk \
        || { umount /mnt/rebuild-boot; cryptsetup close crypt-boot; die "Failed to open LUKS partition with new keyfile"; }

    vgscan --mknodes >/dev/null 2>&1 || true
    vgchange -ay >/dev/null 2>&1 || true
    sleep 2

    # Mount root
    mkdir -p /mnt/rebuild-root
    mount /dev/mapper/vg0-root /mnt/rebuild-root || die "Failed to mount vg0-root"

    # Mount /boot (already open via crypt-boot)
    mount /dev/mapper/crypt-boot /mnt/rebuild-root/boot

    # Mount /home if present (not strictly needed, but keeps LVM consistent)
    if lvdisplay /dev/mapper/vg0-home >/dev/null 2>&1; then
        mkdir -p /mnt/rebuild-root/home
        mount /dev/mapper/vg0-home /mnt/rebuild-root/home 2>/dev/null || true
    fi

    # Mount EFI if UEFI
    if [[ "$BOOT_MODE" == "UEFI" && -n "${EFI_PART:-}" ]]; then
        mkdir -p /mnt/rebuild-root/boot/efi
        mount "$EFI_PART" /mnt/rebuild-root/boot/efi || warn "Failed to mount EFI partition"
    fi

    # Bind mounts for chroot
    mount --bind /dev  /mnt/rebuild-root/dev
    mount --bind /dev/pts /mnt/rebuild-root/dev/pts
    mount --bind /proc /mnt/rebuild-root/proc
    mount --bind /sys  /mnt/rebuild-root/sys

    # Rebuild initramfs (embeds new keyfile via KEYFILE_PATTERN) and GRUB
    msg "Running update-initramfs..."
    chroot /mnt/rebuild-root update-initramfs -u -k all || {
        umount -R /mnt/rebuild-root 2>/dev/null || true
        die "update-initramfs failed inside chroot"
    }

    msg "Running update-grub..."
    chroot /mnt/rebuild-root update-grub || warn "update-grub reported an error (non-fatal)"

    ok "Initramfs and GRUB rebuilt with new keyfile"

    # Cleanup
    sync
    umount -R /mnt/rebuild-root 2>/dev/null || true
    rmdir /mnt/rebuild-root 2>/dev/null || true
    umount /mnt/rebuild-boot 2>/dev/null || true
    rmdir /mnt/rebuild-boot 2>/dev/null || true
    vgchange -an vg0 2>/dev/null || true
    cryptsetup close crypt-disk 2>/dev/null || true
    cryptsetup close crypt-boot 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Change LUKS Keys functionality
# ---------------------------------------------------------------------------
change_luks_keys() {
    step "Changing LUKS Encryption Keys"

    if [[ "$ENCRYPTION_MODE" == "password" ]]; then
        echo -e "  ${C_BLUE}Password Mode Key Change Options:${C_RESET}\n" >&2
        echo -e "  1) Change boot partition password" >&2
        echo -e "  2) Change LVM partition password (backup password)" >&2
        echo -e "  3) Regenerate LVM keyfile on boot partition" >&2
        echo -e "  4) Change all keys (password + keyfile)\n" >&2

        while true; do
            read -rp "Select option [1-4]: " key_choice
            case "$key_choice" in
                1)
                    # Change boot partition password
                    echo >&2
                    msg "Changing boot partition password..."
                    cryptsetup luksChangeKey "$BOOT_PART"
                    ok "Boot partition password changed"
                    warn "Note: Password change does NOT require initramfs rebuild (no keyfile change)"
                    ;;
                2)
                    # Change LVM partition backup password
                    echo >&2
                    msg "Changing LVM partition backup password..."
                    echo -e "\n${C_YELLOW}Enter current LVM partition password:${C_RESET}" >&2
                    cryptsetup luksChangeKey "$LUKS_PART"
                    ok "LVM partition password changed"
                    warn "Note: Password change does NOT require initramfs rebuild (no keyfile change)"
                    ;;
                3)
                    # Regenerate keyfile on boot partition (in-place slot overwrite)
                    echo >&2
                    msg "Regenerating keyfile on boot partition (for LVM partition)..."

                    # Open boot partition
                    echo -e "\n${C_YELLOW}Enter boot partition password to open it:${C_RESET}" >&2
                    cryptsetup open "$BOOT_PART" crypt-boot-temp || die "Failed to open boot partition"

                    # Mount boot partition
                    mkdir -p /mnt/boot-temp
                    mount /dev/mapper/crypt-boot-temp /mnt/boot-temp || {
                        cryptsetup close crypt-boot-temp
                        rmdir /mnt/boot-temp
                        die "Failed to mount boot partition"
                    }

                    # Ensure keyfile exists
                    if [[ ! -f /mnt/boot-temp/luks-lvm.keyfile ]]; then
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Keyfile not found on boot partition"
                    fi

                    # Backup old keyfile
                    cp /mnt/boot-temp/luks-lvm.keyfile /mnt/boot-temp/luks-lvm.keyfile.old

                    # Find the keyslot used by the old keyfile
                    if ! OLD_KEYFILE_SLOT="$(find_keyfile_slot /mnt/boot-temp/luks-lvm.keyfile "${LUKS_PART}")"; then
                        warn "Could not determine old keyfile's keyslot. Aborting to avoid lockout."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Old keyfile keyslot not detectable"
                    fi

                    if ! is_valid_keyslot "$OLD_KEYFILE_SLOT"; then
                        warn "Detected keyslot is not a valid number: '$OLD_KEYFILE_SLOT'. Aborting."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Invalid keyslot value"
                    fi

                    msg "Old keyfile is in keyslot: $OLD_KEYFILE_SLOT on ${LUKS_PART}"

                    # Generate new keyfile
                    msg "Generating new keyfile..."
                    dd if=/dev/urandom of=/mnt/boot-temp/luks-lvm.keyfile.new bs=4096 count=1 status=none
                    chmod 0400 /mnt/boot-temp/luks-lvm.keyfile.new
                    chown root:root /mnt/boot-temp/luks-lvm.keyfile.new

                    # In-place replace: existing key = old keyfile, new key = new keyfile,
                    # overwrite slot = OLD_KEYFILE_SLOT. No stdin prompt.
                    msg "Replacing keyfile in keyslot $OLD_KEYFILE_SLOT (in-place)..."
                    if ! cryptsetup luksChangeKey "$LUKS_PART" /mnt/boot-temp/luks-lvm.keyfile.new \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile \
                            --key-slot "$OLD_KEYFILE_SLOT"; then
                        warn "luksChangeKey failed. No changes were committed."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Failed to replace keyfile in keyslot ${OLD_KEYFILE_SLOT} on ${LUKS_PART}"
                    fi

                    # Verify new keyfile works before committing on-disk replacement
                    msg "Verifying new keyfile..."
                    if ! cryptsetup open --test-passphrase \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile.new \
                            "$LUKS_PART" >/dev/null 2>&1; then
                        # Roll back: use the new keyfile to authorise restoring the old one
                        warn "Verification failed. Attempting rollback to old keyfile..."
                        cryptsetup luksChangeKey "$LUKS_PART" /mnt/boot-temp/luks-lvm.keyfile.old \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile.new \
                            --key-slot "$OLD_KEYFILE_SLOT" \
                            || warn "Rollback also failed! Manual recovery required."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "New keyfile verification failed; no changes were committed"
                    fi
                    ok "New keyfile verified successfully"

                    # Replace keyfile on disk
                    mv /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile
                    rm -f /mnt/boot-temp/luks-lvm.keyfile.old

                    sync
                    umount /mnt/boot-temp
                    rmdir /mnt/boot-temp
                    cryptsetup close crypt-boot-temp

                    # MANDATORY: rebuild initramfs so the new keyfile is embedded
                    rebuild_initramfs_and_grub

                    ok "Keyfile regenerated and LVM partition updated"
                    ;;
                4)
                    # Change boot partition password + regenerate keyfile (in-place)
                    echo -e "\n${C_YELLOW}Step 1: Change boot partition password${C_RESET}" >&2
                    cryptsetup luksChangeKey "$BOOT_PART"

                    # Open boot partition with new password
                    echo -e "\n${C_YELLOW}Step 2: Open boot partition with new password${C_RESET}" >&2
                    cryptsetup open "$BOOT_PART" crypt-boot-temp || die "Failed to open boot partition"
                    mkdir -p /mnt/boot-temp
                    mount /dev/mapper/crypt-boot-temp /mnt/boot-temp || {
                        cryptsetup close crypt-boot-temp
                        rmdir /mnt/boot-temp
                        die "Failed to mount boot partition"
                    }

                    # Ensure keyfile exists
                    if [[ ! -f /mnt/boot-temp/luks-lvm.keyfile ]]; then
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Keyfile not found on boot partition"
                    fi

		    msg "Keyfile found on boot partition..."

                    # Backup old keyfile
                    cp /mnt/boot-temp/luks-lvm.keyfile /mnt/boot-temp/luks-lvm.keyfile.old

                    # Find keyslot of old keyfile
                    if ! OLD_KEYFILE_SLOT="$(find_keyfile_slot /mnt/boot-temp/luks-lvm.keyfile "${LUKS_PART}")"; then
                        warn "Could not determine old keyfile's keyslot. Aborting to avoid lockout."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Old keyfile keyslot not detectable"
                    fi

                    if ! is_valid_keyslot "$OLD_KEYFILE_SLOT"; then
                        warn "Detected keyslot is not a valid number: '$OLD_KEYFILE_SLOT'. Aborting."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Invalid keyslot value"
                    fi

		    msg "LVM paritition detected"
		    msg "Old keyfile is in keyslot: ${OLD_KEYFILE_SLOT} on ${LUKS_PART}"

                    # Generate new keyfile
                    msg "Generating new keyfile..."
                    dd if=/dev/urandom of=/mnt/boot-temp/luks-lvm.keyfile.new bs=4096 count=1 status=none
                    chmod 0400 /mnt/boot-temp/luks-lvm.keyfile.new
                    chown root:root /mnt/boot-temp/luks-lvm.keyfile.new

                    # In-place replace keyfile in its slot
                    echo -e "\n${C_YELLOW}Step 3: Replace LVM partition keyfile in keyslot ${OLD_KEYFILE_SLOT}${C_RESET}" >&2
                    if ! cryptsetup luksChangeKey "$LUKS_PART" /mnt/boot-temp/luks-lvm.keyfile.new \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile \
                            --key-slot "$OLD_KEYFILE_SLOT"; then
                        warn "luksChangeKey failed. No changes were committed."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "Failed to replace keyfile in keyslot $OLD_KEYFILE_SLOT"
                    fi

                    # Verify new keyfile
                    msg "Verifying new keyfile..."
                    if ! cryptsetup open --test-passphrase \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile.new \
                            "$LUKS_PART" >/dev/null 2>&1; then
                        warn "Verification failed. Attempting rollback..."
                        cryptsetup luksChangeKey "$LUKS_PART" /mnt/boot-temp/luks-lvm.keyfile.old \
                            --key-file /mnt/boot-temp/luks-lvm.keyfile.new \
                            --key-slot "$OLD_KEYFILE_SLOT" \
                            || warn "Rollback also failed! Manual recovery required."
                        rm -f /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile.old
                        umount /mnt/boot-temp
                        rmdir /mnt/boot-temp
                        cryptsetup close crypt-boot-temp
                        die "New keyfile verification failed; no changes were committed"
                    fi
                    ok "New keyfile verified successfully"

                    # Change LVM backup password
                    echo -e "\n${C_YELLOW}Step 4: Change LVM partition backup password${C_RESET}" >&2
                    cryptsetup luksChangeKey "$LUKS_PART"
		    echo >&2

                    # Replace keyfile on disk
                    mv /mnt/boot-temp/luks-lvm.keyfile.new /mnt/boot-temp/luks-lvm.keyfile
                    rm -f /mnt/boot-temp/luks-lvm.keyfile.old

                    sync
                    umount /mnt/boot-temp
                    rmdir /mnt/boot-temp
                    cryptsetup close crypt-boot-temp

                    # MANDATORY: rebuild initramfs so the new keyfile is embedded
                    rebuild_initramfs_and_grub

                    ok "All encryption keys changed successfully"
                    ;;
                *)
                    err "Invalid selection. Choose 1, 2, 3, or 4."
                    ;;
            esac
            break
        done

    else
        # USB keyfile mode
        echo -e "  ${C_BLUE}USB Keyfile Mode Key Change Options:${C_RESET}\n" >&2
        echo -e "  1) Change LVM partition backup password" >&2
        echo -e "  2) Regenerate LVM keyfile on USB" >&2
        echo -e "  3) Change both (password + keyfile)\n" >&2

        while true; do
            read -rp "Select option [1-3]: " key_choice
            case "$key_choice" in
                1)
                    # Change LUKS backup password
                    echo >&2
                    msg "Changing LVM partition backup password..."
                    cryptsetup luksChangeKey "$LUKS_PART"
                    ok "LVM partition password changed"
                    warn "Note: USB keyfile mode does NOT embed the keyfile in initramfs; no rebuild required for password change"
                    ;;
                2)
                    # Regenerate keyfile on USB (in-place slot overwrite)
                    echo >&2

                    # Mount USB keyfile partition
                    mkdir -p /mnt/usb-keyfile
                    mount "$USB_KEYFILE_PART" /mnt/usb-keyfile || die "Failed to mount USB keyfile partition"

                    if [[ ! -f /mnt/usb-keyfile/luks-lvm.keyfile ]]; then
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Keyfile not found on USB"
                    fi

                    # Backup old keyfile
                    cp /mnt/usb-keyfile/luks-lvm.keyfile /mnt/usb-keyfile/luks-lvm.keyfile.old

                    # Find keyslot of old keyfile
                    if ! OLD_KEYFILE_SLOT="$(find_keyfile_slot /mnt/usb-keyfile/luks-lvm.keyfile "${LUKS_PART}")"; then
                        warn "Could not determine old keyfile's keyslot on USB. Aborting to avoid lockout."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Old keyfile keyslot not detectable"
                    fi

                    if ! is_valid_keyslot "$OLD_KEYFILE_SLOT"; then
                        warn "Detected keyslot is not a valid number: '$OLD_KEYFILE_SLOT'. Aborting."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Invalid keyslot value"
                    fi
                    msg "Old keyfile is in keyslot ${OLD_KEYFILE_SLOT} on ${LUKS_PART}"

                    # Generate new keyfile
                    msg "Generating keyfile on USB..."
                    dd if=/dev/urandom of=/mnt/usb-keyfile/luks-lvm.keyfile.new bs=4096 count=1 status=none
                    chmod 0400 /mnt/usb-keyfile/luks-lvm.keyfile.new
                    chown root:root /mnt/usb-keyfile/luks-lvm.keyfile.new

                    # In-place replace
                    msg "Replacing keyfile in keyslot ${OLD_KEYFILE_SLOT} ..."
                    if ! cryptsetup luksChangeKey "$LUKS_PART" /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile \
                            --key-slot "$OLD_KEYFILE_SLOT"; then
                        warn "luksChangeKey failed. No changes were committed."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Failed to replace keyfile in keyslot $OLD_KEYFILE_SLOT on USB"
                    fi

                    # Verify new keyfile
                    msg "Verifying new keyfile..."
                    if ! cryptsetup open --test-passphrase \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            "$LUKS_PART" >/dev/null 2>&1; then
                        warn "Verification failed. Attempting rollback..."
                        cryptsetup luksChangeKey "$LUKS_PART" /mnt/usb-keyfile/luks-lvm.keyfile.old \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            --key-slot "$OLD_KEYFILE_SLOT" \
                            || warn "Rollback also failed! Manual recovery required."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "New keyfile verification failed; no changes were committed"
                    fi
                    ok "New keyfile on ${LUKS_PART} verified successfully"

                    # Replace keyfile on disk
                    mv /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile
                    rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old

                    sync
                    umount /mnt/usb-keyfile
                    rmdir /mnt/usb-keyfile

                    ok "Keyfile regenerated and LUKS partition updated"
                    warn "USB keyfile mode does NOT embed the keyfile in initramfs, so no rebuild is required."
                    ;;
                3)
                    # Change both (password + keyfile)
                    # Mount USB keyfile partition
                    mkdir -p /mnt/usb-keyfile
                    mount "$USB_KEYFILE_PART" /mnt/usb-keyfile || die "Failed to mount USB keyfile partition"

                    if [[ ! -f /mnt/usb-keyfile/luks-lvm.keyfile ]]; then
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Keyfile not found on USB"
                    fi

                    # Backup old keyfile
                    cp /mnt/usb-keyfile/luks-lvm.keyfile /mnt/usb-keyfile/luks-lvm.keyfile.old

                    # Find keyslot of old keyfile
                    if ! OLD_KEYFILE_SLOT="$(find_keyfile_slot /mnt/usb-keyfile/luks-lvm.keyfile "${LUKS_PART}")"; then
                        warn "Could not determine old keyfile's keyslot on USB. Aborting to avoid lockout."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Old keyfile keyslot not detectable"
                    fi

                    if ! is_valid_keyslot "$OLD_KEYFILE_SLOT"; then
                        warn "Detected keyslot is not a valid number: '$OLD_KEYFILE_SLOT'. Aborting."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Invalid keyslot value"
                    fi
                    msg "Old keyfile is in keyslot: ${OLD_KEYFILE_SLOT} on ${LUKS_PART}"

                    # Generate new keyfile
                    echo >&2
                    msg "Generating keyfile on USB..."
                    dd if=/dev/urandom of=/mnt/usb-keyfile/luks-lvm.keyfile.new bs=4096 count=1 status=none
                    chmod 0400 /mnt/usb-keyfile/luks-lvm.keyfile.new
                    chown root:root /mnt/usb-keyfile/luks-lvm.keyfile.new

                    # In-place replace keyfile
                    echo -e "\n${C_YELLOW}Step 1: Replace keyfile in keyslot ${OLD_KEYFILE_SLOT} on ${LUKS_PART}${C_RESET}" >&2
                    if ! cryptsetup luksChangeKey "$LUKS_PART" /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile \
                            --key-slot "$OLD_KEYFILE_SLOT"; then
                        warn "luksChangeKey failed. No changes were committed."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "Failed to replace keyfile in keyslot $OLD_KEYFILE_SLOT"
                    fi

                    # Verify new keyfile
                    msg "Verifying new keyfile..."
                    if ! cryptsetup open --test-passphrase \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            "$LUKS_PART" >/dev/null 2>&1; then
                        warn "Verification failed. Attempting rollback..."
                        cryptsetup luksChangeKey "$LUKS_PART" /mnt/usb-keyfile/luks-lvm.keyfile.old \
                            --key-file /mnt/usb-keyfile/luks-lvm.keyfile.new \
                            --key-slot "$OLD_KEYFILE_SLOT" \
                            || warn "Rollback also failed! Manual recovery required."
                        rm -f /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile.old
                        umount /mnt/usb-keyfile
                        rmdir /mnt/usb-keyfile
                        die "New keyfile verification failed; no changes were committed"
                    fi
                    ok "New keyfile verified successfully"

                    # Change backup password
                    echo -e "\n${C_YELLOW}Step 2: Change LVM backup password${C_RESET}" >&2
		    cryptsetup luksChangeKey "$LUKS_PART"

                    # Replace keyfile on disk
                    mv /mnt/usb-keyfile/luks-lvm.keyfile.new /mnt/usb-keyfile/luks-lvm.keyfile
                    rm -f /mnt/usb-keyfile/luks-lvm.keyfile.old

                    sync
                    umount /mnt/usb-keyfile
                    rmdir /mnt/usb-keyfile

                    ok "All encryption keys changed successfully"
                    warn "USB keyfile mode does NOT embed the keyfile in initramfs, so no rebuild is required."
                    ;;
                *)
                    err "Invalid selection. Choose 1, 2, or 3."
                    ;;
            esac
            break
        done
    fi

    # Backup LUKS headers after key change
    echo >&2
    read -rp "Backup LUKS headers to $LIVE_HOME? [y/N]: " r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        backup_file="$LIVE_HOME/luks-headers-$(date +%Y%m%d_%H%M%S).tar"
        mkdir -p /tmp/luks-backup
        cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file /tmp/luks-backup/lvm-header.img
        if [[ "$ENCRYPTION_MODE" == "password" ]]; then
            cryptsetup luksHeaderBackup "$BOOT_PART" --header-backup-file /tmp/luks-backup/boot-header.img
        fi
        tar cf "$backup_file" -C /tmp/luks-backup .
        chmod 600 "$backup_file"
        chown "$TARGET_USER":"$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$backup_file" 2>/dev/null || true
        rm -rf /tmp/luks-backup
        ok "LUKS headers saved to: $backup_file"
        warn "Store this file on offline media immediately!"
    fi
}

# Execute key change if selected
if [[ "$INSTALL_MODE" == "change-keys" ]]; then
    change_luks_keys

    ok "LUKS key(s) change complete!"
    echo -e "\n═════════════════════════════════════════════════════════\n" >&2
    step "Post-Installation Summary:"
    if [[ "$ENCRYPTION_MODE" == "password" ]]; then
        echo -e "\n ${C_GREEN}•${C_RESET} ${C_BOLD}Initramfs and GRUB were rebuilt automatically.${C_RESET}" >&2
        echo -e " ${C_GREEN}•${C_RESET} Test the new keys by rebooting ${C_BOLD}before${C_RESET} relying on this system." >&2
    else
        echo -e "\n ${C_GREEN}•${C_RESET} USB keyfile mode: initramfs does not embed the keyfile." >&2
        echo -e " ${C_GREEN}•${C_RESET} Test the new USB keyfile by rebooting ${C_BOLD}before${C_RESET} relying on this system." >&2
    fi
    echo -e " ${C_GREEN}•${C_RESET} For troubleshooting you can find the log file at:" >&2
    echo -e "   /var/log/debian-fde-setup.log${C_RESET}" >&2
    echo -e "\n═════════════════════════════════════════════════════════\n" >&2
    ok "Reboot when ready"
    echo >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Partition functions
# ---------------------------------------------------------------------------
partition_target_disk() {
    local dev="$1" mode="$2"
    step "Partitioning target disk $dev"

    umount "${dev}"* 2>/dev/null || true
    sgdisk --zap-all "$dev" >/dev/null 2>&1
    wipefs -a "$dev" >/dev/null 2>&1 || true
    partprobe "$dev" 2>/dev/null || true
    sleep 2

    local sfx="$(part_suffix "$dev")"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        if [[ "$mode" == "password" ]]; then
            # UEFI: EFI + BOOT + LUKS
            sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:EF00 -c 1:"EFI" "$dev"
            sgdisk -n 2:0:+${BOOT_PART_SIZE} -t 2:8300 -c 2:"BOOT" "$dev"
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"LUKS" "$dev"
            EFI_PART="${dev}${sfx}1"
            BOOT_PART="${dev}${sfx}2"
            LUKS_PART="${dev}${sfx}3"
        else
            # UEFI: EFI + LUKS (boot on USB)
            sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:EF00 -c 1:"EFI" "$dev"
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"LUKS" "$dev"
            EFI_PART="${dev}${sfx}1"
            LUKS_PART="${dev}${sfx}2"
        fi
    else
        if [[ "$mode" == "password" ]]; then
            # BIOS: BIOS + BOOT + LUKS
            sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS" "$dev"
            sgdisk -n 2:0:+${BOOT_PART_SIZE} -t 2:8300 -c 2:"BOOT" "$dev"
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"LUKS" "$dev"
            BOOT_PART="${dev}${sfx}2"
            LUKS_PART="${dev}${sfx}3"
        else
            # BIOS: BIOS + LUKS (boot on USB)
            sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS" "$dev"
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"LUKS" "$dev"
            LUKS_PART="${dev}${sfx}2"
        fi
    fi
    partprobe "$dev" 2>/dev/null || true
    sleep 2
}

partition_usb_device() {
    local dev="$1"
    step "Partitioning USB device $dev"

    umount "${dev}"* 2>/dev/null || true
    sgdisk --zap-all "$dev" >/dev/null 2>&1
    wipefs -a "$dev" >/dev/null 2>&1 || true
    partprobe "$dev" 2>/dev/null || true
    sleep 2

    local sfx="$(part_suffix "$dev")"

    # BOOT + KEYFILE partitions
    sgdisk -n 1:0:+${BOOT_PART_SIZE} -t 1:8300 -c 1:"BOOT" "$dev"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"KEYFILE" "$dev"
    USB_BOOT_PART="${dev}${sfx}1"
    USB_KEYFILE_PART="${dev}${sfx}2"

    partprobe "$dev" 2>/dev/null || true
    sleep 2
}

# ---------------------------------------------------------------------------
# Execute partitioning (only for fresh install)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    if [[ "$ENCRYPTION_MODE" == "password" ]]; then
        partition_target_disk "$TARGET_DISK" "password"
    else
        partition_usb_device "$USB_DEVICE"
        partition_target_disk "$TARGET_DISK" "usb-keyfile"
    fi
    ok "Partitions created"
fi

# ---------------------------------------------------------------------------
# Format and setup encryption
# ---------------------------------------------------------------------------
setup_encryption() {
    step "Setting up encryption"

    if [[ "$INSTALL_MODE" == "fresh" ]]; then
        if [[ "$ENCRYPTION_MODE" == "password" ]]; then
            # Format EFI if UEFI
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                mkfs.fat -F 32 -n EFI "$EFI_PART" >/dev/null
                sub "EFI partition formatted"
            fi

            # Get password with retry
            echo >&2
            PASSWORD=$(get_password_with_confirmation "Enter encryption password")

            # Encrypt boot partition (LUKS1 for GRUB)
            msg "Encrypting boot partition"
            echo "$PASSWORD" | cryptsetup luksFormat --type luks1 \
                --key-size 256 --cipher aes-xts-plain64 --hash sha512 \
                --iter-time 5000 "$BOOT_PART"
            echo "$PASSWORD" | cryptsetup open "$BOOT_PART" crypt-boot
            mkfs.ext4 -F -L BOOT /dev/mapper/crypt-boot >/dev/null
            ok "Boot partition encrypted"

            # Create keyfile on boot partition with restrictive permissions
            msg "Creating keyfile on boot partition"
            mkdir -p /mnt/boot-temp
            mount /dev/mapper/crypt-boot /mnt/boot-temp
            dd if=/dev/urandom of=/mnt/boot-temp/luks-lvm.keyfile bs=4096 count=1 status=none
            chmod 0400 /mnt/boot-temp/luks-lvm.keyfile
            chown root:root /mnt/boot-temp/luks-lvm.keyfile
            sync
            ok "Keyfile created on boot partition"

            # Encrypt LVM partition with keyfile
            msg "Encrypting LVM partition"
            cryptsetup luksFormat --type luks2 \
                --key-file /mnt/boot-temp/luks-lvm.keyfile "$LUKS_PART"
            # Add password as backup
            echo "$PASSWORD" | cryptsetup luksAddKey \
                --key-file /mnt/boot-temp/luks-lvm.keyfile "$LUKS_PART"
            cryptsetup open --key-file /mnt/boot-temp/luks-lvm.keyfile "$LUKS_PART" crypt-disk
            ok "LVM partition encrypted"

        else
            # USB keyfile mode
            # Format USB partitions
            msg "Formatting USB partitions..."
            mkfs.ext4 -F -L BOOT "$USB_BOOT_PART" >/dev/null
            mkfs.ext4 -F -L KEYFILE "$USB_KEYFILE_PART" >/dev/null
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                mkfs.fat -F 32 -n EFI "$EFI_PART" >/dev/null
            fi
            ok "USB partitions formatted"

            # Create keyfile on USB with restrictive permissions
            msg "Creating keyfile on USB"
            mkdir -p /mnt/usb-keyfile
            mount "$USB_KEYFILE_PART" /mnt/usb-keyfile
            dd if=/dev/urandom of=/mnt/usb-keyfile/luks-lvm.keyfile bs=4096 count=1 status=none
            chmod 0400 /mnt/usb-keyfile/luks-lvm.keyfile
            chown root:root /mnt/usb-keyfile/luks-lvm.keyfile
            sync
            ok "Keyfile created on USB"

            # Encrypt LVM partition with keyfile
            msg "Encrypting LVM partition"
            cryptsetup luksFormat --type luks2 \
                --key-file /mnt/usb-keyfile/luks-lvm.keyfile "$LUKS_PART"

            # Add backup password with retry
            echo >&2
            PASSWORD=$(get_password_with_confirmation "Enter backup password for LVM partition")

            echo "$PASSWORD" | cryptsetup luksAddKey \
                --key-file /mnt/usb-keyfile/luks-lvm.keyfile "$LUKS_PART"

            cryptsetup open --key-file /mnt/usb-keyfile/luks-lvm.keyfile "$LUKS_PART" crypt-disk
            ok "LVM partition encrypted"
        fi
    else
        # Reinstall mode - open existing encryption
        msg "Opening existing encrypted partitions..."

        if [[ "$ENCRYPTION_MODE" == "password" ]]; then
            # Open boot partition first
            echo >&2
            echo -e "${C_YELLOW}Enter password to unlock boot partition:${C_RESET}" >&2
            cryptsetup open "$BOOT_PART" crypt-boot || die "Failed to open boot partition"

            # Get keyfile from boot partition
            mkdir -p /mnt/boot-temp
            mount /dev/mapper/crypt-boot /mnt/boot-temp
            if [[ ! -f /mnt/boot-temp/luks-lvm.keyfile ]]; then
                die "Keyfile not found on boot partition"
            fi

            # Open LVM partition using keyfile
            cryptsetup open --key-file /mnt/boot-temp/luks-lvm.keyfile "$LUKS_PART" crypt-disk || die "Failed to open LVM partition"
        else
            # USB keyfile mode
            # Mount USB keyfile partition
            mkdir -p /mnt/usb-keyfile
            mount "$USB_KEYFILE_PART" /mnt/usb-keyfile || die "Failed to mount USB keyfile partition"

            if [[ ! -f /mnt/usb-keyfile/luks-lvm.keyfile ]]; then
                die "Keyfile not found on USB"
            fi

            # Open LVM partition using keyfile
            cryptsetup open --key-file /mnt/usb-keyfile/luks-lvm.keyfile "$LUKS_PART" crypt-disk || die "Failed to open LVM partition"
        fi
        ok "Encrypted partitions opened"
    fi
}

# Execute device encryption setup
setup_encryption

# ---------------------------------------------------------------------------
# Setup LVM (only for fresh install)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    step "Setting up LVM"
    pvcreate /dev/mapper/crypt-disk >/dev/null
    vgcreate vg0 /dev/mapper/crypt-disk >/dev/null
    lvcreate -L "${ROOT_SIZE}G" -n root vg0 >/dev/null
    if [[ "$SWAP_GB" -gt 0 ]]; then
        lvcreate -L "${SWAP_GB}G" -n swap vg0 >/dev/null
    fi
    lvcreate -l 100%FREE -n home vg0 >/dev/null
    mkfs.ext4 -F -L ROOT /dev/mapper/vg0-root >/dev/null
    mkfs.ext4 -F -L HOME /dev/mapper/vg0-home >/dev/null
    if [[ "$SWAP_GB" -gt 0 ]]; then
        mkswap -L SWAP /dev/mapper/vg0-swap >/dev/null
    fi
    # Ensure LVM volumes are ready
    vgscan --mknodes >/dev/null 2>&1
    vgchange -ay >/dev/null 2>&1
    sleep 2
    ok "LVM setup complete"
else
    # Reinstall mode - activate LVM and format only root/swap
    step "Preparing LVM for reinstall"
    vgscan --mknodes >/dev/null 2>&1
    vgchange -ay >/dev/null 2>&1
    sleep 2

    # Format root partition
    msg "Formatting root partition..."
    mkfs.ext4 -F -L ROOT /dev/mapper/vg0-root >/dev/null

    # Format swap if it exists
    if lvdisplay /dev/mapper/vg0-swap >/dev/null 2>&1; then
        msg "Formatting swap partition..."
        mkswap -L SWAP /dev/mapper/vg0-swap >/dev/null
        SWAP_GB=1
    else
        SWAP_GB=0
    fi

    ok "Root and swap formatted, home preserved"
fi

# ---------------------------------------------------------------------------
# Mount filesystems
# ---------------------------------------------------------------------------
step "Mounting filesystems"
mkdir -p /mnt/luks-root
mount /dev/mapper/vg0-root /mnt/luks-root

if [[ "$INSTALL_MODE" == "fresh" ]]; then
    mkdir -p /mnt/luks-root/home
    mount /dev/mapper/vg0-home /mnt/luks-root/home
else
    # For reinstall, mount home but don't format it
    mkdir -p /mnt/luks-root/home
    mount /dev/mapper/vg0-home /mnt/luks-root/home
    ok "Home partition mounted"
fi

mkdir -p /mnt/luks-root/boot

if [[ "$ENCRYPTION_MODE" == "password" ]]; then
    if [[ "$INSTALL_MODE" == "fresh" ]]; then
        umount /mnt/boot-temp 2>/dev/null || true
        rmdir /mnt/boot-temp 2>/dev/null || true
    fi
    mount /dev/mapper/crypt-boot /mnt/luks-root/boot
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkdir -p /mnt/luks-root/boot/efi
        mount "$EFI_PART" /mnt/luks-root/boot/efi
    fi
else
    mount "$USB_BOOT_PART" /mnt/luks-root/boot
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkdir -p /mnt/luks-root/boot/efi
        mount "$EFI_PART" /mnt/luks-root/boot/efi
    fi
fi
ok "Filesystems mounted"

# ---------------------------------------------------------------------------
# Install base system
# ---------------------------------------------------------------------------
step "Installing Debian 13 base system (this takes some time)"
debootstrap --arch=amd64 trixie /mnt/luks-root http://deb.debian.org/debian
ok "Base system installed"

# ---------------------------------------------------------------------------
# Prepare chroot
# ---------------------------------------------------------------------------
step "Preparing chroot"
mount --bind /dev /mnt/luks-root/dev
mount --bind /dev/pts /mnt/luks-root/dev/pts
mount --bind /proc /mnt/luks-root/proc
mount --bind /sys /mnt/luks-root/sys
cp /etc/resolv.conf /mnt/luks-root/etc/resolv.conf

# Copy LVM metadata
mkdir -p /mnt/luks-root/etc/lvm/backup
if [[ -f /etc/lvm/backup/vg0 ]]; then
    cp /etc/lvm/backup/vg0 /mnt/luks-root/etc/lvm/backup/
    ok "LVM metadata copied to chroot"
fi

ok "Chroot prepared"

# ---------------------------------------------------------------------------
# Configure system in chroot
# ---------------------------------------------------------------------------
step "Configuring system in chroot"

cat > /mnt/luks-root/setup_chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

# Define local logging functions
msg()  { echo "[*] $*" >&2; }
ok()   { echo "[✓] $*" >&2; }
warn() { echo "[!] $*" >&2; }
err()  { echo "[✗] $*" >&2; }

# Verify required variables are set
: "${BOOT_MODE:?BOOT_MODE not set}"
: "${DE:?DE not set}"
: "${SWAP_GB:?SWAP_GB not set}"
: "${ENCRYPTION_MODE:?ENCRYPTION_MODE not set}"
: "${TARGET_DISK:?TARGET_DISK not set}"
: "${LUKS_PART:?LUKS_PART not set}"

if [[ "$ENCRYPTION_MODE" == "password" ]]; then
    : "${BOOT_PART:?BOOT_PART not set}"
fi

if [[ "$ENCRYPTION_MODE" == "usb-keyfile" ]]; then
    : "${USB_BOOT_PART:?USB_BOOT_PART not set}"
    : "${USB_KEYFILE_PART:?USB_KEYFILE_PART not set}"
    : "${USB_DEVICE:?USB_DEVICE not set}"
fi

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    : "${EFI_PART:?EFI_PART not set}"
fi

msg "Starting chroot configuration..."
msg "Boot mode: $BOOT_MODE"
msg "Desktop: $DE"
msg "Encryption mode: $ENCRYPTION_MODE"

# Sources list
msg "Configuring apt sources"
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ trixie main non-free-firmware non-free contrib
deb http://security.debian.org/debian-security trixie-security main non-free-firmware non-free contrib
deb http://deb.debian.org/debian/ trixie-updates main non-free-firmware contrib
EOF

# Update and install base packages
msg "Updating package lists"
apt-get update -qq

msg "Installing base packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    linux-image-amd64 systemd-sysv whois cryptsetup cryptsetup-initramfs \
    lvm2 sudo locales initramfs-tools console-setup keyboard-configuration \
    reiserfsprogs e2fsprogs jfsutils bc exfat-fuse ntfs-3g dosfstools mtools \
    firmware-amd-graphics firmware-iwlwifi firmware-realtek firmware-brcm80211 firmware-ath9k-htc \
    firmware-misc-nonfree intel-microcode firmware-b43-installer
ok "Base packages installed"

# Install desktop environment
msg "Installing $DE desktop environment..."
install_desktop() {
    case "$DE" in
        KDE)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                kde-plasma-desktop plasma-nm sddm konsole dolphin \
                kde-config-screenlocker
            systemctl enable sddm
            ;;
        GNOME)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                gnome-core gdm3 network-manager-gnome gedit \
                gnome-terminal gnome-tweaks
            systemctl enable gdm3
            ;;
        MATE)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                mate-desktop-environment-core mate-desktop-environment-extras lightdm network-manager-gnome \
                mate-terminal caja
            systemctl enable lightdm
            ;;
        XFCE)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                xfce4 xfce4-goodies lightdm network-manager-gnome \
                xfce4-terminal thunar
            systemctl enable lightdm
            ;;
        *)
            echo "Unknown desktop: $DE" >&2
            exit 1
            ;;
    esac
}
install_desktop
ok "Desktop installed"


# Add your specific desktop packages to install here (uncomment to activate)
#msg "Installing custom user desktop packages"
#DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
#    gnupg wget nano exfat-fuse manpages man-db lsof duf \
#    ufw curl htop ssh screen rsync xz-utils zip unzip file gnupg \
#    pipx lm-sensors toilet figlet eza gparted vlc intel-media-va-driver ffmpeg \
#    command-not-found speedtest-cli tealdeer keepassxc \
#    libreoffice-writer libreoffice-calc \
#    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
#    cups system-config-printer foomatic-db openprinting-ppds tcl-tclreadline psutils
#ok "Custom desktop packages installed"


# Install GRUB - only one version based on boot mode
msg "Installing GRUB for $BOOT_MODE"
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q grub-efi-amd64
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q grub-pc
fi
ok "GRUB installed"

# fstab - Fixed with noauto,nofail for boot partitions
msg "Configuring fstab..."
cat > /etc/fstab << EOF
/dev/mapper/vg0-root    /        ext4    defaults,noatime    0 1
/dev/mapper/vg0-home    /home    ext4    defaults,noatime    0 2
EOF

if [[ "$ENCRYPTION_MODE" == "password" ]]; then
    # Use noauto,nofail since initramfs already mounts /boot
    echo "/dev/mapper/crypt-boot  /boot    ext4    defaults,noauto,nofail    0 2" >> /etc/fstab
else
    # USB boot partition - also mounted by initramfs
    echo "UUID=$(blkid -s UUID -o value "$USB_BOOT_PART")  /boot  ext4  defaults,noauto,nofail  0 2" >> /etc/fstab
fi

if [[ "$SWAP_GB" -gt 0 ]]; then
    echo "/dev/mapper/vg0-swap none swap sw 0 0" >> /etc/fstab
fi

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # EFI partition also mounted by initramfs
    echo "UUID=$(blkid -s UUID -o value "$EFI_PART")  /boot/efi  vfat  defaults,noauto,nofail  0 1" >> /etc/fstab
fi
ok "fstab configured"

# Crypttab configuration
msg "Configuring crypttab..."
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")

if [[ "$ENCRYPTION_MODE" == "password" ]]; then
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")

    # crypt-boot: unlocked by password prompt
    # crypt-disk: unlocked by keyfile on mounted /boot partition
    cat > /etc/crypttab << EOF
crypt-boot UUID=${BOOT_UUID} none luks,discard
crypt-disk UUID=${LUKS_UUID} /boot/luks-lvm.keyfile luks,discard
EOF

    # Configure GRUB to pass password to initramfs to avoid double prompt
    msg "Configuring GRUB for encrypted boot..."
    cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Debian"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=/dev/mapper/vg0-root rootdelay=5"
GRUB_ENABLE_CRYPTODISK=y
GRUB_PRELOAD_MODULES="cryptodisk luks lvm"
EOF

else
    # USB keyfile mode
    cat > /etc/crypttab << EOF
crypt-disk UUID=${LUKS_UUID} /dev/disk/by-label/KEYFILE:/luks-lvm.keyfile luks,keyscript=/lib/cryptsetup/scripts/passdev
EOF

    # Create passdev script if needed
    if [[ ! -f /lib/cryptsetup/scripts/passdev ]]; then
        msg "Creating passdev keyscript"
        mkdir -p /lib/cryptsetup/scripts
        cat > /lib/cryptsetup/scripts/passdev << 'PASSDEV_EOF'
#!/bin/sh
set -e
if [ -z "$1" ]; then
    echo "Usage: $0 <device>:<path>" >&2
    exit 1
fi
DEV="${1%%:*}"
KEYPATH="${1#*:}"
for i in $(seq 1 15); do
    [ -e "$DEV" ] && break
    sleep 1
done
[ -e "$DEV" ] || { echo "Device $DEV not found" >&2; exit 1; }
mkdir -p /mnt/passdev
mount -r "$DEV" /mnt/passdev
cat "/mnt/passdev/$KEYPATH"
umount /mnt/passdev
rmdir /mnt/passdev
PASSDEV_EOF
        chmod +x /lib/cryptsetup/scripts/passdev
    fi

    cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Debian"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=/dev/mapper/vg0-root rootdelay=5"
EOF
    if [[ "$BOOT_MODE" != "UEFI" ]]; then
        echo 'GRUB_PRELOAD_MODULES="usb usbms uhci ohci ehci xhci part_msdos ext2"' > /etc/default/grub.d/usb.cfg
    fi
fi
ok "crypttab configured"

# Configure cryptsetup-initramfs with restrictive permissions
msg "Configuring cryptsetup-initramfs for keyfiles"
cat > /etc/cryptsetup-initramfs/conf-hook << EOF
CRYPTSETUP=y
export CRYPTSETUP=y
KEYFILE_PATTERN="/boot/luks-lvm.keyfile"
UMASK=0077
EOF

# Create custom initramfs hook to ensure keyfile permissions
msg "Creating initramfs hook for keyfile permissions"
mkdir -p /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/keyfile-permissions << 'HOOK_EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# Ensure keyfile has restrictive permissions in initramfs
if [ -f "${DESTDIR}/boot/luks-lvm.keyfile" ]; then
    chmod 0400 "${DESTDIR}/boot/luks-lvm.keyfile"
    chown root:root "${DESTDIR}/boot/luks-lvm.keyfile"
fi

# Also check for keyfile in other locations
if [ -f "${DESTDIR}/etc/luks/luks-lvm.keyfile" ]; then
    chmod 0400 "${DESTDIR}/etc/luks/luks-lvm.keyfile"
    chown root:root "${DESTDIR}/etc/luks/luks-lvm.keyfile"
fi
HOOK_EOF
chmod +x /etc/initramfs-tools/hooks/keyfile-permissions

# Create initramfs script to mount boot partition before crypt-disk unlock
msg "Creating boot mount script for initramfs"
mkdir -p /etc/initramfs-tools/scripts/local-premount
cat > /etc/initramfs-tools/scripts/local-premount/mount_boot << 'MOUNT_EOF'
#!/bin/sh

prereqs() {
    echo "cryptroot"
}

case $1 in
    prereqs)
        exit 0
        ;;
esac

# Wait for crypt-boot to be available (password mode only)
if [ "$ENCRYPTION_MODE" = "password" ]; then
    for i in $(seq 1 10); do
        if [ -e /dev/mapper/crypt-boot ]; then
            break
        fi
        sleep 1
    done

    # Mount encrypted boot partition to access keyfile
    if [ -e /dev/mapper/crypt-boot ] && [ ! -e /boot/luks-lvm.keyfile ]; then
        mkdir -p /boot
        mount /dev/mapper/crypt-boot /boot 2>/dev/null || true

        # For UEFI, also mount EFI partition
        if [ "$BOOT_MODE" = "UEFI" ]; then
            mkdir -p /boot/efi
            # Find EFI partition by UUID
            EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null)
            if [ -n "$EFI_UUID" ]; then
                mount UUID="$EFI_UUID" /boot/efi 2>/dev/null || true
            fi
        fi
    fi
fi

# For USB mode, mount USB boot partition
if [ "$ENCRYPTION_MODE" = "usb-keyfile" ]; then
    mkdir -p /boot
    # Wait for USB device
    for i in $(seq 1 15); do
        USB_UUID=$(blkid -s UUID -o value "$USB_BOOT_PART" 2>/dev/null)
        if [ -n "$USB_UUID" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "$USB_UUID" ]; then
        mount UUID="$USB_UUID" /boot 2>/dev/null || true

        # For UEFI, also mount EFI partition
        if [ "$BOOT_MODE" = "UEFI" ]; then
            mkdir -p /boot/efi
            EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null)
            if [ -n "$EFI_UUID" ]; then
                mount UUID="$EFI_UUID" /boot/efi 2>/dev/null || true
            fi
        fi
    fi
fi
MOUNT_EOF
chmod +x /etc/initramfs-tools/scripts/local-premount/mount_boot

# Create initramfs boot script for LVM activation
msg "Creating LVM activation script"
mkdir -p /etc/initramfs-tools/scripts/init-premount
cat > /etc/initramfs-tools/scripts/init-premount/lvm_activate << 'LVM_EOF'
#!/bin/sh

prereqs() {
    echo "cryptroot"
}

case $1 in
    prereqs)
        exit 0
        ;;
esac

# Wait for crypt devices
for i in $(seq 1 10); do
    if [ -e /dev/mapper/crypt-disk ]; then
        break
    fi
    sleep 1
done

# Activate LVM (try multiple paths for lvm binary)
if command -v lvm >/dev/null 2>&1; then
    lvm vgscan --mknodes 2>/dev/null
    lvm vgchange -ay 2>/dev/null
elif [ -x /sbin/lvm ]; then
    /sbin/lvm vgscan --mknodes 2>/dev/null
    /sbin/lvm vgchange -ay 2>/dev/null
elif [ -x /bin/lvm ]; then
    /bin/lvm vgscan --mknodes 2>/dev/null
    /bin/lvm vgchange -ay 2>/dev/null
fi
LVM_EOF
chmod +x /etc/initramfs-tools/scripts/init-premount/lvm_activate

# Add kernel modules
msg "Adding kernel modules..."
for mod in dm_mod dm_crypt dm_snapshot dm_mirror dm_region_hash dm_log; do
    grep -q "^$mod$" /etc/initramfs-tools/modules 2>/dev/null || echo "$mod" >> /etc/initramfs-tools/modules
done

# For USB mode, add USB modules
if [[ "$ENCRYPTION_MODE" == "usb-keyfile" ]]; then
    for mod in xhci_hcd ehci_hcd ohci_hcd usb_storage usbhid hid_generic; do
        grep -q "^$mod$" /etc/initramfs-tools/modules 2>/dev/null || echo "$mod" >> /etc/initramfs-tools/modules
    done
fi

# Ensure lvm2 is properly configured in initramfs
msg "Ensuring LVM2 is configured in initramfs"
if [ -f /etc/initramfs-tools/conf.d/lvm2 ]; then
    echo "LVM2 already configured"
else
    cat > /etc/initramfs-tools/conf.d/lvm2 << 'LVM2_CONF'
# Enable LVM in initramfs
LVM=yes
LVM2_CONF
fi

# Update initramfs
msg "Updating initramfs..."
update-initramfs -u -k all
ok "Initramfs updated"

# Install GRUB
msg "Installing GRUB to disk"
if [[ "$ENCRYPTION_MODE" == "password" ]]; then
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable
    else
        grub-install --target=i386-pc "$TARGET_DISK"
    fi
else
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable "$USB_DEVICE"
    else
        grub-install --target=i386-pc --boot-directory=/boot --recheck "$USB_DEVICE"
    fi
fi
update-grub
ok "GRUB installed"

# Basic system configuration
msg "Configuring system basics"
echo "debian13" > /etc/hostname
echo "127.0.0.1 localhost debian13" >> /etc/hosts

# Configure locale
cat > /etc/locale.gen << 'EOF'
en_US.UTF-8 UTF-8
EOF
locale-gen
update-locale LANG=en_US.UTF-8
echo '%sudo ALL=(ALL:ALL) ALL' >> /etc/sudoers

# Enable NetworkManager
systemctl enable NetworkManager

# Set root password
echo "root:changeme" | chpasswd
warn "Root password set to 'changeme' - CHANGE IT AFTER FIRST BOOT!"

ok "Chroot configuration complete"
CHROOT_EOF

chmod +x /mnt/luks-root/setup_chroot.sh

# Pass variables explicitly to chroot
chroot /mnt/luks-root /bin/bash -c "
    export BOOT_MODE='$BOOT_MODE'
    export DE='$DE'
    export SWAP_GB='$SWAP_GB'
    export ENCRYPTION_MODE='$ENCRYPTION_MODE'
    export TARGET_DISK='$TARGET_DISK'
    export LUKS_PART='$LUKS_PART'
    export EFI_PART='${EFI_PART:-}'
    export BOOT_PART='${BOOT_PART:-}'
    export USB_BOOT_PART='${USB_BOOT_PART:-}'
    export USB_KEYFILE_PART='${USB_KEYFILE_PART:-}'
    export USB_DEVICE='${USB_DEVICE:-}'
    export INSTALL_MODE='$INSTALL_MODE'
    /bin/bash /setup_chroot.sh
"

rm -f /mnt/luks-root/setup_chroot.sh
ok "System configured"

# ---------------------------------------------------------------------------
# Create user
# ---------------------------------------------------------------------------
step "Creating user account"

if [[ "$INSTALL_MODE" == "reinstall" ]]; then
    echo -e "  ${C_DIM}(Note: You can reuse the previous username to pick up all existing configs and settings without the extra restoration work)${C_RESET}\n" >&2
fi

while true; do
    read -rp "Enter username: " new_user
    if [[ "${new_user}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        break
    else
        warn "Invalid username. Use lowercase letters, numbers, underscore, and hyphen only."
    fi
done

while true; do
    read -sp "Enter password for '${new_user}': " pass1
    echo >&2
    read -sp "Confirm password: " pass2
    echo >&2
    if [[ "${pass1}" == "${pass2}" ]]; then
        ok "Password confirmed"

        # Add username and password to desktop
        export new_user pass1
        chroot /mnt/luks-root /bin/bash -c 'adduser "${new_user}" --disabled-password --gecos "" && echo "${new_user}:${pass1}" | chpasswd && usermod -aG sudo "${new_user}"'

        ok "User '${new_user}' created with sudo privileges"
        break
    else
        err "Password does not match. Enter again."
    fi
done

# Clear variables for security
unset pass1 pass2 new_user 2>/dev/null || true

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
step "Cleaning up"
umount -R /mnt/luks-root 2>/dev/null || true
cryptsetup close crypt-boot 2>/dev/null || true
cryptsetup close crypt-disk 2>/dev/null || true
if [[ "$ENCRYPTION_MODE" == "usb-keyfile" ]]; then
    umount /mnt/usb-keyfile 2>/dev/null || true
fi
ok "Cleanup complete"

# ---------------------------------------------------------------------------
# Backup LUKS headers (only for fresh install)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    step "LUKS header backup"
    read -rp "Backup LUKS headers to $LIVE_HOME? [y/N]: " r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        backup_file="$LIVE_HOME/luks-headers-$(date +%Y%m%d_%H%M%S).tar"
        mkdir -p /tmp/luks-backup
        cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file /tmp/luks-backup/lvm-header.img
        if [[ "$ENCRYPTION_MODE" == "password" ]]; then
            cryptsetup luksHeaderBackup "$BOOT_PART" --header-backup-file /tmp/luks-backup/boot-header.img
        fi
        tar cf "$backup_file" -C /tmp/luks-backup .
        chmod 600 "$backup_file"
        chown "$TARGET_USER":"$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$backup_file" 2>/dev/null || true
        rm -rf /tmp/luks-backup
        ok "LUKS headers saved to: $backup_file"
        warn "Store this file on offline media immediately!"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo >&2
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    ok "Installation complete!"
else
    ok "Re-installation complete!"
fi

echo -e "\n${C_YELLOW}----------------------------------------------${C_RESET}" >&2
echo -e "${C_YELLOW}${C_BOLD}|  ⚠️  IMPORTANT:                             |${C_RESET}" >&2
echo -e "${C_YELLOW}|  Root password is 'changeme' - CHANGE IT!  |${C_RESET}" >&2
echo -e "${C_YELLOW}----------------------------------------------${C_RESET}" >&2

echo -e "\n═════════════════════════════════════════════════════════" >&2

# Summary banner
if [[ "$INSTALL_MODE" == "fresh" ]]; then
    step "Post-Installation Recommendations:"

    if [[ "$ENCRYPTION_MODE" == "password" ]]; then
        echo -e "\n${C_YELLOW}🔑 Remember: The password is the critical security factor so ${C_RESET}" >&2
        echo -e "${C_YELLOW}   use a strong password${C_RESET}" >&2
        echo -e "${C_RED}   Security will be fully compromised if exposed!${C_RESET}\n" >&2

        echo -e " ${C_GREEN}•${C_RESET} Backup password for LVM has been added (keyslot 1)" >&2
    else
        echo -e "\n${C_YELLOW}🔑 Remember: The USB stick is the 'keys to the castle'${C_RESET}" >&2
        echo -e "${C_YELLOW}   Protect it just like physical keys${C_RESET}" >&2
        echo -e "${C_RED}   Security will be fully compromised if discovered!${C_RESET}\n" >&2

        echo -e " ${C_GREEN}•${C_RESET} Don't be lazy, ${C_CYAN}${C_BOLD}remove USB stick${C_RESET} and store securely when not in use" >&2
        echo -e "\n ${C_GREEN}•${C_RESET} Backup the USB to secure locations" >&2
        echo -e "   ${C_DIM}(use multiple backups, not just one)${C_RESET}\n" >&2
        echo -e " ${C_GREEN}•${C_RESET} Backup password for LVM has been added (keyslot 1) for recovery" >&2
    fi
else
    step "LUKS Desktop Re-install Summary:"
    echo -e "\n ${C_GREEN}•${C_RESET} Partition structure, Home directory data, and LUKS encryption keys ${C_BLUE}preserved${C_RESET}" >&2
    echo -e " ${C_GREEN}•${C_RESET} New desktop environment installed: ${C_BLUE}$DE${C_RESET}" >&2
fi

echo -e "\n ${C_GREEN}•${C_RESET} For troubleshooting you can find the log file at: /var/log/debian-fde-setup.log${C_RESET}" >&2
echo -e "\n ${C_GREEN}•${C_RESET} After every upgrade, update the initramfs and grub before rebooting" >&2
echo -e "   ${C_DIM}(kernel updates could lock you out of your system!)${C_RESET}\n" >&2

ok "Reboot when ready"
echo >&2
