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
    elif [ "${platform}" == "amlogic" ];then
        echo "Installing Amlogic U-Boot..."
        if [ -f ${uboot_dir}/output/u-boot.bin.sd.bin ]; then
            dd if=${uboot_dir}/output/u-boot.bin.sd.bin of=/dev/${loopX} bs=1 count=442 conv=fsync
            dd if=${uboot_dir}/output/u-boot.bin.sd.bin of=/dev/${loopX} bs=512 skip=1 seek=1 conv=fsync
        else
            ERROR "amlogic u-boot file can not be found!"
            exit 2
        fi
    elif [ "${platform}" == "stm32mp2" ];then
        echo "Installing STM32MP2 U-Boot..."
        if [ -f ${work_dir}/atf-src/build/stm32mp2/release/fip.bin ]; then
            part_num=$(fdisk -l | grep "^/dev/${loopX}" | wc -l)

            echo "2048,2048" | sfdisk --no-reread --append /dev/${loopX}
            sgdisk -c $((part_num+1)):"fsbla" /dev/${loopX}
            echo "4096,8192" | sfdisk --no-reread --append /dev/${loopX}
            sgdisk -c $((part_num+2)):"fip" /dev/${loopX}
            echo "12288,2048" | sfdisk --no-reread --append /dev/${loopX}
            sgdisk -c $((part_num+3)):"u-boot-env" /dev/${loopX}
	
            dd if=${work_dir}/atf-src/build/stm32mp2/release/tf-a-${board}.stm32 of=/dev/${loopX} bs=512 seek=2048 conv=notrunc
            dd if=${work_dir}/atf-src/build/stm32mp2/release/fip.bin of=/dev/${loopX} bs=512 seek=4096 conv=notrunc
        else
            ERROR "stm32mp2 u-boot file can not be found!"
            exit 2
        fi
    else
        echo "Unsupported platform"
    fi
}
