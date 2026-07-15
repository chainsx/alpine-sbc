#!/usr/bin/env bash

# Boot filesystem generators. Variables such as KERNEL_FLAVOR, bootargs,
# dtb_name, initrd, and WORK_DIR are supplied by scripts/mkimage.sh.
# shellcheck disable=SC2154

generate_extlinux_config() {
	local directory="$1"
	mkdir -p "$directory/extlinux"
	{
		printf 'default Alpine\n'
		printf 'timeout 30\n\n'
		printf 'label Alpine\n'
		printf '  kernel /vmlinuz-%s\n' "$KERNEL_FLAVOR"
		if [[ "$initrd" == yes ]]; then
			printf '  initrd /initramfs-%s\n' "$KERNEL_FLAVOR"
		fi
		if [[ "$dtb_name" != none ]]; then
			printf '  fdt /dtbs-%s/%s.dtb\n' "$KERNEL_FLAVOR" "$dtb_name"
		fi
		printf '  append %s\n' "$bootargs"
	} > "$directory/extlinux/extlinux.conf"
}

generate_grub_config() {
	local directory="$1"
	mkdir -p "$directory/grub"
	{
		printf 'set default=0\n'
		printf 'set timeout=1\n\n'
		printf 'menuentry "Alpine Linux (%s)" {\n' "$KERNEL_FLAVOR"
		printf '    search --no-floppy --set=root --label bootfs\n'
		printf '    linux /vmlinuz-%s %s\n' "$KERNEL_FLAVOR" "$bootargs"
		if [[ "$initrd" == yes ]]; then
			printf '    initrd /initramfs-%s\n' "$KERNEL_FLAVOR"
		fi
		printf '}\n'
	} > "$directory/grub/grub.cfg"
}

generate_grub_early_config() {
	local path="$1"
	{
		printf 'search --no-floppy --set=root --label bootfs\n'
		# The GRUB variable must be evaluated by GRUB, not by this shell.
		# shellcheck disable=SC2016
		printf 'set prefix=($root)/grub\n'
	} > "$path"
}

install_grub_arm64_efi() {
	local directory="$1"
	local module_dir="${GRUB_ARM64_MODULE_DIR:-/usr/lib/grub/arm64-efi}"
	local early_config="$directory/grub/early.cfg"
	local fallback="$directory/EFI/BOOT/BOOTAA64.EFI"
	local named_loader="$directory/EFI/alpine/grubaa64.efi"
	local modules=(
		all_video disk part_gpt part_msdos linux normal configfile search
		search_label efi_gop fat iso9660 cat echo ls test true help gzio
	)
	local module

	[[ -d "$module_dir" ]] || die "GRUB arm64 EFI modules are missing: $module_dir"
	for module in "${modules[@]}"; do
		[[ -f "$module_dir/$module.mod" ]] \
			|| die "Required GRUB arm64 EFI module is missing: $module.mod"
	done

	mkdir -p "$directory/EFI/BOOT" "$directory/EFI/alpine" "$directory/grub"
	generate_grub_early_config "$early_config"
	log_info "Building ARM64 GRUB EFI loader"
	grub-mkimage \
		--config="$early_config" \
		--directory="$module_dir" \
		--prefix=/grub \
		--output="$fallback" \
		--format=arm64-efi \
		--compression=xz \
		"${modules[@]}"
	[[ -s "$fallback" ]] || die "GRUB did not produce $fallback"
	cp "$fallback" "$named_loader"
	log_info "Installed EFI loaders: EFI/BOOT/BOOTAA64.EFI and EFI/alpine/grubaa64.efi"
}
