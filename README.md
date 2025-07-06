# Arch Pine64 Build Guide

This guide provides instructions for building an Arch Linux image for Pine64 devices. Follow the steps below to set up your environment and build the image.

## Prerequisites
### Arch Linux

```sh
sudo pacman -Syu --noconfirm
sudo pacman -S --needed devtools base-devel lsof libarchive dosfstools util-linux wget arch-install-scripts qemu-user-static qemu-user-static-binfmt e2fsprogs
```

### Debian

```sh
sudo apt-get update
sudo apt-get install -y lsof wget util-linux libarchive-tools e2fsprogs dosfstools arch-install-scripts fdisk qemu-user-static
```

## Building An Image
### Usage

To build the project, use the following command:

```sh
./build.sh [-a ARCHITECTURE] [-d device] [-u ui] [-h hostname] [--osk-sdl] [--noconfirm] [--cachedir directory] [--no-cachedir]
```

### Options

- `-a ARCHITECTURE`: Specify the architecture for the build (e.g., arm, arm64).
- `-d device`: Define the target device for the build.
- `-u ui`: Choose the user interface to be installed.
- `-h hostname`: Set the hostname for the device.
- `--osk-sdl`: Enable the on-screen keyboard using SDL.
- `--noconfirm`: Proceed with the build without prompting for confirmation.
- `--cachedir directory`: Specify a directory to use for caching.
- `--no-cachedir`: Disable the use of a cache directory.

