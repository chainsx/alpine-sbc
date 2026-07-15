#!/usr/bin/env bash

# Shared helpers for all alpine-sbc entry points.  Do not enable shell options
# here: this file is also sourced by small board-support libraries.

if [[ -n "${ALPINE_SBC_COMMON_LOADED:-}" ]]; then
	return 0
fi
readonly ALPINE_SBC_COMMON_LOADED=1

if [[ -z "${PROJECT_ROOT:-}" ]]; then
	PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/build}"
LOG_DIR="${LOG_DIR:-$WORK_DIR/log}"

_color_enabled=0
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	_color_enabled=1
fi

_log() {
	local level="$1" color="$2"
	shift 2
	if (( _color_enabled )); then
		printf '\033[%sm[%s] %s %s\033[0m\n' "$color" "$level" \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
	else
		printf '[%s] %s %s\n' "$level" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
	fi
}

log_info() { _log INFO 32 "$@"; }
log_warn() { _log WARN 33 "$@"; }
log_error() { _log ERROR 31 "$@"; }
log_debug() {
	[[ "${ALPINE_SBC_DEBUG:-0}" == 1 ]] || return 0
	_log DEBUG 36 "$@"
}

die() {
	log_error "$*"
	exit 1
}

init_logging() {
	local stage="${1:-build}"
	mkdir -p "$LOG_DIR"
	if [[ -z "${ALPINE_SBC_LOG_FILE:-}" ]]; then
		ALPINE_SBC_LOG_FILE="$LOG_DIR/${stage}-$(date -u '+%Y%m%dT%H%M%SZ').log"
		export ALPINE_SBC_LOG_FILE
		exec > >(tee -a "$ALPINE_SBC_LOG_FILE") 2>&1
	fi
	log_info "Log file: $ALPINE_SBC_LOG_FILE"
}

_handle_error() {
	local rc="$1" line="$2" command="$3"
	log_error "Command failed (exit $rc) at ${BASH_SOURCE[1]}:$line: $command"
	exit "$rc"
}

enable_error_trap() {
	trap '_handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

require_root() {
	(( EUID == 0 )) || die "This operation requires root privileges (run with sudo)."
}

normalize_arch() {
	case "$1" in
		aarch64 | arm64) printf '%s\n' arm64 ;;
		x86_64 | amd64) printf '%s\n' x86_64 ;;
		*) printf '%s\n' "$1" ;;
	esac
}

apk_arch_for_kernel_arch() {
	case "$1" in
		arm64 | aarch64) printf '%s\n' aarch64 ;;
		*) printf '%s\n' "$1" ;;
	esac
}

require_alpine_arm64_host() {
	[[ -r /etc/os-release ]] || die "Cannot identify the host operating system."
	local id
	# shellcheck disable=SC1091
	id="$(. /etc/os-release; printf '%s' "${ID:-}")"
	[[ "$id" == alpine ]] || die "The supported build host is Alpine Linux; detected '$id'."
	local host_arch
	host_arch="$(normalize_arch "$(uname -m)")"
	[[ "$host_arch" == arm64 ]] || die "The supported build host architecture is arm64; detected '$host_arch'."
}

require_commands() {
	local cmd missing=()
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}"
}

require_arg_value() {
	local option="$1" value="${2:-}"
	[[ -n "$value" && "$value" != --* ]] || die "Option $option requires a value."
}

validate_board_name() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid board name: $1"
}

derive_kernel_flavor() {
	local name="$1"
	name="${name,,}"
	name="${name//_/-}"
	name="${name//./-}"
	name="${name//[^a-z0-9-]/-}"
	while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
	printf 'sbc-%s\n' "${name#-}"
}

load_board_config() {
	local requested_board="$1"
	validate_board_name "$requested_board"
	local config="$PROJECT_ROOT/boards/$requested_board.config"
	[[ -f "$config" ]] || die "Board configuration not found: $config"
	board="$requested_board"
	# shellcheck disable=SC1090
	source "$config"
	validate_board_config
	log_info "Loaded board configuration: $board ($config)"
}

require_board_variables() {
	local name missing=()
	for name in "$@"; do
		[[ -n "${!name:-}" ]] || missing+=("$name")
	done
	((${#missing[@]} == 0)) || die "Board '$board' is missing required settings: ${missing[*]}"
}

# Board fields are populated dynamically by the sourced configuration file.
# shellcheck disable=SC2154
validate_board_config() {
	require_board_variables \
		arch platform bootloader boot_mode bootargs \
		bootloader_url bootloader_branch bootloader_config atf_compile \
		kernel_url kernel_branch kernel_config kernel_flavor kernel_pkgrel \
		dtb_name initrd rootfs_arch part_table boot_size serial_console serial_baud

	[[ "$(normalize_arch "$arch")" == arm64 ]] \
		|| die "Board '$board' must use arch=arm64."
	[[ "$rootfs_arch" == aarch64 ]] \
		|| die "Board '$board' must use rootfs_arch=aarch64."
	[[ "$bootloader" == u-boot ]] \
		|| die "Board '$board' selects unsupported bootloader '$bootloader'."
	[[ -f "$PROJECT_ROOT/configs/kernel/$kernel_config" ]] \
		|| die "Board '$board' references missing kernel config: $kernel_config"
	[[ "$kernel_pkgrel" =~ ^[0-9]+$ ]] \
		|| die "Board '$board' has invalid kernel_pkgrel '$kernel_pkgrel'."

	case "$platform" in
		qemu | efi-arm64 | rockchip64 | amlogic | stm32mp2 | allwinner | phytium) ;;
		*) die "Board '$board' selects unsupported platform '$platform'." ;;
	esac
	case "$boot_mode" in
		extlinux | grub) ;;
		*) die "Board '$board' has unsupported boot_mode '$boot_mode'." ;;
	esac
	[[ "$initrd" == yes ]] \
		|| die "Board '$board' must explicitly set initrd=yes."
	case "$part_table" in
		gpt | msdos) ;;
		*) die "Board '$board' has unsupported part_table '$part_table'." ;;
	esac
	[[ "$boot_size" =~ ^[1-9][0-9]*$ ]] \
		|| die "Board '$board' has invalid boot_size '$boot_size'."
	(( boot_size >= 64 )) \
		|| die "Board '$board' boot_size must be at least 64 MiB."
	[[ "$serial_console" =~ ^[A-Za-z0-9._-]+$ ]] \
		|| die "Board '$board' has invalid serial_console '$serial_console'."
	[[ "$serial_baud" =~ ^[1-9][0-9]*$ ]] \
		|| die "Board '$board' has invalid serial_baud '$serial_baud'."
	[[ " $bootargs " == *" console=$serial_console,$serial_baud "* ]] \
		|| die "Board '$board' bootargs do not contain console=$serial_console,$serial_baud."
	[[ " $bootargs " == *' root=LABEL=rootfs '* ]] \
		|| die "Board '$board' bootargs must select root=LABEL=rootfs."

	for flag in atf_compile rkbin optee_compile amlogic_boot_fip stm32mp2_boot_fip; do
		case "${!flag:-no}" in
			yes | no) ;;
			*) die "Board '$board' has invalid $flag='${!flag}'. Use yes or no." ;;
		esac
	done

	if [[ "$boot_mode" == grub && "$platform" != efi-arm64 ]]; then
		die "Board '$board' may use GRUB only with platform=efi-arm64."
	fi
	case "$platform" in
		qemu)
			[[ "$boot_mode" == extlinux && "$part_table" == gpt && "$dtb_name" == none ]] \
				|| die "QEMU extlinux board '$board' requires extlinux, GPT, and dtb_name=none."
			;;
		efi-arm64)
			[[ "$boot_mode" == grub && "$part_table" == gpt && "$dtb_name" == none ]] \
				|| die "EFI board '$board' requires GRUB, GPT, and dtb_name=none."
			;;
		rockchip64)
			require_board_variables soc rkbin
			[[ "$boot_mode" == extlinux ]] \
				|| die "Rockchip board '$board' requires boot_mode=extlinux."
			[[ "$rkbin" == yes || "$atf_compile" == yes ]] \
				|| die "Rockchip board '$board' requires rkbin=yes or atf_compile=yes."
			;;
		amlogic)
			require_board_variables soc amlogic_boot_fip
			[[ "$boot_mode" == extlinux && "$amlogic_boot_fip" == yes ]] \
				|| die "Amlogic board '$board' requires extlinux and amlogic_boot_fip=yes."
			;;
		stm32mp2)
			require_board_variables soc atf_url atf_branch atf_plat stm32mp2_boot_fip \
				optee_compile optee_url optee_branch
			[[ "$boot_mode" == extlinux && "$part_table" == gpt ]] \
				|| die "STM32MP2 board '$board' requires extlinux and GPT."
			[[ "$atf_compile" == yes && "$optee_compile" == yes \
				&& "$stm32mp2_boot_fip" == yes ]] \
				|| die "STM32MP2 board '$board' requires TF-A, OP-TEE, and FIP generation."
			;;
	esac

	if [[ "$atf_compile" == yes ]]; then
		require_board_variables atf_url atf_branch atf_plat
	fi
	if [[ "${optee_compile:-no}" == yes ]]; then
		require_board_variables optee_url optee_branch
		[[ "$atf_compile" == yes ]] \
			|| die "Board '$board' enables OP-TEE without TF-A integration."
	fi
	if [[ "${rkbin:-no}" == yes && "$platform" != rockchip64 ]]; then
		die "Board '$board' enables rkbin outside the Rockchip platform."
	fi

	log_debug "Validated board configuration contract: $board"
}

validate_bootloader_manifest() {
	local manifest="$1"
	[[ -s "$manifest" ]] \
		|| die "Bootloader artifact manifest is missing or empty: $manifest"
	sha256sum -c "$manifest" >/dev/null \
		|| die "One or more cached bootloader artifacts failed checksum validation."
	log_info "Validated cached bootloader artifacts: $manifest"
}

load_kernel_package_manifest() {
	local manifest="${1:-$WORK_DIR/packages/kernel-packages.env}"
	local expected_flavor="${2:-${kernel_flavor:-}}"
	local variable package_name package_path
	[[ -s "$manifest" ]] \
		|| die "Kernel package manifest is missing or empty: $manifest"

	# Clear all exported values first so an incomplete manifest cannot inherit
	# metadata from an earlier load in the same process.
	KERNEL_PACKAGE=""
	KERNEL_DEV_PACKAGE=""
	KERNEL_DOC_PACKAGE=""
	KERNEL_HEADERS_PACKAGE=""
	KERNEL_FLAVOR=""
	KERNEL_PKGVER=""
	KERNEL_PKGREL=""
	# Consumed by callers after this helper returns.
	# shellcheck disable=SC2034
	KERNEL_ABI_RELEASE=""
	KERNEL_REPOSITORY=""
	KERNEL_PUBLIC_KEY=""
	# This file is generated locally by kernel-pkg.sh and contains only quoted
	# scalar assignments.
	# shellcheck disable=SC1090
	source "$manifest"

	for variable in KERNEL_PACKAGE KERNEL_DEV_PACKAGE KERNEL_DOC_PACKAGE \
		KERNEL_HEADERS_PACKAGE \
		KERNEL_FLAVOR KERNEL_PKGVER KERNEL_PKGREL KERNEL_ABI_RELEASE \
		KERNEL_REPOSITORY KERNEL_PUBLIC_KEY; do
		[[ -n "${!variable:-}" ]] \
			|| die "Kernel package manifest does not define $variable: $manifest"
	done
	[[ -z "$expected_flavor" || "$KERNEL_FLAVOR" == "$expected_flavor" ]] \
		|| die "Kernel packages for '$KERNEL_FLAVOR' do not match '$expected_flavor'."
	[[ "$KERNEL_PACKAGE" == "linux-$KERNEL_FLAVOR" \
		&& "$KERNEL_DEV_PACKAGE" == "linux-$KERNEL_FLAVOR-dev" \
		&& "$KERNEL_DOC_PACKAGE" == "linux-$KERNEL_FLAVOR-doc" \
		&& "$KERNEL_HEADERS_PACKAGE" == linux-headers ]] \
		|| die "Kernel package names are inconsistent in $manifest"
	[[ "$KERNEL_PKGREL" =~ ^[0-9]+$ ]] \
		|| die "Kernel package manifest has invalid KERNEL_PKGREL='$KERNEL_PKGREL'."
	[[ -s "$KERNEL_REPOSITORY/APKINDEX.tar.gz" ]] \
		|| die "Signed kernel repository index is missing: $KERNEL_REPOSITORY/APKINDEX.tar.gz"
	[[ -s "$KERNEL_PUBLIC_KEY" ]] \
		|| die "Kernel repository public key is missing: $KERNEL_PUBLIC_KEY"

	for package_name in "$KERNEL_PACKAGE" "$KERNEL_DEV_PACKAGE" \
		"$KERNEL_DOC_PACKAGE" "$KERNEL_HEADERS_PACKAGE"; do
		package_path="$KERNEL_REPOSITORY/$package_name-$KERNEL_PKGVER-r$KERNEL_PKGREL.apk"
		[[ -s "$package_path" ]] || die "Kernel package is missing or empty: $package_path"
	done
	log_info "Validated kernel package repository for $KERNEL_FLAVOR"
}

stage_apk_repository() {
	local source_repository="$1" rootfs="$2" repository_root="$3" repository_arch="$4"
	local destination packages=("$source_repository"/*.apk)
	[[ "$repository_root" == /* && "$repository_root" != / ]] \
		|| die "APK repository root must be an absolute path below /: $repository_root"
	[[ "$repository_arch" =~ ^[A-Za-z0-9._-]+$ ]] \
		|| die "Invalid APK repository architecture: $repository_arch"
	[[ -s "$source_repository/APKINDEX.tar.gz" && -e "${packages[0]}" ]] \
		|| die "Source APK repository is incomplete: $source_repository"
	destination="$rootfs${repository_root%/}/$repository_arch"
	mkdir -p "$destination"
	cp "$source_repository/APKINDEX.tar.gz" "${packages[@]}" "$destination/"
	log_info "Staged APK repository: ${repository_root%/}/$repository_arch"
}

validate_gzip_initramfs() {
	local archive="$1"
	[[ -s "$archive" ]] || die "Initramfs is missing or empty: $archive"
	gzip -t "$archive" || die "Initramfs is not a valid gzip stream: $archive"
	if ! gzip -dc "$archive" \
		| cpio -t 2>/dev/null \
		| awk '$0 == "init" || $0 == "./init" { found = 1 } END { exit !found }'; then
		die "Initramfs does not contain the required /init program: $archive"
	fi
	log_info "Validated gzip initramfs with /init: $archive"
}

prepare_apk_signing_key() {
	local private_key="$1" public_key="$2" trusted_keys_dir="$3"
	local temporary_public_key="${public_key}.tmp.$$"
	local trusted_public_key="$trusted_keys_dir/${public_key##*/}"
	[[ -s "$private_key" ]] || die "APK signing private key is missing or empty: $private_key"
	chmod 600 "$private_key"
	openssl rsa -in "$private_key" -check -noout >/dev/null 2>&1 \
		|| die "APK signing private key is invalid: $private_key"
	if ! openssl rsa -in "$private_key" -pubout -out "$temporary_public_key"; then
		rm -f "$temporary_public_key"
		die "Could not derive the APK public key from $private_key"
	fi
	chmod 644 "$temporary_public_key"
	mv -f "$temporary_public_key" "$public_key"
	install -Dm644 "$public_key" "$trusted_public_key"
	cmp -s "$public_key" "$trusted_public_key" \
		|| die "APK public key installation failed: $trusted_public_key"
	log_info "Trusted APK signing key installed: $trusted_public_key"
}

safe_remove_tree() {
	local path="$1"
	[[ -n "$path" && "$path" == "$WORK_DIR"/* && "$path" != "$WORK_DIR" ]] \
		|| die "Refusing to remove unsafe path: $path"
	rm -rf -- "$path"
}

tree_fingerprint() {
	local path="$1"
	if [[ ! -d "$path" ]]; then
		printf '%s\n' none
		return
	fi
	find "$path" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null \
		| sha256sum | awk '{print $1}'
}

copy_tree_contents() {
	local source_dir="$1" destination_dir="$2"
	[[ -d "$source_dir" ]] || return 0
	mkdir -p "$destination_dir"
	cp -a "$source_dir"/. "$destination_dir"/
}
