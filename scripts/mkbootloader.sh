#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: scripts/mkbootloader.sh --board NAME [--jobs N] [--force-fetch]

Fetch, patch, and build U-Boot plus board-specific firmware components.
EOF
}

board=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
force_fetch=0
arch=""
bootloader_url=""
bootloader_branch=""
bootloader_config=""
while (($#)); do
	case "$1" in
		--board | --jobs)
			require_arg_value "$1" "${2:-}"
			case "$1" in --board) board="$2" ;; --jobs) jobs="$2" ;; esac
			shift 2
			;;
		--force-fetch) force_fetch=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ -n "$board" ]] || die "--board is required."
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer."

init_logging bootloader
enable_error_trap
load_board_config "$board"
require_board_variables arch platform bootloader_url bootloader_branch bootloader_config
[[ "$(normalize_arch "$arch")" == arm64 ]] || die "Only arm64 bootloader targets are supported."
[[ "$(normalize_arch "$(uname -m)")" == arm64 ]] || die "Bootloader builds require an arm64 host."
require_commands find git make gcc python3 sha256sum sort

# Compatibility variables used by the sourced board-support libraries.
# shellcheck disable=SC2034
src_dir="$PROJECT_ROOT"
# shellcheck disable=SC2034
work_dir="$WORK_DIR"
# shellcheck disable=SC2034
log_dir="$LOG_DIR"

uboot_dir="$WORK_DIR/u-boot"
source_state="$uboot_dir/.alpine-sbc-source"
patch_root="$PROJECT_ROOT/patches/u-boot/$bootloader_branch"
expected_state="url=$bootloader_url
ref=$bootloader_branch
board=$board
patches=$(tree_fingerprint "$patch_root")"

fetch_uboot() {
	local replace=0
	if (( force_fetch )); then
		replace=1
	elif [[ -d "$uboot_dir" ]] && { [[ ! -f "$source_state" ]] \
		|| [[ "$(cat "$source_state")" != "$expected_state" ]]; }; then
		replace=1
	fi
	if (( replace )); then safe_remove_tree "$uboot_dir"; fi
	if [[ ! -d "$uboot_dir" ]]; then
		log_info "Cloning U-Boot '$bootloader_branch' from $bootloader_url"
		git clone --depth=1 --branch "$bootloader_branch" "$bootloader_url" "$uboot_dir"
	else
		log_info "Using cached U-Boot source: $uboot_dir"
	fi
}

apply_patch_directory() {
	local directory="$1" patch
	[[ -d "$directory" ]] || return 0
	while IFS= read -r -d '' patch; do
		log_info "Applying U-Boot patch: ${patch#"$PROJECT_ROOT"/}"
		git -C "$uboot_dir" apply --whitespace=nowarn "$patch"
	done < <(find "$directory" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
}

patch_uboot() {
	[[ -f "$source_state" ]] && return 0
	apply_patch_directory "$patch_root/generic/patches"
	copy_tree_contents "$patch_root/generic/files" "$uboot_dir"
	apply_patch_directory "$patch_root/$board/patches"
	copy_tree_contents "$patch_root/$board/files" "$uboot_dir"
	printf '%s\n' "$expected_state" > "$source_state"
}

fetch_uboot
patch_uboot

uboot_extra_config="${uboot_extra_config:-}"
if [[ "${atf_compile:-no}" == no && "${rkbin:-no}" == yes ]]; then
	# shellcheck source=scripts/libs/rkbin-version.sh
	source "$PROJECT_ROOT/scripts/libs/rkbin-version.sh"
	fetch_rkbin
	# shellcheck disable=SC2154
	uboot_extra_config="ROCKCHIP_TPL=$WORK_DIR/rkbin/$tpl_bin BL31=$WORK_DIR/rkbin/$atf_bin"
fi

if [[ "${atf_compile:-no}" == yes ]]; then
	# shellcheck source=scripts/libs/atf-compile.sh
	source "$PROJECT_ROOT/scripts/libs/atf-compile.sh"
	fetch_atf
	[[ -f "$WORK_DIR/atf-src/.patched" ]] || patch_atf
	compile_atf
fi

log_info "Configuring U-Boot with $bootloader_config"
make -C "$uboot_dir" "$bootloader_config"
# Board configuration values are trusted make assignments, intentionally split.
# shellcheck disable=SC2086
make -C "$uboot_dir" -j"$jobs" $uboot_extra_config

if [[ "${optee_compile:-no}" == yes ]]; then
	# shellcheck source=scripts/libs/optee-compile.sh
	source "$PROJECT_ROOT/scripts/libs/optee-compile.sh"
	fetch_optee
	compile_optee
fi

if [[ "${atf_compile:-no}" == yes && "${stm32mp2_boot_fip:-no}" == yes ]]; then
	mk_stm32mp2_boot_fip
fi
if [[ "${atf_compile:-no}" == no && "${amlogic_boot_fip:-no}" == yes ]]; then
	# shellcheck source=scripts/libs/amlogic-boot-fip.sh
	source "$PROJECT_ROOT/scripts/libs/amlogic-boot-fip.sh"
	fetch_aml_fip
	mk_amlogic_fip
fi

log_info "Bootloader build complete: $uboot_dir"
