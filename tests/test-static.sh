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
		rootfs_arch part_table boot_size kernel_flavor kernel_pkgrel
	load_board_config "$board" >/dev/null
	# shellcheck disable=SC2154
	for required in arch platform boot_mode bootargs bootloader_url bootloader_branch \
		bootloader_config kernel_url kernel_branch kernel_config dtb_name rootfs_arch \
		part_table boot_size; do
		[[ -n "${!required:-}" ]] || fail "$config does not define $required"
	done
	# shellcheck disable=SC2154
	[[ -f "configs/kernel/$kernel_config" ]] || fail "$config references missing $kernel_config"
	# shellcheck disable=SC2154
	[[ "$arch" == arm64 && "$rootfs_arch" == aarch64 ]] \
		|| fail "$config is not arm64/aarch64"
done

for placeholder in FLAVOR ABI_RELEASE PKGVER PKGREL BOARD KERNEL_URL APK_ARCH; do
	rg -q "@$placeholder@" packaging/kernel/APKBUILD.in \
		|| fail "APKBUILD template is missing @$placeholder@"
done

rendered_apkbuild="$(mktemp)"
trap 'rm -f "$rendered_apkbuild"' EXIT
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

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git diff --check
fi
printf 'All static tests passed (%d scripts, %d boards).\n' \
	"${#scripts[@]}" "$(find boards -type f -name '*.config' | wc -l)"
