#!/bin/bash


set -e

SUPPORTED_ARCHES=(aarch64 armv7)
NOCONFIRM=0
OSK_SDL=0
NO_BOOTLOADER=0
use_pipewire=0
output_folder="build"
mkdir -p "$output_folder"
mkdir -p "$output_folder/key"
cachedir="$output_folder/pkgcache"
temp=$(mktemp -p $output_folder -d)
date=$(date +%Y%m%d)

error() { echo -e "\e[41m\e[5mERROR:\e[49m\e[25m $1" && exit 1; }
check_dependency() { [ $(which $1) ] || error "$1 not found. Please make sure it is installed and on your PATH."; }
usage() { error "$0 [-a ARCHITECTURE] [-d device] [-u ui] [-h hostname] [--osk-sdl] [--noconfirm] [--cachedir directory] [--no-cachedir]"; }
cleanup() {
    trap '' EXIT
    trap '' INT
    if [ -d "$temp" ]; then
        unmount_chroot
        rm -r "$temp"
    fi
}

###trap cleanup EXIT
###trap cleanup INT

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
    chmod 755 "$temp"
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
}

download_rootfs() {
    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/armtix-$arch-latest.tar.xz" ] && return

    [ -f "$output_folder/armtix-$arch-latest.tar.xz"  ] && {
        read -rp "Stock rootfs already exist, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/armtix-$arch-latest.tar.xz" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    wget -r -nd -l 1 -A "armtix-dinit-*.tar.xz" https://armtixlinux.org/images/
    curl -s -L https://armtixlinux.org/images/sha256sums | sha256sum -c |& grep ": OK" || { rm armtix-$arch-latest.tar.xz && error "Rootfs checksum failed!"; }
    mv armtix-dinit-*.tar.xz "$output_folder/armtix-$arch-latest.tar.xz"
}

extract_rootfs() {
    [ -f "$output_folder/armtix-$arch-latest.tar.xz" ] || error "Rootfs not found"
    bsdtar -xpf "$output_folder/armtix-$arch-latest.tar.xz" -C "$temp"
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
    if [ $OSK_SDL -gt 0 ]; then
        rootfs_tarball="rootfs-$device-$ui-$date-osksdl.tar.gz"
        packages_ui+=( osk-sdl )
    else
        rootfs_tarball="rootfs-$device-$ui-$date.tar.gz"
    fi

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/$rootfs_tarball" ] && rm "$output_folder/$rootfs_tarball"

    [ -f "$output_folder/$rootfs_tarball"  ] && {
        read -rp "Rootfs seems to have generated before, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/$rootfs_tarball" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }
    read -p "OK ? - checks" #####################################################

    download_rootfs
    read -p "OK ? - download" #####################################################
    extract_rootfs
    read -p "OK ? - extract" #####################################################
    mount_chroot
    mount_cache
    read -p "OK ? - mounts" #####################################################

    rm "$temp/etc/resolv.conf"
    cat /etc/resolv.conf > "$temp/etc/resolv.conf" #####

    cp "overlays/base/etc/pacman.conf" "$temp/etc/pacman.conf"
    wget -O "$temp/etc/pacman.d/mirrorlist-archlinuxarm" https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/pacman-mirrorlist/mirrorlist

    if [[ $ui = "barebone" ]]; then
        sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' "$temp/etc/locale.gen"
    fi

    echo "${hostname:-ppa}" > "$temp/etc/hostname"
    
    ls "$temp/usr/share/pacman/keyrings"
    # Download our gpg key and install it first, this however will be overwritten with our package later.
    wget https://raw.githubusercontent.com/dreemurrs-embedded/Pine64-Arch/master/PKGBUILDS/danctnix/danctnix-keyring/danctnix.gpg \
        -O "$temp/usr/share/pacman/keyrings/danctnix.gpg"
    wget https://raw.githubusercontent.com/dreemurrs-embedded/Pine64-Arch/master/PKGBUILDS/danctnix/danctnix-keyring/danctnix-trusted \
        -O "$temp/usr/share/pacman/keyrings/danctnix-trusted"
    # Arch mirrorlist and keyring
    wget -O "$temp/etc/pacman.d/mirrorlist-archlinuxarm" https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/pacman-mirrorlist/mirrorlist
    wget -r -nd -l 1 -A "archlinuxarm-keyring-*any.pkg.tar.xz" https://fl.us.mirror.archlinuxarm.org/aarch64/core/
    mv archlinuxarm-keyring-*any.pkg.tar.xz "$output_folder/archlinuxarm-keyring.tar.xz"
    #tar --wildcards -C "$output_folder/key" -xf "$output_folder/archlinuxarm-keyring.tar.xz" usr/share/pacman/keyrings/* --strip-components=4
    tar -C "$temp" -xf "$output_folder/archlinuxarm-keyring.tar.xz"
    wget -r -nd -l 1 -A "archlinux-keyring-*any.pkg.tar.xz" https://fl.us.mirror.archlinuxarm.org/aarch64/core/
    mv archlinux-keyring-*any.pkg.tar.xz "$output_folder/archlinux-keyring.tar.xz"
    tar -C "$temp" -xf "$output_folder/archlinux-keyring.tar.xz"
    ls "$temp/usr/share/pacman/keyrings"
    cat > "$temp/second-phase" <<EOF
#!/bin/bash
set -e
dhcpcd
ntpdate pool.ntp.org
read -p "OK ? - dhcp and time" ###############
pacman-key --init
echo "FS1"
pacman-key --populate archlinuxarm danctnix
echo "FS2"
pacman -Rsn --noconfirm linux-$arch linux-$arch-headers linux-$arch-lts linux-$arch-lts-headers
echo "FS3"
pacman -Syy  --noconfirm
echo "FS4"
pacman -S  --noconfirm --overwrite=* pacman pacman-contrib  
echo "FS5"
pacman -S  --noconfirm --overwrite=* archlinuxarm-keyring archlinuxarm-mirrorlist artix-keyring artix-mirrorlist artix-archlinux-support 
echo "FS6"
pacman -Syu  --noconfirm --overwrite=*
echo "FS7"
pacman -S --noconfirm --overwrite=* --needed ${packages_device[@]} ${packages_ui[@]}
echo "FS8"


#dinitctl disable sshd
###dinitctl enable zramswap
#dinitctl enable NetworkManager

usermod -a -G network,video,audio,rfkill,wheel,input,power,storage,optical,lp,scanner,dbus,uucp armtix

#$(echo -e "${postinstall[@]}")

cp -rv /etc/skel/. /home/armtix
chown -R armtix:armtix /home/armtix

if [ -e /etc/sudoers ]; then
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

cat << FOE | passwd armtix
armtix
armtix

FOE

locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# remove pacman gnupg keys post generation
rm -rf /etc/pacman.d/gnupg
#####rm /second-phase
EOF
echo "Echo of second phase:" ###############
cat "$temp/second-phase" ##################
read -p "OK ? - echo of second-phase" #####################################################
    chmod +x "$temp/second-phase"
    do_chroot /second-phase || error "Failed to run the second phase rootfs build!"

    cp -r overlays/base/* "$temp/"
    [ -d "overlays/$ui" ] && cp -r overlays/$ui/* "$temp/"
    [ -d "devices/$device/overlays/base" ] && cp -r devices/$device/overlays/base/* "$temp/"
    [ -d "devices/$device/overlays/$ui" ] && cp -r devices/$device/overlays/$ui/* "$temp/"

    if [ -e "$temp/usr/lib/initcpio/hooks/resizerootfs" ] && [ $OSK_SDL -gt 0 ]; then
        rm -f $temp/usr/lib/initcpio/hooks/resizerootfs
        rm -f $temp/usr/lib/initcpio/install/resizerootfs
    fi

    [ -e "$temp/usr/lib/initcpio/hooks/resizerootfs" ] && sed -i 's/fsck/resizerootfs fsck/g' "$temp/etc/mkinitcpio.conf"
    [ -e "$temp/usr/lib/initcpio/hooks/osk-sdl" ] && sed -i 's/fsck/osk-sdl fsck/g' "$temp/etc/mkinitcpio.conf"
    [ -e "$temp/usr/lib/initcpio/install/bootsplash-danctnix" ] && sed -i 's/fsck/fsck bootsplash-danctnix/g' "$temp/etc/mkinitcpio.conf"

    sed -i "s/REPLACEDATE/$date/g" "$temp/usr/local/sbin/first_time_setup.sh"
    echo "sudo /usr/local/sbin/first_time_setup.sh" >> "$temp/etc/bash/bashrc.d/artix.bashrc"

    [[ "$ui" != "barebone" ]] && do_chroot passwd -dl root

    [ -d "$temp/usr/share/glib-2.0/schemas" ] && do_chroot /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
    do_chroot mkinitcpio -P

    unmount_cache
    yes | do_chroot pacman -Scc

    unmount_chroot

    echo "Creating tarball: $rootfs_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$rootfs_tarball .
    popd
    read -p "OK ? - part2 end" #####################################################
    rm -rf $temp
}

make_image() {
    [ ! -e "$output_folder/$rootfs_tarball" ] && \
        error "Rootfs not found! (how did you get here?)"

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/armtix-$device-$ui-$date.img" ] && \
        rm "$output_folder/armtix-$device-$ui-$date.img"

    [ -f "$output_folder/armtix-$device-$ui-$date.img"  ] && {
        read -rp "Disk image already exist, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/armtix-$device-$ui-$date.img" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    disk_size="$(eval "echo \${size_ui_$ui}")"

    disk_output="$output_folder/armtix-$device-$ui-$date.img"

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
    losetup -P $loop_device "$output_folder/armtix-$device-$ui-$date.img"

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

    [ $NOCONFIRM -gt 0 ] && [ -f "$output_folder/armtix-$device-$ui-$date.sqfs" ] && \
        rm "$output_folder/armtix-$device-$ui-$date.sqfs"

    [ -f "$output_folder/armtix-$device-$ui-$date.sqfs"  ] && {
        read -rp "Squashfs image already exist, delete it? (y/n) " yn
        case $yn in
            [Yy]*) rm "$output_folder/armtix-$device-$ui-$date.sqfs" ;;
            [Nn]*) return ;;
            *) echo "Aborting." && exit 1 ;;
        esac; }

    mkdir -p "$temp"
    bsdtar -xpf "$output_folder/$rootfs_tarball" -C "$temp"
    mksquashfs "$temp" "$output_folder/armtix-$device-$ui-$date.sqfs"
    rm -rf "$temp"
}

pre_check
parse_args $@
[[ "$arch" && "$device" && "$ui" ]] || usage
check_arch
parse_presets
init_rootfs
read -p "OK ? - about to make  squash or image, based on osk var: $OSK_SDL"
[ $OSK_SDL -gt 0 ] && make_squashfs || make_image
