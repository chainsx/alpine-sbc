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
[[ -x extra/scripts/run-build-container.sh ]] || fail "Docker build entrypoint is not executable"
[[ -x extra/scripts/test-boot.sh ]] || fail "QEMU boot test entrypoint is not executable"

# shellcheck source=scripts/libs/common.sh
source "$project_root/scripts/libs/common.sh"
[[ "$(normalize_arch aarch64)" == arm64 ]] || fail "aarch64 normalization"
[[ "$(apk_arch_for_kernel_arch arm64)" == aarch64 ]] || fail "APK architecture mapping"
[[ "$(derive_kernel_flavor 'Firefly_RK3568.ROC-PC')" == sbc-firefly-rk3568-roc-pc ]] \
	|| fail "kernel flavor normalization"

declare -A kernel_group_signatures=()
declare -A kernel_group_boards=()

rg -q '(^|[[:space:]])gnutls-dev([[:space:]\\]|$)' build.sh \
	|| fail "host dependencies are missing gnutls-dev for U-Boot mkeficapsule"
rg -q '(^|[[:space:]])gawk([[:space:]\\]|$)' build.sh \
	|| fail "host dependencies are missing Alpine's U-Boot gawk dependency"
rg -q '(^|[[:space:]])util-linux-dev([[:space:]\\]|$)' build.sh \
	|| fail "host dependencies are missing Alpine's U-Boot util-linux-dev dependency"
rg -q '(^|[[:space:]])sgdisk([[:space:]\\]|$)' build.sh \
	|| fail "host dependencies are missing Alpine's standalone sgdisk package"
if rg -q '(^|[[:space:]])gptfdisk([[:space:]\\]|$)' build.sh; then
	fail "gptfdisk does not install its split sgdisk command subpackage"
fi
rg -Fq 'image_commands+=(sgdisk)' build.sh \
	|| fail "the early image-tool preflight does not require sgdisk for GPT"
rg -q '(^|[[:space:]])kmod([[:space:]\\]|$)' build.sh \
	|| fail "host dependencies are missing kmod for loop-device setup"
rg -q '^ensure_loop_device_nodes$' scripts/mkimage.sh \
	|| fail "image creation does not repair missing loop device nodes"
rg -Fq 'restore_block_device_node "$path"' scripts/mkimage.sh \
	|| fail "partition waits do not repair missing loop partition nodes"

for config in boards/*.config; do
	board="${config##*/}"
	board="${board%.config}"
	unset arch platform boot_mode bootargs bootloader_url bootloader_branch \
		bootloader bootloader_config atf_compile atf_url atf_branch atf_plat \
		atf_extra_config rkbin rkbin_tpl_bin rkbin_tpl_revision \
		amlogic_boot_fip stm32mp2_boot_fip optee_compile optee_url optee_branch \
		optee_extra_config soc kernel_url kernel_branch kernel_config dtb_name \
		rootfs_arch part_table kernel_group kernel_flavor kernel_pkgrel initrd \
		kernel_firmware_packages serial_console serial_baud serial_getty boot_timeout mdev_coldplug
	load_board_config "$board" >/dev/null
	# shellcheck disable=SC2154
	for required in arch platform bootloader boot_mode bootargs bootloader_url bootloader_branch \
		bootloader_config kernel_url kernel_branch kernel_config kernel_group kernel_flavor kernel_pkgrel \
		dtb_name rootfs_arch \
		part_table boot_size initrd serial_getty mdev_coldplug; do
		[[ -n "${!required:-}" ]] || fail "$config does not define $required"
	done
	# shellcheck disable=SC2154
	[[ -f "configs/kernel/$kernel_config" ]] || fail "$config references missing $kernel_config"
	[[ "$kernel_flavor" == "$(derive_kernel_flavor "$kernel_group")" ]] \
		|| fail "$config does not derive kernel_flavor from kernel_group"
	# shellcheck disable=SC2154
	[[ "$arch" == arm64 && "$rootfs_arch" == aarch64 ]] \
		|| fail "$config is not arm64/aarch64"
	case "$serial_getty" in
		yes)
		[[ -n "${serial_console:-}" && -n "${serial_baud:-}" ]] \
			|| fail "$config enables serial_getty without serial settings"
		# Values are supplied by the sourced board configuration.
		# shellcheck disable=SC2154
		[[ "$serial_baud" =~ ^[1-9][0-9]*$ ]] || fail "$config has an invalid serial_baud"
		# shellcheck disable=SC2154
		[[ "$bootargs" == *"console=$serial_console,"* ]] \
			|| fail "$config bootargs does not select $serial_console"
		;;
		no)
		[[ -z "${serial_console:-}" || "$serial_console" == none ]] \
			|| fail "$config disables serial_getty but defines serial_console"
		;;
		*) fail "$config has an invalid serial_getty" ;;
	esac
	[[ "$initrd" == yes ]] || fail "$config does not explicitly enable initrd"
	for option in BLK_DEV_INITRD RD_GZIP MODULES DEVTMPFS DEVTMPFS_MOUNT EXT4_FS; do
		rg -q "^CONFIG_${option}=y$" "configs/kernel/$kernel_config" \
			|| fail "$config kernel config is missing built-in CONFIG_${option}"
	done
	if [[ "$serial_getty" == yes ]]; then
		case "$serial_console" in
			ttyFIQ*) console_options=(FIQ_DEBUGGER_CONSOLE ROCKCHIP_FIQ_DEBUGGER) ;;
			ttyAML*) console_options=(SERIAL_MESON_CONSOLE) ;;
			ttySTM*) console_options=(SERIAL_STM32_CONSOLE) ;;
			ttyAMA*) console_options=(SERIAL_AMBA_PL011_CONSOLE) ;;
			ttyS*) console_options=(SERIAL_8250_CONSOLE) ;;
			*) fail "$config has an unsupported serial_console" ;;
			esac
		for option in "${console_options[@]}"; do
			rg -q "^CONFIG_${option}=y$" "configs/kernel/$kernel_config" \
				|| fail "$config kernel config cannot drive $serial_console (CONFIG_${option})"
		done
	fi
	# Values are supplied by the sourced board configuration.
	# shellcheck disable=SC2154
	case "$boot_mode" in extlinux | grub) ;; *) fail "$config has unsupported boot_mode" ;; esac
	case "$mdev_coldplug" in yes | no) ;; *) fail "$config has invalid mdev_coldplug" ;; esac
	if [[ "$platform" == qemu || "$platform" == efi-arm64 ]]; then
		[[ "$mdev_coldplug" == no ]] || fail "$config should skip mdev coldplug on a virtual board"
	else
		[[ "$mdev_coldplug" == yes ]] || fail "$config must retain mdev coldplug on a physical board"
	fi
	if [[ "$boot_mode" == extlinux ]]; then
		[[ -n "${boot_timeout:-}" ]] || fail "$config does not define boot_timeout"
		[[ "$boot_timeout" =~ ^[1-9][0-9]*$ ]] || fail "$config has an invalid boot_timeout"
	fi
	# shellcheck disable=SC2154
	if [[ "$boot_mode" == grub ]]; then
		[[ "$platform" == efi-arm64 ]] || fail "$config does not use the EFI platform"
		[[ "$part_table" == gpt ]] || fail "$config does not use GPT for EFI"
		[[ "$initrd" == yes ]] || fail "$config does not enable an initramfs"
	fi
	# shellcheck disable=SC2154
	signature="$kernel_url|$kernel_branch|$kernel_config|$kernel_pkgrel"
	if [[ -n "${kernel_group_signatures[$kernel_group]:-}" \
		&& "${kernel_group_signatures[$kernel_group]}" != "$signature" ]]; then
		fail "$config changes the source/configuration of shared kernel_group=$kernel_group"
	fi
	kernel_group_signatures[$kernel_group]="$signature"
	kernel_group_boards[$kernel_group]+=" $board"
done

[[ "${#kernel_group_signatures[@]}" -eq 5 ]] \
	|| fail "expected five explicit kernel groups for the supported boards"
[[ " ${kernel_group_boards[generic-arm64]} " == *" efi-arm64 "* \
	&& " ${kernel_group_boards[generic-arm64]} " == *" extlinux-arm64 "* ]] \
	|| fail "generic-arm64 must be shared by EFI and extlinux QEMU boards"
[[ " ${kernel_group_boards[rockchip64-bsp]} " == *" firefly-rk3588s-roc-pc "* ]] \
	|| fail "rockchip64-bsp group is missing a supported board"

if rg -n '(^|[[:space:]])loglevel=8([[:space:]]|")' boards/*.config; then
	fail "board bootargs retain the maximum kernel log level; use the default level to avoid unnecessary boot-time serial output"
fi

rg -q '^CONFIG_INITRAMFS_SOURCE=""$' configs/kernel/linux-generic-arm64-qemu.config \
	|| fail "generic arm64 kernel config retains a host-specific built-in initramfs path"
rg -Fq 'validate_gzip_initramfs "$rootfs_dir/boot/initramfs-$KERNEL_FLAVOR"' \
	scripts/mkimage.sh \
	|| fail "image creation does not inspect the initramfs before packaging"
rg -Fq "printf 'prompt 0\\n'" scripts/libs/boot-config.sh \
	|| fail "extlinux configuration does not disable the interactive prompt"
rg -Fq "printf 'timeout %s\\n\\n' \"\$timeout\"" scripts/libs/boot-config.sh \
	|| fail "extlinux configuration does not use the short boot timeout"
if rg -q 'Scanning hardware drivers|find /sys -name modalias' scripts/mkrootfs.sh; then
	fail "rootfs still performs the slow full /sys module scan at every boot"
fi
rg -q '^[[:space:]]*e2fsprogs-extra$' scripts/mkrootfs.sh \
	|| fail "rootfs does not provide fsck.ext4 for the enabled filesystem check"
rg -Fq 'if [[ "$serial_getty" == yes ]]' scripts/mkrootfs.sh \
	|| fail "rootfs serial getty policy is not explicit"
rg -Fq 'Skipping mdev coldplug and module scan' scripts/mkrootfs.sh \
	|| fail "rootfs does not expose the virtual-board mdev coldplug optimization"
rg -Fq 'rm -f "$rootfs/etc/init.d/modules" "$rootfs/etc/conf.d/modules"' scripts/mkrootfs.sh \
	|| fail "virtual-board rootfs does not mask OpenRC's indirect modules dependency"
rg -Fq -- "-name 'linux-sbc-*.apk' -delete" scripts/libs/kernel-pkg.sh \
	|| fail "kernel package staging does not remove stale per-board APKs"

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
	rg -q "^CONFIG_${option}=y$" configs/kernel/linux-generic-arm64-qemu.config \
		|| fail "generic arm64 kernel config is missing CONFIG_${option}=y"
done

# Render boot configurations without requiring root, loop devices, or GRUB.
# shellcheck source=scripts/libs/boot-config.sh
source "$project_root/scripts/libs/boot-config.sh"
boot_config_dir="$(mktemp -d)"
rendered_apkbuild=""
package_test_dir=""
manifest_test_dir=""
signing_test_dir=""
initramfs_test_dir=""
trap 'rm -f "${rendered_apkbuild:-}"; rm -rf "$boot_config_dir" \
	"${package_test_dir:-}" "${manifest_test_dir:-}" "${signing_test_dir:-}" \
	"${initramfs_test_dir:-}"' EXIT
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
	[[ "$subpackages" == *linux-headers:_headers* ]] || fail "rendered linux-headers subpackage"
	[[ "$depends" == *initramfs-generator* ]] || fail "rendered initramfs dependency"
	[[ "$_depends_dev" == *linux-headers=6.12.1-r0* ]] \
		|| fail "rendered linux-headers dependency is not version-locked"
)

# Exercise the generated package functions with the same initially absent
# pkgdir/subpkgdir state provided by abuild.
package_test_dir="$(mktemp -d)"
mkdir -p \
	"$package_test_dir/start/kernel-bin/lib/modules/6.12.1-0-sbc-test-board" \
	"$package_test_dir/start/kernel-dev-bin/usr/src/linux-headers-6.12.1-0-sbc-test-board" \
	"$package_test_dir/start/kernel-doc-bin/usr/share/doc/linux-test" \
	"$package_test_dir/start/kernel-headers-bin/usr/include/linux"
touch \
	"$package_test_dir/start/kernel-bin/kernel.marker" \
	"$package_test_dir/start/kernel-dev-bin/dev.marker" \
	"$package_test_dir/start/kernel-doc-bin/doc.marker"
printf '#define LINUX_VERSION_CODE 0\n' \
	> "$package_test_dir/start/kernel-headers-bin/usr/include/linux/version.h"
(
	# shellcheck disable=SC1090
	source "$rendered_apkbuild"
	# Consumed by the package functions loaded from the generated APKBUILD.
	# shellcheck disable=SC2034
	startdir="$package_test_dir/start"
	pkgdir="$package_test_dir/pkg/main"
	package
	[[ -f "$pkgdir/kernel.marker" ]] || fail "kernel package function did not populate pkgdir"
	subpkgdir="$package_test_dir/pkg/dev"
	_dev
	[[ -f "$subpkgdir/dev.marker" ]] || fail "kernel dev function did not populate subpkgdir"
	subpkgdir="$package_test_dir/pkg/doc"
	_doc
	[[ -f "$subpkgdir/doc.marker" ]] || fail "kernel doc function did not populate subpkgdir"
	subpkgdir="$package_test_dir/pkg/headers"
	_headers
	[[ -f "$subpkgdir/usr/include/linux/version.h" ]] \
		|| fail "linux-headers function did not populate subpkgdir"
)

rg -Fq 'make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch"' scripts/mklinux.sh \
	|| fail "linux-headers is not generated from the configured kernel build"
rg -Fq 'AWK="${AWK:-mawk}" headers' scripts/mklinux.sh \
	|| fail "linux-headers does not use the kernel headers target"
rg -Fq "find \"\$include_dir\" ! -iname '*.h' -type f -delete" scripts/mklinux.sh \
	|| fail "linux-headers does not purge non-header UAPI output"

# Exercise the cache validators used by all --skip-* build paths.
manifest_test_dir="$(mktemp -d)"
printf 'bootloader\n' > "$manifest_test_dir/u-boot.bin"
sha256sum "$manifest_test_dir/u-boot.bin" > "$manifest_test_dir/bootloader.sha256"
validate_bootloader_manifest "$manifest_test_dir/bootloader.sha256"
mkdir -p "$manifest_test_dir/repository"
printf 'index\n' > "$manifest_test_dir/repository/APKINDEX.tar.gz"
printf 'key\n' > "$manifest_test_dir/repository/alpine-sbc.rsa.pub"
for package_name in linux-sbc-test-board linux-sbc-test-board-dev \
	linux-sbc-test-board-doc linux-headers; do
	printf 'apk\n' > "$manifest_test_dir/repository/$package_name-6.12.1-r0.apk"
done
cat > "$manifest_test_dir/kernel-packages.env" <<EOF
KERNEL_PACKAGE='linux-sbc-test-board'
KERNEL_DEV_PACKAGE='linux-sbc-test-board-dev'
KERNEL_DOC_PACKAGE='linux-sbc-test-board-doc'
KERNEL_HEADERS_PACKAGE='linux-headers'
KERNEL_GROUP='test-board'
KERNEL_FLAVOR='sbc-test-board'
KERNEL_PKGVER='6.12.1'
KERNEL_PKGREL='0'
KERNEL_ABI_RELEASE='6.12.1-0-sbc-test-board'
KERNEL_REPOSITORY='$manifest_test_dir/repository'
KERNEL_PUBLIC_KEY='$manifest_test_dir/repository/alpine-sbc.rsa.pub'
EOF
kernel_group="test-board"
load_kernel_package_manifest "$manifest_test_dir/kernel-packages.env" sbc-test-board
[[ "$KERNEL_ABI_RELEASE" == 6.12.1-0-sbc-test-board ]] \
	|| fail "kernel package manifest did not export the validated ABI release"
mkdir -p "$manifest_test_dir/rootfs"
stage_apk_repository "$manifest_test_dir/repository" "$manifest_test_dir/rootfs" \
	/tmp/alpine-sbc-repository aarch64
for repository_file in APKINDEX.tar.gz linux-sbc-test-board-6.12.1-r0.apk \
	linux-headers-6.12.1-r0.apk; do
	[[ -s "$manifest_test_dir/rootfs/tmp/alpine-sbc-repository/aarch64/$repository_file" ]] \
		|| fail "staged APK repository is missing aarch64/$repository_file"
done
rg -Fq -- '--repository "$rootfs_kernel_repository"' scripts/mkrootfs.sh \
	|| fail "rootfs package installation does not use the staged repository root"
rg -Fq '"$KERNEL_HEADERS_PACKAGE=$KERNEL_PKGVER-r$KERNEL_PKGREL"' scripts/mkrootfs.sh \
	|| fail "rootfs does not install the exact generated linux-headers version"

# abuild's automatic repository-index update verifies the newly signed APKs.
# Exercise the same key derivation and trust installation used by kernel-pkg.sh.
signing_test_dir="$(mktemp -d)"
openssl genrsa -out "$signing_test_dir/test.rsa" 2048 >/dev/null 2>&1
prepare_apk_signing_key "$signing_test_dir/test.rsa" \
	"$signing_test_dir/test.rsa.pub" "$signing_test_dir/trusted"
cmp -s "$signing_test_dir/test.rsa.pub" "$signing_test_dir/trusted/test.rsa.pub" \
	|| fail "APK signing public key was not installed into the trust directory"
rg -Fq 'prepare_apk_signing_key "$private_key" "$public_key" /etc/apk/keys' \
	scripts/libs/kernel-pkg.sh \
	|| fail "kernel package builder does not trust its signing key before abuild"

if command -v cpio >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
	initramfs_test_dir="$(mktemp -d)"
	mkdir -p "$initramfs_test_dir/tree"
	printf '#!/bin/sh\nexec /sbin/init\n' > "$initramfs_test_dir/tree/init"
	chmod 755 "$initramfs_test_dir/tree/init"
	(
		cd "$initramfs_test_dir/tree"
		find . -print | cpio -o -H newc 2>/dev/null | gzip -9 \
			> "$initramfs_test_dir/initramfs.gz"
	)
	validate_gzip_initramfs "$initramfs_test_dir/initramfs.gz"
fi

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
