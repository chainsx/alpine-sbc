#!/bin/bash

INSTALL_U_BOOT(){

    if [ "${platform}" == "rockchip64" ];then
        echo "Installing Rockchip U-Boot..."

        if [ -f ${uboot_dir}/idbloader.img ]; then
            dd if=${uboot_dir}/idbloader.img of=/dev/${loopX} seek=64
        else
            ERROR "u-boot idbloader file can not be found!"
            exit 2
        fi
    
        if [ -f ${uboot_dir}/u-boot.itb ]; then
            dd if=${uboot_dir}/u-boot.itb of=/dev/${loopX} seek=16384
        else
            ERROR "u-boot.itb file can not be found!"
            exit 2
        fi
        
    elif [ "${platform}" == "phytium" ];then
        echo "Installing Phytium U-Boot..."
        if [ -f ${uboot_dir}/fip-all-sd-boot.bin ]; then
            sfdisk --dump /dev/${loopX} > ${uboot_dir}/part.txt
            dd if=${uboot_dir}/fip-all-sd-boot.bin of=/dev/${loopX}
            sfdisk --no-reread /dev/${loopX} < ${uboot_dir}/part.txt
        else
            ERROR "phytium fip-all-sd-boot file can not be found!"
            exit 2
        fi
    elif [ "${platform}" == "allwinner" ];then
        echo "Installing Allwinner U-Boot..."
        if [ -f ${uboot_dir}/u-boot-sunxi-with-spl.bin ]; then
            dd if=${uboot_dir}/u-boot-sunxi-with-spl.bin of=/dev/${loopX} seek=8k
        else
            ERROR "allwinner u-boot file can not be found!"
            exit 2
        fi
    else
        echo "Unsupported platform"
    fi
}
