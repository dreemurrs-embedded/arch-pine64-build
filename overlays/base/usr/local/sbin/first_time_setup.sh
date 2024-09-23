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

if [ -e "/usr/lib/initcpio/hooks/resizerootfs" ]; then
    rm /usr/lib/initcpio/hooks/resizerootfs
    rm /usr/lib/initcpio/install/resizerootfs

    sed -i '/^HOOKS=/s/resizerootfs //g' /etc/mkinitcpio.conf
    mkinitcpio -P
fi

# Cleanup
rm /usr/local/sbin/first_time_setup.sh
rm /usr/lib/systemd/system/first_time_setup.service
rm /usr/lib/systemd/system/basic.target.wants/first_time_setup.service
