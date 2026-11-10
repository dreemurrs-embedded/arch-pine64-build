#!/bin/bash

# Copyright 2021-2024 - Dreemurrs Embedded Labs / DanctNIX Community

# This is a first time boot script, it is supposed to self destruct after the script has finished.

echo "THE FIRST BOOT SCRIPT IS NOW RUNNING, PLEASE WAIT."
echo "ONCE IT'S DONE, YOU'LL BE BOOTED TO THE OPERATING SYSTEM."

date +%Y%m%d -s "REPLACEDATE" # this is changed by the make_rootfs script

# Initialize the pacman keyring
pacman-key --init
pacman-key --populate archlinuxarm danctnix
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6

# Grow the root partition and filesystem to fill the disk. This used to be
# an initcpio run_hook, but the ALARM mkinitcpio.conf now uses the systemd
# hook, which never runs those. ext4 can be grown while mounted, so do it
# here. Only uses the kernel, sysfs and blkid: this runs before
# sysinit.target, when the udev database may still be empty.
resize_rootfs() {
    local part disk partnum

    part=$(findmnt -no SOURCE /)
    if [ "$(findmnt -no FSTYPE /)" != "ext4" ] || [ ! -e "/sys/class/block/${part##*/}/partition" ]; then
        echo "Root ($part) is not an ext4 partition, not resizing it."
        return 0
    fi

    disk=/dev/$(lsblk -no PKNAME "$part")
    partnum=$(cat "/sys/class/block/${part##*/}/partition")

    echo "Growing $part to fill $disk..."
    # Images are smaller than the card, so the backup GPT is not at the end.
    if [ "$(blkid -p -o value -s PTTYPE "$disk")" = "gpt" ]; then
        sfdisk --relocate gpt-bak-std "$disk"
    fi
    echo ", +" | sfdisk --no-reread -N "$partnum" "$disk" &&
        partx -u "$disk" &&
        resize2fs "$part"
}
resize_rootfs

# Cleanup
rm /usr/local/sbin/first_time_setup.sh
rm /usr/lib/systemd/system/first_time_setup.service
rm /usr/lib/systemd/system/sysinit.target.wants/first_time_setup.service
