#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# A user added to the docker group must start a new login session before the
# supplementary group appears in `id`.  Make the entrypoint usable immediately
# while keeping the normal direct-docker path unchanged.
if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
	if getent group docker 2>/dev/null | cut -d: -f4 \
		| grep -Eq "(^|,)$(id -un)(,|$)" \
		&& ! id -nG | tr ' ' '\n' | grep -Fxq docker; then
		command_line="$(printf '%q ' "$PROJECT_ROOT/extra/scripts/run-build-container.sh" "$@")"
		exec sg docker -c "$command_line"
	fi
fi

usage() {
	cat <<'EOF'
Usage: extra/scripts/run-build-container.sh [container options] [build.sh options]

Run the ARM64 build inside the matching Alpine Docker image.  The container is
always privileged because image creation needs loop devices and mounts.

Container options:
  --alpine-version VERSION  Alpine image and rootfs version (default: 3.23.0)
  --platform PLATFORM        Docker platform (default: linux/arm64)
  -h, --help                 Show this help

Examples:
  extra/scripts/run-build-container.sh --board extlinux-arm64
  extra/scripts/run-build-container.sh --alpine-version 3.23.0 \
    --board efi-arm64 --jobs 4
EOF
}

alpine_version=3.23.0
docker_platform="${DOCKER_PLATFORM:-linux/arm64}"
build_args=()
requested_build_version=""

while (($#)); do
	case "$1" in
		--alpine-version)
			[[ -n "${2:-}" && "$2" != --* ]] \
				|| { printf 'ERROR: --alpine-version requires a value.\n' >&2; exit 2; }
			alpine_version="$2"
			shift 2
			;;
		--platform)
			[[ -n "${2:-}" && "$2" != --* ]] \
				|| { printf 'ERROR: --platform requires a value.\n' >&2; exit 2; }
			docker_platform="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--version)
			[[ -n "${2:-}" && "$2" != --* ]] \
				|| { printf 'ERROR: --version requires a value.\n' >&2; exit 2; }
			requested_build_version="$2"
			build_args+=("$1" "$2")
			shift 2
			;;
		*)
			build_args+=("$1")
			shift
			;;
	esac
done

[[ "$alpine_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { printf 'ERROR: invalid Alpine version: %s\n' "$alpine_version" >&2; exit 2; }
if [[ -n "$requested_build_version" && "$requested_build_version" != "$alpine_version" ]]; then
	printf 'ERROR: build version %s must match --alpine-version %s.\n' \
		"$requested_build_version" "$alpine_version" >&2
	exit 2
fi
if [[ -z "$requested_build_version" ]]; then
	build_args+=(--version "$alpine_version")
fi

command -v docker >/dev/null 2>&1 \
	|| { printf 'ERROR: docker is required.\n' >&2; exit 1; }

image="alpine:$alpine_version"
printf '[INFO] Pulling %s for %s\n' "$image" "$docker_platform" >&2
docker pull --platform "$docker_platform" "$image"

# The initial shell only installs bash so that build.sh can install and check
# the complete Alpine toolchain itself.  The repository is mounted at the
# same path in every invocation, so build/ remains reusable between stages.
exec docker run --rm --privileged --network=host \
	--platform "$docker_platform" \
	--workdir /work \
	--mount "type=bind,src=$PROJECT_ROOT,dst=/work" \
	-e ALPINE_SBC_CONTAINER=1 \
	"$image" /bin/sh -ec '
	apk add --no-cache bash ca-certificates
	exec /work/build.sh "$@"
' build-container "${build_args[@]}"
