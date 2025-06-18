#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2023 Dang Huynh <danct12@disroot.org>
# Ruined 2025 by Christian Duerr <alarm@christianduerr.com>

set -e

SUPPORTED_ARCHES=(aarch64 armv7)
NOCONFIRM=0
NO_BOOTLOADER=0
use_pipewire=0
output_folder="build"
mkdir -p "$output_folder"
cachedir="$output_folder/pkgcache"
temp=$(mktemp -p $output_folder -d)
date=$(date +%Y%m%d)

error() { echo -e "\e[41m\e[5mERROR:\e[49m\e[25m $1" && exit 1; }
check_dependency() { [ $(which $1) ] || error "$1 not found. Please make sure it is installed and on your PATH."; }
usage() { error "$0 <-a ARCHITECTURE> <-d DEVICE> <-p PACKAGES> [--postinstall POSTINSTALL] [-h HOSTNAME] [--noconfirm] [--cachedir directory] [--no-cachedir]"; }
cleanup() {
    trap '' EXIT
    trap '' INT
    if [ -d "$temp" ]; then
        unmount_chroot
        rm -r "$temp"
    fi
}

trap cleanup EXIT
trap cleanup INT

pre_check() {
    check_dependency curl
    check_dependency bsdtar
    check_dependency fallocate
    check_dependency fdisk
    check_dependency losetup
    check_dependency mkfs.vfat
    check_dependency mkfs.ext4
    check_dependency genfstab
    check_dependency lsof
    check_dependency parted
    chmod 755 "$temp"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -a|--arch) arch=$2; shift ;;
            -d|--device) device=$2; shift ;;
            -p|--packages) packages=$2; shift ;;
            --postinstall) postinstall=$2; shift ;;
            -h|--hostname) hostname=$2; shift ;;
            --noconfirm) NOCONFIRM=1;;
            --cachedir) cachedir=$2; shift ;;
            --no-cachedir) cachedir= ;;
            *) usage ;;
        esac
        shift
    done
}

parse_presets() {
    [ ! -e "devices/$device" ] && error "Device \"$device\" is unknown!"

    [ ! -e "devices/$device/config" ] && error "\"$device\" doesn't have a config file!" \
        || source "devices/$device/config"

    for i in $(cat "devices/$device/packages"); do
        packages_device+=( $i )
    done
}

check_arch() {
    echo ${SUPPORTED_ARCHES[@]} | grep -q $arch || { echo "$arch is not supported. Supported architecture are: ${SUPPORTED_ARCHES[@]}" && exit 1; }
}

download_rootfs() {
    alarm_filename="ArchLinuxARM-$arch-latest.tar.gz"
    alarm_url="http://os.archlinuxarm.org/os/$alarm_filename"
    alarm_rootfs="ArchLinuxARM-$arch-$date.tar.gz"

    # Short-circuit if rootfs already exists.
    if [ -f "$output_folder/$alarm_rootfs" ]; then
        echo "Using cached ALARM rootfs."
        return
    fi

    # Download ALARM rootfs.
    curl -L "$alarm_url" -o "$output_folder/$alarm_filename"

    # Verify rootfs checksum.
    pushd .
    cd $output_folder && { curl -sL "$alarm_url.md5" | md5sum -c \
        || { rm "$alarm_rootfs" && error "ALARM rootfs checksum failed!"; } }
    popd

    # Move to dated filename.
    mv "$output_folder/$alarm_filename" "$output_folder/$alarm_rootfs"
}

extract_rootfs() {
    [ -f "$output_folder/$alarm_rootfs" ] || error "ALARM rootfs not found"
    bsdtar -xpf "$output_folder/$alarm_rootfs" -C "$temp"
}

mount_chroot() {
    mount -o bind /dev "$temp/dev"
    mount -t proc proc "$temp/proc"
    mount -t sysfs sys "$temp/sys"
    mount -t tmpfs tmpfs "$temp/tmp"
}

unmount_chroot() {
    for i in $(lsof +D "$temp" | tail -n+2 | tr -s ' ' | cut -d ' ' -f 2 | sort -nu); do
        kill -9 $i
    done

    for i in $(cat /proc/mounts | awk '{print $2}' | grep "^$(readlink -f $temp)"); do
        [ $i ] && umount -l $i
    done
}

mount_cache() {
    if [ -n "$cachedir" ]; then
        mkdir -p "$cachedir"
        mount --bind "$cachedir" "$temp/var/cache/pacman/pkg" || error "Failed to mount pkg cache!";
    fi
}

unmount_cache() {
    if [[ $(findmnt "$temp/var/cache/pacman/pkg") ]]; then
        umount -l "$temp/var/cache/pacman/pkg" || error "Failed to unmount pkg cache!";
    fi
}

do_chroot() {
    chroot "$temp" "$@"
}

init_rootfs() {
    download_rootfs

    rootfs_md5=$(md5sum "$output_folder/$alarm_rootfs" | awk '{print $1}')
    rootfs_tarball="rootfs-$device-$rootfs_md5.tar.gz"

    # Short-circuit if danctnix rootfs already exists.
    if [ -f "$output_folder/$rootfs_tarball" ]; then
        echo "Using cached Danctnix rootfs."
        return
    fi

    extract_rootfs
    mount_chroot
    mount_cache

    rm "$temp/etc/resolv.conf"
    cat /etc/resolv.conf > "$temp/etc/resolv.conf"

    cp "overlays/base/etc/pacman.conf" "$temp/etc/pacman.conf"

    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' "$temp/etc/locale.gen"

    echo "${hostname:-danctnix}" > "$temp/etc/hostname"

    # Download our gpg key and install it first, this however will be overwritten with our package later.
    curl https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix.gpg \
        -o "$temp/usr/share/pacman/keyrings/danctnix.gpg"
    curl https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix-trusted \
        -o "$temp/usr/share/pacman/keyrings/danctnix-trusted"

    cat > "$temp/second-phase" <<EOF
#!/bin/bash
set -e
pacman-key --init
pacman-key --populate archlinuxarm danctnix
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
pacman -Rsn --noconfirm linux-$arch
pacman -Syu --noconfirm --overwrite=*
pacman -S --noconfirm --overwrite=* --needed ${packages_device[@]}


systemctl disable sshd
systemctl disable systemd-networkd
systemctl disable systemd-resolved
systemctl enable zramswap
systemctl enable NetworkManager

usermod -a -G network,video,audio,rfkill,wheel alarm

cp -rv /etc/skel/. /home/alarm
chown -R alarm:alarm /home/alarm

if [ -e /etc/sudoers ]; then
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

cat << FOE | passwd alarm
123456
123456

FOE

locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -s ../usr/share/zoneinfo/Europe/London /etc/localtime

# remove pacman gnupg keys post generation
rm -rf /etc/pacman.d/gnupg
rm /second-phase
EOF

    chmod +x "$temp/second-phase"
    do_chroot /second-phase || error "Failed to run the second phase rootfs build!"

    cp -r overlays/base/* "$temp/"
    [ -d "devices/$device/overlays/base" ] && cp -r devices/$device/overlays/base/* "$temp/"

    [ -e "$temp/usr/lib/initcpio/hooks/resizerootfs" ] && sed -i '/^HOOKS=/s/fsck/resizerootfs fsck/g' "$temp/etc/mkinitcpio.conf"

    sed -i "s/REPLACEDATE/$date/g" "$temp/usr/local/sbin/first_time_setup.sh"

    do_chroot passwd -dl root

    [ -d "$temp/usr/share/glib-2.0/schemas" ] && do_chroot /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
    do_chroot mkinitcpio -P

    unmount_cache
    yes | do_chroot pacman -Scc

    unmount_chroot

    echo "Creating base image tarball: $rootfs_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$rootfs_tarball .
    popd
}

add_packages() {
    packages_md5=$(echo "$packages" | md5sum - | awk '{print $1}')
    danctnix_tarball="danctnix-$device-$rootfs_md5-$packages_md5.tar.gz"

    # Short-circuit if image tarball is up to date.
    if [ -f "$output_folder/$danctnix_tarball" ]; then
        echo "Using cached packages rootfs."
        return;
    fi

    # Ensure tempdir is clean.
    rm -rf $temp
    mkdir -p $temp

    # Recover existing rootfs.
    echo "Extracting base image tarball…"
    bsdtar -xpf "$output_folder/$rootfs_tarball" -C "$temp"

    echo "Installing additional packages…"

    mount_chroot
    mount_cache

    cat > "$temp/add_packages" <<EOF
#!/bin/bash
set -e
pacman-key --init
pacman-key --populate archlinuxarm danctnix
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
pacman -S --noconfirm --overwrite=* --needed ${packages[@]}

$(echo -e "${postinstall[@]}")

rm /add_packages
EOF

    chmod +x "$temp/add_packages"
    do_chroot /add_packages || error "Failed to add packages to rootfs!"

    unmount_cache
    yes | do_chroot pacman -Scc

    unmount_chroot

    echo "Creating image tarball: $danctnix_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$danctnix_tarball .
    popd
}

make_image() {
    [ ! -e "$output_folder/$danctnix_tarball" ] && \
        error "Image tarball not found! (how did you get here?)"

    image="archlinux-$device-$rootfs_md5-$packages_md5.img"

    # Short-circuit if image is up to date.
    if [ -f "$output_folder/$image.xz" ]; then
        echo "Using cached image."
        return;
    fi

    # Ensure tempdir is clean.
    rm -rf $temp
    mkdir -p $temp

    image_path="$output_folder/$image"

    disk_size="8G"
    echo "Generating a blank disk image ($disk_size)"
    fallocate -l $disk_size $image_path

    boot_part_start=${boot_part_start:-1}
    boot_part_size=${boot_part_size:-128}

    echo "Boot partition start: ${boot_part_start}MB"
    echo "Boot partition size: ${boot_part_size}MB"

    parted -s $image_path mktable gpt
    parted -s $image_path mkpart boot fat32 ${boot_part_start}MB $[boot_part_start+boot_part_size]MB
    parted -s $image_path set 1 esp on
    parted -s $image_path mkpart rootfs ext4 $[boot_part_start+boot_part_size]MB '100%'

    echo "Attaching loop device"
    loop_device=$(losetup -f)
    losetup -P $loop_device "$image_path"

    echo "Creating filesystems"
    mkfs.vfat ${loop_device}p1
    mkfs.ext4 ${loop_device}p2

    echo "Mounting disk image"
    mount ${loop_device}p2 $temp
    mkdir -p $temp/boot
    mount ${loop_device}p1 $temp/boot

    echo "Extracting rootfs to image"
    bsdtar -xpf "$output_folder/$rootfs_tarball" -C "$temp" || true

    [ $NO_BOOTLOADER -lt 1 ] && {
        echo "Installing bootloader"
        case $platform in
            "rockchip")
                dd if=$temp/boot/idbloader.img of=$loop_device seek=64 conv=notrunc,fsync
                dd if=$temp/boot/u-boot.itb of=$loop_device seek=16384 conv=notrunc,fsync
                ;;
            *)
                dd if=$temp/boot/$bootloader of=$loop_device bs=128k seek=1
                ;;
        esac; }

    echo "Generating fstab"
    genfstab -U $temp | grep UUID | grep -v "swap" | tee -a $temp/etc/fstab

    echo "Unmounting disk image"
    umount -R $temp
    rm -rf $temp
    losetup -d $loop_device

    echo "Compressing image"
    xz -z "$output_folder/$image"
}

pre_check
parse_args "$@"
[[ "$arch" && "$device" && "$packages" ]] || usage
check_arch
parse_presets
init_rootfs
add_packages
make_image
