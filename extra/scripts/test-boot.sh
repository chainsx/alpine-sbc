#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=extra/scripts/../../scripts/libs/common.sh
source "$PROJECT_ROOT/scripts/libs/common.sh"

usage() {
	cat <<'EOF'
Usage: extra/scripts/test-boot.sh --board NAME [options]

Boot a built ARM64 image until the serial login prompt appears, timestamp the
console milestones, and stop QEMU. Results are saved below build/boot-tests.

Options:
  --board NAME       efi-arm64 or extlinux-arm64
  --firmware NAME    u-boot or edk2 (default: u-boot)
  --image FILE       Raw or .xz image (default: newest board image)
  --timeout SECONDS  Maximum wait for a login prompt (default: 90)
  -h, --help         Show this help
EOF
}

board_name=""
firmware="u-boot"
image_path=""
timeout_seconds=90

while (($#)); do
	case "$1" in
		--board | --firmware | --image | --timeout)
			require_arg_value "$1" "${2:-}"
			case "$1" in
				--board) board_name="$2" ;;
				--firmware) firmware="$2" ;;
				--image) image_path="$2" ;;
				--timeout) timeout_seconds="$2" ;;
			esac
			shift 2
			;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$board_name" ]] || die "--board is required."
[[ "$board_name" == efi-arm64 || "$board_name" == extlinux-arm64 ]] \
	|| die "Unsupported board: $board_name"
[[ "$firmware" == u-boot || "$firmware" == edk2 ]] \
	|| die "Unsupported firmware: $firmware"
[[ "$board_name" != extlinux-arm64 || "$firmware" == u-boot ]] \
	|| die "extlinux-arm64 requires U-Boot firmware."
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
	|| die "--timeout must be a positive integer."
require_commands mkfifo mktemp date kill mkdir rm sleep tee

run_script="$PROJECT_ROOT/extra/scripts/run-qemu.sh"
[[ -x "$run_script" ]] || die "QEMU launcher is missing: $run_script"

if [[ -z "$image_path" ]]; then
	candidates=()
	while IFS= read -r candidate; do
		candidates+=("$candidate")
	done < <(
		compgen -G "$WORK_DIR/output/alpine-${board_name}-*.img" || true
		compgen -G "$WORK_DIR/output/alpine-${board_name}-*.img.xz" || true
	)
	((${#candidates[@]} > 0)) || die "No image found for $board_name."
	image_path="${candidates[0]}"
	for candidate in "${candidates[@]:1}"; do
		[[ "$candidate" -nt "$image_path" ]] && image_path="$candidate"
	done
fi
[[ -f "$image_path" ]] || die "Image does not exist: $image_path"

test_dir="${BOOT_TEST_DIR:-$WORK_DIR/boot-tests}"
mkdir -p "$test_dir"
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
log_path="$test_dir/$board_name-$stamp.log"
summary_path="$test_dir/$board_name-$stamp.env"
tmp_dir="$(mktemp -d "$test_dir/.run.XXXXXX")"
export QEMU_DIR="${QEMU_DIR:-$tmp_dir/qemu}"
fifo="$tmp_dir/console"
mkfifo "$fifo"
qemu_pid=""
watchdog_pid=""
cleanup() {
	set +e
	[[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null
	[[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null
	rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

now_ms() { date +%s%3N; }
start_ms="$(now_ms)"
kernel_ms=""
login_ms=""

record_console_line() {
	local line="$1" line_ms relative_ms
	line="${line//$'\r'/}"
	[[ -n "$line" ]] || return 0
	line_ms="$(now_ms)"
	relative_ms=$((line_ms - start_ms))
	printf '[+%sms] %s\n' "$relative_ms" "$line" | tee -a "$log_path"
	if [[ -z "$kernel_ms" && "$line" == *"Linux version "* ]]; then
		kernel_ms="$relative_ms"
	fi
}

log_info "Starting $board_name boot test; console output: $log_path"
set +e
"$run_script" --board "$board_name" --firmware "$firmware" --image "$image_path" \
	>"$fifo" 2>&1 &
qemu_pid=$!
set -e

(
	sleep "$timeout_seconds"
	if kill -0 "$qemu_pid" 2>/dev/null; then
		kill "$qemu_pid" 2>/dev/null
	fi
) &
watchdog_pid=$!

: > "$log_path"
line=""
while IFS= read -r -N 1 char; do
	line+="$char"
	if [[ "$char" == $'\n' ]]; then
		record_console_line "$line"
		line=""
	fi
	# BusyBox getty prints its login prompt without a trailing newline.  Read
	# one character at a time so the test does not mistake a watchdog EOF for
	# a prompt that appeared only after QEMU was killed.
	if [[ "$line" == *" login:"* || "$line" =~ (^|[[:space:]])login:[[:space:]]*$ ]]; then
		login_ms="$(( $(now_ms) - start_ms ))"
		record_console_line "$line"
		break
	fi
done < "$fifo"
if [[ -n "$line" && -z "$login_ms" ]]; then
	record_console_line "$line"
fi

if [[ -n "$login_ms" ]]; then
	status=pass
	[[ -n "$kernel_ms" ]] || kernel_ms=-1
	log_info "Boot reached serial login in ${login_ms}ms (kernel output at ${kernel_ms}ms)"
	if kill -0 "$qemu_pid" 2>/dev/null; then
		kill "$qemu_pid" 2>/dev/null || true
	fi
else
	status=fail
	login_ms=-1
	[[ -n "$kernel_ms" ]] || kernel_ms=-1
	log_error "Serial login prompt did not appear within ${timeout_seconds}s"
fi

kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

cat > "$summary_path" <<EOF
BOARD=$board_name
FIRMWARE=$firmware
IMAGE=$image_path
STATUS=$status
KERNEL_OUTPUT_MS=$kernel_ms
LOGIN_PROMPT_MS=$login_ms
EOF

[[ "$status" == pass ]] || exit 1
