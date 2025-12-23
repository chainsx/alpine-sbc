#!/bin/bash
set -e
set -x

__usage="
Usage: gen_image [OPTIONS]
Generate bootable image.

Options: 
  -n, --name IMAGE_NAME         The image name to be built.
  --board BOARD_CONFIG          Required! The config of target board in the boards folder, which defaults to firefly-rk3399.
  -h, --help                    Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    work_dir=$src_dir/build
    outputdir=${work_dir}/output
    name=alpine-aarch64-alpha1
    board=extlinux-arm64
    platform=generic-arm64
    boot_size=128
    rootfs_dir=${work_dir}/rootfs
    boot_dir=${work_dir}/rootfs/boot
    uboot_dir=${work_dir}/u-boot
    boot_mnt=${work_dir}/boot_tmp
    root_mnt=${work_dir}/root_tmp
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

LOSETUP_D_IMG(){
    set +e
    if [ -d ${root_mnt} ]; then
        if grep -q "${root_mnt} " /proc/mounts ; then
            umount ${root_mnt}
        fi
    fi
    if [ -d ${boot_mnt} ]; then
        if grep -q "${boot_mnt} " /proc/mounts ; then
            umount ${boot_mnt}
        fi
    fi
    if [ -d ${rootfs_dir} ]; then
        if grep -q "${rootfs_dir} " /proc/mounts ; then
            umount ${rootfs_dir}
        fi
    fi
    if [ -d ${boot_dir} ]; then
        if grep -q "${boot_dir} " /proc/mounts ; then
            umount ${boot_dir}
        fi
    fi
    if [ "x$device" != "x" ]; then
        kpartx -d ${device}
        losetup -d ${device}
        device=""
    fi
    if [ -d ${root_mnt} ]; then
        rm -rf ${root_mnt}
    fi
    if [ -d ${boot_mnt} ]; then
        rm -rf ${boot_mnt}
    fi
    set -e
}

buildid=$(date +%Y%m%d%H%M%S)
builddate=${buildid:0:8}

ERROR(){
    echo `date` - ERROR, $* | tee -a ${log_dir}/${builddate}.log
}

LOG(){
    echo `date` - INFO, $* | tee -a ${log_dir}/${builddate}.log
}

gen_bootmode(){
    if [ ${boot_mode} == "extlinux" ];then
        echo "label Alpine
        kernel /Image
        initrd /initrd.img" \
        > ${root_mnt}/boot/extlinux/extlinux.conf

        if [ -z ${dtb_name} ];then
            echo "        fdt /${dtb_name}.dtb" >> ${root_mnt}/boot/extlinux/extlinux.conf
        fi
    
        echo "        append  ${bootargs}" >> ${root_mnt}/boot/extlinux/extlinux.conf
    elif [ ${boot_mode} == "grub" ];then
        echo "TODO"
    else
        ERROR "Unknown boot mode: ${boot_mode}"
        exit 2
    fi
}

make_img(){
    if [[ -d ${work_dir}/kernel-pkg ]];then
        LOG "kernel-pkg dir check done."
    else
        ERROR "kernel-pkg dir check failed, please re-run mklinux.sh."
        exit 2
    fi
    if [[ -d ${work_dir}/rootfs ]];then
        LOG "rootfs dir check done."
    else
        ERROR "rootfs dir check failed, please re-run mkrootfs.sh."
        exit 2
    fi

    device=""
    LOSETUP_D_IMG
    root_size=`du -sh --block-size=1MiB ${work_dir}/rootfs | cut -f 1 | xargs`
    kernel_size=`du -sh --block-size=1MiB ${work_dir}/kernel-pkg | cut -f 1 | xargs`
    size=$((${root_size}+${boot_size}+${kernel_size}+880))
    losetup -D
    img_file=${work_dir}/${name}.img
    LOG create ${img_file} size of ${size}MiB
    dd if=/dev/zero of=${img_file} bs=1MiB count=$size status=progress && sync

    LOG "create ${part_table} partition table."

    section1_start=32768
    section1_end=$((${section1_start}+(${boot_size}*2048)-1))

    parted ${img_file} mklabel ${part_table}
    parted ${img_file} mkpart primary fat32 ${section1_start}s ${section1_end}s
    parted ${img_file} -s set 1 boot on
    parted ${img_file} mkpart primary ext4 $(($section1_end+1))s 100%
    
    sgdisk -c 1:"bootfs" ${img_file}
    sgdisk -c 2:"rootfs" ${img_file}

    device=`losetup -f --show -P ${img_file}`
    LOG "after losetup: ${device}"
    trap 'LOSETUP_D_IMG' EXIT
    LOG "image ${img_file} created and mounted as ${device}"
    kpartx -va ${device}
    loopX=${device##*\/}
    partprobe ${device}

    bootp=/dev/mapper/${loopX}p1
    rootp=/dev/mapper/${loopX}p2
    LOG "make image partitions done."
    
    mkfs.vfat -n boot ${bootp}
    mkfs.ext4 -L rootfs ${rootp}
    LOG "make filesystems done."
    mkdir -p ${root_mnt} ${boot_mnt}
    mount -t vfat ${bootp} ${boot_mnt}
    mount -t ext4 ${rootp} ${root_mnt}

    rootfs_dir=${work_dir}/rootfs
    boot_dir=${work_dir}/rootfs/boot
    
    rsync -avHAXq ${rootfs_dir}/* ${root_mnt}
    sync
    sleep 10
    LOG "copy root done."

    cp ${work_dir}/*apk ${root_mnt}/kernel.apk
    chroot ${root_mnt} apk add --allow-untrusted /kernel.apk
    rm ${root_mnt}/kernel.apk
    
    chroot ${root_mnt} apk add dracut
    chroot ${root_mnt} dracut --no-kernel
    cp ${root_mnt}/boot/initramfs* ${root_mnt}/boot/initrd.img

    if [ ! -d ${root_mnt}/boot/extlinux ];then
        mkdir ${root_mnt}/boot/extlinux
    fi

    line=$(blkid | grep $rootp)
    uuid=${line#*UUID=\"}
    uuid=${uuid%%\"*}

    gen_bootmode

    if [ -n ${boot_size} ];then
        mv ${root_mnt}/boot/* ${boot_mnt} || LOG "${root_mnt}/boot is empty."
    fi

    umount $rootp
    umount $bootp
    
    INSTALL_U_BOOT
    
    LOG "install u-boot done."

    LOSETUP_D_IMG
    losetup -D
}

outputd(){
    if [ -d ${outputdir} ];then
        find ${outputdir} -name "${name}.img" -o -name "${name}.tar.gz" -o -name "${name}.img.xz" -delete
    else
        mkdir -p $outputdir
    fi
    mv ${work_dir}/${name}.img ${outputdir}
    LOG "xz image begin..."
    pushd $outputdir
    xz -T 20 ${name}.img
    if [ ! -f ${outputdir}/${name}.img.xz ]; then
        ERROR "xz image failed!"
        exit 2
    else
        LOG "xz image success."
    fi

    sha256sum ${name}.img.xz > ${name}.img.xz.sha256sum
    popd

    LOG "The target images: ${outputdir}/${name}.img.xz."
}

set -e
src_dir=$(pwd)
default_param
parseargs "$@" || help $?

if [ ! -d ${work_dir} ]; then
    mkdir ${work_dir}
fi

source ${src_dir}/boards/${board}.config
source ${src_dir}/scripts/libs/bootloader-install.sh

if [ ! -d ${log_dir} ];then mkdir -p ${log_dir}; fi

LOG "gen image..."
make_img
outputd
