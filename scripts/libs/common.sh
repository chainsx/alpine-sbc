#!/usr/bin/env bash

# Shared helpers for all alpine-sbc entry points.  Do not enable shell options
# here: this file is also sourced by small board-support libraries.

if [[ -n "${ALPINE_SBC_COMMON_LOADED:-}" ]]; then
	return 0
fi
readonly ALPINE_SBC_COMMON_LOADED=1

if [[ -z "${PROJECT_ROOT:-}" ]]; then
	PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/build}"
LOG_DIR="${LOG_DIR:-$WORK_DIR/log}"

_color_enabled=0
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	_color_enabled=1
fi

_log() {
	local level="$1" color="$2"
	shift 2
	if (( _color_enabled )); then
		printf '\033[%sm[%s] %s %s\033[0m\n' "$color" "$level" \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
	else
		printf '[%s] %s %s\n' "$level" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
	fi
}

log_info() { _log INFO 32 "$@"; }
log_warn() { _log WARN 33 "$@"; }
log_error() { _log ERROR 31 "$@"; }
log_debug() {
	[[ "${ALPINE_SBC_DEBUG:-0}" == 1 ]] || return 0
	_log DEBUG 36 "$@"
}

die() {
	log_error "$*"
	exit 1
}

init_logging() {
	local stage="${1:-build}"
	mkdir -p "$LOG_DIR"
	if [[ -z "${ALPINE_SBC_LOG_FILE:-}" ]]; then
		ALPINE_SBC_LOG_FILE="$LOG_DIR/${stage}-$(date -u '+%Y%m%dT%H%M%SZ').log"
		export ALPINE_SBC_LOG_FILE
		exec > >(tee -a "$ALPINE_SBC_LOG_FILE") 2>&1
	fi
	log_info "Log file: $ALPINE_SBC_LOG_FILE"
}

_handle_error() {
	local rc="$1" line="$2" command="$3"
	log_error "Command failed (exit $rc) at ${BASH_SOURCE[1]}:$line: $command"
	exit "$rc"
}

enable_error_trap() {
	trap '_handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

require_root() {
	(( EUID == 0 )) || die "This operation requires root privileges (run with sudo)."
}

normalize_arch() {
	case "$1" in
		aarch64 | arm64) printf '%s\n' arm64 ;;
		x86_64 | amd64) printf '%s\n' x86_64 ;;
		*) printf '%s\n' "$1" ;;
	esac
}

apk_arch_for_kernel_arch() {
	case "$1" in
		arm64 | aarch64) printf '%s\n' aarch64 ;;
		*) printf '%s\n' "$1" ;;
	esac
}

require_alpine_arm64_host() {
	[[ -r /etc/os-release ]] || die "Cannot identify the host operating system."
	local id
	# shellcheck disable=SC1091
	id="$(. /etc/os-release; printf '%s' "${ID:-}")"
	[[ "$id" == alpine ]] || die "The supported build host is Alpine Linux; detected '$id'."
	local host_arch
	host_arch="$(normalize_arch "$(uname -m)")"
	[[ "$host_arch" == arm64 ]] || die "The supported build host architecture is arm64; detected '$host_arch'."
}

require_commands() {
	local cmd missing=()
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}"
}

require_arg_value() {
	local option="$1" value="${2:-}"
	[[ -n "$value" && "$value" != --* ]] || die "Option $option requires a value."
}

validate_board_name() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid board name: $1"
}

derive_kernel_flavor() {
	local name="$1"
	name="${name,,}"
	name="${name//_/-}"
	name="${name//./-}"
	name="${name//[^a-z0-9-]/-}"
	while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
	printf 'sbc-%s\n' "${name#-}"
}

load_board_config() {
	local requested_board="$1"
	validate_board_name "$requested_board"
	local config="$PROJECT_ROOT/boards/$requested_board.config"
	[[ -f "$config" ]] || die "Board configuration not found: $config"
	board="$requested_board"
	# shellcheck disable=SC1090
	source "$config"
	kernel_flavor="${kernel_flavor:-$(derive_kernel_flavor "$board")}"
	kernel_pkgrel="${kernel_pkgrel:-0}"
	log_info "Loaded board configuration: $board ($config)"
}

require_board_variables() {
	local name missing=()
	for name in "$@"; do
		[[ -n "${!name:-}" ]] || missing+=("$name")
	done
	((${#missing[@]} == 0)) || die "Board '$board' is missing required settings: ${missing[*]}"
}

safe_remove_tree() {
	local path="$1"
	[[ -n "$path" && "$path" == "$WORK_DIR"/* && "$path" != "$WORK_DIR" ]] \
		|| die "Refusing to remove unsafe path: $path"
	rm -rf -- "$path"
}

tree_fingerprint() {
	local path="$1"
	if [[ ! -d "$path" ]]; then
		printf '%s\n' none
		return
	fi
	find "$path" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null \
		| sha256sum | awk '{print $1}'
}

copy_tree_contents() {
	local source_dir="$1" destination_dir="$2"
	[[ -d "$source_dir" ]] || return 0
	mkdir -p "$destination_dir"
	cp -a "$source_dir"/. "$destination_dir"/
}
