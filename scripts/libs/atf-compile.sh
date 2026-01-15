#!/bin/bash

if [ -z ${atf_url} ];then
    exit 2
fi

# https://github.com/ARM-software/arm-trusted-firmware

if [ -z ${atf_branch} ];then
    exit 2
fi

# lts-v2.10.26

if [ -z ${atf_plat} ];then
    exit 2
fi

# qemu
# STM: stm32mp1, stm32mp2
# Allwinner: sun50i_a64, sun50i_h6, sun50i_h616, sun50i_r329

if [ -z ${atf_extra_config} ];then
    atf_extra_config=""
fi

# TF-A extra build options

patch_atf() {
    pushd ${work_dir}/atf-src

    if [ -d "${work_dir}/../patches/atf/${atf_branch}/generic/patches" ]; then
        log_info "Applying patches..."
        for patch in ${work_dir}/../patches/atf/${atf_branch}/generic/patches/*.patch; do
            log_info "Applying patch: $(basename $patch)"
            git apply "$patch"
        done
    else
        log_info "No patches directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/atf/${atf_branch}/generic/files" ]; then
        log_info "Applying files..."
        cp -r ${work_dir}/../patches/atf/${atf_branch}/generic/files/* .
    else
        log_info "No files directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/atf/${atf_branch}/${board}/patches" ]; then
        log_info "Applying patches..."
        for patch in ${work_dir}/../patches/atf/${atf_branch}/${board}/patches/*.patch; do
            log_info "Applying patch: $(basename $patch)"
            git apply "$patch"
        done
    else
        log_info "No patches directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/atf/${atf_branch}/${board}/files" ]; then
        log_info "Applying files..."
        cp -r ${work_dir}/../patches/atf/${atf_branch}/${board}/files/* .
    else
        log_info "No files directory found. Skipping patching."
    fi

    touch .patched
    
    popd
}

fetch_atf(){
    if [ ! -d ${work_dir}/atf-src ];then
        git clone --depth=1 ${atf_url} -b ${atf_branch} ${work_dir}/atf-src
    fi
}

compile_atf(){
    pushd ${work_dir}/atf-src
    make -j$(nproc) ARCH=aarch64 PLAT=${atf_plat} ${atf_extra_config}
    #cp build/${atf_plat}/release/bl31.bin ${work_dir}
    popd
}

mk_stm32mp2_boot_fip(){
    pushd ${work_dir}/atf-src
    make -j$(nproc) PLAT=stm32mp2 ARCH=aarch64 ARM_ARCH_MAJOR=8 \
    LOG_LEVEL=40 DTB_FILE_NAME=${board}.dtb \
    SPD=opteed STM32MP25=1 \
	BL32=${work_dir}/optee-src/out/arm-plat-stm32mp2/core/tee-header_v2.bin \
	BL32_EXTRA1=${work_dir}/optee-src/out/arm-plat-stm32mp2/core/tee-pager_v2.bin \
	BL32_EXTRA2=${work_dir}/optee-src/out/arm-plat-stm32mp2/core/tee-pageable_v2.bin \
	BL33=${work_dir}/u-boot/u-boot-nodtb.bin \
	BL33_CFG=${work_dir}/u-boot/u-boot.dtb \
	STM32MP_SDMMC=1 STM32MP_LPDDR4_TYPE=1 all fip
    popd
}

work_dir="$(pwd)/build"

source ${src_dir}/boards/${board}.config

#fetch_atf
#compile_atf
