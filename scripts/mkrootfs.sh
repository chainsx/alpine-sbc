#!/bin/bash

__usage="
Usage: mkrootfs [OPTIONS]
Build Rootfs rootfs.
Run in root user.

Options: 
  --mirror MIRROR_ADDR         The URL/path of target mirror address.
  --rootfs ROOTFS_DIR          The directory name of rootfs rootfs.
  --version ROOTFS_VER         The version of alpine.
  --arch ROOTFS_ARCH
  --help                       Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    ROOTFS="rootfs"
    VERSION="3.22"
    ARCH="aarch64"
    MIRROR="https://dl-cdn.alpinelinux.org"
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
        elif [ "x$1" == "x-m" -o "x$1" == "x--mirror" ]; then
            MIRROR=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-r" -o "x$1" == "x--rootfs" ]; then
            ROOTFS=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--version" ]; then
            VERSION=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--arch" ]; then
            ARCH=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

get_minirootfs() {
    if [ ! -d ${ROOTFS} ];then
      mkdir $ROOTFS
    fi
    
    wget "${MIRROR}/alpine/v${VERSION}/releases/${ARCH}/alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz"
    
    tar -zxvf "alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz" \
    -C $ROOTFS
    
    rm "alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz"
}

init_rootfs() {
    cp -b /etc/resolv.conf ${ROOTFS}/etc/resolv.conf

    sed -i "s|https|http|g" ${ROOTFS}/etc/apk/repositories
    
    cat <<EOF | chroot ${ROOTFS} sh
apk update
apk add bash
EOF

}

install_pkgs(){
    chroot ${ROOTFS} apk add openrc openrc-bash-completion openrc-init
}

default_param
parseargs "$@" || help $?

get_minirootfs
init_rootfs
install_pkgs

