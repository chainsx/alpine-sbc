#!/usr/bin/env bash

# shellcheck disable=SC2154 # Variables are supplied by scripts/mkimage.sh.
INSTALL_U_BOOT() {
	local disk="/dev/$loopX"
	case "$platform" in
		qemu)
			log_info "QEMU uses $uboot_dir/u-boot.bin as external firmware; no image write needed"
			;;
		rockchip64)
			[[ -f "$uboot_dir/idbloader.img" ]] || die "Missing Rockchip idbloader.img"
			[[ -f "$uboot_dir/u-boot.itb" ]] || die "Missing Rockchip u-boot.itb"
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
			[[ -f "$uboot_dir/u-boot-sunxi-with-spl.bin" ]] || die "Missing Allwinner U-Boot image"
			dd if="$uboot_dir/u-boot-sunxi-with-spl.bin" of="$disk" bs=1K seek=8 \
				conv=notrunc,fsync status=none
			;;
		amlogic)
			local aml_image="$uboot_dir/output/u-boot.bin.sd.bin"
			[[ -f "$aml_image" ]] || die "Missing signed Amlogic U-Boot image"
			dd if="$aml_image" of="$disk" bs=1 count=442 conv=notrunc,fsync status=none
			dd if="$aml_image" of="$disk" bs=512 skip=1 seek=1 conv=notrunc,fsync status=none
			;;
		stm32mp2)
			local atf_dir="$WORK_DIR/atf-src/build/stm32mp2/release"
			[[ -f "$atf_dir/fip.bin" ]] || die "Missing STM32MP2 fip.bin"
			[[ -f "$atf_dir/tf-a-$board.stm32" ]] || die "Missing STM32MP2 TF-A image"
			# The STM32MP2 raw firmware areas are reserved before the first
			# filesystem partition by mkimage (first partition begins at 16 MiB).
			dd if="$atf_dir/tf-a-$board.stm32" of="$disk" bs=512 seek=2048 \
				conv=notrunc,fsync status=none
			dd if="$atf_dir/fip.bin" of="$disk" bs=512 seek=4096 \
				conv=notrunc,fsync status=none
			;;
		*) die "Unsupported bootloader installation platform: $platform" ;;
	esac
}
