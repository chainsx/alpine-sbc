#!/usr/bin/env bash
# shellcheck disable=SC2154 # Contract: caller supplies work_dir, board, and jobs.

[[ -n "${atf_url:-}" ]] || die "Board configuration does not define atf_url."
[[ -n "${atf_branch:-}" ]] || die "Board configuration does not define atf_branch."
[[ -n "${atf_plat:-}" ]] || die "Board configuration does not define atf_plat."
atf_extra_config="${atf_extra_config:-}"
atf_directory="$work_dir/atf-src"
atf_patch_root="$PROJECT_ROOT/patches/atf/$atf_branch"
atf_source_state="$atf_directory/.alpine-sbc-source"
atf_expected_state="url=$atf_url
ref=$atf_branch
board=$board
config=$atf_extra_config
patches=$(tree_fingerprint "$atf_patch_root")"

apply_atf_patch_directory() {
	local directory="$1" patch
	[[ -d "$directory" ]] || return 0
	while IFS= read -r -d '' patch; do
		log_info "Applying TF-A patch: ${patch#"$PROJECT_ROOT"/}"
		git -C "$work_dir/atf-src" apply --whitespace=nowarn "$patch"
	done < <(find "$directory" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
}

patch_atf() {
	apply_atf_patch_directory "$atf_patch_root/generic/patches"
	copy_tree_contents "$atf_patch_root/generic/files" "$atf_directory"
	apply_atf_patch_directory "$atf_patch_root/$board/patches"
	copy_tree_contents "$atf_patch_root/$board/files" "$atf_directory"
	printf '%s\n' "$atf_expected_state" > "$atf_source_state"
	touch "$atf_directory/.patched"
}

fetch_atf() {
	if [[ -d "$atf_directory" ]] && { (( force_fetch )) \
		|| [[ ! -f "$atf_source_state" ]] \
		|| [[ "$(cat "$atf_source_state")" != "$atf_expected_state" ]]; }; then
		log_warn "Replacing cached TF-A source because its source, board, or build configuration changed"
		safe_remove_tree "$atf_directory"
	fi
	if [[ ! -d "$atf_directory" ]]; then
		log_info "Cloning TF-A '$atf_branch' from $atf_url"
		git clone --depth=1 --branch "$atf_branch" "$atf_url" "$atf_directory"
	else
		log_info "Using cached TF-A source: $atf_directory"
	fi
}

compile_atf() {
	log_info "Building TF-A for $atf_plat"
	# Board configuration values are trusted make assignments, intentionally split.
	# shellcheck disable=SC2086
	make -C "$atf_directory" -j"$jobs" ARCH=aarch64 PLAT="$atf_plat" $atf_extra_config
}

mk_stm32mp2_boot_fip() {
	local optee_build="$work_dir/optee-src/out/arm-plat-stm32mp2/core"
	local uboot_build="$work_dir/u-boot"
	local release_dir="$atf_directory/build/stm32mp2/release"
	local fiptool="$atf_directory/tools/fiptool/fiptool"
	local artifact
	for artifact in \
		"$optee_build/tee-header_v2.bin" \
		"$optee_build/tee-pager_v2.bin" \
		"$optee_build/tee-pageable_v2.bin" \
		"$uboot_build/u-boot-nodtb.bin" \
		"$uboot_build/u-boot.dtb"; do
		[[ -s "$artifact" ]] || die "STM32MP2 FIP input is missing: $artifact"
	done

	log_info "Generating STM32MP2 FIP"
	rm -f "$release_dir/fip.bin"
	make -C "$atf_directory" -j"$jobs" PLAT=stm32mp2 ARCH=aarch64 ARM_ARCH_MAJOR=8 \
		LOG_LEVEL=40 "DTB_FILE_NAME=$board.dtb" SPD=opteed STM32MP25=1 \
		PSA_FWU_SUPPORT=0 \
		"BL32=$optee_build/tee-header_v2.bin" \
		"BL32_EXTRA1=$optee_build/tee-pager_v2.bin" \
		"BL32_EXTRA2=$optee_build/tee-pageable_v2.bin" \
		"BL33=$uboot_build/u-boot-nodtb.bin" \
		"BL33_CFG=$uboot_build/u-boot.dtb" \
		STM32MP_SDMMC=1 STM32MP_LPDDR4_TYPE=1 all fip

	[[ -s "$release_dir/fip.bin" ]] || die "TF-A did not produce the STM32MP2 FIP."
	[[ -s "$release_dir/tf-a-$board.stm32" ]] \
		|| die "TF-A did not produce the STM32MP2 SD-card FSBL."
	[[ -x "$fiptool" ]] || die "TF-A fiptool was not built: $fiptool"
	"$fiptool" info "$release_dir/fip.bin" > "$release_dir/fip.info"
	for artifact in \
		'Secure Payload BL32 (Trusted OS)' \
		'Secure Payload BL32 Extra1 (Trusted OS Extra1)' \
		'Secure Payload BL32 Extra2 (Trusted OS Extra2)' \
		'Non-Trusted Firmware BL33'; do
		grep -Fq "$artifact" "$release_dir/fip.info" \
			|| die "STM32MP2 FIP is missing required payload: $artifact"
	done
	log_info "Validated STM32MP2 FIP payloads: $release_dir/fip.info"
}
