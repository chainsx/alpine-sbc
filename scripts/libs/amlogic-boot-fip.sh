#!/bin/bash

if [ -z ${board} ];then
    exit 2
fi

AML_FIP_SOURCE_URL="https://github.com/LibreELEC/amlogic-boot-fip.git"
AML_FIP_SOURCE_VERSION="4e2848a9579e68afe015865309ea6df7096a50e5"

fetch_aml_fip(){
    if [ ! -d ${work_dir}/amlogic-boot-fip ];then
        git clone ${AML_FIP_SOURCE_URL} ${work_dir}/amlogic-boot-fip

        pushd ${work_dir}/amlogic-boot-fip
        git checkout ${AML_FIP_SOURCE_VERSION}
        popd
    else
        echo "amlogic-boot-fip source found, skip clone."
    fi
}

mk_amlogic_fip(){
    pushd ${work_dir}/amlogic-boot-fip
    mkdir -p ${work_dir}/u-boot/output
    ./build-fip.sh: ${board} ${work_dir}/u-boot/u-boot.bin ${work_dir}/u-boot/output
    popd
}