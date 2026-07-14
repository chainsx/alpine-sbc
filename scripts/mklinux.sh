#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: scripts/mklinux.sh --board NAME [options]

Fetch, patch, configure, and compile a board kernel.  The output is staged in
the same layout used by Alpine's linux-* APKBUILD, including the external
module development tree used by linux-<flavor>-dev.

Options:
  --board NAME          Board configuration name
  --jobs N              Parallel jobs (default: number of CPUs)
  --force-fetch         Replace the cached kernel checkout
  --kernel-arch ARCH    Override board kernel architecture
  --kernel-url URL      Override board kernel repository
  --kernel-branch REF   Override board branch/tag
  --kernel-config FILE  Override board kernel config filename
  -h, --help            Show this help
EOF
}

board=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
force_fetch=0
override_arch=""
override_url=""
override_branch=""
override_config=""
kernel_flavor=""
kernel_pkgrel=""

while (($#)); do
	case "$1" in
		--board | --jobs | --kernel-arch | --kernel_arch | --kernel-url | --kernel_url | \
		--kernel-branch | --kernel_branch | --kernel-config | --kernel_config)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--board) board="$2" ;;
				--jobs) jobs="$2" ;;
				--kernel-arch | --kernel_arch) override_arch="$2" ;;
				--kernel-url | --kernel_url) override_url="$2" ;;
				--kernel-branch | --kernel_branch) override_branch="$2" ;;
				--kernel-config | --kernel_config) override_config="$2" ;;
			esac
			shift 2
			;;
		--force-fetch) force_fetch=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$board" ]] || die "--board is required."
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer."

init_logging kernel
enable_error_trap
load_board_config "$board"

kernel_arch="${override_arch:-${arch:-}}"
kernel_url="${override_url:-${kernel_url:-}}"
kernel_branch="${override_branch:-${kernel_branch:-}}"
kernel_config="${override_config:-${kernel_config:-}}"
require_board_variables kernel_arch kernel_url kernel_branch kernel_config kernel_flavor kernel_pkgrel

kernel_arch="$(normalize_arch "$kernel_arch")"
[[ "$kernel_arch" == arm64 ]] || die "Only arm64 kernels are supported; requested '$kernel_arch'."
host_arch="$(normalize_arch "$(uname -m)")"
[[ "$host_arch" == arm64 ]] || die "Native arm64 kernel builds require an arm64 host; detected '$host_arch'."

require_commands git make gcc mawk openssl cpio find sha256sum sort

kernel_src="$WORK_DIR/linux-src"
kernel_build="$WORK_DIR/linux-build/$kernel_flavor"
package_stage="$WORK_DIR/kernel-pkg/kernel-bin"
dev_stage="$WORK_DIR/kernel-pkg/kernel-dev-bin"
doc_stage="$WORK_DIR/kernel-pkg/kernel-doc-bin"
config_path="$PROJECT_ROOT/configs/kernel/$kernel_config"
source_state="$kernel_src/.alpine-sbc-source"

[[ -f "$config_path" ]] || die "Kernel config not found: $config_path"

patch_root="$PROJECT_ROOT/patches/kernel/$kernel_branch"
patch_fingerprint="$(tree_fingerprint "$patch_root")"
expected_state="url=$kernel_url
ref=$kernel_branch
board=$board
patches=$patch_fingerprint"

fetch_kernel() {
	local replace=0
	if (( force_fetch )); then
		replace=1
	elif [[ -d "$kernel_src" ]]; then
		if [[ ! -f "$source_state" ]] || [[ "$(cat "$source_state")" != "$expected_state" ]]; then
			log_warn "Cached kernel source does not match the requested source or patches"
			replace=1
		fi
	fi

	if (( replace )); then
		safe_remove_tree "$kernel_src"
		safe_remove_tree "$kernel_build"
	fi

	if [[ ! -d "$kernel_src" ]]; then
		log_info "Cloning kernel '$kernel_branch' from $kernel_url"
		git clone --depth=1 --branch "$kernel_branch" "$kernel_url" "$kernel_src"
	else
		log_info "Using cached kernel source: $kernel_src"
	fi
}

apply_patch_directory() {
	local directory="$1" patch
	[[ -d "$directory" ]] || return 0
	while IFS= read -r -d '' patch; do
		log_info "Applying kernel patch: ${patch#"$PROJECT_ROOT"/}"
		git -C "$kernel_src" apply --whitespace=nowarn "$patch"
	done < <(find "$directory" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
}

apply_kernel_changes() {
	[[ -f "$source_state" ]] && return 0
	apply_patch_directory "$patch_root/patches"
	copy_tree_contents "$patch_root/files" "$kernel_src"
	apply_patch_directory "$patch_root/generic/patches"
	copy_tree_contents "$patch_root/generic/files" "$kernel_src"
	apply_patch_directory "$patch_root/$board/patches"
	copy_tree_contents "$patch_root/$board/files" "$kernel_src"
	printf '%s\n' "$expected_state" > "$source_state"
}

configure_kernel() {
	mkdir -p "$kernel_build"
	printf -- '-%s-%s\n' "$kernel_pkgrel" "$kernel_flavor" > "$kernel_build/localversion-alpine"
	cp "$config_path" "$kernel_build/.config"

	# Git checkouts otherwise append a commit suffix when a vendor config enables
	# CONFIG_LOCALVERSION_AUTO.  Alpine's source-tarball build has no such suffix.
	if [[ -x "$kernel_src/scripts/config" ]]; then
		"$kernel_src/scripts/config" --file "$kernel_build/.config" \
			--set-str LOCALVERSION '' --disable LOCALVERSION_AUTO
	fi

	if [[ -n "${KERNEL_SIGNING_KEY:-}" && -f "${KERNEL_SIGNING_KEY:-}" ]]; then
		"$kernel_src/scripts/config" --file "$kernel_build/.config" \
			--enable MODULE_SIG --set-str MODULE_SIG_KEY "$KERNEL_SIGNING_KEY"
	fi

	log_info "Configuring $kernel_flavor with $kernel_config"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" olddefconfig
}

build_kernel() {
	local source_epoch
	source_epoch="$(git -C "$kernel_src" log -1 --format=%ct 2>/dev/null || date +%s)"
	export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$source_epoch}"
	export KBUILD_BUILD_TIMESTAMP
	KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
		|| date -u '+%Y-%m-%d %H:%M:%S')"
	unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS

	log_info "Building Linux kernel with $jobs jobs"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" CC="${CC:-gcc}" \
		KBUILD_BUILD_VERSION="$((kernel_pkgrel + 1))-Alpine" -j"$jobs"

	if grep -q '^CONFIG_DEBUG_INFO_BTF=y' "$kernel_build/.config"; then
		require_commands bpftool
		log_info "Generating vmlinux.h from kernel BTF data"
		bpftool btf dump file "$kernel_build/vmlinux" format c > "$kernel_build/vmlinux.h"
	fi
}

stage_kernel_package() {
	local abi_release="$1"
	safe_remove_tree "$package_stage"
	mkdir -p "$package_stage/boot" "$package_stage/lib/modules"

	log_info "Installing kernel modules into package staging"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" INSTALL_MOD_PATH="$package_stage" \
		INSTALL_MOD_STRIP=1 DEPMOD=true modules_install

	rm -f "$package_stage/lib/modules/$abi_release/build" \
		"$package_stage/lib/modules/$abi_release/source"
	rm -rf "$package_stage/lib/firmware"

	install -Dm644 "$kernel_build/arch/arm64/boot/Image" \
		"$package_stage/boot/vmlinuz-$kernel_flavor"
	install -Dm644 "$kernel_build/System.map" \
		"$package_stage/boot/System.map-$abi_release"
	install -Dm644 "$kernel_build/.config" \
		"$package_stage/boot/config-$abi_release"

	log_info "Installing device trees into flavor-specific boot directory"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" \
		INSTALL_DTBS_PATH="$package_stage/boot/dtbs-$kernel_flavor" dtbs_install

	install -Dm644 "$kernel_build/include/config/kernel.release" \
		"$package_stage/usr/share/kernel/$kernel_flavor/kernel.release"
	ln -sfn "/boot/vmlinuz-$kernel_flavor" \
		"$package_stage/lib/modules/$abi_release/vmlinuz"
	printf -- '-%s\n' "$kernel_flavor" \
		> "$package_stage/lib/modules/$abi_release/kernel-suffix"
}

stage_kernel_dev_package() {
	local abi_release="$1"
	local header_dir="$dev_stage/usr/src/linux-headers-$abi_release"
	local karch=arm64

	safe_remove_tree "$dev_stage"
	mkdir -p "$header_dir"
	cp -a "$kernel_build/.config" "$kernel_build/localversion-alpine" "$header_dir/"
	[[ ! -f "$kernel_build/certs/signing_key.x509" ]] \
		|| install -Dm644 "$kernel_build/certs/signing_key.x509" "$header_dir/certs/signing_key.x509"
	[[ ! -f "$kernel_build/vmlinux.h" ]] \
		|| install -Dm644 "$kernel_build/vmlinux.h" "$header_dir/vmlinux.h"

	log_info "Preparing external-module headers (linux-$kernel_flavor-dev)"
	make -C "$kernel_src" O="$header_dir" ARCH="$kernel_arch" AWK="${AWK:-mawk}" \
		prepare modules_prepare scripts
	rm -f "$header_dir/Makefile" "$header_dir/source"

	(
		cd "$kernel_src"
		find . -path './include/*' -prune -o -path './scripts/*' -prune -o -type f \
			\( -name 'Makefile*' -o -name 'Kconfig*' -o -name 'Kbuild*' \
			-o -name '*.sh' -o -name '*.pl' -o -name '*.lds' -o -name 'Platform' \) \
			-print | cpio -pdm "$header_dir"
		cp -a scripts include "$header_dir"
		find "arch/$karch" tools/include "tools/arch/$karch" -type f -path '*/include/*' \
			-print | cpio -pdm "$header_dir"
	)

	install -Dm644 "$kernel_build/Module.symvers" "$header_dir/Module.symvers"
	rm -rf "$header_dir/Documentation"
	[[ ! -f "$header_dir/Kconfig" ]] || sed -i '/Documentation/d' "$header_dir/Kconfig"
	find "$header_dir" -type f \( -name '*.o' -o -name '*.cmd' \) -delete
	mkdir -p "$dev_stage/lib/modules/$abi_release"
	ln -s "/usr/src/linux-headers-$abi_release" "$dev_stage/lib/modules/$abi_release/build"
}

stage_kernel_doc_package() {
	safe_remove_tree "$doc_stage"
	local destination="$doc_stage/usr/share/doc/linux-doc-$kernel_pkgver"
	mkdir -p "$destination"
	cp -a "$kernel_src/Documentation"/. "$destination"/
	rm -f "$destination/.gitignore" "$destination/conf.py" "$destination/docutils.conf" \
		"$destination/Kconfig" "$destination/Makefile"
	ln -s "linux-doc-$kernel_pkgver" "$doc_stage/usr/share/doc/linux-doc"
}

write_metadata() {
	local abi_release="$1"
	cat > "$WORK_DIR/kernel-pkg/kernel.env" <<EOF
KERNEL_FLAVOR='$kernel_flavor'
KERNEL_PKGVER='$kernel_pkgver'
KERNEL_PKGREL='$kernel_pkgrel'
KERNEL_ABI_RELEASE='$abi_release'
KERNEL_APK_ARCH='$(apk_arch_for_kernel_arch "$kernel_arch")'
KERNEL_BOARD='$board'
EOF
}

fetch_kernel
apply_kernel_changes
configure_kernel
build_kernel

kernel_pkgver="$(make -s -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" kernelversion)"
abi_release="$(make -s -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" kernelrelease)"
[[ "$kernel_pkgver" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?([._][A-Za-z0-9]+)*$ ]] \
	|| die "Kernel version '$kernel_pkgver' is not a valid Alpine pkgver."
[[ "$abi_release" == *"-$kernel_pkgrel-$kernel_flavor" ]] \
	|| die "Unexpected kernel ABI '$abi_release'; expected suffix '-$kernel_pkgrel-$kernel_flavor'."

log_info "Kernel package version: $kernel_pkgver-r$kernel_pkgrel; ABI: $abi_release"
stage_kernel_package "$abi_release"
stage_kernel_dev_package "$abi_release"
stage_kernel_doc_package
write_metadata "$abi_release"
log_info "Kernel staging complete: $WORK_DIR/kernel-pkg"
