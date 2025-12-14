#!/bin/bash

if [[ boot_mode != "extlinux" ]];then
    exit 2
fi

gen_extlinux(){
    echo "output file is: $1"

    echo "label linux-lts" >> $1

    if [ -z ${fdt_file} ];then
        echo "    fdt /${fdt_file}.dtb" >> $1
    fi
    
    if [[ ${use_initrd} == "yes" ]];then
        echo "    initrd /initrd.img" >> $1
    fi
    
    echo "    append  ${bootargs}" >> $1

}
