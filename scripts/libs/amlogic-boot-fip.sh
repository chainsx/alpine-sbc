#!/usr/bin/env bash
# shellcheck disable=SC2154 # Contract: caller supplies work_dir.

[[ -n "${board:-}" ]] || die "Board name is required for Amlogic FIP generation."

AML_FIP_SOURCE_URL="https://github.com/LibreELEC/amlogic-boot-fip.git"
AML_FIP_SOURCE_VERSION="4e2848a9579e68afe015865309ea6df7096a50e5"

fetch_aml_fip() {
	local directory="$work_dir/amlogic-boot-fip"
	if [[ -d "$directory" ]]; then
		local revision
		revision="$(git -C "$directory" rev-parse HEAD 2>/dev/null || true)"
		if [[ "$revision" != "$AML_FIP_SOURCE_VERSION" ]]; then
			log_warn "Replacing Amlogic FIP checkout at unexpected revision"
			safe_remove_tree "$directory"
		fi
	fi
	if [[ ! -d "$directory" ]]; then
		log_info "Fetching pinned Amlogic FIP revision $AML_FIP_SOURCE_VERSION"
		git clone --filter=blob:none "$AML_FIP_SOURCE_URL" "$directory"
		git -C "$directory" -c advice.detachedHead=false checkout "$AML_FIP_SOURCE_VERSION"
	fi
}

mk_amlogic_fip() {
	local directory="$work_dir/amlogic-boot-fip"
	local output="$work_dir/u-boot/output"
	[[ -f "$work_dir/u-boot/u-boot.bin" ]] || die "U-Boot binary missing before Amlogic FIP generation."
	mkdir -p "$output"
	log_info "Generating signed Amlogic boot image for $board"
	"$directory/build-fip.sh" "$board" "$work_dir/u-boot/u-boot.bin" "$output"
	[[ -f "$output/u-boot.bin.sd.bin" ]] || die "Amlogic FIP generation did not produce u-boot.bin.sd.bin."
}
