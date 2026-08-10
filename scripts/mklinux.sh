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
module development tree used by linux-<flavor>-dev and the sanitized UAPI
headers used by linux-headers.

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
kernel_group=""
kernel_pkgrel=""
boot_mode=""
initrd=""
dtb_name=""
serial_console=""
serial_baud=""
serial_getty=""

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
require_board_variables kernel_arch kernel_group kernel_url kernel_branch kernel_config kernel_flavor kernel_pkgrel \
	boot_mode initrd dtb_name

if [[ "$serial_getty" == yes ]]; then
	require_board_variables serial_console serial_baud
fi

kernel_arch="$(normalize_arch "$kernel_arch")"
[[ "$kernel_arch" == arm64 ]] || die "Only arm64 kernels are supported; requested '$kernel_arch'."
host_arch="$(normalize_arch "$(uname -m)")"
[[ "$host_arch" == arm64 ]] || die "Native arm64 kernel builds require an arm64 host; detected '$host_arch'."

require_commands cmp git make gcc mawk openssl cpio find sha256sum sort

kernel_src="$WORK_DIR/linux-src"
kernel_build="$WORK_DIR/linux-build/$kernel_flavor"
# Some vendor configurations enable SELinux's host-side header generator.  Its
# upstream Makefile includes the source UAPI directory but not the generated
# arch UAPI directory when building out of tree, so provide that path for all
# kernel host tools.  This also keeps the fix local to the selected kernel
# build and preserves any caller-supplied HOSTCFLAGS.
kernel_host_cflags="${HOSTCFLAGS:-} -I$kernel_src/arch/$kernel_arch/include/uapi -I$kernel_build/arch/$kernel_arch/include/generated/uapi -I$kernel_src/arch/$kernel_arch/include -I$kernel_build/arch/$kernel_arch/include/generated"
export HOSTCFLAGS="$kernel_host_cflags"
package_stage="$WORK_DIR/kernel-pkg/kernel-bin"
dev_stage="$WORK_DIR/kernel-pkg/kernel-dev-bin"
doc_stage="$WORK_DIR/kernel-pkg/kernel-doc-bin"
headers_stage="$WORK_DIR/kernel-pkg/kernel-headers-bin"
config_path="$PROJECT_ROOT/configs/kernel/$kernel_config"
source_state="$kernel_src/.alpine-sbc-source"

[[ -f "$config_path" ]] || die "Kernel config not found: $config_path"

patch_root="$PROJECT_ROOT/patches/kernel/$kernel_branch"
patch_fingerprint="$(tree_fingerprint "$patch_root")"
expected_state="group=$kernel_group
url=$kernel_url
ref=$kernel_branch
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
	apply_patch_directory "$patch_root/$kernel_group/patches"
	copy_tree_contents "$patch_root/$kernel_group/files" "$kernel_src"
	apply_patch_directory "$patch_root/$board/patches"
	copy_tree_contents "$patch_root/$board/files" "$kernel_src"
	printf '%s\n' "$expected_state" > "$source_state"
}

configure_kernel() {
	local option
	mkdir -p "$kernel_build"
	local expected_localversion="-$kernel_pkgrel-$kernel_flavor"
	local config_state="$kernel_build/.alpine-sbc-config"
	local config_fingerprint
	config_fingerprint="$(sha256sum "$config_path" | awk '{print $1}')|signing=${KERNEL_SIGNING_KEY:-}"
	local refresh_config=0
	# Do not rewrite an unchanged configuration: kbuild treats its mtime as a
	# dependency and would otherwise rebuild every object on each retry.  The
	# state file records the source config rather than comparing against .config,
	# because olddefconfig legitimately adds new kernel defaults.
	if [[ ! -f "$config_state" ]] || [[ "$(cat "$config_state")" != "$config_fingerprint" ]]; then
		refresh_config=1
	fi
	if (( refresh_config )); then
		# A changed config can disable modules that are still present in the old
		# output tree.  Reusing that tree would leak stale modules into the APK.
		safe_remove_tree "$kernel_build"
		mkdir -p "$kernel_build"
		cp "$config_path" "$kernel_build/.config"
	fi
	if [[ ! -f "$kernel_build/localversion-alpine" ]] \
		|| [[ "$(cat "$kernel_build/localversion-alpine")" != "$expected_localversion" ]]; then
		printf '%s\n' "$expected_localversion" > "$kernel_build/localversion-alpine"
	fi

	# Git checkouts otherwise append a commit suffix when a vendor config enables
	# CONFIG_LOCALVERSION_AUTO.  Alpine's source-tarball build has no such suffix.
	if (( refresh_config )) && [[ -x "$kernel_src/scripts/config" ]]; then
		"$kernel_src/scripts/config" --file "$kernel_build/.config" \
			--set-str LOCALVERSION '' --disable LOCALVERSION_AUTO
	fi

	if (( refresh_config )) && [[ -n "${KERNEL_SIGNING_KEY:-}" && -f "${KERNEL_SIGNING_KEY:-}" ]]; then
		"$kernel_src/scripts/config" --file "$kernel_build/.config" \
			--enable MODULE_SIG --set-str MODULE_SIG_KEY "$KERNEL_SIGNING_KEY"
	fi

	log_info "Configuring $kernel_flavor with $kernel_config"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" olddefconfig
	printf '%s\n' "$config_fingerprint" > "$config_state"

	for option in CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_EXT4_FS; do
		grep -q "^${option}=y" "$kernel_build/.config" \
			|| die "Bootable rootfs requires ${option}=y."
	done
	if [[ "$initrd" == yes ]]; then
		for option in CONFIG_BLK_DEV_INITRD CONFIG_RD_GZIP; do
			grep -q "^${option}=y" "$kernel_build/.config" \
				|| die "Board gzip initramfs support requires ${option}=y."
		done
	fi

	if [[ "$serial_getty" == yes ]]; then
		case "$serial_console" in
			ttyFIQ*)
				for option in CONFIG_FIQ_DEBUGGER_CONSOLE CONFIG_ROCKCHIP_FIQ_DEBUGGER; do
					grep -q "^${option}=y" "$kernel_build/.config" \
						|| die "$serial_console requires ${option}=y."
					done
				;;
			ttyAML*) option=CONFIG_SERIAL_MESON_CONSOLE ;;
			ttySTM*) option=CONFIG_SERIAL_STM32_CONSOLE ;;
			ttyAMA*) option=CONFIG_SERIAL_AMBA_PL011_CONSOLE ;;
			ttyS*) option=CONFIG_SERIAL_8250_CONSOLE ;;
			*) die "Unsupported serial console device: $serial_console" ;;
		esac
		if [[ "$serial_console" != ttyFIQ* ]]; then
			grep -q "^${option}=y" "$kernel_build/.config" \
				|| die "$serial_console requires ${option}=y."
		fi
	fi

	if [[ "$boot_mode" == grub ]]; then
		local required_efi_options=(
			CONFIG_EFI CONFIG_EFI_STUB CONFIG_EFI_PARTITION CONFIG_ACPI CONFIG_PCI
			CONFIG_PCI_HOST_GENERIC
			CONFIG_VIRTIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_PCI
			CONFIG_SERIAL_AMBA_PL011 CONFIG_SERIAL_AMBA_PL011_CONSOLE
		)
		for option in "${required_efi_options[@]}"; do
			grep -q "^${option}=y" "$kernel_build/.config" \
				|| die "EFI board kernel configuration requires ${option}=y."
		done
	fi
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
	build_targets=(all)
	if [[ "$dtb_name" == none ]]; then
		# QEMU/EFI supplies its own device tree.  Building every arm64 DTB is
		# unnecessary for these images and dominates the first build time.
		build_targets=(Image modules)
	fi
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" CC="${CC:-gcc}" \
		KBUILD_BUILD_VERSION="$((kernel_pkgrel + 1))-Alpine" -j"$jobs" \
		"${build_targets[@]}"

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

	# Keep Alpine's vmlinuz-* package naming, but stage the native ARM64 Image.
	# U-Boot's extlinux bootflow does not have a reliable way to pass the exact
	# compressed-file length to booti after it has loaded the initramfs; using
	# Image avoids that extra decompression failure point and starts directly at
	# the Linux entry point.  The package still contains the same kernel ABI,
	# modules, initramfs contract, config, and external-module metadata.
	install -Dm644 "$kernel_build/arch/arm64/boot/Image" \
		"$package_stage/boot/vmlinuz-$kernel_flavor"
	install -Dm644 "$kernel_build/System.map" \
		"$package_stage/boot/System.map-$abi_release"
	install -Dm644 "$kernel_build/.config" \
		"$package_stage/boot/config-$abi_release"

	if [[ "$dtb_name" != none ]]; then
		log_info "Installing device trees into flavor-specific boot directory"
		make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
			AWK="${AWK:-mawk}" \
			INSTALL_DTBS_PATH="$package_stage/boot/dtbs-$kernel_flavor" dtbs_install
		[[ -s "$package_stage/boot/dtbs-$kernel_flavor/$dtb_name.dtb" ]] \
			|| die "Configured board DTB was not built: $dtb_name.dtb"
	fi

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

stage_linux_headers_package() {
	local abi_release="$1"
	local include_dir="$headers_stage/usr/include"
	local header_count

	safe_remove_tree "$headers_stage"
	mkdir -p "$headers_stage/usr"

	# Match Alpine's main/linux-headers build: export the sanitized userspace
	# UAPI from this exact kernel source instead of packaging the source tree or
	# reusing headers from an unrelated repository kernel.
	log_info "Exporting sanitized userspace UAPI headers (linux-headers)"
	# `make headers` does not remove files left by a previous kernel/config.  A
	# clean export prevents stale UAPI headers from leaking into a retry.
	rm -rf "$kernel_build/usr/include"
	make -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" \
		AWK="${AWK:-mawk}" headers
	[[ -d "$kernel_build/usr/include/linux" ]] \
		|| die "The kernel headers target did not generate usr/include/linux."
	cp -a "$kernel_build/usr/include" "$headers_stage/usr/"
	find "$include_dir" ! -iname '*.h' -type f -delete

	# Alpine carries these two UAPI compatibility changes in main/linux-headers.
	# Apply the equivalent changes to the exported copy so the compiled kernel
	# source and external-module development tree remain untouched.
	if [[ -f "$include_dir/linux/if_tunnel.h" ]]; then
		sed -i \
			-e '/^#include <linux\/if\.h>$/d' \
			-e '/^#include <linux\/ip\.h>$/d' \
			-e '/^#include <linux\/in6\.h>$/d' \
			"$include_dir/linux/if_tunnel.h"
	fi
	if [[ -f "$include_dir/linux/kernel.h" ]] \
		&& grep -Fxq '#include <linux/sysinfo.h>' "$include_dir/linux/kernel.h" \
		&& ! grep -Fxq '#ifdef __GLIBC__' "$include_dir/linux/kernel.h"; then
		sed -i \
			'/^#include <linux\/sysinfo\.h>$/i #ifdef __GLIBC__' \
			"$include_dir/linux/kernel.h"
		sed -i \
			'/^#include <linux\/sysinfo\.h>$/a #endif' \
			"$include_dir/linux/kernel.h"
	fi

	[[ -s "$include_dir/linux/version.h" ]] \
		|| die "Generated linux-headers is missing linux/version.h."
	[[ -s "$include_dir/asm/unistd.h" ]] \
		|| die "Generated linux-headers is missing architecture UAPI headers."
	header_count="$(find "$include_dir" -type f -name '*.h' -print | wc -l)"
	((header_count > 0)) || die "Generated linux-headers package contains no headers."
	log_info "Staged $header_count sanitized UAPI headers from $abi_release"
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
KERNEL_GROUP='$kernel_group'
KERNEL_FLAVOR='$kernel_flavor'
KERNEL_PKGVER='$kernel_pkgver'
KERNEL_PKGREL='$kernel_pkgrel'
KERNEL_ABI_RELEASE='$abi_release'
KERNEL_APK_ARCH='$(apk_arch_for_kernel_arch "$kernel_arch")'
EOF
}

fetch_kernel
apply_kernel_changes
configure_kernel
build_kernel

log_info "Resolving kernel package version and ABI release"
kernel_pkgver="$(make -s -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" kernelversion)"
abi_release="$(make -s -C "$kernel_src" O="$kernel_build" ARCH="$kernel_arch" kernelrelease)"
log_info "Resolved kernel version '$kernel_pkgver' and ABI '$abi_release'"
[[ "$kernel_pkgver" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?([._][A-Za-z0-9]+)*$ ]] \
	|| die "Kernel version '$kernel_pkgver' is not a valid Alpine pkgver."
[[ "$abi_release" == *"-$kernel_pkgrel-$kernel_flavor" ]] \
	|| die "Unexpected kernel ABI '$abi_release'; expected suffix '-$kernel_pkgrel-$kernel_flavor'."

log_info "Kernel package version: $kernel_pkgver-r$kernel_pkgrel; ABI: $abi_release"
stage_kernel_package "$abi_release"
stage_kernel_dev_package "$abi_release"
stage_linux_headers_package "$abi_release"
stage_kernel_doc_package
write_metadata "$abi_release"
log_info "Kernel staging complete: $WORK_DIR/kernel-pkg"
