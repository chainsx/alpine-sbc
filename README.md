# alpine-sbc

Build bootable Alpine Linux images for ARM64 single-board computers on a native
ARM64 Alpine host. The project builds U-Boot, board kernels, signed Alpine kernel
packages, a root filesystem, and the final disk image.

## Requirements

- Alpine Linux on an ARM64/aarch64 host
- Root privileges for packages, chroot, loop devices, and mounts
- At least 30 GiB of free disk space
- Network access to Alpine mirrors and the Git repositories selected by a board

## Quick start

```sh
sudo ./build.sh --board extlinux-arm64 --version 3.23.0
```

Build the ARM64 EFI/GRUB image for QEMU:

```sh
sudo ./build.sh --board efi-arm64 --version 3.23.0
```

Useful options:

```text
--clean               Remove generated build state
--jobs N              Set parallel build jobs
--mirror URL          Select an Alpine mirror
--skip-deps           Do not install host dependencies
--skip-bootloader     Reuse the bootloader build
--skip-kernel         Reuse signed kernel packages
--skip-rootfs         Reuse the root filesystem
--skip-image          Stop before image generation
```

Generated files are stored below `build/`:

```text
packages/aarch64/             Signed kernel APKs and APKINDEX
keys/alpine-sbc.rsa.pub       Local repository public key
rootfs/                       Alpine root filesystem
output/*.img.xz               Compressed disk images
output/*.img.xz.sha256        Image checksums
output/*.img.layout           Final partition layout
bootloader-artifacts.sha256   Boot firmware artifact manifest
log/*.log                     Stage logs
```

## Boot paths

| Platform | Boot path |
| --- | --- |
| Rockchip | BootROM → DDR TPL/SPL → BL31 + U-Boot FIT → extlinux → kernel/initramfs/DTB |
| Amlogic | BootROM → signed vendor FIP → U-Boot → extlinux → kernel |
| STM32MP2 | BootROM → redundant TF-A BL2 → FIP containing BL31, OP-TEE, and U-Boot → extlinux → kernel/DTB |
| QEMU extlinux | External U-Boot → standard boot/extlinux → kernel/initramfs |
| QEMU EFI | U-Boot EFI or EDK2 → `BOOTAA64.EFI` → GRUB → kernel/initramfs |

STM32MP2 images use two redundant `fsbla*` partitions, one 4 MiB `fip`
partition, and `u-boot-env`. The build explicitly sets `PSA_FWU_SUPPORT=0` and
therefore does not create misleading FWU metadata or A/B slots. A future A/B
implementation must enable TF-A FWU and generate matching metadata and GPT
partition UUIDs as one atomic change.

Bootloader artifacts are checked for presence and size before raw writes.
Kernel configuration checks require built-in root filesystem, devtmpfs,
initramfs, and board console support. The configured DTB must exist in the
staged kernel package.

## Kernel packages

The package layout follows Alpine's `linux-lts` conventions:

- `linux-sbc-<board>`: kernel, modules, config, System.map, and DTBs
- `linux-sbc-<board>-dev`: external-module headers and `Module.symvers`
- `linux-sbc-<board>-doc`: kernel documentation

The development package depends on Alpine's official `linux-headers` package.
All local APKs and `APKINDEX.tar.gz` are signed; the rootfs does not use
`--allow-untrusted`.

## QEMU EFI testing

After building `efi-arm64`, boot it with the project U-Boot:

```sh
extra/scripts/run-qemu.sh --firmware u-boot
```

Or with Alpine AAVMF/EDK2:

```sh
extra/scripts/run-qemu.sh --firmware edk2
```

Use `--dry-run` to print the QEMU command. Secure Boot is not enabled.

## Adding a board

Create `boards/<name>.config` with at least:

```sh
arch="arm64"
rootfs_arch="aarch64"
platform="rockchip64"
boot_mode="extlinux"
bootargs="console=ttyS2,1500000 root=LABEL=rootfs rootwait rw"

bootloader_url="..."
bootloader_branch="..."
bootloader_config="..._defconfig"

kernel_url="..."
kernel_branch="..."
kernel_config="linux-....config"
dtb_name="vendor/board"

serial_console="ttyS2"
serial_baud="1500000"
part_table="gpt"
boot_size="256"
```

Board and generic patches are loaded from `patches/{u-boot,kernel,atf}/`.

## Supported configurations

- `100ask-dshanpi-a1`
- `100ask-dshanpi-r1`
- `efi-arm64`
- `extlinux-arm64`
- `firefly-rk3566-roc-pc`
- `firefly-rk3568-roc-pc`
- `firefly-rk3588s-roc-pc`
- `khadas-vim3`
- `myb-stm32mp257x-1GB`
- `sakurapi-rk3308b`

## Validation

Run host-independent checks with:

```sh
make test
shellcheck -x build.sh scripts/*.sh scripts/libs/*.sh extra/scripts/*.sh tests/*.sh
```

Full compilation and hardware boot testing require an ARM64 Alpine host.
See [STARTUP_CHAIN_AUDIT.md](STARTUP_CHAIN_AUDIT.md) for the audited upstream
base, startup-chain fixes, and validation scope.

## References

- [Alpine aports: linux-lts](https://gitlab.alpinelinux.org/alpine/aports/-/tree/master/main/linux-lts)
- [Alpine image scripts](https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/scripts/mkimg.base.sh)
- [chainsx/build STM32MP2 branch](https://github.com/chainsx/build/tree/stm32mp2)
- [Armbian Rockchip boot implementation](https://github.com/armbian/build/blob/main/config/sources/families/include/rockchip64_common.inc)
- [ST STM32CubeProgrammer FlashLayout](https://wiki.st.com/stm32mpu/wiki/STM32CubeProgrammer_flashlayout)
- [ST manual bootloader update](https://wiki.st.com/stm32mpu/wiki/How_to_manually_update_bootloaders)
