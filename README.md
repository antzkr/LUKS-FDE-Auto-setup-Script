# LUKS-FDE-Auto-setup-Script
Bash script to auto-setup a Debian 13 full disk encryption (FDE) desktop, with a keyfile on a USB stick. 

v12

# RATIONALE
High security (ie. encrypting everything, including the bootloader) comes at the cost of useability. This script aims to provide the best balance between security and convienience. The structure of the FDE system:
- USB Stick: Contains /boot partition (unencrypted) and LUKS keyfile
- Main Disk: LUKS encrypted with LVM containing separate root and home logical volumes
- Keyfile: Stored on USB, used to unlock the LUKS container without typing a password

# KEY FEATURES
- Once encrypted, system CANNOT boot without the USB stick
- There is no password typing at startup, enabling a fast boot time)
- Boot directory is physically seperated from the main disk so can't be tampered with (Evil Maid attack protection)
- Separate encrypted /root and /home LVM partitions allows for independent management to make upgrading much simpler.
- Choice of desktop environments

# SYSTEM REQUIREMENTS
Script can only be run from debian-based Linux flavors.
- Only x64 systems are supported (no x32).
- ATA/SSD disk: SSD is strongly recommended to counter the runtime encryption overhead
- One USB for the keyfile (at least 1GB)
- One USB for the bootable live USB OS (e.g. Debian 13 live)
- Remember to backup important data. All data on disk will be irreversibly deleted!

# INSTALLATION

1. First flash your favorite bootable live USB OS to the USB stick (e.g. Balena Etcher works well for this). Then boot into the live environment.
2. Boot into live environment and download script.
3. Make executable and run:


# LEGAL
