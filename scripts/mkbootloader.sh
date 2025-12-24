#!/bin/bash
set -e
set -x

__usage="
Usage: build_u-boot [OPTIONS]
Build u-boot image.

Options: 
  --board, BOARD_CONFIG     Required! The config of target board in the boards folder.
  -h, --help                Show command help.
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
    work_dir="$(pwd)/build"
    bootloader_url="https://github.com/u-boot/u-boot.git"
    log_dir=${work_dir}/log
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
            --help|-h)
                help 0
                ;;
            *)
                log_err "Unknown parameter: $1"
                help 2
                ;;
        esac
    done
}

buildid=$(date +%Y%m%d%H%M%S)
builddate=${buildid:0:8}

ERROR(){
    echo `date` - ERROR, $* | tee -a ${log_dir}/${builddate}.log
}

LOG(){
    echo `date` - INFO, $* | tee -a ${log_dir}/${builddate}.log
}



fetch_u-boot() {
    pushd ${work_dir}
    if [ -d ${work_dir}/u-boot ];then
        pushd ${work_dir}/u-boot
        remote_url_exist=`git remote -v | grep "origin"`
        remote_url=`git ls-remote --get-url origin`
        popd
        if [[ ${remote_url_exist} = "" || ${remote_url} != ${bootloader_url} ]]; then
            rm -rf ${work_dir}/u-boot
            git clone --depth=1 -b ${bootloader_branch} ${bootloader_url}
            if [[ $? -eq 0 ]]; then
                LOG "clone u-boot done."
            else
                ERROR "clone u-boot failed."
                exit 1
            fi
        fi
    else
        git clone --depth=1 -b ${bootloader_branch} ${bootloader_url}
        LOG "clone u-boot done."
    fi
    popd
}

patch_u-boot() {
    pushd ${work_dir}/u-boot

    if [ -d "${work_dir}/../patches/u-boot/${bootloader_branch}/generic/patches" ]; then
        log_info "Applying patches..."
        for patch in ${work_dir}/../patches/u-boot/${bootloader_branch}/generic/patches/*.patch; do
            log_info "Applying patch: $(basename $patch)"
            git apply "$patch"
        done
    else
        log_info "No patches directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/u-boot/${bootloader_branch}/generic/files" ]; then
        log_info "Applying files..."
        cp -r ${work_dir}/../patches/u-boot/${bootloader_branch}/generic/files/* .
    else
        log_info "No files directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/u-boot/${bootloader_branch}/${board}/patches" ]; then
        log_info "Applying patches..."
        for patch in ${work_dir}/../patches/u-boot/${bootloader_branch}/${board}/patches/*.patch; do
            log_info "Applying patch: $(basename $patch)"
            git apply "$patch"
        done
    else
        log_info "No patches directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/u-boot/${bootloader_branch}/${board}/files" ]; then
        log_info "Applying files..."
        cp -r ${work_dir}/../patches/u-boot/${bootloader_branch}/${board}/files/* .
    else
        log_info "No files directory found. Skipping patching."
    fi

    touch .patched
    
    popd
}

compile_u-boot() {
    pushd ${work_dir}/u-boot
    make ${bootloader_config}
    make ${uboot_extra_config} -j$(nproc)
    LOG "make u-boot done."
    popd

}

set -e
src_dir=$(pwd)
default_param
parseargs "$@" || help $?

if [ ! -d ${work_dir} ]; then
    mkdir ${work_dir}
fi

source ${src_dir}/boards/${board}.config

if [ ! -d ${log_dir} ];then mkdir -p ${log_dir}; fi

host_arch=$(arch)

if [[ "${host_arch}" == "x86_64" && "${arch}" == "arm64" ]];then
    LOG "You are running this script on a ${host_arch} mechine, use cross compile...."
    export CROSS_COMPILE="aarch64-linux-gnu-"
else
    LOG "You are running this script on a ${host_arch} mechine, progress...."
fi

if [[ ${atf_compile} == "no" && ${rkbin} == "yes" ]];then
    source ${src_dir}/scripts/libs/rkbin-version.sh
    fetch_rkbin

    uboot_extra_config="ROCKCHIP_TPL=${work_dir}/rkbin/${tpl_bin} BL31=${work_dir}/rkbin/${atf_bin}"
fi

if [[ ${atf_compile} == "yes" ]];then
    source ${src_dir}/scripts/libs/atf-compile.sh
    
    fetch_atf
    compile_atf
fi

LOG "build u-boot..."

fetch_u-boot

if [ ! -f ${work_dir}/u-boot/.patched ];then
    patch_u-boot
fi

compile_u-boot
