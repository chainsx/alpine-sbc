#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mapfile -t scripts < <(find . -type f -name '*.sh' -not -path './build/*' | sort)
((${#scripts[@]} > 0)) || fail "no shell scripts found"
for script in "${scripts[@]}"; do
	bash -n "$script"
done

# shellcheck source=scripts/libs/common.sh
source "$project_root/scripts/libs/common.sh"
[[ "$(normalize_arch aarch64)" == arm64 ]] || fail "aarch64 normalization"
[[ "$(apk_arch_for_kernel_arch arm64)" == aarch64 ]] || fail "APK architecture mapping"
[[ "$(derive_kernel_flavor 'Firefly_RK3568.ROC-PC')" == sbc-firefly-rk3568-roc-pc ]] \
	|| fail "kernel flavor normalization"

for config in boards/*.config; do
	board="${config##*/}"
	board="${board%.config}"
	unset arch platform boot_mode bootargs bootloader_url bootloader_branch \
		bootloader_config kernel_url kernel_branch kernel_config dtb_name \
		rootfs_arch part_table boot_size kernel_flavor kernel_pkgrel initrd \
		kernel_firmware_packages serial_console serial_baud
	load_board_config "$board" >/dev/null
	# shellcheck disable=SC2154
	for required in arch platform boot_mode bootargs bootloader_url bootloader_branch \
		bootloader_config kernel_url kernel_branch kernel_config dtb_name rootfs_arch \
		part_table boot_size serial_console serial_baud; do
		[[ -n "${!required:-}" ]] || fail "$config does not define $required"
	done
	# shellcheck disable=SC2154
	[[ -f "configs/kernel/$kernel_config" ]] || fail "$config references missing $kernel_config"
	# shellcheck disable=SC2154
	[[ "$arch" == arm64 && "$rootfs_arch" == aarch64 ]] \
		|| fail "$config is not arm64/aarch64"
	# Values are supplied by the sourced board configuration.
	# shellcheck disable=SC2154
	[[ "$serial_baud" =~ ^[1-9][0-9]*$ ]] || fail "$config has an invalid serial_baud"
	# shellcheck disable=SC2154
	[[ "$bootargs" == *"console=$serial_console,"* ]] \
		|| fail "$config bootargs does not select $serial_console"
	for option in DEVTMPFS DEVTMPFS_MOUNT EXT4_FS; do
		rg -q "^CONFIG_${option}=y$" "configs/kernel/$kernel_config" \
			|| fail "$config kernel config is missing built-in CONFIG_${option}"
	done
	case "$serial_console" in
		ttyFIQ*) console_options=(FIQ_DEBUGGER_CONSOLE ROCKCHIP_FIQ_DEBUGGER) ;;
		ttyAML*) console_options=(SERIAL_MESON_CONSOLE) ;;
		ttySTM*) console_options=(SERIAL_STM32_CONSOLE) ;;
		ttyAMA*) console_options=(SERIAL_AMBA_PL011_CONSOLE) ;;
		ttyS*) console_options=(SERIAL_8250_CONSOLE) ;;
	esac
	for option in "${console_options[@]}"; do
		rg -q "^CONFIG_${option}=y$" "configs/kernel/$kernel_config" \
			|| fail "$config kernel config cannot drive $serial_console (CONFIG_${option})"
	done
	# Values are supplied by the sourced board configuration.
	# shellcheck disable=SC2154
	case "$boot_mode" in extlinux | grub) ;; *) fail "$config has unsupported boot_mode" ;; esac
	# shellcheck disable=SC2154
	if [[ "$boot_mode" == grub ]]; then
		[[ "$platform" == efi-arm64 ]] || fail "$config does not use the EFI platform"
		[[ "$part_table" == gpt ]] || fail "$config does not use GPT for EFI"
		[[ "${initrd:-}" == yes ]] || fail "$config does not enable an initramfs"
	fi
done

rg -q '^dtb_name="rockchip/rk3576-100ask-dshanpi-a1"$' \
	boards/100ask-dshanpi-a1.config || fail "DshanPi A1 does not select its RK3576 DTB"
rg -q '^rkbin_tpl_bin=".*rk3576_ddr_.*_v1\.08\.bin"$' \
	boards/100ask-dshanpi-a1.config || fail "DshanPi A1 does not pin RK3576 DDR v1.08"
rg -q '^rkbin_tpl_revision="[0-9a-f]{40}"$' boards/100ask-dshanpi-a1.config \
	|| fail "DshanPi A1 rkbin compatibility revision is not immutable"
for board_name in firefly-rk3566-roc-pc firefly-rk3568-roc-pc; do
	config="boards/$board_name.config"
	# shellcheck disable=SC1090
	source "$config"
	# Values are supplied by the sourced board configuration.
	# shellcheck disable=SC2154
	[[ -f "patches/u-boot/$bootloader_branch/$board_name/files/configs/$bootloader_config" ]] \
		|| fail "$config custom U-Boot defconfig overlay is missing"
done
[[ -f patches/u-boot/v2025.10/100ask-dshanpi-r1/files/configs/100ask-dshanpi-r1_defconfig ]] \
	|| fail "DshanPi R1 custom U-Boot defconfig is missing"
rg -q '^\+\+\+ b/configs/sakurapi_rk3308b_defconfig$' \
	patches/u-boot/v2025.04/sakurapi-rk3308b/patches/add-board-sakurapi-rk3308b.patch \
	|| fail "SakuraPi custom U-Boot defconfig patch is missing"

[[ -f boards/efi-arm64.config ]] || fail "efi-arm64 board configuration is missing"
for option in EFI EFI_STUB EFI_PARTITION ACPI PCI PCI_HOST_GENERIC VIRTIO VIRTIO_BLK VIRTIO_PCI \
	SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE DEVTMPFS DEVTMPFS_MOUNT; do
	rg -q "^CONFIG_${option}=y$" configs/kernel/linux-generic-arm64-lts.config \
		|| fail "generic arm64 kernel config is missing CONFIG_${option}=y"
done

# Render boot configurations without requiring root, loop devices, or GRUB.
# shellcheck source=scripts/libs/boot-config.sh
source "$project_root/scripts/libs/boot-config.sh"
boot_config_dir="$(mktemp -d)"
rendered_apkbuild=""
trap 'rm -f "${rendered_apkbuild:-}"; rm -rf "$boot_config_dir"' EXIT
KERNEL_FLAVOR="sbc-test-board"
bootargs="console=ttyS2,1500000 root=LABEL=rootfs rootwait rw"
dtb_name="rockchip/test-board"
initrd="yes"
generate_extlinux_config "$boot_config_dir"
rg -q '^\s+kernel /vmlinuz-sbc-test-board$' "$boot_config_dir/extlinux/extlinux.conf" \
	|| fail "extlinux config does not use the custom kernel"
rg -q '^\s+initrd /initramfs-sbc-test-board$' "$boot_config_dir/extlinux/extlinux.conf" \
	|| fail "extlinux config does not use the custom initramfs"
rg -q '^\s+fdt /dtbs-sbc-test-board/rockchip/test-board.dtb$' \
	"$boot_config_dir/extlinux/extlinux.conf" || fail "extlinux config does not use the board DTB"
rg -q '^\s+append console=ttyS2,1500000 root=LABEL=rootfs rootwait rw$' \
	"$boot_config_dir/extlinux/extlinux.conf" || fail "extlinux config loses board bootargs"

KERNEL_FLAVOR="sbc-efi-arm64"
bootargs="console=ttyAMA0,115200 root=LABEL=rootfs rw"
dtb_name="none"
initrd="yes"
generate_grub_config "$boot_config_dir"
generate_grub_early_config "$boot_config_dir/early.cfg"
rg -q '^    linux /vmlinuz-sbc-efi-arm64 console=ttyAMA0,115200 root=LABEL=rootfs rw$' \
	"$boot_config_dir/grub/grub.cfg" || fail "GRUB config does not use the custom kernel"
rg -q '^    initrd /initramfs-sbc-efi-arm64$' "$boot_config_dir/grub/grub.cfg" \
	|| fail "GRUB config does not use the custom initramfs"
rg -q '^set prefix=\(\$root\)/grub$' "$boot_config_dir/early.cfg" \
	|| fail "GRUB early config does not select the ESP configuration directory"

qemu_uboot_command="$(QEMU_BIN=/bin/true UBOOT_BIN=README.md \
	extra/scripts/run-qemu.sh --firmware u-boot --image README.md --dry-run)"
[[ "$qemu_uboot_command" == *'-bios README.md'* ]] \
	|| fail "QEMU U-Boot dry-run does not select the U-Boot firmware"
qemu_edk2_command="$(QEMU_BIN=/bin/true AAVMF_CODE=README.md AAVMF_VARS=README.md \
	extra/scripts/run-qemu.sh --firmware edk2 --image README.md --dry-run)"
[[ "$qemu_edk2_command" == *'if=pflash'* && "$qemu_edk2_command" == *'AAVMF_VARS.fd'* ]] \
	|| fail "QEMU EDK2 dry-run does not configure pflash firmware"

for placeholder in FLAVOR ABI_RELEASE PKGVER PKGREL BOARD KERNEL_URL APK_ARCH; do
	rg -q "@$placeholder@" packaging/kernel/APKBUILD.in \
		|| fail "APKBUILD template is missing @$placeholder@"
done

rendered_apkbuild="$(mktemp)"
sed \
	-e 's|@FLAVOR@|sbc-test-board|g' \
	-e 's|@ABI_RELEASE@|6.12.1-0-sbc-test-board|g' \
	-e 's|@PKGVER@|6.12.1|g' \
	-e 's|@PKGREL@|0|g' \
	-e 's|@BOARD@|test-board|g' \
	-e 's|@KERNEL_URL@|https://example.invalid/linux.git|g' \
	-e 's|@APK_ARCH@|aarch64|g' \
	packaging/kernel/APKBUILD.in > "$rendered_apkbuild"
bash -n "$rendered_apkbuild"
(
	pkgname=""
	subpackages=""
	depends=""
	_depends_dev=""
	# shellcheck disable=SC1090
	source "$rendered_apkbuild"
	[[ "$pkgname" == linux-sbc-test-board ]] || fail "rendered kernel package name"
	[[ "$subpackages" == *linux-sbc-test-board-dev:_dev* ]] || fail "rendered dev subpackage"
	[[ "$depends" == *initramfs-generator* ]] || fail "rendered initramfs dependency"
	[[ "$_depends_dev" == *linux-headers* ]] || fail "rendered linux-headers dependency"
)

for pattern in \
	'mkpart fsbla1 34s 545s' \
	'mkpart fsbla2 546s 1057s' \
	'mkpart fip 1058s 9249s' \
	'mkpart u-boot-env 9250s 10273s' \
	'19D5DF83-11B0-457B-BE2C-7559C13142A5' \
	'3DE21764-95DB-54BD-A5C3-4ABE786F38A8'; do
	rg -Fq "$pattern" scripts/mkimage.sh || fail "STM32MP2 layout is missing: $pattern"
done
rg -q 'of="\$stm32_fsbl_partition1"' scripts/libs/bootloader-install.sh \
	|| fail "STM32MP2 installer does not write FSBL copy 1"
rg -q 'of="\$stm32_fsbl_partition2"' scripts/libs/bootloader-install.sh \
	|| fail "STM32MP2 installer does not write FSBL copy 2"
rg -q 'of="\$stm32_fip_partition"' scripts/libs/bootloader-install.sh \
	|| fail "STM32MP2 installer does not write the non-FWU FIP"
rg -q 'PSA_FWU_SUPPORT=0' boards/myb-stm32mp257x-1GB.config \
	|| fail "STM32MP2 TF-A mode is ambiguous without an FWU metadata generator"
if rg -q 'mkpart (metadata[12]|fip-[ab])' scripts/mkimage.sh; then
	fail "STM32MP2 non-FWU image must not expose metadata or A/B FIP partitions"
fi
for payload in 'Secure Payload BL32 \(Trusted OS\)' \
	'Secure Payload BL32 Extra1 \(Trusted OS Extra1\)' \
	'Secure Payload BL32 Extra2 \(Trusted OS Extra2\)' \
	'Non-Trusted Firmware BL33'; do
	rg -q "$payload" scripts/libs/atf-compile.sh \
		|| fail "STM32MP2 FIP validation is missing $payload"
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git diff --check
fi
printf 'All static tests passed (%d scripts, %d boards).\n' \
	"${#scripts[@]}" "$(find boards -type f -name '*.config' | wc -l)"
