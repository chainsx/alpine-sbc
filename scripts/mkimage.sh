#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: scripts/mkimage.sh --board NAME [options]

Options:
  --board NAME    Board configuration name
  --name NAME     Output image basename (without .img)
  -h, --help      Show this help
EOF
}

board=""
name=""
kernel_flavor=""
dtb_name=""
boot_size=""
part_table=""
bootargs=""
boot_mode=""
KERNEL_FLAVOR=""
while (($#)); do
	case "$1" in
		--board | --name)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--board) board="$2" ;;
				--name) name="$2" ;;
			esac
			shift 2
			;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ -n "$board" ]] || die "--board is required."
[[ -n "$name" ]] || name="alpine-$board-aarch64"
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid image name: $name"

init_logging image
enable_error_trap
require_root
require_commands awk du mount mountpoint umount parted losetup mkfs.vfat mkfs.ext4 \
	rsync sha256sum sync truncate xz
load_board_config "$board"
require_board_variables platform boot_mode bootargs part_table boot_size dtb_name

package_manifest="$WORK_DIR/packages/kernel-packages.env"
[[ -f "$package_manifest" ]] || die "Kernel package manifest is missing."
# shellcheck disable=SC1090
source "$package_manifest"
[[ "$KERNEL_FLAVOR" == "$kernel_flavor" ]] || die "Kernel package flavor does not match board '$board'."

rootfs_dir="$WORK_DIR/rootfs"
# Used by the sourced bootloader installation function.
# shellcheck disable=SC2034
uboot_dir="$WORK_DIR/u-boot"
output_dir="$WORK_DIR/output"
mount_dir="$WORK_DIR/image-mounts"
root_mount="$mount_dir/root"
boot_mount="$mount_dir/boot"
image_file="$WORK_DIR/$name.img"
device=""

[[ -f "$rootfs_dir/etc/alpine-release" ]] || die "Root filesystem is missing or incomplete: $rootfs_dir"
[[ -f "$rootfs_dir/boot/vmlinuz-$KERNEL_FLAVOR" ]] \
	|| die "Kernel image is missing from rootfs."
if [[ "${initrd:-yes}" == yes ]]; then
	[[ -s "$rootfs_dir/boot/initramfs-$KERNEL_FLAVOR" ]] || die "Initramfs is missing from rootfs."
fi
if [[ "$dtb_name" != none ]]; then
	[[ -f "$rootfs_dir/boot/dtbs-$KERNEL_FLAVOR/$dtb_name.dtb" ]] \
		|| die "Board DTB is missing: dtbs-$KERNEL_FLAVOR/$dtb_name.dtb"
fi
[[ "$boot_size" =~ ^[1-9][0-9]*$ ]] || die "boot_size must be an integer number of MiB."
case "$part_table" in gpt | msdos) ;; *) die "Unsupported partition table: $part_table" ;; esac

# shellcheck source=scripts/libs/bootloader-install.sh
source "$PROJECT_ROOT/scripts/libs/bootloader-install.sh"

cleanup_image() {
	local rc=$?
	set +e
	trap - EXIT
	mountpoint -q "$boot_mount" && umount "$boot_mount"
	mountpoint -q "$root_mount" && umount "$root_mount"
	if [[ -n "$device" ]]; then
		losetup -d "$device" 2>/dev/null || true
	fi
	rm -rf "$mount_dir"
	if (( rc != 0 )); then
		log_error "Image generation failed; incomplete image retained at $image_file"
	fi
	return "$rc"
}
trap cleanup_image EXIT

wait_for_path() {
	local path="$1" attempts=50
	while [[ ! -b "$path" && $attempts -gt 0 ]]; do
		sleep 0.1
		attempts=$((attempts - 1))
	done
	[[ -b "$path" ]] || die "Partition device did not appear: $path"
}

generate_extlinux() {
	local directory="$1"
	mkdir -p "$directory/extlinux"
	{
		printf 'default Alpine\n'
		printf 'timeout 30\n\n'
		printf 'label Alpine\n'
		printf '  kernel /vmlinuz-%s\n' "$KERNEL_FLAVOR"
		if [[ "${initrd:-yes}" == yes ]]; then
			printf '  initrd /initramfs-%s\n' "$KERNEL_FLAVOR"
		fi
		if [[ "$dtb_name" != none ]]; then
			printf '  fdt /dtbs-%s/%s.dtb\n' "$KERNEL_FLAVOR" "$dtb_name"
		fi
		printf '  append %s\n' "$bootargs"
	} > "$directory/extlinux/extlinux.conf"
}

[[ "$boot_mode" == extlinux ]] || die "Only extlinux boot mode is currently implemented."

root_mib="$(du -sm "$rootfs_dir" | awk '{print $1}')"
boot_mib="$(du -sm "$rootfs_dir/boot" | awk '{print $1}')"
(( boot_mib + 32 <= boot_size )) \
	|| die "boot_size=${boot_size}MiB is too small for ${boot_mib}MiB of boot files."
image_mib=$((root_mib + boot_size + 512))

rm -f "$image_file"
mkdir -p "$mount_dir" "$output_dir"
log_info "Creating sparse ${image_mib}MiB image: $image_file"
truncate -s "${image_mib}M" "$image_file"

boot_start=32768
boot_end=$((boot_start + boot_size * 2048 - 1))
parted -s "$image_file" mklabel "$part_table"
parted -s "$image_file" unit s mkpart primary fat32 "${boot_start}s" "${boot_end}s"
parted -s "$image_file" set 1 boot on
parted -s "$image_file" unit s mkpart primary ext4 "$((boot_end + 1))s" 100%

device="$(losetup --find --show --partscan "$image_file")"
# Used by the sourced bootloader installation function.
# shellcheck disable=SC2034
loopX="${device##*/}"
boot_partition="${device}p1"
root_partition="${device}p2"
wait_for_path "$boot_partition"
wait_for_path "$root_partition"

mkfs.vfat -F 32 -n bootfs "$boot_partition"
mkfs.ext4 -F -L rootfs "$root_partition"
mkdir -p "$root_mount" "$boot_mount"
mount "$root_partition" "$root_mount"
mount "$boot_partition" "$boot_mount"

log_info "Copying root filesystem"
rsync -aHAX --numeric-ids --exclude=/boot/ "$rootfs_dir/" "$root_mount/"
mkdir -p "$root_mount/boot"

log_info "Copying boot filesystem"
rsync -rtD --delete "$rootfs_dir/boot/" "$boot_mount/"
generate_extlinux "$boot_mount"
sync

umount "$boot_mount"
umount "$root_mount"

INSTALL_U_BOOT
sync
losetup -d "$device"
device=""

rm -f "$output_dir/$name.img" "$output_dir/$name.img.xz" \
	"$output_dir/$name.img.xz.sha256"
mv "$image_file" "$output_dir/$name.img"
log_info "Compressing image with xz"
xz -T0 -f "$output_dir/$name.img"
(
	cd "$output_dir"
	sha256sum "$name.img.xz" > "$name.img.xz.sha256"
)

trap - EXIT
rmdir "$boot_mount" "$root_mount" "$mount_dir" 2>/dev/null || true
log_info "Image ready: $output_dir/$name.img.xz"
