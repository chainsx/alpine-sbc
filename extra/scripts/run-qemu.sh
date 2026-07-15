#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: extra/scripts/run-qemu.sh [options]

Boot an efi-arm64 image with either U-Boot's EFI implementation or EDK2.

Options:
  --firmware NAME  u-boot or edk2 (default: u-boot)
  --image FILE     Raw or .xz efi-arm64 image (default: newest build output)
  --memory SIZE    QEMU memory size (default: 2G)
  --cpus N         Virtual CPU count (default: 4)
  --reset-vars     Reset the writable EDK2 variable store
  --dry-run        Print the QEMU command without executing it
  -h, --help       Show this help

Environment overrides:
  QEMU_BIN, UBOOT_BIN, AAVMF_CODE, AAVMF_VARS
EOF
}

firmware="u-boot"
image_path=""
memory="2G"
cpus="4"
reset_vars=0
dry_run=0

while (($#)); do
	case "$1" in
		--firmware | --image | --memory | --cpus)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--firmware) firmware="$2" ;;
				--image) image_path="$2" ;;
				--memory) memory="$2" ;;
				--cpus) cpus="$2" ;;
			esac
			shift 2
			;;
		--reset-vars) reset_vars=1; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

case "$firmware" in u-boot | edk2) ;; *) die "Unsupported firmware: $firmware" ;; esac
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die "--cpus must be a positive integer."
[[ "$memory" =~ ^[1-9][0-9]*[KkMmGgTt]?$ ]] || die "Invalid --memory value: $memory"

qemu_bin="${QEMU_BIN:-qemu-system-aarch64}"
command -v "$qemu_bin" >/dev/null 2>&1 || die "QEMU executable not found: $qemu_bin"

if [[ -z "$image_path" ]]; then
	shopt -s nullglob
	candidates=(
		"$WORK_DIR/output"/alpine-efi-arm64-*.img
		"$WORK_DIR/output"/alpine-efi-arm64-*.img.xz
	)
	shopt -u nullglob
	((${#candidates[@]} > 0)) \
		|| die "No efi-arm64 image found below $WORK_DIR/output."
	image_path="${candidates[0]}"
	for candidate in "${candidates[@]:1}"; do
		[[ "$candidate" -nt "$image_path" ]] && image_path="$candidate"
	done
fi
[[ -f "$image_path" ]] || die "Image does not exist: $image_path"

qemu_dir="$WORK_DIR/qemu"
if [[ "$image_path" == *.xz ]]; then
	raw_image="$qemu_dir/${image_path##*/}"
	raw_image="${raw_image%.xz}"
	if (( ! dry_run )) && { [[ ! -f "$raw_image" ]] || [[ "$image_path" -nt "$raw_image" ]]; }; then
		mkdir -p "$qemu_dir"
		log_info "Decompressing $image_path to $raw_image"
		rm -f "$raw_image.part"
		if ! xz -dc "$image_path" > "$raw_image.part"; then
			rm -f "$raw_image.part"
			die "Unable to decompress image: $image_path"
		fi
		mv "$raw_image.part" "$raw_image"
	fi
	image_path="$raw_image"
fi

qemu_args=(
	-machine "virt,gic-version=3"
	-cpu cortex-a72
	-smp "$cpus"
	-m "$memory"
	-nographic
	-no-reboot
)

case "$firmware" in
	u-boot)
		uboot_bin="${UBOOT_BIN:-$WORK_DIR/u-boot/u-boot.bin}"
		[[ -s "$uboot_bin" ]] || die "U-Boot firmware is missing: $uboot_bin"
		qemu_args+=(-bios "$uboot_bin")
		;;
	edk2)
		aavmf_code="${AAVMF_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}"
		aavmf_vars="${AAVMF_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}"
		[[ -s "$aavmf_code" ]] || die "AAVMF code firmware is missing: $aavmf_code"
		[[ -s "$aavmf_vars" ]] || die "AAVMF variable template is missing: $aavmf_vars"
		vars_runtime="$qemu_dir/AAVMF_VARS.fd"
		if (( ! dry_run )); then
			mkdir -p "$qemu_dir"
			if (( reset_vars )) || [[ ! -f "$vars_runtime" ]]; then
				cp "$aavmf_vars" "$vars_runtime"
			fi
		fi
		qemu_args+=(
			-drive "if=pflash,format=raw,readonly=on,file=$aavmf_code"
			-drive "if=pflash,format=raw,file=$vars_runtime"
		)
		;;
esac

qemu_args+=(
	-drive "if=none,file=$image_path,format=raw,id=hd0"
	-device "virtio-blk-pci,drive=hd0"
	-object "rng-random,filename=/dev/urandom,id=rng0"
	-device "virtio-rng-pci,rng=rng0"
	-netdev "user,id=net0"
	-device "virtio-net-pci,netdev=net0"
)

if (( dry_run )); then
	printf '%q' "$qemu_bin"
	printf ' %q' "${qemu_args[@]}"
	printf '\n'
	exit 0
fi

log_info "Starting efi-arm64 image with $firmware firmware"
exec "$qemu_bin" "${qemu_args[@]}"
