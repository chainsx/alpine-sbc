#!/usr/bin/env bash
# shellcheck disable=SC2154 # Contract: caller supplies work_dir and jobs.

[[ -n "${optee_url:-}" ]] || die "Board configuration does not define optee_url."
[[ -n "${optee_branch:-}" ]] || die "Board configuration does not define optee_branch."

optee_extra_config="${optee_extra_config:-}"

fetch_optee() {
	local directory="$work_dir/optee-src"
	if [[ ! -d "$directory" ]]; then
		log_info "Cloning OP-TEE '$optee_branch' from $optee_url"
		git clone --depth=1 --branch "$optee_branch" "$optee_url" "$directory"
	else
		log_info "Using cached OP-TEE source: $directory"
	fi
}

compile_optee() {
	local tool_dir="$work_dir/toolchain-links"
	mkdir -p "$tool_dir"
	local tool
	for tool in cpp objcopy ar ld.bfd objdump nm readelf; do
		[[ -x "/usr/bin/$tool" ]] || die "Required OP-TEE tool is missing: /usr/bin/$tool"
		ln -sfn "/usr/bin/$tool" "$tool_dir/aarch64-alpine-linux-musl-$tool"
	done
	[[ -x /usr/bin/gcc ]] || die "Required OP-TEE tool is missing: /usr/bin/gcc"
	ln -sfn /usr/bin/gcc "$tool_dir/aarch64-alpine-linux-musl-gcc"

	log_info "Building OP-TEE"
	# Board configuration values are trusted make assignments, intentionally split.
	# shellcheck disable=SC2086
	PATH="$PATH:$tool_dir" make -C "$work_dir/optee-src" -j"$jobs" ARCH=arm \
		CROSS_COMPILE_core=aarch64-alpine-linux-musl- \
		CROSS_COMPILE_ta_arm64=aarch64-alpine-linux-musl- \
		$optee_extra_config
}
