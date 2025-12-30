#!/bin/bash

if [ ! -z ${atf_url} ];then
    exit 2
fi

# https://github.com/ARM-software/arm-trusted-firmware

if [ ! -z ${atf_branch} ];then
    exit 2
fi

# lts-v2.10.26

if [ ! -z ${atf_plat} ];then
    exit 2
fi

# qemu
# STM: stm32mp1, stm32mp2
# Amlogic: axg, g12a, gxbb, gxl
# Allwinner: sun50i_a64, sun50i_h6, sun50i_h616, sun50i_r329

if [ ! -z ${atf_extra_config} ];then
    atf_extra_config=""
fi

# TF-A extra build options

fetch_atf(){
    if [ ! -d ${work_dir}/atf-src ];then
        git clone --depth=1 ${atf_url} -b ${atf_branch} ${work_dir}/atf-src
    fi
}

compile_atf(){
    pushd ${work_dir}/atf-src
    make ARCH=${arch} PLAT=${atf_plat} bl31 ${atf_extra_config}
    cp build/${atf_plat}/release/bl31.bin ${work_dir}
    popd
}

work_dir="$(pwd)/build"

source ${src_dir}/boards/${board}.config

#fetch_atf
#compile_atf
