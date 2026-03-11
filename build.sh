#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2023 Dang Huynh <danct12@disroot.org>

set -e

SUPPORTED_ARCHES=(aarch64 armv7)
NOCONFIRM=0
OSK_SDL=0
NO_BOOTLOADER=0
use_pipewire=0
output_folder="build"
mkdir -p "$output_folder"
cachedir="$output_folder/pkgcache"
temp=$(mktemp -p $output_folder -d)
sharedcache=$(mktemp -p $output_folder -d)
date=$(date +%Y%m%d)

error() { echo -e "\e[41m\e[5mERROR:\e[49m\e[25m $1" && exit 1; }
check_dependency() { [ $(which $1) ] || error "$1 not found. Please make sure it is installed and on your PATH."; }
check_service() { systemctl -q is-active "$1" || error "$1 inactive. Please make sure it is installed and enabled."; }
usage() { error "$0 [-a ARCHITECTURE] [-d device] [-u ui] [-h hostname] [--osk-sdl] [--noconfirm] [--cachedir directory] [--no-cachedir]"; }
cleanup() {
    trap '' EXIT
    trap '' INT

    if [ -d "$temp" ]; then
        unmount_chroot
        unmount_cache
        rm -rf "$temp"
    fi
    if [ -d "$sharedcache" ]; then
        unmount_shared
        rm -rf "$sharedcache"
    fi
}

set_trap() {
    trap cleanup EXIT
    trap cleanup INT
}

pre_check() {
    check_dependency wget
    check_dependency bsdtar
    check_dependency fallocate
    check_dependency fdisk
    check_dependency losetup
    check_dependency mkfs.vfat
    check_dependency mkfs.ext4
    check_dependency genfstab
    check_dependency lsof
    check_dependency parted
    check_dependency arch-chroot
    check_dependency qemu-$genericarch-static
    check_service    systemd-binfmt.service
    check_service    proc-sys-fs-binfmt_misc.mount
    chmod 0755 "$temp"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -a|--arch) arch=$2; shift ;;
            -d|--device) device=$2; shift ;;
            -u|--ui) ui=$2; shift ;;
            -h|--hostname) hostname=$2; shift ;;
            --noconfirm) NOCONFIRM=1;;
            --osk-sdl) OSK_SDL=1;;
            --cachedir) cachedir=$2; shift ;;
            --no-cachedir) cachedir= ;;
            *) usage ;;
        esac
        shift
    done
}

parse_presets() {
    [ ! -e "devices/$device" ] && error "Device \"$device\" is unknown!"
    [ ! -e "ui/$ui" ] && error "User Interface \"$ui\" is unknown!"

    [ ! -e "devices/$device/config" ] && error "\"$device\" doesn't have a config file!" \
        || source "devices/$device/config"

    for i in $(cat "devices/$device/packages"); do
        packages_device+=( $i )
    done

    for i in $(cat "ui/$ui/packages"); do
        [ $use_pipewire -gt 0 ] && packages_ui+=( pipewire-audio pipewire-alsa pipewire-jack pipewire-pulse )
        packages_ui+=( $i )
    done

    if [ -e "devices/$device/packages-$ui-extra" ]; then
        for i in $(cat "devices/$device/packages-$ui-extra"); do
            packages_ui+=( $i )
        done
    fi

    if [ -e "ui/$ui/postinstall" ]; then
        while IFS= read -r postinstall_line; do
            postinstall+=("$postinstall_line\n")
        done < ui/$ui/postinstall
    fi
}

check_arch() {
    echo ${SUPPORTED_ARCHES[@]} | grep -q $arch || { echo "$arch is not supported. Supported architecture are: ${SUPPORTED_ARCHES[@]}" && exit 1; }
    case $arch in
         armv7) genericarch=arm ;;
         *) genericarch=$arch ;;
    esac
}

download_keyring() {
    [ -f "$output_folder/danctnix.gpg" ] && [ -f "$output_folder/danctnix-trusted" ] && return

    wget https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix.gpg \
        -O "$output_folder/danctnix.gpg"
    wget https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix-trusted \
        -O "$output_folder/danctnix-trusted"
}

download_rootfs() {
    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/ArchLinuxARM-$arch-latest.tar.gz" ] && return

    [ -f "$output_folder/ArchLinuxARM-$arch-latest.tar.gz"  ] && {
        read -rp "Stock rootfs already exist, delete it? (y/N) " yn
        case $yn in
            [Yy]*) rm "$output_folder/ArchLinuxARM-$arch-latest.tar.gz" ;;
            [Nn]*|"") return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    # Use the Californian mirror because it supports HTTPS
    wget -O "$output_folder/ArchLinuxARM-$arch-latest.tar.gz" https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

    pushd .
    cd $output_folder && { curl -s -L https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-$arch-latest.tar.gz.md5 | md5sum -c \
        || { rm ArchLinuxARM-$arch-latest.tar.gz && error "Rootfs checksum failed!"; } }
    popd
}

extract_rootfs() {
    [ -f "$output_folder/ArchLinuxARM-$arch-latest.tar.gz" ] || error "Rootfs not found"
    bsdtar -xpf $output_folder/ArchLinuxARM-$arch-latest.tar.gz -C $temp
}

mount_chroot() {
    mount --bind "$temp" "$temp"
}

unmount_chroot() {
    umount -l "$temp"
}

mount_cache() {
    if [ -n "$cachedir" ]; then
        mkdir -p "$cachedir"
        mount --bind "$cachedir" "$temp/var/cache/pacman/pkg" || error "Failed to mount pkg cache!";
    fi
}

unmount_cache() {
    if [[ $(findmnt "$temp/mnt") ]]; then
        umount -l "$temp/mnt" || error "Failed to unmount shared cache!";
    fi

    if [[ $(findmnt "$temp/var/cache/pacman/pkg") ]]; then
        umount -l "$temp/var/cache/pacman/pkg" || error "Failed to unmount pkg cache!";
    fi
}

mount_shared() {
    echo "Running sudo to mount shared cache"
    mount --bind "$sharedcache" "$temp/mnt" || error "Failed to mount shared cache!"

}

unmount_shared() {
    echo "Running sudo to unmount shared cache"
    umount -l "$sharedcache" || error "Failed to unmount shared cache!"

}

do_chroot() {
    arch-chroot "$temp" "$@"
    sync
}

init_rootfs() {
    if [ $OSK_SDL -gt 0 ]; then
        rootfs_tarball="rootfs-$device-$ui-$date-osksdl.tar.gz"
        packages_ui+=( osk-sdl )
    else
        rootfs_tarball="rootfs-$device-$ui-$date.tar.gz"
    fi

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/$rootfs_tarball" ] && rm "$output_folder/$rootfs_tarball"

    [ -f "$output_folder/$rootfs_tarball"  ] && {
        read -rp "Rootfs seems to have generated before, delete it? (Y/n) " yn
        case $yn in
            [Yy]*|"") rm "$output_folder/$rootfs_tarball" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    download_keyring
    download_rootfs
    extract_rootfs
    mount_chroot
    mount_cache
    mount_shared

    # workaround for vconsole.conf not found
    touch "$temp/etc/vconsole.conf"

    cp "overlays/base/etc/pacman.conf" "$sharedcache/pacman.conf"
    sync
    do_chroot cp /mnt/pacman.conf /etc/pacman.conf

    if [[ $ui = "barebone" ]]; then
        do_chroot sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' "/etc/locale.gen"
    fi

    do_chroot sh -c "echo ${hostname:-danctnix} > /etc/hostname"

    # Install our GPG key first, this will be overwritten with our package later.
    cp $output_folder/danctnix.gpg "$sharedcache/danctnix.gpg"
    cp $output_folder/danctnix-trusted "$sharedcache/danctnix-trusted"

    do_chroot cp /mnt/danctnix.gpg /usr/share/pacman/keyrings/danctnix.gpg
    do_chroot cp /mnt/danctnix-trusted /usr/share/pacman/keyrings/danctnix-trusted

    cat > "$sharedcache/second-phase" <<EOF
#!/bin/bash
set -e
pacman-key --init
pacman-key --populate archlinuxarm danctnix
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
pacman -Rsn --noconfirm linux-$arch
pacman -Syu --noconfirm --overwrite=*
pacman -S --noconfirm --overwrite=* --needed ${packages_device[@]} ${packages_ui[@]}


systemctl disable sshd
systemctl disable systemd-networkd
systemctl disable systemd-resolved
systemctl enable zramswap
systemctl enable NetworkManager

usermod -a -G network,video,audio,rfkill,wheel alarm

$(echo -e "${postinstall[@]}")

cp -rv /etc/skel/. /home/alarm
chown -R alarm:alarm /home/alarm

if [ -e /etc/sudoers.d ]; then
    echo '%wheel ALL=(ALL:ALL) ALL/' > /etc/sudoers.d/90_wheel
elif [ -e /etc/sudoers ]; then
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
rm /mnt/second-phase
EOF

    chmod +x "$sharedcache/second-phase"
    do_chroot /mnt/second-phase || error "Failed to run the second phase rootfs build!"

    mkdir "$sharedcache/overlay"
    cp -r overlays/base/* "$sharedcache/overlay/"
    [ -d "overlays/$ui" ] && cp -r overlays/$ui/* "$sharedcache/overlay/"
    [ -d "devices/$device/overlays/base" ] && cp -r devices/$device/overlays/base/* "$sharedcache/overlay/"
    [ -d "devices/$device/overlays/$ui" ] && cp -r devices/$device/overlays/$ui/* "$sharedcache/overlay/"
    do_chroot sh -c "cp -r /mnt/overlay/* /"

    if [ -e "$temp/usr/lib/initcpio/hooks/resizerootfs" ] && [ $OSK_SDL -gt 0 ]; then
        do_chroot rm -f /usr/lib/initcpio/hooks/resizerootfs
        do_chroot rm -f /usr/lib/initcpio/install/resizerootfs
    fi

    [ -e "$temp/usr/lib/initcpio/hooks/resizerootfs" ] && do_chroot sed -i '/^HOOKS=/s/fsck/resizerootfs fsck/g' "/etc/mkinitcpio.conf"
    [ -e "$temp/usr/lib/initcpio/hooks/osk-sdl" ] && do_chroot sed -i '/^HOOKS=/s/fsck/osk-sdl fsck/g' "/etc/mkinitcpio.conf"

    do_chroot sed -i "s/REPLACEDATE/$date/g" "/usr/local/sbin/first_time_setup.sh"

    [[ "$ui" != "barebone" ]] && do_chroot passwd -dl root

    [ -d "$temp/usr/share/glib-2.0/schemas" ] && do_chroot /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
    do_chroot mkinitcpio -P

    unmount_cache
    unmount_shared
    yes | do_chroot pacman -Scc

    unmount_chroot

    echo "Creating tarball: $rootfs_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$rootfs_tarball .
    popd
    rm -rf $temp
}

make_image() {
    [ ! -e "$output_folder/$rootfs_tarball" ] && \
        error "Rootfs not found! (how did you get here?)"

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/archlinux-$device-$ui-$date.img" ] && \
        rm "$output_folder/archlinux-$device-$ui-$date.img"

    [ -f "$output_folder/archlinux-$device-$ui-$date.img"  ] && {
        read -rp "Disk image already exist, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/archlinux-$device-$ui-$date.img" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    disk_size="$(eval "echo \${size_ui_$ui}")"

    disk_output="$output_folder/archlinux-$device-$ui-$date.img"

    echo "Generating a blank disk image ($disk_size)"
    fallocate -l $disk_size $disk_output

    boot_part_start=${boot_part_start:-1}
    boot_part_size=${boot_part_size:-128}

    echo "Boot partition start: ${boot_part_start}MB"
    echo "Boot partition size: ${boot_part_size}MB"

    parted -s $disk_output mktable gpt
    parted -s $disk_output mkpart boot fat32 ${boot_part_start}MB $[boot_part_start+boot_part_size]MB
    parted -s $disk_output set 1 esp on
    parted -s $disk_output mkpart rootfs ext4 $[boot_part_start+boot_part_size]MB '100%'

    echo "Attaching loop device"
    loop_device=$(losetup -f)
    losetup -P $loop_device "$output_folder/archlinux-$device-$ui-$date.img"

    echo "Creating filesystems"
    mkfs.vfat ${loop_device}p1
    mkfs.ext4 ${loop_device}p2

    mkdir -p $temp
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
}

make_squashfs() {
    check_dependency mksquashfs

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/archlinux-$device-$ui-$date.sqfs" ] && \
        rm "$output_folder/archlinux-$device-$ui-$date.sqfs"

    [ -f "$output_folder/archlinux-$device-$ui-$date.sqfs"  ] && {
        read -rp "Squashfs image already exist, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/archlinux-$device-$ui-$date.sqfs" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    mkdir -p "$temp"
    bsdtar -xpf "$output_folder/$rootfs_tarball" -C "$temp"
    mksquashfs "$temp" "$output_folder/archlinux-$device-$ui-$date.sqfs"
    rm -rf "$temp"
}

parse_args "$@"
[[ "$arch" && "$device" && "$ui" ]] || usage
check_arch
pre_check
parse_presets
set_trap
init_rootfs
[ $OSK_SDL -gt 0 ] && make_squashfs || make_image
