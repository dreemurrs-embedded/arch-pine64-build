#!/bin/bash

# Copyright 2021-2022 - Dreemurrs Embedded Labs / DanctNIX Community

# This is a first time boot script, it is supposed to self destruct after the script has finished.

if [ -e /sys/devices/platform/bootsplash.0/enabled ]; then
    echo 0 > /sys/devices/platform/bootsplash.0/enabled
fi

echo "THE FIRST BOOT SCRIPT IS NOW RUNNING, PLEASE WAIT."
echo "ONCE IT'S DONE, YOU'LL BE BOOTED TO THE OPERATING SYSTEM."

date +%Y%m%d -s "REPLACEDATE" # this is changed by the make_rootfs script

# Initialize the pacman keyring
pacman-key --init
pacman-key --populate archlinuxarm danctnix armtix

if [ -e "/usr/lib/initcpio/hooks/resizerootfs" ]; then
    rm /usr/lib/initcpio/hooks/resizerootfs
    rm /usr/lib/initcpio/install/resizerootfs

    sed -i 's/resizerootfs//g' /etc/mkinitcpio.conf
    mkinitcpio -P
fi

# Cleanup
rm /usr/local/sbin/first_time_setup.sh
rm /usr/lib/systemd/system/first_time_setup.service
rm /usr/lib/systemd/system/basic.target.wants/first_time_setup.service
sed -i '/first_time_setup/d' /etc/bash/bashrc.d/artix.bashrc

if [ -e /sys/devices/platform/bootsplash.0/enabled ]; then
    echo 1 > /sys/devices/platform/bootsplash.0/enabled
fi
