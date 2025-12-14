#!/bin/bash

src_dir=$(pwd)
source ${src_dir}/boards/${board}.config

bash scripts/mkbootloader.sh --board extlinux-arm64

bash scripts/mklinux.sh \
           --kernel_arch arm64 \
           --kernel_branch v6.12 \
           --kernel_config linux-generic-arm64-lts.config

bash scripts/mkrootfs.sh --rootfs ${src_dir}/build/rootfs --version 3.22 --arch aarch64

bash scripts/mkimage.sh --board extlinux-arm64
