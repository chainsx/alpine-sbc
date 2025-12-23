#!/bin/bash
set -x

__usage="
Usage: build.sh --board <board> --version <version>
Build Alpine Linux.

Options:
  --board <board>  --version <version>

Run as root or with sudo if necessary for packaging permissions.
"

help()
{
    echo "$__usage"
    exit $1
}

log_info() { echo -e "\033[32m[INFO] $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $1\033[0m"; }
log_err() { echo -e "\033[31m[ERR] $1\033[0m"; }

default_param() {
    board="extlinux-arm64"
    version="3.22.0"
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        case "$1" in
            --board)
                board="$2"
                shift 2
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            *)
                log_err "Unknown parameter: $1"
                help 2
                ;;
        esac
    done
}

default_param
parseargs "$@" || help $?

src_dir=$(pwd)
source ${src_dir}/boards/${board}.config

apk add bash gcc g++ ncurses-dev flex binutils \
             gnutls-dev alpine-sdk abuild bison \
             openssl-dev perl coreutils losetup \
             parted sgdisk kpartx e2fsprogs lsblk \
             rsync xz python3 py3-setuptools swig \
             python3-dev py3-elftools

bash scripts/mkbootloader.sh --board ${board}

bash scripts/mklinux.sh \
           --kernel_arch ${arch} \
           --kernel_branch ${kernel_branch} \
           --kernel_config ${kernel_config}

bash scripts/libs/kernel-pkg.sh

bash scripts/mkrootfs.sh --rootfs ${src_dir}/build/rootfs \
                         --version ${version} --arch ${rootfs_arch}

bash scripts/mkimage.sh --board ${board}
