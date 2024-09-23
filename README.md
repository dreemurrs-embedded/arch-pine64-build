# Prerequisites
### Archlinux
```sh
sudo pacman -Syu --noconfirm
sudo pacman -S --neeeded devtools \
  base-devel \
  lsof \
  libarchive \
  dosfstools \
  util-linux \
  wget \
  arch-install-scripts \
  qemu-user-static \
  qemu-user-static-binfmt \
  e2fsprogs
```
### Debian
```sh
sudo apt-get update
sudo apt-get install -y lsof \
  wget \
  util-linux \
  libarchive-tools \
  e2fsprogs \
  dosfstools \
  arch-install-scripts \
  fdisk \
  qemu-user-static
```
Usage
