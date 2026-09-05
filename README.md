# LUKS Full Disk Encryption Debian 13 Auto-setup Script
version 2.31


# PURPOSE
This bash script auto-sets up and installs a LUKS Full Disk Encryption system together with a Debian 13 desktop to your disk with minimal intervention. You only have to choose the security mode, root and swap partition size, desktop environment, and username to get a completely working system from scratch.

Designed for the average user with some Linux experience who doesn't want the hassle of manually creating a secure LUKS FDE system in the terminal.


# RATIONALE
Standard LUKS FDE on typical linux distributions take the approach of encrypting the OS partitions (root, swap and home) but not the boot partition. For some users this might not be secure enough. But there is a problem. What is the best way to protect a system without making everyday use too inconvenient?

Securing a system always comes with trade-offs. Encrypting everything on a disk (including the bootloader) comes at the cost of useability and speed. Whereas, using a password-less encrypted boot is vulnerable to physical risks such as loss or theft.

This script aims to provide the user with a choice between the two most effective models for secure everyday use, depending on their threat scenario.


# SECURITY MODES
The structure of the FDE system can be built according to two modes: 'Single Password' mode and 'USB keyfile' mode.

Single Password:
- Main Disk: Boot partition LUKS encrypted, with a password used to unlock the embedded keyfile for the LVM volume.
- Main Disk: LUKS encrypted LVM volume containing root, swap and home.

USB keyfile:
- USB Stick: Boot partition with embedded keyfile (both unencrypted) used to unlock main disk
- Main Disk: LUKS encrypted LVM volume containing separate root, swap and home
- Keyfile: Stored on USB, used to unlock main disk without typing a password

Carefully assess which security setup works best for you. They both have their pros and cons. If typing a secure password on every boot is bothersome to you, the 'USB keyfile' mode is recommended. If physical security is a major threat, the 'Single Password' mode would be a better choice.

Using both Secure Boot and TPM in the boot chain will give you the strongest security but will also create more complexity eg. every system update will require resetting signatures and keys. Which is why this method was excluded from this build. In fact, for users wanting the ultimate secure system the only way is to NOT have ANY sensitive data in their physical possession at all. How can you compromise something that doesn't exist?

And remember that FDE only works when the device is at rest so there is **no protection** while the device is powered on and running. Read this wiki for a deeper analysis of various FDE models:

https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#Overview


# KEY FEATURES
'Single Password' mode:
- Password only required **once** at boot
- A keyfile protects the LVM volumes (no 2nd password)
- Entire disk is essentially encrypted, making tampering very difficult

'USB keyfile' mode:
- System **CANNOT** boot without the USB stick
- There is **no password typing on startup**, enabling a fast boot time
- Boot directory is physically seperated from the main disk

Both modes include:
- Separate /root, /swap and /home LVM volumes for simpler upgrades
- Choice of auto-installed minimal desktop environments
- Support for both UEFI and legacy BIOS systems


# CUSTOMIZATION
A very lean set of packages are installed to get your desktop up and running on first boot. No uneccessary fluff. Or if you prefer you can preseed your own custom packages. Feel free to modify the script, and add or delete packages as you wish. These desktop environments are available during the build process:
- KDE Plasma
- Gnome
- Mate
- XFCE

Note: LUKS default encryption parameters are completely fine for most users. Even though LUKS2 is marginally stronger than LUKS1, GRUB requires a LUKS1 encrypted partition to work successfully in 'Single Password' mode. In practice the differences between the two are not that significant - encryption parameters only matter when the password is weak! 

Aim to generate a password with at least 80 bits of entropy.


# SYSTEM REQUIREMENTS
Script can only be built from Debian-based linux desktop environments. Other linux derivatives such as Arch, Fedora or Slackware are not supported.
- Only x64 systems are supported (no legacy x32 architecture).
- ATA/SSD disk: An SSD is strongly recommended to counter the runtime encryption overhead
- One USB for the keyfile (at least 1GB)
- One USB for the bootable live USB OS

Installing will destroy ALL the existing data on the disk so remember to backup any important data before starting!



# INSTALLATION
1. First flash your favorite bootable live USB OS to the USB stick (e.g. Linux Mint)
2. Boot into live environment and download the script.
3. Make executable, run the script and follow the prompts:

     **chmod +x debian13-fde-auto-setup-v2x.sh**
   
     **sudo ./debian13-fde-auto-setup-v2x.sh**

4. Reboot once set up completes.


# DEFAULT SETTINGS
- Locale: en_US
- Username/Password: (set by user)
- Root password: changeme

**CRITICAL: Change the root password on first boot!**


# BOOT PROCESS
How the process works at boot time for 'Single Password' mode:
1. Device prompts for password → unlocks LUKS1 boot partition
2. GRUB loads kernel & initramfs (which contains embedded keyfile)
3. Kernel boots → initramfs starts
4. initramfs automatically unlocks LUKS2 crypt-disk partition using embedded keyfile
5. LVM volumes activate, mount, & system loads to desktop

And for 'USB keyfile' mode:
1. GRUB loads from USB stick
2. Kernel boots → initramfs starts
3. initramfs waits for USB device via passdev script
4. Reads keyfile from USB → unlocks LUKS2 crypt-disk automatically
5. LVM volumes activate, mount, & system loads to desktop



# Recommendations:
- The password is the critical security factor **so use a strong password**:
https://www.strongdm.com/blog/nist-password-guidelines
- Keyfile Backup: Store multiple backups of the USB keyfile in secure locations. One USB backup is **not enough**.
- Header Backup: Store securely OFFLINE with restricted permissions (for emergency recovery)
- USB Protection: **The USB keyfile stick is a critical component - protect it physically like real keys. Don't get lazy and leave the USB in the device when not in use!**
- Optional: To speed up boot time optimize initramfs size by loading only the modules for your hardware (sudo sed -i 's/MODULES=most/MODULES=dep' /etc/initramfs-tools/initramfs.conf && sudo update-initramfs -u -k all)
- Optional: Consider using AIDE (Advanced Intrusion Detection Environment) to monitor EFI/BIOS boot files integrity
- For troubleshooting you can find the log file at: /var/log/debian-fde-setup.log
- System upgrade: After every kernel change you should update the initramfs and grub before rebooting, otherwise your system could lock you out.


# DISCLAIMER
Please review the LUKS FDE Auto-setup bash script carefully. NEVER run a script blindly without understanding what it could do. Don't trust me. Google around to find out more. Please research, research, research.


# LEGAL
Please note that by downloading and running this bash script you acknowledge that I am not responsible or liable for any damages or losses arising from your use or inability to use the script and or software used under this script. You are solely responsible for your use of this script. If you harm someone or get into a dispute with a 3rd party, you consent to me waiving any involvement.
