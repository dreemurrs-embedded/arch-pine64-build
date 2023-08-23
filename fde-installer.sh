#!/bin/bash

# Copyright 2023 - root https://github.com/root2185
#
# This script setup FDE on Artix Linux PinePhone
# and PineTab.
#
# Based on: https://github.com/dreemurrs-embedded/archarm-mobile-fde-installer/tree/master
# That was inspired by:
# https://github.com/sailfish-on-dontbeevil/flash-it

set +e

DOWNLOAD_SERVER="https://github.com/jackffmm/armtix-pine64/releases/tag/"
TMPMOUNT=$(mktemp -p . -d)

# Parse arguments
# https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -h|--help)
        echo "Artix ARM for PP/PT Encrypted Setup"
        echo ""
        printf '%s\n' \
               "This script will use/download the latest encrypted image for the" \
               "PinePhone and PineTab. It downloads and create a image for the user" \
               "to flash on their device or SD card." \
               "" \
               "usage: $0 " \
               "" \
               "Options:" \
               "" \
               "	-h, --help		Print this help and exit." \
               "" \
               "This command requires: parted, curl, sudo, wget, tar, unzip," \
               "mkfs.ext4, losetup." \
               ""

        exit 0
        shift
        ;;
    *) # unknown argument
        POSITIONAL+=("$1") # save it in an array for later
        shift # past argument
        ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Helper functions
# Error out if the given command is not found in PATH.
function check_dependency {
    dependency=$1
    hash $dependency >/dev/null 2>&1 || {
    	echo -e "\e[1mInstall missing dep/s using pacman?\e[0m"
    	select OPTION in "Yes" "No"; do
    	    case $OPTION in
    	        "Yes" ) pacman -S --needed --noconfirm parted cryptsetup sudo wget tar e2fsprogs util-linux zstd curl; break;;
    	        "No" ) echo >&2 "No? ${dependency} not found. Please make sure it is installed and on your PATH."; exit 1;
    	    esac
    	done
    }
}

function error {
    echo -e "\e[41m\e[5mERROR:\e[49m\e[25m $1"
}

# Check dependencies
check_dependency "parted"
check_dependency "cryptsetup"
check_dependency "sudo"
check_dependency "wget"
check_dependency "tar"
#check_dependency "unsquashfs"
check_dependency "mkfs.ext4"
#check_dependency "mkfs.f2fs"
#check_dependency "mkfs.btrfs"
check_dependency "losetup"
check_dependency "zstd"
check_dependency "curl"

# Image selection, all commented
<< ///
echo -e "\e[1mWhich image do you want to create?\e[0m"
select OPTION in "PinePhone" "PineTab"; do
    case $OPTION in
        "PinePhone" ) DEVICE="pinephone"; break;;
        "PineTab" ) DEVICE="pinetab"; break;;
    esac
done

echo -e "\e[1mWhich environment would you like to install?\e[0m"
select OPTION in "Phosh" "Plasma" "Sxmo" "Barebone"; do
    case $OPTION in
        "Phosh" ) USR_ENV="phosh"; break;;
        "Plasma" ) USR_ENV="plasma"; break;;
        "Sxmo" ) USR_ENV="sxmo"; break;;
        "Barebone" ) USR_ENV="barebone"; break;;
    esac
done

SQFSDATE=$(curl -s -f $DOWNLOAD_SERVER/version.txt || echo BAD)
SQFSROOT="archlinux-$DEVICE-$USR_ENV-$SQFSDATE.sqfs"

[ $SQFSDATE = "BAD" ] && { error "Failed to fetch for the latest version. The server may be down, please try again later." && exit 1; }

# Filesystem selection
echo -e "\e[1mWhich filesystem would you like to use?\e[0m"
select OPTION in "ext4" "btrfs"; do
    case $OPTION in
        "ext4" ) FILESYSTEM="ext4"; break;;
        "btrfs" ) FILESYSTEM="btrfs"; break;;
    esac
done
///
# end of commented part

# WORK IN PROGRESS
DEVICE="pinephone";
# Download the image https://github.com/jackffmm/armtix-pine64/releases/tag/ or build it
# and set the correct path and name.
TARBALL="fde-files/rootfs-pinephone-barebone-20230823-osksdl.tar.gz"
# Required package is shipped, to updated it:
# wget --quiet --show-progress -c -O fde-files/arch-install-scripts.tar.zst "https://archlinux.org/packages/extra/any/arch-install-scripts/download/"

# Filesystem selection
FILESYSTEM="ext4";
#FILESYSTEM="btrfs";

# Select flash target
echo -e "\e[1mWhich SD card do you want to flash?\e[0m"
lsblk
read -p "Device node (/dev/sdX): " DISK_IMAGE
echo "Flashing image to: $DISK_IMAGE"
echo "WARNING: All data will be erased! You have been warned!"
echo "Some commands require root permissions, you might be asked to enter your sudo password."

# Make sure people won't pick the wrong thing and ultimately erase the disk
echo
echo -e "\e[31m\e[1mARE YOU SURE \e[5m\e[4m${DISK_IMAGE}\e[24m\e[25m IS WHAT YOU PICKED?\e[39m\e[0m"
read -p "Confirm device node: " CONFIRM_DISK_IMAGE
[ "$DISK_IMAGE" != "$CONFIRM_DISK_IMAGE" ] && error "The device node mismatched. Aborting." && exit 1
echo

# Downloading images
<< ///
echo -e "\e[1mDownloading images...\e[0m"

wget --quiet --show-progress -c -O $SQFSROOT $DOWNLOAD_SERVER/$SQFSROOT || {
    error "Root filesystem image download failed. Aborting."
    exit 2
}

# Checksum check, make sure the root image is the real deal.
curl -s $DOWNLOAD_SERVER/$SQFSROOT.sha512sum | sha512sum -c || { error "Checksum does not match. Aborting." && rm $SQFSROOT && exit 1; }

wget --quiet --show-progress -c -O arch-install-scripts.tar.zst "https://archlinux.org/packages/extra/any/arch-install-scripts/download/" || {
	error "arch-install-scripts download failed. Aborting."
	exit 2
}
///

#cp fde-files/arch-install-scripts-*-any.pkg.tar.zst ./arch-install-scripts.tar.zst
cp fde-files/arch-install-scripts.tar.zst ./
tar --transform='s,^\([^/][^/]*/\)\+,,' -xf arch-install-scripts.tar.zst usr/bin/genfstab
chmod +x genfstab

[ ! -e "genfstab" ] && error "Failed to locate genfstab. Aborting." && exit 2

[ $FILESYSTEM = "ext4" ] && MKFS="mkfs.ext4"
[ $FILESYSTEM = "btrfs" ] && MKFS="mkfs.btrfs"

#sudo parted -a optimal ${DISK_IMAGE} mklabel msdos --script
sudo parted -a optimal ${DISK_IMAGE} mklabel gpt --script
#sudo parted -a optimal ${DISK_IMAGE} mkpart primary fat32 '0%' 2048MB --script
sudo parted -a optimal ${DISK_IMAGE} mkpart boot ext4 70MB 1070MB --script
#sudo parted -a optimal ${DISK_IMAGE} mkpart primary ext4 2048MB 100% --script
sudo parted -a optimal ${DISK_IMAGE} mkpart system ext4 1070MB 100% --script
sudo parted ${DISK_IMAGE} set 1 boot on --script

# The first partition is the boot partition and the second one the root
PARTITIONS=$(lsblk $DISK_IMAGE -l | grep ' part ' | awk '{print $1}')
BOOTPART=/dev/$(echo "$PARTITIONS" | sed -n '1p')
ROOTPART=/dev/$(echo "$PARTITIONS" | sed -n '2p')

ENCRYNAME=$(basename $(mktemp -p /dev/mapper/ -u))
ENCRYPART="/dev/mapper/$ENCRYNAME"

echo "You'll now be asked to type in a new encryption key. DO NOT LOSE THIS!"

# Generating LUKS header on a modern computer would make the container slow to unlock
# on slower devices such as PinePhone.
#
# Unless you're happy with the phone taking an eternity to unlock, this is it for now.
#sudo cryptsetup -q -y -v luksFormat --pbkdf-memory=20721 --pbkdf-parallel=4 --pbkdf-force-iterations=4 $ROOTPART
sudo cryptsetup -q -y -v luksFormat $ROOTPART
sudo cryptsetup open $ROOTPART $ENCRYNAME

[ ! -e /dev/mapper/${ENCRYNAME} ] && error "Failed to locate rootfs mapper. Aborting." && exit 1

sudo mkfs.vfat $BOOTPART
sudo $MKFS $ENCRYPART

sudo mount $ENCRYPART $TMPMOUNT
sudo mkdir $TMPMOUNT/boot
sudo mount $BOOTPART $TMPMOUNT/boot

#sudo unsquashfs -f -d $TMPMOUNT $SQFSROOT
sudo tar -xf $TARBALL $TMPMOUNT 

./genfstab -U $TMPMOUNT | grep UUID | grep -v "swap" | sudo tee -a $TMPMOUNT/etc/fstab
sudo sed -i "s:UUID=[0-9a-f-]*\s*/\s:/dev/mapper/cryptroot / :g" $TMPMOUNT/etc/fstab

sudo dd if=${TMPMOUNT}/boot/u-boot-sunxi-with-spl-${DEVICE}-552.bin of=${DISK_IMAGE} bs=8k seek=1

sudo umount -R $TMPMOUNT
sudo cryptsetup close $ENCRYNAME


echo -e "\e[1mCleaning up working directory...\e[0m"
sudo rm -f arch-install-scripts.tar.zst || true
sudo rm -f genfstab || true
sudo rm -rf $TMPMOUNT || true

echo -e "\e[32m\e[1mAll done! Please insert the card to your device and power on.\e[39m\e[0m"
