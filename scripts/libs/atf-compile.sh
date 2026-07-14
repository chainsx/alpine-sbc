#!/usr/bin/env bash
# shellcheck disable=SC2154 # Contract: caller supplies work_dir, board, and jobs.

[[ -n "${atf_url:-}" ]] || die "Board configuration does not define atf_url."
[[ -n "${atf_branch:-}" ]] || die "Board configuration does not define atf_branch."
[[ -n "${atf_plat:-}" ]] || die "Board configuration does not define atf_plat."
atf_extra_config="${atf_extra_config:-}"

apply_atf_patch_directory() {
	local directory="$1" patch
	[[ -d "$directory" ]] || return 0
	while IFS= read -r -d '' patch; do
		log_info "Applying TF-A patch: ${patch#"$PROJECT_ROOT"/}"
		git -C "$work_dir/atf-src" apply --whitespace=nowarn "$patch"
	done < <(find "$directory" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
}

patch_atf() {
	local patch_root="$PROJECT_ROOT/patches/atf/$atf_branch"
	apply_atf_patch_directory "$patch_root/generic/patches"
	copy_tree_contents "$patch_root/generic/files" "$work_dir/atf-src"
	apply_atf_patch_directory "$patch_root/$board/patches"
	copy_tree_contents "$patch_root/$board/files" "$work_dir/atf-src"
	touch "$work_dir/atf-src/.patched"
}

fetch_atf() {
	if [[ ! -d "$work_dir/atf-src" ]]; then
		log_info "Cloning TF-A '$atf_branch' from $atf_url"
		git clone --depth=1 --branch "$atf_branch" "$atf_url" "$work_dir/atf-src"
	else
		log_info "Using cached TF-A source: $work_dir/atf-src"
	fi
}

compile_atf() {
	log_info "Building TF-A for $atf_plat"
	# Board configuration values are trusted make assignments, intentionally split.
	# shellcheck disable=SC2086
	make -C "$work_dir/atf-src" -j"$jobs" ARCH=aarch64 PLAT="$atf_plat" $atf_extra_config
}

mk_stm32mp2_boot_fip() {
	log_info "Generating STM32MP2 FIP"
	make -C "$work_dir/atf-src" -j"$jobs" PLAT=stm32mp2 ARCH=aarch64 ARM_ARCH_MAJOR=8 \
		LOG_LEVEL=40 "DTB_FILE_NAME=$board.dtb" SPD=opteed STM32MP25=1 \
		"BL32=$work_dir/optee-src/out/arm-plat-stm32mp2/core/tee-header_v2.bin" \
		"BL32_EXTRA1=$work_dir/optee-src/out/arm-plat-stm32mp2/core/tee-pager_v2.bin" \
		"BL32_EXTRA2=$work_dir/optee-src/out/arm-plat-stm32mp2/core/tee-pageable_v2.bin" \
		"BL33=$work_dir/u-boot/u-boot-nodtb.bin" \
		"BL33_CFG=$work_dir/u-boot/u-boot.dtb" \
		STM32MP_SDMMC=1 STM32MP_LPDDR4_TYPE=1 all fip
}
