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
        if [ "x$1" == "x-h" -o "x$1" == "x--help" ]; then
            return 1
        elif [ "x$1" == "x" ]; then
            shift
        elif [ "x$1" == "x--board" ]; then
            board=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
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

compile_u-boot() {
    pushd ${work_dir}/u-boot
    if [[ -f ${work_dir}/u-boot/u-boot.bin ]];then
        LOG "u-boot is the latest"
    else
        make ${bootloader_config}
        make -j$(nproc)
        make ${uboot_extra_config} -j$(nproc)
        LOG "make u-boot done."
    fi
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

if [ ! -z ${uboot_extra_config} ];then
    uboot_extra_config=""
fi

if [[ ${atf_compile} == "no" && ${rkbin} == "yes" ]];then
    source ${src_dir}/scripts/libs/rkbin-version.sh
    
    fetch_rkbin
fi

if [[ ${atf_compile} == "yes" ]];then
    source ${src_dir}/scripts/libs/atf-compile.sh
    
    fetch_atf
    compile_atf
fi

LOG "build u-boot..."

fetch_u-boot
compile_u-boot
