#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: scripts/mkrootfs.sh --board NAME [options]

Options:
  --board NAME       Board configuration name
  --rootfs DIR       Destination (default: build/rootfs)
  --version VERSION  Alpine release with patch component (default: 3.23.0)
  --arch ARCH        Alpine architecture (default: aarch64)
  --mirror URL       Alpine mirror root
  --keep-rootfs      Update an existing rootfs instead of recreating it
  -h, --help         Show this help
EOF
}

board=""
rootfs="$WORK_DIR/rootfs"
version=3.23.0
apk_arch=aarch64
mirror=https://dl-cdn.alpinelinux.org
keep_rootfs=0
kernel_flavor=""
KERNEL_FLAVOR=""
KERNEL_PACKAGE=""
KERNEL_PKGVER=""
KERNEL_PKGREL=""
KERNEL_ABI_RELEASE=""
KERNEL_REPOSITORY=""
KERNEL_PUBLIC_KEY=""
platform=""
rootfs_arch=""
rootfs_kernel_repository="/tmp/alpine-sbc-repository"

while (($#)); do
	case "$1" in
		--board | --rootfs | --version | --arch | --mirror)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--board) board="$2" ;;
				--rootfs) rootfs="$2" ;;
				--version) version="$2" ;;
				--arch) apk_arch="$2" ;;
				--mirror) mirror="${2%/}" ;;
			esac
			shift 2
			;;
		--keep-rootfs) keep_rootfs=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$board" ]] || die "--board is required."
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Alpine release: $version"
[[ "$apk_arch" == aarch64 ]] || die "Only the aarch64 root filesystem is supported."
[[ "$rootfs" == "$WORK_DIR"/* ]] || die "Rootfs must be located below $WORK_DIR."

init_logging rootfs
enable_error_trap
require_root
require_commands wget sha256sum tar chroot mount mountpoint umount rsync
load_board_config "$board"
require_board_variables platform rootfs_arch
[[ "$rootfs_arch" == "$apk_arch" ]] \
	|| die "Board rootfs_arch '$rootfs_arch' does not match requested '$apk_arch'."

package_manifest="$WORK_DIR/packages/kernel-packages.env"
load_kernel_package_manifest "$package_manifest" "$kernel_flavor"

release_branch="v${version%.*}"
archive="alpine-minirootfs-$version-$apk_arch.tar.gz"
download_dir="$WORK_DIR/downloads"
archive_path="$download_dir/$archive"
archive_url="$mirror/alpine/$release_branch/releases/$apk_arch/$archive"

mounts=()
cleanup_mounts() {
	local index
	set +e
	for ((index=${#mounts[@]} - 1; index >= 0; index--)); do
		mountpoint -q "${mounts[index]}" && umount -R "${mounts[index]}"
	done
	set -e
}
trap cleanup_mounts EXIT

download_rootfs() {
	mkdir -p "$download_dir"
	if [[ ! -f "$archive_path" ]]; then
		log_info "Downloading $archive_url"
		wget -O "$archive_path.part" "$archive_url"
		mv "$archive_path.part" "$archive_path"
	else
		log_info "Using cached minirootfs: $archive_path"
	fi

	log_info "Verifying minirootfs SHA-256 checksum"
	if wget -q -O "$archive_path.sha256" "$archive_url.sha256"; then
		(
			cd "$download_dir"
			sha256sum -c "$archive.sha256"
		)
	else
		rm -f "$archive_path.sha256"
		die "The mirror did not provide $archive.sha256; refusing an unverified rootfs archive."
	fi
}

extract_rootfs() {
	if (( keep_rootfs )) && [[ -f "$rootfs/etc/alpine-release" ]]; then
		log_info "Updating existing rootfs: $rootfs"
		return
	fi
	[[ ! -e "$rootfs" ]] || safe_remove_tree "$rootfs"
	mkdir -p "$rootfs"
	log_info "Extracting Alpine minirootfs $version ($apk_arch)"
	tar -xzf "$archive_path" -C "$rootfs" --numeric-owner
}

mount_chroot_filesystems() {
	mkdir -p "$rootfs/dev" "$rootfs/proc" "$rootfs/sys" "$rootfs/run"
	mount --rbind /dev "$rootfs/dev"
	mounts+=("$rootfs/dev")
	mount --make-rslave "$rootfs/dev"
	mount -t proc proc "$rootfs/proc"
	mounts+=("$rootfs/proc")
	mount --rbind /sys "$rootfs/sys"
	mounts+=("$rootfs/sys")
	mount --make-rslave "$rootfs/sys"
	mount -t tmpfs tmpfs "$rootfs/run"
	mounts+=("$rootfs/run")
}

configure_repositories() {
	mkdir -p "$rootfs/etc/apk/keys"
	cp /etc/resolv.conf "$rootfs/etc/resolv.conf"
	cat > "$rootfs/etc/apk/repositories" <<EOF
$mirror/alpine/$release_branch/main
$mirror/alpine/$release_branch/community
EOF
	cp "$KERNEL_PUBLIC_KEY" "$rootfs/etc/apk/keys/"

	rm -rf "$rootfs$rootfs_kernel_repository"
	stage_apk_repository "$KERNEL_REPOSITORY" "$rootfs" \
		"$rootfs_kernel_repository" "$apk_arch"
}

kernel_firmware_packages="${kernel_firmware_packages:-}"
if [[ -z "$kernel_firmware_packages" ]]; then
	case "$platform" in
		rockchip64) kernel_firmware_packages="linux-firmware-rockchip" ;;
		amlogic) kernel_firmware_packages="linux-firmware-amlogic" ;;
		qemu | efi-arm64 | stm32mp2) kernel_firmware_packages="linux-firmware-none" ;;
		*) kernel_firmware_packages="linux-firmware-other" ;;
	esac
fi

base_packages=(
	alpine-base bash bash-completion btop busybox-mdev-openrc busybox-openrc
	busybox-suid coreutils dhcpcd mdev-conf networkmanager networkmanager-bluetooth
	networkmanager-cli networkmanager-dnsmasq networkmanager-openrc networkmanager-tui
	networkmanager-wifi openrc openrc-bash-completion openrc-init openssh
	openssh-server-common-openrc sudo tzdata util-linux vim
)

install_packages() {
	log_info "Installing base system packages"
	chroot "$rootfs" apk update
	chroot "$rootfs" apk add --no-cache "${base_packages[@]}"
	# Board configuration values are trusted package names, intentionally split.
	# shellcheck disable=SC2086
	chroot "$rootfs" apk add --no-cache $kernel_firmware_packages

	log_info "Installing signed custom kernel package: $KERNEL_PACKAGE"
	chroot "$rootfs" apk add --no-cache \
		--repository "$rootfs_kernel_repository" "$KERNEL_PACKAGE"

	chroot "$rootfs" apk info --exists "$KERNEL_PACKAGE=$KERNEL_PKGVER-r$KERNEL_PKGREL" \
		|| die "The requested kernel package version was not installed."

	# Installation already invokes Alpine's mkinitfs trigger.  Generate once more
	# explicitly so trigger failures and stale images from --keep-rootfs are visible.
	chroot "$rootfs" mkinitfs -o "/boot/initramfs-$KERNEL_FLAVOR" "$KERNEL_ABI_RELEASE"
	[[ -s "$rootfs/boot/initramfs-$KERNEL_FLAVOR" ]] || die "Initramfs generation failed."
}

enable_service() {
	local service="$1" runlevel="$2"
	if chroot "$rootfs" rc-service -e "$service" >/dev/null 2>&1; then
		chroot "$rootfs" rc-update add "$service" "$runlevel"
	else
		log_warn "OpenRC service is unavailable and was not enabled: $service"
	fi
}

configure_system() {
	log_info "Configuring OpenRC and base system"
	enable_service devfs sysinit
	enable_service procfs sysinit
	enable_service sysfs sysinit
	enable_service mdev sysinit
	enable_service modules boot
	enable_service local default
	enable_service sshd default
	enable_service networkmanager default

	mkdir -p "$rootfs/etc/network" "$rootfs/etc/local.d" "$rootfs/root"
	cat > "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

	cat > "$rootfs/etc/local.d/load-modules.start" <<'EOF'
#!/bin/sh
echo "Scanning hardware drivers..."
mdev -s
find /sys -name modalias -type f -exec cat '{}' + 2>/dev/null \
	| sort -u | xargs -r -n1 modprobe -b -q 2>/dev/null || true
EOF
	chmod 755 "$rootfs/etc/local.d/load-modules.start"

	printf '%s\n' alpine-sbc > "$rootfs/etc/hostname"
	ln -sfn /usr/share/zoneinfo/Asia/Singapore "$rootfs/etc/localtime"
	printf '%s\n' Asia/Singapore > "$rootfs/etc/timezone"

	# Remove serial getty entries created by older alpine-sbc builds so
	# --keep-rootfs can safely switch boards or corrected console names.
	sed -i -E \
		'/^(ttyAMA[0-9]+|ttyFIQ[0-9]+|ttyAML[0-9]+|ttySTM[0-9]+|ttyS[0-9]+)::respawn:\/sbin\/getty -L [0-9]+ [A-Za-z0-9._-]+ vt100( # alpine-sbc)?$/d' \
		"$rootfs/etc/inittab"
	printf '%s::respawn:/sbin/getty -L %s %s vt100 # alpine-sbc\n' \
		"$serial_console" "$serial_baud" "$serial_console" \
		>> "$rootfs/etc/inittab"
	if [[ -f "$rootfs/etc/securetty" ]] \
		&& ! grep -Fxq "$serial_console" "$rootfs/etc/securetty"; then
		printf '%s\n' "$serial_console" >> "$rootfs/etc/securetty"
	fi
	log_info "Enabled serial console getty on $serial_console at $serial_baud baud"

	sed -i -E \
		-e 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin prohibit-password/' \
		-e 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' \
		"$rootfs/etc/ssh/sshd_config"
	if [[ -n "${ALPINE_SBC_ROOT_PASSWORD:-}" ]]; then
		printf 'root:%s\n' "$ALPINE_SBC_ROOT_PASSWORD" | chroot "$rootfs" chpasswd
		log_info "Configured the requested root console password"
	else
		chroot "$rootfs" passwd -d root >/dev/null
		log_warn "Root has no console password; SSH password authentication remains disabled"
	fi

	cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=rootfs  /      ext4  defaults,noatime  0 1
LABEL=bootfs  /boot  vfat  defaults          0 2
EOF

	cat > "$rootfs/etc/alpine-sbc-release" <<EOF
BOARD=$board
KERNEL_FLAVOR=$KERNEL_FLAVOR
KERNEL_RELEASE=$KERNEL_ABI_RELEASE
SERIAL_CONSOLE=$serial_console
SERIAL_BAUD=$serial_baud
EOF

	rm -rf "$rootfs$rootfs_kernel_repository" "$rootfs/var/cache/apk"/*
}

download_rootfs
extract_rootfs
mount_chroot_filesystems
configure_repositories
install_packages
configure_system
cleanup_mounts
mounts=()
trap - EXIT
log_info "Root filesystem ready: $rootfs"
