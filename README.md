# LUKS Full Disk Encryption Debian 13 Auto-setup Script
version 12

# PURPOSE
This bash script auto-sets up and installs a LUKS Full Disk Encryption system together with a Debian 13 desktop to your device disk with minimal intervention. You only have to choose the target disk and USB, root partition size, desktop environment, and username to get a completely working system.

Designed for the average user with some Linux experience who doesn't want the hassle of typing complex commands in the terminal.

# RATIONALE
High security (ie. encrypting everything, including the bootloader) comes at the cost of useability (and speed). This script aims to provide the best balance between security and convienience. The structure of the FDE system is as follows:
- USB Stick: Contains /boot partition (unencrypted) and LUKS keyfile
- Main Disk: LUKS encrypted with LVM containing separate root and home logical volumes
- Keyfile: Stored on USB, used to unlock the LUKS container without typing a password

Carefully assess whether the security of this setup works for you. FDE only works when the device is at rest: there is no protection while the device is powered on and running.

https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#Overview

# KEY FEATURES
- Once encrypted, the system **CANNOT** boot without the USB stick
- There is **no password typing on startup**, enabling a fast boot time
- To mitigate against tampering, boot directory is physically seperated from the main disk (Evil Maid attack protection)
- Separate /root and /home LVM partitions make upgrading much simpler.
- Choice of auto-installed desktop environments.
- UEFI and legacy BIOS are both supported.

# CUSTOMIZATION
A minimal set of packages are installed to get you up and running on first boot. If you want a very lean and basic install, feel free to modify the script, and add or delete packages as you wish. These desktop environments available during the build process:
- KDE Plasma
- Gnome
- Mate
- XFCE

Consider adding a swapfile on first login, since a swap partition adds increasing complexity for no significant advantage. Plus the size of a swapfile can be easily increased without restructuring the LVM layout. Strongly suggested for systems with less than 16GB available RAM.

# SYSTEM REQUIREMENTS
Script can only be built from Debian-based linux desktop environments. Other linux derivatives such as Arch, Fedora or Slackware are not supported.
- Only x64 systems are supported (no legacy x32).
- ATA/SSD disk: An SSD is strongly recommended to counter the runtime encryption overhead
- One USB for the keyfile (at least 1GB)
- One USB for the bootable live USB OS (e.g. Debian 13 live)

Installing FDE will destroy the existing data on the disk so remember to backup any important data before starting!


# INSTALLATION
1. First flash your favorite bootable live USB OS to the USB stick (e.g. Linux Mint)
2. Boot into live environment and download the script.
3. Make executable, run the script and follow the prompts:

     **chmod +x debian13-fde-auto-setup-v1x.sh**
   
     **sudo ./debian13-fde-auto-setup-v1x.sh**

5. Reboot once set up completes.

# BOOT PROCESS
How the process works at boot time:
1.	GRUB loads from USB /boot partition
2.	Initramfs starts
3.	The passdev keyscript reads the crypttab entry
4.	It identifies the USB device by label/UUID
5.	Mounts the keyfile partition temporarily
6.	Reads the keyfile from USB
7.	Unlocks the LUKS container
8.	Unmounts the keyfile partition
9.	Continues booting with decrypted root

# General recommendations:
- Keyfile Backup: Store multiple backups of the USB keyfile in secure locations. One USB backup is **not enough**.
- Header Backup: Store securely **OFFLINE** with restricted permissions
- USB Protection: **The USB keyfile stick is now a critical component - protect it physically like real keys. Don't get lazy and leave the USB in the device when not in use!**
- Optional: Consider enabling TRIM for improved SSD performance.
- System upgrade: After every kernel change you should update the initramfs and grub before rebooting, otherwise your system could lock you out.

# DISCLAIMER
Please review the LUKS FDE Auto-setup bash script carefully. NEVER run a script blindly without understanding what it could do. Don't trust me. Google around to find out more. Please research, research, research.

# LEGAL
Please note that by downloading and running this bash script you acknowledge that I am not responsible or liable for any damages or losses arising from your use or inability to use the script and or software used under this script. You are solely responsible for your use of this script. If you harm someone or get into a dispute with a 3rd party, you consent to me waiving any involvement.
