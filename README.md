#  Rootfs builder for Arch Linux ARM on PinePhone (Pro)/PineTab

## Usage

```
./build.sh [-a ARCHITECTURE] [-d device] [-u ui] [-h hostname] [--osk-sdl] [--noconfirm] [--cachedir directory] [--no-cachedir]
```

Supported architectures are `aarch64` and `armv7`.


## Building on x86\_64

If you want to cross-build the image from another architecture, you will need to [use QEMU](https://wiki.archlinux.org/title/QEMU#Chrooting_into_arm/arm64_environment_from_x86_64) for the second build stage.

On Arch Linux, this can be done by installing [`binfmt-qemu-static`](https://aur.archlinux.org/packages/binfmt-qemu-static/) and [`qemu-user-static`](https://aur.archlinux.org/packages/qemu-user-static/) on the build host.


