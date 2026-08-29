#!/bin/bash

# Debian 13 Full Disk Encryption Autosetup Script

# v14

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BOOT_PART_SIZE="512M"
EFI_PART_SIZE="1G"
ROOT_LV_SIZE=""
SWAP_SIZE=""
LOG_FILE="/var/log/debian-fde-setup.log"

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
die()  { err "$@" && echo >&2; exit 1; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# ---------------------------------------------------------------------------
# Pre-install checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)"

TARGET_USER="${SUDO_USER:-$USER}"
LIVE_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$LIVE_HOME" ]] || die "Cannot determine home directory for user '$TARGET_USER'"

if [[ ! -f /etc/live/config.conf ]]; then
    echo >&2
    warn "Live OS not detected, even though you could be in a live environment."
    read -rp "Continue anyway? [Y/n]: " r
    [[ "$r" =~ ^[Nn]$ ]] || exit 1
fi

# Welcome banner
echo -e "\n═════════════════════════════════════════════════════════\n" >&2
echo -e "${C_CYAN}This script will setup a Debian 13 desktop with full disk encryption (FDE)${C_RESET}" >&2
echo -e "${C_CYAN}using a keyfile on a USB stick to boot.${C_RESET}\n" >&2
echo -e "The structure of the FDE system:" >&2
echo -e " ${C_GREEN}•${C_RESET} USB Stick: Contains ${C_YELLOW}/boot${C_RESET} partition (unencrypted) and LUKS keyfile" >&2
echo -e " ${C_GREEN}•${C_RESET} Main Disk: LUKS encrypted with LVM containing separate ${C_YELLOW}root${C_RESET}, ${C_YELLOW}home${C_RESET}," >&2
echo -e "   and ${C_YELLOW}swap${C_RESET} logical volumes" >&2
echo -e " ${C_GREEN}•${C_RESET} Keyfile: Stored on USB, used to unlock the LUKS container without" >&2
echo -e "   typing a password" >&2
echo -e "\n═════════════════════════════════════════════════════════\n" >&2

BOOT_MODE="BIOS"
[[ -d /sys/firmware/efi ]] && BOOT_MODE="UEFI"
msg "Detected boot mode: $BOOT_MODE"

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
step "Installing required packages"
apt-get update -qq

PACKAGES="gdisk parted cryptsetup lvm2 e2fsprogs dosfstools mtools debootstrap grub-common"
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
list_devices() {
    echo -e "\n${C_BOLD}Available block devices:${C_RESET}" >&2
    lsblk -d -p -o NAME,SIZE,MODEL,TYPE | sed 's/^/  /' >&2
    echo >&2
}

select_device() {
    local label="$1" dev=""
    while true; do
        read -rp "Enter $label device (e.g. /dev/sda): " dev
        [[ -b "$dev" ]] || { err "Invalid device: $dev"; continue; }

        echo -e "\n  ${C_BOLD}Block device selected: $dev${C_RESET}" >&2
        lsblk -o NAME,SIZE,TYPE,LABEL,FSTYPE,MOUNTPOINTS "$dev" | sed 's/^/  /' >&2
        echo >&2

        warn "This will DESTROY ALL DATA on $dev"
        read -p "Type YES to confirm: " confirm
        [[ "$confirm" == "YES" ]] && { echo >&2; echo "$dev"; return 0; }
        warn "Not confirmed. Please select again."
    done
}

step "Device selection"
list_devices
TARGET_DISK=$(select_device "target disk")
USB_DEVICE=$(select_device "USB keyfile")
[[ "$USB_DEVICE" != "$TARGET_DISK" ]] || die "Target disk and USB device cannot be the same!"

echo -e "\n  ${C_BOLD}${C_CYAN}Boot mode:${C_RESET} ${BOOT_MODE}" >&2
echo -e "  ${C_BOLD}${C_CYAN}Target Disk:${C_RESET} ${TARGET_DISK}" >&2
echo -e "  ${C_BOLD}${C_CYAN}Target USB device:${C_RESET} ${USB_DEVICE}\n" >&2

read -p "Proceed with installation? [y/N]: " r
[[ "$r" =~ ^[Yy]$ ]] || { msg "Installation cancelled."; exit 0; }

# ---------------------------------------------------------------------------
# Desktop environment selection
# ---------------------------------------------------------------------------
step "Desktop environment selection"
echo -e "Minimal set of packages will be installed to setup a working" >&2
echo -e "desktop to first login:" >&2
echo -e "  1) KDE" >&2
echo -e "  2) GNOME" >&2
echo -e "  3) MATE" >&2
echo -e "  4) XFCE" >&2
echo -e "  5) <Cancel>\n" >&2

while true; do
    read -rp "Select [1-5]: " n
    case "$n" in
        1) DE="KDE"; break ;;
        2) DE="GNOME"; break ;;
        3) DE="MATE"; break ;;
        4) DE="XFCE"; break ;;
        5) die "No desktop environment selected. Exiting.";;
        *) err "Invalid selection. Choose 1-5." ;;
    esac
done
ok "Selected: $DE"
export DE

# ---------------------------------------------------------------------------
# Swap size selection
# ---------------------------------------------------------------------------
select_swap_size() {
step "Swap Logical Volume size selection"
    echo -e "  ${C_BOLD}With LVM, swap will be a separate logical volume${C_RESET}" >&2
    echo -e "  ${C_DIM}(provides better performance and easier resizing)${C_RESET}\n" >&2

    echo -e "  Recommended sizes:" >&2
    echo -e "  • 2GB  :  Minimum (for 2-4GB RAM)" >&2
    echo -e "  • 4GB  :  Average (for 4-8GB RAM)" >&2
    echo -e "  • 8GB  :  Large (for 8-16GB RAM)" >&2
    echo -e "  • 16GB+:  For systems with 16GB+ RAM or heavy workloads" >&2
    echo -e "  • 0    :  <Skip swap creation>\n" >&2

while true; do
        read -rp "Enter swap size in GB (recommended 4-8GB): " swap_size
        if [[ "$swap_size" =~ ^[0-9]+$ ]]; then
            if [[ "$swap_size" -eq 0 ]]; then
                SWAP_SIZE="0"
                ok "Swap creation skipped"
                return 0
            elif [[ "$swap_size" -ge 1 ]] && [[ "$swap_size" -le 64 ]]; then
                SWAP_SIZE="${swap_size}G"
                ok "Swap size selected: ${SWAP_SIZE}"
                export SWAP_SIZE
                return 0
            elif [[ "$swap_size" -gt 64 ]]; then
                err "Swap is too large. Beyond 64GB adds no benefit to system performance. Choose a smaller size or 0 to skip."
            else
                err "Size must be a positive integer or 0 to skip."
            fi
        else
            err "Please enter a valid integer (e.g., 4)"
        fi
    done
}

select_swap_size

# ---------------------------------------------------------------------------
# Root partition size selection
# ---------------------------------------------------------------------------
root_size() {
    local dev="$1"
    step "Root partition size"

    echo -e "  ${C_BOLD}The root volume will contain system files and applications${C_RESET}" >&2
    echo -e "  ${C_DIM}(home and swap will be on separate LVs)${C_RESET}\n" >&2

    while true; do
        read -rp "Enter the root partition size in GB (recommended 50GB): " rs
        if [[ ! "$rs" =~ ^[0-9]+$ ]]; then
            err "Enter positive integers only."
        elif [[ "$rs" -lt "5" ]]; then
            err "Size selected is too small. Modern Linux desktops require at least 5GB."
        elif [[ "$rs" -gt "100" ]]; then
            warn "Root size of ${rs}GB may be excessive. 50GB+ is plenty for most use cases."
            read -p "Continue with ${rs}GB? [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || continue
        fi

        ok "\nRoot size selected on $dev: ${rs}GB"
        ROOT_LV_SIZE="${rs}G"
        export ROOT_LV_SIZE
        break
    done
}

# ---------------------------------------------------------------------------
# Partition creation
# ---------------------------------------------------------------------------
part_suffix() {
    [[ "$1" == *"nvme"* ]] && echo "p" || echo ""
}

create_partitions() {
    local dev="$1" is_usb="$2" name="$3"
    step "Creating partitions on $name ($dev)"

    # Check if device exists
    [[ -b "$dev" ]] || die "Device $dev does not exist"

    # Unmount any mounted partitions
    umount "${dev}"* 2>/dev/null || true

    # Zap all existing partitions and wipe signatures
    sgdisk --zap-all "$dev" >/dev/null 2>&1 || {
        err "Failed to zap partitions on $dev"
        return 1
    }
    wipefs -a "$dev" >/dev/null 2>&1 || true
    sleep 1

    local sfx="$(part_suffix "$dev")"

    if [[ "$is_usb" == "true" ]]; then
        # USB: Create BOOT partition and KEYFILE partition
        msg "Creating USB partitions..."
        sgdisk -n 1:0:+${BOOT_PART_SIZE} -t 1:8300 -c 1:"BOOT" "$dev" || {
            err "Failed to create BOOT partition on USB"
            return 1
        }
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"KEYFILE" "$dev" || {
            err "Failed to create KEYFILE partition on USB"
            return 1
        }
        sub "BOOT (${BOOT_PART_SIZE}) + KEYFILE (remaining space)"
    else
        # Target disk: Create EFI/BIOS and LUKS partitions
        msg "Creating target disk partitions..."
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:EF00 -c 1:"EFI" "$dev" || {
                err "Failed to create EFI partition"
                return 1
            }
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"DISK" "$dev" || {
                err "Failed to create LUKS partition"
                return 1
            }
            sub "EFI (${EFI_PART_SIZE}) + LUKS (remaining space)"
        else
            sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS" "$dev" || {
                err "Failed to create BIOS boot partition"
                return 1
            }
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"DISK" "$dev" || {
                err "Failed to create LUKS partition"
                return 1
            }
            sub "BIOS boot (1M) + LUKS (remaining space)"
        fi
    fi

    # Force kernel to reread partition table
    msg "Waiting for kernel to detect partitions..."
    partprobe "$dev" 2>/dev/null || true
    sleep 3

    # Verify partitions were created
    if [[ "$is_usb" == "true" ]]; then
        if [[ ! -b "${dev}${sfx}1" ]]; then
            err "BOOT partition not detected: ${dev}${sfx}1"
            lsblk "$dev" >&2
            return 1
        fi
        if [[ ! -b "${dev}${sfx}2" ]]; then
            err "KEYFILE partition not detected: ${dev}${sfx}2"
            lsblk "$dev" >&2
            return 1
        fi
        ok "USB partitions created: ${dev}${sfx}1, ${dev}${sfx}2"
    else
        if [[ ! -b "${dev}${sfx}1" ]]; then
            err "First partition not detected: ${dev}${sfx}1"
            lsblk "$dev" >&2
            return 1
        fi
        ok "Target disk partitions created: ${dev}${sfx}1, ${dev}${sfx}2"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Partition formatting
# ---------------------------------------------------------------------------
format_partitions() {
    local sfx_usb="$(part_suffix "$USB_DEVICE")"
    local sfx_tgt="$(part_suffix "$TARGET_DISK")"

    USB_BOOT_PART="${USB_DEVICE}${sfx_usb}1"
    USB_KEYFILE_PART="${USB_DEVICE}${sfx_usb}2"
    TARGET_EFI_PART="${TARGET_DISK}${sfx_tgt}1"
    TARGET_LUKS_PART="${TARGET_DISK}${sfx_tgt}2"

    step "Formatting partitions"

    # Check if partitions exist before formatting
    [[ -b "$USB_BOOT_PART" ]] || die "USB BOOT partition not found: $USB_BOOT_PART"
    [[ -b "$USB_KEYFILE_PART" ]] || die "USB KEYFILE partition not found: $USB_KEYFILE_PART"
    [[ -b "$TARGET_LUKS_PART" ]] || die "LUKS partition not found: $TARGET_LUKS_PART"

    mkfs.ext4 -F -L BOOT "$USB_BOOT_PART" >/dev/null
    sub "USB boot: $USB_BOOT_PART"

    mkfs.ext4 -F -L KEYFILE "$USB_KEYFILE_PART" >/dev/null
    sub "USB keyfile: $USB_KEYFILE_PART"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        [[ -b "$TARGET_EFI_PART" ]] || die "EFI partition not found: $TARGET_EFI_PART"
        mkfs.fat -F 32 -n EFI "$TARGET_EFI_PART" >/dev/null
        sub "EFI: $TARGET_EFI_PART"
    fi
    sub "LUKS partition prepared: $TARGET_LUKS_PART"

    export USB_BOOT_PART USB_KEYFILE_PART TARGET_EFI_PART TARGET_LUKS_PART
    ok "All partitions formatted"
}

# ---------------------------------------------------------------------------
# Encryption setup
# ---------------------------------------------------------------------------
generate_keyfile() {
    step "Generating keyfile"
    mkdir -p /mnt/usb-keyfile
    mount "$USB_KEYFILE_PART" /mnt/usb-keyfile

    dd if=/dev/urandom of=/mnt/usb-keyfile/luks-boot.keyfile bs=4096 count=1 status=none
    chmod 0400 /mnt/usb-keyfile/luks-boot.keyfile
    sync
    ok "Keyfile created on USB"
}

setup_luks() {
    step "Setting up LUKS encryption"

    cryptsetup luksFormat --verbose --type luks2 \
        --key-file /mnt/usb-keyfile/luks-boot.keyfile \
        --key-slot 0 "$TARGET_LUKS_PART"
    ok "LUKS container formatted (keyfile on slot 0)"

    cryptsetup luksAddKey --verbose \
        --key-file /mnt/usb-keyfile/luks-boot.keyfile \
        --key-slot 1 "$TARGET_LUKS_PART"
    ok "Backup passphrase added (password on slot 1)"

    cryptsetup open --key-file /mnt/usb-keyfile/luks-boot.keyfile \
        "$TARGET_LUKS_PART" crypt-disk
    ok "LUKS container opened as /dev/mapper/crypt-disk"
}

# ---------------------------------------------------------------------------
# LVM setup with swap support
# ---------------------------------------------------------------------------
setup_lvm() {
    step "Setting up LVM"

    # Create physical volume
    pvcreate /dev/mapper/crypt-disk >/dev/null
    sub "Physical volume created"

    # Create volume group
    vgcreate vg0 /dev/mapper/crypt-disk >/dev/null
    sub "Volume group 'vg0' created"

    # Create root logical volume
    lvcreate -L "$ROOT_LV_SIZE" -n root vg0 >/dev/null
    sub "Root LV ($ROOT_LV_SIZE)"

    # Create swap logical volume if enabled
    if [[ "$SWAP_SIZE" != "0" ]]; then
        lvcreate -L "$SWAP_SIZE" -n swap vg0 >/dev/null
        sub "Swap LV ($SWAP_SIZE)"
    fi

    # Create home logical volume using remaining space
    lvcreate -l 100%FREE -n home vg0 >/dev/null
    sub "Home LV (remaining space)"

    # Format filesystems
    mkfs.ext4 -F -L ROOT /dev/mapper/vg0-root >/dev/null
    mkfs.ext4 -F -L HOME /dev/mapper/vg0-home >/dev/null

    # Setup swap if enabled
    if [[ "$SWAP_SIZE" != "0" ]]; then
        mkswap -L SWAP /dev/mapper/vg0-swap >/dev/null
        sub "Swap LV formatted"
    fi

    ok "LVM setup complete"
}

# ---------------------------------------------------------------------------
# Mount filesystems
# ---------------------------------------------------------------------------
mount_filesystems() {
    step "Mounting filesystems"

    mkdir -p /mnt/luks-root
    mount /dev/mapper/vg0-root /mnt/luks-root

    mkdir -p /mnt/luks-root/{boot,home}
    mount /dev/mapper/vg0-home /mnt/luks-root/home
    mount "$USB_BOOT_PART" /mnt/luks-root/boot

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkdir -p /mnt/luks-root/boot/efi
        mount "$TARGET_EFI_PART" /mnt/luks-root/boot/efi
    fi

    ok "Filesystems mounted"
}

# ---------------------------------------------------------------------------
# Install base system
# ---------------------------------------------------------------------------
install_base_system() {
    step "Installing Debian 13 (Trixie) base system"
    msg "This will take several minutes..."
    debootstrap --arch=amd64 --variant=minbase trixie /mnt/luks-root http://deb.debian.org/debian
    ok "Base system installed"
}

# ---------------------------------------------------------------------------
# Chroot configuration
# ---------------------------------------------------------------------------
configure_system() {
    step "Configuring system"

    # Prepare chroot environment
    mkdir -p /mnt/luks-root/dev/pts
    mount --bind /dev     /mnt/luks-root/dev
    mount --bind /dev/pts /mnt/luks-root/dev/pts
    mount --bind /proc    /mnt/luks-root/proc
    mount --bind /sys     /mnt/luks-root/sys
    cp /etc/resolv.conf   /mnt/luks-root/etc/resolv.conf
    ok "Chroot environment prepared"

    # Export variables for chroot script
    export BOOT_MODE TARGET_DISK USB_BOOT_PART TARGET_EFI_PART TARGET_LUKS_PART SWAP_SIZE DE

    cat > /mnt/luks-root/setup_chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

# ---------------------------------------------------------------------
# Sources list
# ---------------------------------------------------------------------
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ trixie main non-free-firmware non-free contrib
deb-src http://deb.debian.org/debian/ trixie main non-free-firmware non-free contrib
deb http://security.debian.org/debian-security trixie-security main non-free-firmware non-free contrib
deb-src http://security.debian.org/debian-security trixie-security main non-free-firmware non-free contrib
deb http://deb.debian.org/debian/ trixie-updates main non-free-firmware contrib
deb-src http://deb.debian.org/debian/ trixie-updates main non-free-firmware contrib
EOF

# ---------------------------------------------------------------------
# Update and install base packages
# ---------------------------------------------------------------------
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -q linux-image-amd64 systemd-sysv

# ---------------------------------------------------------------------
# Desktop environment setup
# ---------------------------------------------------------------------
setup_kde() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        kde-plasma-desktop plasma-nm sddm sddm-theme-breeze \
        kwin-addons dolphin konsole
}

setup_gnome() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        gnome-core gdm3 network-manager-gnome gedit
}

setup_mate() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        mate-desktop-environment-core lightdm mate-media \
        pulseaudio pulseaudio-utils alsa-utils network-manager-gnome \
        mate-power-manager upower acpid
}

setup_xfce() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        xfce4 xfce4-goodies lightdm network-manager-gnome
}

case "$DE" in
    KDE)   setup_kde ;;
    GNOME) setup_gnome ;;
    MATE)  setup_mate ;;
    XFCE)  setup_xfce ;;
esac

# ---------------------------------------------------------------------
# Install desktop packages
# ---------------------------------------------------------------------
# Customize your installed applications here
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    sudo gnupg firmware-amd-graphics firmware-iwlwifi firmware-realtek \
    firmware-misc-nonfree intel-microcode locales wget nano exfat-fuse \
    ntfs-3g ufw curl htop ssh screen rsync xz-utils zip unzip file \
    manpages man-db lsof

# Encryption packages (required)
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    cryptsetup cryptsetup-initramfs lvm2 e2fsprogs mtools dosfstools grub-common

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q grub-efi-amd64
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q grub-pc
fi

# ---------------------------------------------------------------------
# Preload USB modules for boot
# ---------------------------------------------------------------------
for mod in xhci_hcd ehci_hcd ohci_hcd usb_storage; do
    echo "$mod" >> /etc/initramfs-tools/modules
done

# ---------------------------------------------------------------------
# Configure fstab
# ---------------------------------------------------------------------
cat > /etc/fstab << EOF
/dev/mapper/vg0-root    /        ext4    defaults    0 1
/dev/mapper/vg0-home    /home    ext4    defaults    0 2
UUID=$(blkid -s UUID -o value "$USB_BOOT_PART")  /boot  ext4  defaults  0 2
EOF

if [[ "$SWAP_SIZE" != "0" ]]; then
    echo "/dev/mapper/vg0-swap none swap sw 0 0" >> /etc/fstab
fi

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    echo "UUID=$(blkid -s UUID -o value "$TARGET_EFI_PART")  /boot/efi  vfat  defaults  0 1" >> /etc/fstab
fi

# ---------------------------------------------------------------------
# Configure crypttab
# ---------------------------------------------------------------------
LUKS_UUID=$(blkid -s UUID -o value "$TARGET_LUKS_PART")
cat > /etc/crypttab << EOF
crypt-disk UUID=${LUKS_UUID} /dev/disk/by-label/KEYFILE:/luks-boot.keyfile luks,keyscript=/lib/cryptsetup/scripts/passdev
EOF

# ---------------------------------------------------------------------
# Configure GRUB
# ---------------------------------------------------------------------
if [[ "$BOOT_MODE" != "UEFI" ]]; then
    echo 'GRUB_PRELOAD_MODULES="usb usbms uhci ohci ehci xhci"' >> /etc/default/grub
fi

# Optimize GRUB for faster boot
echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub

# ---------------------------------------------------------------------
# Update initramfs
# ---------------------------------------------------------------------
update-initramfs -u -k all

# ---------------------------------------------------------------------
# Install GRUB
# ---------------------------------------------------------------------
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable
else
    grub-install --target=i386-pc --boot-directory=/boot "$TARGET_DISK"
fi

update-grub

# ---------------------------------------------------------------------
# Configure locale
# ---------------------------------------------------------------------
# Modify to user preference here
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------------
# Configure sudo
# ---------------------------------------------------------------------
echo '%sudo ALL=(ALL:ALL) ALL' >> /etc/sudoers

# ---------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------
systemctl enable NetworkManager

if [[ "$DE" == "KDE" ]]; then
    systemctl enable sddm
elif [[ "$DE" == "GNOME" ]]; then
    systemctl enable gdm3
else
    systemctl enable lightdm
fi

# ---------------------------------------------------------------------
# Configure timezone
# ---------------------------------------------------------------------
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# ---------------------------------------------------------------------
# Configure swap for optimal performance
# ---------------------------------------------------------------------
if [[ "$SWAP_SIZE" != "0" ]]; then
    # Enable swap
    swapon /dev/mapper/vg0-swap

    # Optimize swap settings for desktop use
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf

    # Make swap more efficient for SSDs
    echo "vm.page-cluster=0" >> /etc/sysctl.conf

    echo "Swap configured with optimal settings"
fi

# ---------------------------------------------------------------------
# Create helper scripts for the user
# ---------------------------------------------------------------------

# Script to resize swap (if needed)
cat > /usr/local/bin/resize-swap.sh << 'RESIZE_EOF'
#!/bin/bash
# Helper script to resize swap logical volume

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must be run as root"; exit 1; }

# Check if swap LV exists
if ! lvs vg0/swap >/dev/null 2>&1; then
    echo "No swap LV found. Creating new swap LV..."

    while true; do
        read -p "Enter swap size in GB: " size
        [[ "$size" =~ ^[0-9]+$ ]] && break
        echo "Please enter a valid number"
    done

    lvcreate -L "${size}G" -n swap vg0
    mkswap /dev/mapper/vg0-swap
    echo "/dev/mapper/vg0-swap none swap sw 0 0" >> /etc/fstab
    swapon /dev/mapper/vg0-swap
    echo "Swap created and enabled"
    exit 0
fi

# Get current size
CURRENT_SIZE=$(lvs vg0/swap --noheadings -o lv_size | awk '{print $1}')
echo "Current swap size: $CURRENT_SIZE"

# Show swap usage
echo -e "\nCurrent swap usage:"
swapon --show

echo -e "\nOptions:"
echo "1) Increase swap size"
echo "2) Decrease swap size"
echo "3) <Cancel>"
read -p "Select option [1-3]: " option

case $option in
    1|2)
        read -p "Enter new size in GB: " new_size
        [[ "$new_size" =~ ^[0-9]+$ ]] || { echo "Invalid size"; exit 1; }

        echo "Turning off swap..."
        swapoff /dev/mapper/vg0-swap

        if [[ $option -eq 1 ]]; then
            echo "Extending swap LV to ${new_size}G..."
            lvextend -L "${new_size}G" vg0/swap
        else
            echo "Reducing swap LV to ${new_size}G..."
            # Need to reduce filesystem first for swap
            # Swap doesn't have a filesystem, can reduce directly
            # But we need to ensure we don't reduce below used space
            lvreduce -L "${new_size}G" vg0/swap
        fi

        echo "Recreating swap..."
        mkswap /dev/mapper/vg0-swap
        swapon /dev/mapper/vg0-swap

        echo "Swap resized to ${new_size}G"
        ;;
    3)
        echo "Cancelled"
        exit 0
        ;;
    *)
        echo "Invalid option"
        exit 1
        ;;
esac

echo -e "\nNew swap status:"
swapon --show
RESIZE_EOF

chmod +x /usr/local/bin/resize-swap.sh

echo "Swap helper script created: /usr/local/bin/resize-swap.sh"
CHROOT_EOF

    # Make the chroot script executable and run it
    chmod +x /mnt/luks-root/setup_chroot.sh
    chroot /mnt/luks-root /bin/bash /setup_chroot.sh
    rm -f /mnt/luks-root/setup_chroot.sh

    ok "System configuration complete"
}

# ---------------------------------------------------------------------------
# User creation
# ---------------------------------------------------------------------------
create_user() {
    step "Creating user account"
    while true; do
        read -rp "Username: " new_user
        [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
            warn "Invalid username format. Use lowercase letters, numbers, underscore, and hyphen only."
            continue
        }

        read -rp "Confirm username: " confirm
        [[ "$confirm" == "$new_user" ]] || {
            warn "Usernames don't match. Try again."
            continue
        }

        echo -e "\n  Creating user ${C_BOLD}'$new_user'${C_RESET} with sudo privileges..." >&2
        chroot /mnt/luks-root /bin/bash -c "adduser --gecos '' '$new_user' && usermod -aG sudo '$new_user'"
        ok "User '$new_user' created with sudo privileges"
        echo
        break
    done
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    step "Cleaning up"

    # Unmount filesystems
    umount -R /mnt/luks-root 2>/dev/null || true
    umount -R /mnt/usb-keyfile 2>/dev/null || true

    # Deactivate volume group
    vgchange -a n vg0 2>/dev/null || true

    # Close LUKS container
    cryptsetup close crypt-disk 2>/dev/null || true

    ok "Cleanup complete"
}

# Set up trap handlers
trap 'echo >&2; err "Interrupted."; cleanup; exit 130' INT TERM
trap 'echo >&2; err "Script failed at line $LINENO."; cleanup; exit 1' ERR

# ---------------------------------------------------------------------------
# Main installation routine
# ---------------------------------------------------------------------------
main() {
    echo
    msg "Starting FDE setup with LVM swap..."

    # Create partitions
    create_partitions "$USB_DEVICE" "true" "USB" || die "Failed to create USB partitions"
    create_partitions "$TARGET_DISK" "false" "target disk" || die "Failed to create target disk partitions"

    # Format partitions
    format_partitions

    # Setup encryption
    generate_keyfile
    setup_luks

    # Select and setup LVM
    root_size "$TARGET_DISK"
    setup_lvm

    # Mount and install
    mount_filesystems
    install_base_system
    configure_system
    create_user
    cleanup

    # ---------------------------------------------------------------------------
    # LUKS header backup
    # ---------------------------------------------------------------------------
    step "LUKS header backup"
    read -rp "Backup LUKS header to $LIVE_HOME? [y/N]: " r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        local backup="$LIVE_HOME/luks_header_$(date +%Y%m%d_%H%M%S).img"
        cryptsetup luksHeaderBackup "$TARGET_LUKS_PART" --header-backup-file "$backup"
        chmod 600 "$backup"
        chown "$TARGET_USER":"$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$backup" 2>/dev/null || true
        ok "Header saved: $backup"
        warn "Store this file on offline media immediately!"
    fi

    # ---------------------------------------------------------------------------
    # Installation complete
    # ---------------------------------------------------------------------------
    echo
    ok "Full Disk Encryption installation completed!"

    # Summary banner
    step "Post-Installation Recommendations:"
    echo -e " ${C_GREEN}•${C_RESET} Don't be lazy, ${C_RED}remove USB${C_RESET} and store securely when not in use" >&2
    echo -e "   ${C_DIM}(critial for security)${C_RESET}"
    echo -e " ${C_GREEN}•${C_RESET} Backup the USB to secure locations" >&2
    echo -e "   ${C_DIM}(use multiple backups, not just one)${C_RESET}" >&2
    echo -e " ${C_GREEN}•${C_RESET} Store the backup LUKS header securely OFFLINE" >&2
    echo -e "   ${C_DIM}(LUKS header will be required for disaster recovery)${C_RESET}" >&2
    echo -e " ${C_GREEN}•${C_RESET} Swap has been configured as a separate LVM logical volume" >&2
    echo -e "   ${C_DIM}(can resize with this script: /usr/local/bin/resize-swap.sh)${C_RESET}" >&2
    echo -e " ${C_GREEN}•${C_RESET} After every upgrade, update the initramfs and grub before rebooting" >&2
    echo -e "   ${C_DIM}(kernel updates could lock you out of your system!)${C_RESET}\n" >&2

    ok "Reboot when ready"
    echo >&2
}

# ---------------------------------------------------------------------------
# Run main
# ---------------------------------------------------------------------------
main
