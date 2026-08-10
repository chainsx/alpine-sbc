#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: sudo ./build.sh [options]

Build an arm64 Alpine Linux image for a supported single-board computer.

Options:
  --board NAME          Board configuration name (default: extlinux-arm64)
  --version VERSION     Alpine release, including patch version (default: 3.23.0)
  --mirror URL          Alpine mirror root (default: https://dl-cdn.alpinelinux.org)
  --jobs N              Parallel compiler jobs (default: number of CPUs)
  --clean               Remove generated build state before starting
  --skip-deps           Do not install build dependencies with apk
  --skip-bootloader     Reuse an existing bootloader build
  --skip-kernel         Reuse existing kernel packages
  --skip-rootfs         Reuse an existing root filesystem
  --skip-image          Stop after building the root filesystem
  --debug               Enable debug logging
  -h, --help            Show this help
EOF
}

board=extlinux-arm64
version=3.23.0
mirror=https://dl-cdn.alpinelinux.org
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
arch=""
rootfs_arch=""
boot_mode=""
clean=0
install_deps=1
build_bootloader=1
build_kernel=1
build_rootfs=1
build_image=1

while (($#)); do
	case "$1" in
		--board | --version | --mirror | --jobs)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--board) board="$2" ;;
				--version) version="$2" ;;
				--mirror) mirror="${2%/}" ;;
				--jobs) jobs="$2" ;;
			esac
			shift 2
			;;
		--clean) clean=1; shift ;;
		--skip-deps) install_deps=0; shift ;;
		--skip-bootloader) build_bootloader=0; shift ;;
		--skip-kernel) build_kernel=0; shift ;;
		--skip-rootfs) build_rootfs=0; shift ;;
		--skip-image) build_image=0; shift ;;
		--debug) export ALPINE_SBC_DEBUG=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer."
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| die "--version must include major, minor, and patch components (for example 3.23.0)."

require_root
require_alpine_arm64_host
load_board_config "$board"
require_board_variables arch rootfs_arch kernel_group kernel_url kernel_branch kernel_config \
	bootloader_url bootloader_branch bootloader_config platform boot_mode part_table boot_size

[[ "$(normalize_arch "$arch")" == arm64 ]] || die "Only arm64 target kernels are supported."
[[ "$rootfs_arch" == aarch64 ]] || die "Only aarch64 Alpine root filesystems are supported."

if (( clean )); then
	log_warn "Removing generated build state: $WORK_DIR"
	rm -rf -- "$WORK_DIR"
fi
init_logging build
enable_error_trap

if (( install_deps )); then
	log_info "Installing Alpine build dependencies"
	host_dependencies=(
		alpine-sdk abuild bash bc binutils bison bpftool build-base ca-certificates cmake cpio \
		coreutils curl diffutils dosfstools dtc e2fsprogs e2fsprogs-extra \
		elfutils-dev findutils flex gawk git gmp-dev gnutls-dev grep kmod libarchive-tools linux-headers \
		mawk mpc1-dev mpfr-dev ncurses-dev openssl openssl-dev pahole parted \
		perl py3-cryptography py3-elftools py3-pillow py3-setuptools \
		python3 python3-dev rsync sed shadow \
		sgdisk swig tar util-linux util-linux-dev wget xz zstd
	)
	if [[ "$boot_mode" == grub ]]; then
		host_dependencies+=(grub grub-efi aavmf qemu-system-aarch64)
	fi
	apk add --no-cache "${host_dependencies[@]}"
else
	log_warn "Dependency installation skipped"
fi

require_commands apk git make gcc abuild abuild-sign openssl rsync tar xz
if (( build_image )); then
	image_commands=(
		awk cpio dd du gzip losetup mkfs.ext4 mkfs.vfat mknod modprobe mount
		mountpoint parted rsync sha256sum stat sync truncate umount xz
	)
	if [[ "$part_table" == gpt ]]; then image_commands+=(sgdisk); fi
	if [[ "$boot_mode" == grub ]]; then image_commands+=(grub-mkimage); fi
	require_commands "${image_commands[@]}"
fi
mkdir -p "$WORK_DIR"

if (( build_bootloader )); then
	log_info "Stage 1/4: bootloader"
	"$PROJECT_ROOT/scripts/mkbootloader.sh" --board "$board" --jobs "$jobs"
else
	log_warn "Stage 1/4 skipped: bootloader"
	validate_bootloader_manifest "$WORK_DIR/bootloader-artifacts.sha256"
fi

if (( build_kernel )); then
	log_info "Stage 2/4: Linux kernel and Alpine packages"
	"$PROJECT_ROOT/scripts/mklinux.sh" --board "$board" --jobs "$jobs"
	"$PROJECT_ROOT/scripts/libs/kernel-pkg.sh" --board "$board"
else
	log_warn "Stage 2/4 skipped: kernel"
	load_kernel_package_manifest "$WORK_DIR/packages/kernel-packages.env" "$kernel_flavor"
fi

if (( build_rootfs )); then
	log_info "Stage 3/4: Alpine root filesystem"
	"$PROJECT_ROOT/scripts/mkrootfs.sh" \
		--rootfs "$WORK_DIR/rootfs" \
		--version "$version" \
		--arch "$rootfs_arch" \
		--mirror "$mirror" \
		--board "$board"
else
	log_warn "Stage 3/4 skipped: root filesystem"
	load_kernel_package_manifest "$WORK_DIR/packages/kernel-packages.env" "$kernel_flavor"
	rootfs_release="$WORK_DIR/rootfs/etc/alpine-release"
	rootfs_metadata="$WORK_DIR/rootfs/etc/alpine-sbc-release"
	[[ -s "$rootfs_release" && "$(cat "$rootfs_release")" == "$version" ]] \
		|| die "Root filesystem is missing or is not Alpine $version; rebuild without --skip-rootfs."
	[[ -s "$rootfs_metadata" ]] \
		|| die "Root filesystem board metadata is missing; rebuild without --skip-rootfs."
	grep -Fxq "BOARD=$board" "$rootfs_metadata" \
		|| die "Cached root filesystem was built for a different board."
	grep -Fxq "KERNEL_FLAVOR=$kernel_flavor" "$rootfs_metadata" \
		|| die "Cached root filesystem contains a different kernel flavor."
	[[ -s "$WORK_DIR/rootfs/boot/vmlinuz-$kernel_flavor" ]] \
		|| die "Cached root filesystem is missing its kernel image."
	[[ -s "$WORK_DIR/rootfs/boot/initramfs-$kernel_flavor" ]] \
		|| die "Cached root filesystem is missing its initramfs."
	if [[ "$dtb_name" != none ]]; then
		[[ -s "$WORK_DIR/rootfs/boot/dtbs-$kernel_flavor/$dtb_name.dtb" ]] \
			|| die "Cached root filesystem is missing the board DTB."
	fi
	log_info "Validated cached root filesystem for $board"
fi

if (( build_image )); then
	log_info "Stage 4/4: disk image"
	image_name="alpine-${board}-${version}-aarch64"
	"$PROJECT_ROOT/scripts/mkimage.sh" --name "$image_name" --board "$board"
	log_info "Build complete: $WORK_DIR/output/$image_name.img.xz"
else
	log_info "Image stage skipped; root filesystem is ready at $WORK_DIR/rootfs"
fi
