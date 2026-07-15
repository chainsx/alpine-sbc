#!/usr/bin/env bash

# shellcheck disable=SC2154 # Variables are supplied by scripts/mkimage.sh.
_require_artifact_fits() {
	local path="$1" maximum_bytes="$2" description="$3"
	local size
	[[ -s "$path" ]] || die "Missing $description: $path"
	size="$(stat -c '%s' "$path")"
	(( size <= maximum_bytes )) \
		|| die "$description is ${size} bytes and exceeds its ${maximum_bytes}-byte boot region."
}

INSTALL_U_BOOT() {
	local disk="/dev/$loopX"
	local first_partition_bytes=$((boot_start * 512))
	case "$platform" in
		qemu | efi-arm64)
			log_info "QEMU firmware is external to the disk image; no raw bootloader write needed"
			;;
		rockchip64)
			_require_artifact_fits "$uboot_dir/idbloader.img" $(((16384 - 64) * 512)) \
				"Rockchip idbloader.img"
			_require_artifact_fits "$uboot_dir/u-boot.itb" $(((boot_start - 16384) * 512)) \
				"Rockchip u-boot.itb"
			log_info "Installing Rockchip U-Boot on $disk"
			dd if="$uboot_dir/idbloader.img" of="$disk" bs=512 seek=64 conv=notrunc,fsync status=none
			dd if="$uboot_dir/u-boot.itb" of="$disk" bs=512 seek=16384 conv=notrunc,fsync status=none
			;;
		phytium)
			[[ -f "$uboot_dir/fip-all-sd-boot.bin" ]] || die "Missing Phytium FIP image"
			local part_dump="$uboot_dir/part.txt"
			sfdisk --dump "$disk" > "$part_dump"
			dd if="$uboot_dir/fip-all-sd-boot.bin" of="$disk" conv=notrunc,fsync status=none
			sfdisk --no-reread "$disk" < "$part_dump"
			;;
		allwinner)
			_require_artifact_fits "$uboot_dir/u-boot-sunxi-with-spl.bin" \
				$((first_partition_bytes - 8 * 1024)) "Allwinner U-Boot image"
			dd if="$uboot_dir/u-boot-sunxi-with-spl.bin" of="$disk" bs=1K seek=8 \
				conv=notrunc,fsync status=none
			;;
		amlogic)
			local aml_image="$uboot_dir/output/u-boot.bin.sd.bin"
			_require_artifact_fits "$aml_image" "$first_partition_bytes" \
				"signed Amlogic U-Boot image"
			dd if="$aml_image" of="$disk" bs=1 count=442 conv=notrunc,fsync status=none
			dd if="$aml_image" of="$disk" bs=512 skip=1 seek=1 conv=notrunc,fsync status=none
			;;
		stm32mp2)
			local atf_dir="$WORK_DIR/atf-src/build/stm32mp2/release"
			local fsbl="$atf_dir/tf-a-$board.stm32"
			local fip="$atf_dir/fip.bin"
			_require_artifact_fits "$fsbl" $((256 * 1024)) "STM32MP2 TF-A FSBL"
			_require_artifact_fits "$fip" $((4 * 1024 * 1024)) "STM32MP2 FIP"
			[[ -b "$stm32_fsbl_partition1" && -b "$stm32_fsbl_partition2" \
				&& -b "$stm32_fip_partition" ]] \
				|| die "STM32MP2 firmware partitions are unavailable."
			log_info "Installing redundant STM32MP2 FSBL copies and the non-FWU FIP"
			dd if="$fsbl" of="$stm32_fsbl_partition1" bs=1M conv=fsync status=none
			dd if="$fsbl" of="$stm32_fsbl_partition2" bs=1M conv=fsync status=none
			dd if="$fip" of="$stm32_fip_partition" bs=1M conv=fsync status=none
			;;
		*) die "Unsupported bootloader installation platform: $platform" ;;
	esac
}
