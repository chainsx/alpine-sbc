#!/bin/bash

board=$1

if [ -z $1 ];then
    exit 2
fi

src_dir=$(pwd)
source ${src_dir}/boards/${board}.config

apk add bash gcc g++ ncurses-dev flex binutils \
             gnutls-dev alpine-sdk abuild bison \
             openssl-dev perl coreutils losetup \
             parted sgdisk kpartx e2fsprogs lsblk rsync xz

bash scripts/mkbootloader.sh --board extlinux-arm64

bash scripts/mklinux.sh \
           --kernel_arch arm64 \
           --kernel_branch v6.12 \
           --kernel_config linux-generic-arm64-lts.config

bash scripts/libs/kernel-pkg.sh

bash scripts/mkrootfs.sh --rootfs ${src_dir}/build/rootfs --version 3.22 --arch aarch64

bash scripts/mkimage.sh --board extlinux-arm64
